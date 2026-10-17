defmodule OpenResults.Stats.Viewers do
  @moduledoc """
  Real numbers for the admin stats page: unique readers per day, page views,
  bot hits and refreshes, overall and per tournament, with a history that
  outlives a restart.

  `OpenResults.Stats` answers "how busy is the server"; this answers "how many
  people actually read it", which needs a way to tell one reader from another
  without remembering who they are.

  ## Telling readers apart without knowing them

  A reader is the keyed hash of their client address, their user agent and
  the day, under a secret salt drawn fresh for each day. The address is the
  one `OpenResultsWeb.ClientAddress` already trusts (Cloudflare's
  `cf-connecting-ip` when the request really came through the proxy on this
  box). Plausible does it the same way, and the properties are the same:

    * no cookie, nothing stored on the reader's side;
    * the address and the user agent are hashed in the request process and
      go no further; only the first 8 bytes of the hash are kept;
    * the salt exists only in memory. At the first request of a new day it is
      replaced, and the old one is gone for good - so yesterday's hashes can
      no longer be recomputed from anybody's address, by anyone, and the same
      reader on two days is two unrelated hashes;
    * hashes are held in memory for their own day and dropped when the day
      ends. They are never written to the database.

  What reaches the database is arithmetic: per day, how many different
  hashes were seen, how many page views, bot hits and refreshes, and the
  same two figures per tournament. A restart forgets the hashes and the
  salt, so a reader who comes back after a restart on the same day is counted
  once more; the totals are added to what is stored, never replaced. That
  overcount is small, rare, and the price of not writing hashes anywhere.

  Per-tournament uniques are counted per tournament, so one reader who
  looked at three tournaments is one of the day's readers and one of each of
  the three. Added up over several days, a tournament's figure is "reader
  days", not people: the same person on Monday and Tuesday is two.

  ## What is a real page view

  A GET on a public route (not static assets, not the API, not the admin
  panel) that answered 2xx or 304 with an HTML document, from a user agent
  that is not obviously a program and is not a refresher's poll. Programs -
  empty user agents, anything calling itself a bot, crawler, spider or link
  preview, command-line and library clients - are counted as bot hits
  instead, whatever they asked for, so the gap between the two is visible.
  Polls (`x-openresults-refresh`, or any `Sec-Fetch-Mode` but `navigate`)
  are counted as refreshes, as `OpenResultsWeb.StatsTelemetry` already does
  per tournament.

  ## The cost

  Everything on the request path is ETS: one `update_counter` for a bot hit
  or a refresh, and for a view one HMAC, one or two `insert_new` and the
  counters. No process is called and nothing touches the database. Past
  `seen_cap/0` remembered hashes, views are still counted but no new reader
  is, which bounds the memory however hostile the traffic.

  The server flushes the counters to the database every minute and when a day
  ends, as deltas that are added to the stored row; a failed write keeps the
  deltas for the next try. Rows older than `retention_days/0` are deleted.

  ## Table layout

  | row | meaning |
  |---|---|
  | `{:salt, day, key}` | the current salt; replaced atomically by the first request of a later day |
  | `{{:day, day}, unique, views, bots, refreshes}` | counters not yet flushed |
  | `{{:slug, day, slug}, unique, views}` | a tournament's counters not yet flushed |
  | `{{:seen, day, hash}}`, `{{:seen, day, slug, hash}}` | hashes already counted that day |

  `day` is whole days since the Unix epoch, UTC.
  """

  use GenServer

  import Ecto.Query

  alias OpenResults.Repo
  alias OpenResults.Stats.TrafficDay
  alias OpenResults.Stats.TrafficTournamentDay

  require Logger

  @table :openresults_viewers
  @seen_cap 1_000_000
  @retention_days 400
  @flush_ms :timer.minutes(1)
  @chunk 400

  # Substrings of a lowercased user agent that mean "a program". Deliberately
  # a list of what is common rather than a promise: a scraper that dresses as
  # a browser is a browser as far as anything here can tell.
  @bot_markers ~w(bot crawl spider slurp preview curl/ wget python httpx aiohttp requests/ go-http
                  java/ okhttp libwww httpclient node-fetch axios scrapy postman headless
                  phantomjs lighthouse pingdom uptime monitor facebookexternalhit whatsapp
                  telegram discord mastodon feedfetcher feedly validator checker scanner
                  archive.org ia_archiver mediapartners)

  def table, do: @table
  def seen_cap, do: @seen_cap
  def retention_days, do: @retention_days

  ## ---------- the process ----------

  @doc """
  Options: `:name` (default this module, `nil` for none), `:table`, `:clock`
  (zero-arity, Unix seconds), `:flush` (milliseconds, or `:manual`).
  """
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Writes the unflushed counters to the database now. `:ok`, or `:error` when it could not."
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush, 30_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    table = Keyword.get(opts, :table, @table)

    :ets.new(table, [:set, :public, :named_table, write_concurrency: true, read_concurrency: true])

    state = %{
      table: table,
      clock: Keyword.get(opts, :clock, fn -> System.os_time(:second) end),
      flush: Keyword.get(opts, :flush, @flush_ms)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:flush, _from, state),
    do: {:reply, flush_table(state.table, today(state)), state}

  @impl true
  def handle_info(:flush, state) do
    flush_table(state.table, today(state))
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    flush_table(state.table, today(state))
    :ok
  end

  defp schedule(%{flush: :manual}), do: :ok
  defp schedule(%{flush: ms}), do: Process.send_after(self(), :flush, ms)

  defp today(state), do: div(state.clock.(), 86_400)

  ## ---------- recording: the request path ----------

  @doc "Whole days since the Unix epoch, UTC: the day a request arriving now belongs to."
  def day_now, do: div(System.os_time(:second), 86_400)

  @doc "A day number as a `Date`."
  def to_date(day), do: Date.add(~D[1970-01-01], day)

  @doc "Whether a user agent is, as far as it can be told, a program."
  @spec bot?(String.t() | nil) :: boolean()
  def bot?(nil), do: true
  def bot?(""), do: true

  def bot?(agent) when is_binary(agent),
    do: :binary.match(String.downcase(agent), @bot_markers) != :nomatch

  @doc """
  Sorts one finished request into the day's counters. Called for the public
  route group only; see the moduledoc for the rules. Never raises.
  """
  def observe(conn), do: observe(@table, day_now(), conn)

  @doc false
  def observe(table, day, %Plug.Conn{method: "GET"} = conn) do
    agent = header(conn, "user-agent")

    cond do
      bot?(agent) -> count_bot(table, day)
      refresh?(conn) -> if counted_status?(conn.status), do: count_refresh(table, day)
      counted_status?(conn.status) and html?(conn) -> view(table, day, conn, agent)
      true -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  def observe(_table, _day, _conn), do: :ok

  @doc "Counts one bot hit."
  def count_bot(table, day), do: bump(table, {:day, day}, [{4, 1}], 5)

  @doc "Counts one refresh."
  def count_refresh(table, day), do: bump(table, {:day, day}, [{5, 1}], 5)

  @doc """
  Counts one real page view by the reader behind `address` (text) and
  `agent`, on a tournament's page when `slug` is given.
  """
  def count_view(table, day, address, agent, slug \\ nil) do
    {day, salt} = salt(table, day)
    hash = hash(salt, day, address, agent)
    room? = :ets.info(table, :size) < @seen_cap

    new? = room? and :ets.insert_new(table, {{:seen, day, hash}})
    bump(table, {:day, day}, if(new?, do: [{3, 1}, {2, 1}], else: [{3, 1}]), 5)

    if slug do
      new_here? = room? and :ets.insert_new(table, {{:seen, day, slug, hash}})
      bump(table, {:slug, day, slug}, if(new_here?, do: [{3, 1}, {2, 1}], else: [{3, 1}]), 3)
    end

    :ok
  end

  @doc "The reader code for this address and agent on `day`: what `count_view/5` remembers."
  def reader(table, day, address, agent) do
    {day, salt} = salt(table, day)
    hash(salt, day, address, agent)
  end

  defp view(table, day, conn, agent) do
    slug =
      case {conn.assigns, conn.path_params} do
        {%{tournament_visibility: visibility}, %{"slug" => slug}}
        when visibility in [:pending, :listed] and is_binary(slug) ->
          slug

        _other ->
          nil
      end

    address = conn |> OpenResultsWeb.ClientAddress.of() |> :inet.ntoa() |> List.to_string()
    count_view(table, day, address, agent, slug)
  end

  defp hash(salt, day, address, agent) do
    :hmac
    |> :crypto.mac(:sha256, salt, [address, 0, agent, 0, <<day::32>>])
    |> binary_part(0, 8)
  end

  # The salt for `day`. The first request of a later day replaces the stored
  # one in a single atomic step, so two racing requests cannot each draw
  # their own; a request that finds a LATER salt than its clock (a day
  # boundary crossed mid-request) is simply filed under that later day.
  defp salt(table, day) do
    case :ets.lookup(table, :salt) do
      [{:salt, ^day, key}] ->
        {day, key}

      [{:salt, stored, key}] when stored > day ->
        {stored, key}

      [{:salt, _older, _key}] ->
        fresh = {:salt, day, :crypto.strong_rand_bytes(32)}

        :ets.select_replace(table, [
          {{:salt, :"$1", :_}, [{:<, :"$1", day}], [{:const, fresh}]}
        ])

        salt(table, day)

      [] ->
        :ets.insert_new(table, {:salt, day, :crypto.strong_rand_bytes(32)})
        salt(table, day)
    end
  end

  defp bump(table, tag_key, ops, size) do
    key = tag_key
    row = :erlang.make_tuple(size, 0, [{1, key}])
    :ets.update_counter(table, key, ops, row)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp counted_status?(status), do: status in 200..299 or status == 304

  defp refresh?(conn) do
    case header(conn, "x-openresults-refresh") do
      nil ->
        case header(conn, "sec-fetch-mode") do
          nil -> false
          "navigate" -> false
          _other -> true
        end

      _present ->
        true
    end
  end

  # An HTML document: the response says so, or - a 304 carries no body and
  # sometimes no type - the request asked for one.
  defp html?(conn) do
    case Plug.Conn.get_resp_header(conn, "content-type") do
      [type | _] -> String.starts_with?(type, "text/html")
      [] -> conn.status == 304 and String.contains?(header(conn, "accept") || "", "text/html")
    end
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  ## ---------- flushing ----------

  @doc """
  Adds every unflushed counter of `table` to the database, forgets what the
  past days no longer need and prunes old rows. `:ok`, or `:error` (logged)
  with the counters kept for the next try.
  """
  def flush_table(table, today) do
    days = :ets.match_object(table, {{:day, :_}, :_, :_, :_, :_})
    slugs = :ets.match_object(table, {{:slug, :_, :_}, :_, :_})

    day_rows =
      for {{:day, day}, u, v, b, r} <- days, u + v + b + r > 0 do
        %{day: to_date(day), unique_viewers: u, page_views: v, bot_hits: b, refreshes: r}
      end

    slug_rows =
      for {{:slug, day, slug}, u, v} <- slugs, u + v > 0 do
        %{day: to_date(day), slug: slug, unique_viewers: u, page_views: v}
      end

    oldest = to_date(today - @retention_days)

    result =
      Repo.transaction(fn ->
        write(TrafficDay, day_rows, [:day])
        write(TrafficTournamentDay, slug_rows, [:day, :slug])
        Repo.delete_all(from t in TrafficDay, where: t.day < ^oldest)
        Repo.delete_all(from t in TrafficTournamentDay, where: t.day < ^oldest)
      end)

    case result do
      {:ok, _} ->
        # Subtract what was written; an increment that raced the flush stays.
        for {{:day, _} = key, u, v, b, r} <- days,
            do: :ets.update_counter(table, key, [{2, -u}, {3, -v}, {4, -b}, {5, -r}])

        for {{:slug, _, _} = key, u, v} <- slugs,
            do: :ets.update_counter(table, key, [{2, -u}, {3, -v}])

        forget_past(table, today)
        :ok

      {:error, reason} ->
        Logger.error("Viewer totals not saved: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.error("Viewer totals not saved: #{Exception.message(error)}")
      :error
  catch
    :exit, reason ->
      Logger.error("Viewer totals not saved: #{inspect(reason)}")
      :error
  end

  defp write(_schema, [], _conflict), do: :ok

  defp write(schema, rows, conflict) do
    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk ->
      Repo.insert_all(schema, chunk,
        on_conflict: add_on_conflict(schema),
        conflict_target: conflict
      )
    end)
  end

  defp add_on_conflict(TrafficDay) do
    from(t in TrafficDay,
      update: [
        set: [
          unique_viewers: fragment("? + excluded.unique_viewers", t.unique_viewers),
          page_views: fragment("? + excluded.page_views", t.page_views),
          bot_hits: fragment("? + excluded.bot_hits", t.bot_hits),
          refreshes: fragment("? + excluded.refreshes", t.refreshes)
        ]
      ]
    )
  end

  defp add_on_conflict(TrafficTournamentDay) do
    from(t in TrafficTournamentDay,
      update: [
        set: [
          unique_viewers: fragment("? + excluded.unique_viewers", t.unique_viewers),
          page_views: fragment("? + excluded.page_views", t.page_views)
        ]
      ]
    )
  end

  # Yesterday's hashes, its salt and its emptied counters: nothing here needs
  # them any more, and the hashes are the only thing in this module that could
  # be matched to a reader, so they do not outlive their day.
  defp forget_past(table, today) do
    :ets.select_delete(table, [
      {{{:seen, :"$1", :_}}, [{:<, :"$1", today}], [true]},
      {{{:seen, :"$1", :_, :_}}, [{:<, :"$1", today}], [true]},
      {{:salt, :"$1", :_}, [{:<, :"$1", today}], [true]},
      {{{:day, :"$1"}, 0, 0, 0, 0}, [{:<, :"$1", today}], [true]},
      {{{:slug, :"$1", :_}, 0, 0}, [{:<, :"$1", today}], [true]}
    ])
  end

  ## ---------- reading: the admin page ----------

  @doc """
  What the stats page shows, after a flush: the last `days` days (newest
  first, missing days as zeros) and the top tournaments by unique viewers
  over today, 7 days and 30 days. `nil` when the database cannot be read.
  """
  def report(today \\ Date.utc_today(), days \\ 30) do
    _ = if Process.whereis(__MODULE__), do: flush()
    first = Date.add(today, 1 - days)

    stored =
      from(t in TrafficDay, where: t.day >= ^first and t.day <= ^today)
      |> Repo.all()
      |> Map.new(&{&1.day, &1})

    history =
      for offset <- 0..(days - 1) do
        day = Date.add(today, -offset)
        row = Map.get(stored, day)

        %{
          day: day,
          unique_viewers: (row && row.unique_viewers) || 0,
          page_views: (row && row.page_views) || 0,
          bot_hits: (row && row.bot_hits) || 0,
          refreshes: (row && row.refreshes) || 0
        }
      end

    %{
      days: history,
      top: %{
        today: top(today, today),
        week: top(Date.add(today, -6), today),
        month: top(Date.add(today, -29), today)
      }
    }
  rescue
    _ -> nil
  end

  defp top(from, to, limit \\ 10) do
    from(t in TrafficTournamentDay,
      where: t.day >= ^from and t.day <= ^to,
      group_by: t.slug,
      order_by: [desc: sum(t.unique_viewers), desc: sum(t.page_views), asc: t.slug],
      limit: ^limit,
      select: {t.slug, sum(t.unique_viewers), sum(t.page_views)}
    )
    |> Repo.all()
    |> Enum.map(fn {slug, u, v} ->
      %{slug: slug, unique_viewers: to_int(u), page_views: to_int(v)}
    end)
  end

  defp to_int(nil), do: 0
  defp to_int(n) when is_integer(n), do: n
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
end
