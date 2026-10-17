defmodule OpenResults.StatsViewersTest do
  @moduledoc """
  Unique readers: the same reader twice is one, another user agent is
  another, a new day is a new salt, programs and polls are not readers, and
  the daily totals reach the database and add up across flushes.

  Each test has a table and a server of its own and passes the day in, so
  nothing here waits for midnight.
  """
  use OpenResults.DataCase, async: false

  import Plug.Conn

  alias OpenResults.Stats.TrafficDay
  alias OpenResults.Stats.TrafficTournamentDay
  alias OpenResults.Stats.Viewers

  # Recent, because every flush prunes what is older than the retention.
  @day div(System.os_time(:second), 86_400)
  @phone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1"
  @desktop "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36"

  setup do
    table = :"viewers_test_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Viewers, name: nil, table: table, flush: :manual, clock: fn -> @day * 86_400 end},
        id: table
      )

    {:ok, table: table, pid: pid}
  end

  # A counter row as {unique, views, bots, refreshes}.
  defp counts(table, day) do
    case :ets.lookup(table, {:day, day}) do
      [{_key, u, v, b, r}] -> {u, v, b, r}
      [] -> {0, 0, 0, 0}
    end
  end

  defp request(agent, opts \\ []) do
    conn =
      :get
      |> Plug.Test.conn(Keyword.get(opts, :path, "/"))
      |> Map.put(:remote_ip, Keyword.get(opts, :ip, {203, 0, 113, 7}))

    conn = if agent, do: put_req_header(conn, "user-agent", agent), else: conn

    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, c ->
        put_req_header(c, k, v)
      end)

    conn
    |> Map.put(:method, Keyword.get(opts, :method, "GET"))
    |> put_resp_content_type(Keyword.get(opts, :type, "text/html"))
    |> Map.put(:path_params, Keyword.get(opts, :params, %{}))
    |> Map.put(:assigns, Map.new(Keyword.get(opts, :assigns, [])))
    |> resp(Keyword.get(opts, :status, 200), "")
  end

  defp tournament(slug, visibility \\ :listed),
    do: [params: %{"slug" => slug}, assigns: [tournament_visibility: visibility]]

  describe "unique readers" do
    test "the same reader twice is one reader and two views", %{table: t} do
      Viewers.observe(t, @day, request(@phone))
      Viewers.observe(t, @day, request(@phone))

      assert counts(t, @day) == {1, 2, 0, 0}
    end

    test "another user agent, or another address, is another reader", %{table: t} do
      Viewers.observe(t, @day, request(@phone))
      Viewers.observe(t, @day, request(@desktop))
      Viewers.observe(t, @day, request(@phone, ip: {203, 0, 113, 8}))

      assert counts(t, @day) == {3, 3, 0, 0}
    end

    test "the client address is the one behind the proxy, not the proxy's", %{table: t} do
      # Both arrive from the loopback proxy; only Cloudflare's header differs.
      a = request(@phone, ip: {127, 0, 0, 1}, headers: [{"cf-connecting-ip", "198.51.100.1"}])
      b = request(@phone, ip: {127, 0, 0, 1}, headers: [{"cf-connecting-ip", "198.51.100.2"}])
      Viewers.observe(t, @day, a)
      Viewers.observe(t, @day, b)

      assert counts(t, @day) == {2, 2, 0, 0}
    end

    test "the next day has another salt, so the same reader is a new code", %{table: t} do
      first = Viewers.reader(t, @day, "203.0.113.7", @phone)
      assert first == Viewers.reader(t, @day, "203.0.113.7", @phone)
      [{:salt, @day, salt_one}] = :ets.lookup(t, :salt)

      later = Viewers.reader(t, @day + 1, "203.0.113.7", @phone)
      [{:salt, day, salt_two}] = :ets.lookup(t, :salt)

      assert day == @day + 1
      refute salt_one == salt_two
      refute first == later
      # One salt at a time: yesterday's is gone, not kept beside today's.
      assert length(:ets.match_object(t, {:salt, :_, :_})) == 1
    end

    test "that reader is unique again on the next day", %{table: t} do
      Viewers.observe(t, @day, request(@phone))
      Viewers.observe(t, @day + 1, request(@phone))

      assert counts(t, @day) == {1, 1, 0, 0}
      assert counts(t, @day + 1) == {1, 1, 0, 0}
    end

    test "unique readers are counted per tournament as well", %{table: t} do
      Viewers.observe(t, @day, request(@phone, tournament("open")))
      Viewers.observe(t, @day, request(@phone, tournament("open")))
      Viewers.observe(t, @day, request(@desktop, tournament("open")))
      Viewers.observe(t, @day, request(@phone))

      assert [{{:slug, @day, "open"}, 2, 3}] = :ets.lookup(t, {:slug, @day, "open"})
      # The overall figure counts the phone once across both pages.
      assert counts(t, @day) == {2, 4, 0, 0}
    end

    test "a hidden or unpublished slug adds no tournament row", %{table: t} do
      Viewers.observe(t, @day, request(@phone, tournament("secret", :hidden)))

      assert :ets.match_object(t, {{:slug, :_, :_}, :_, :_}) == []
    end
  end

  describe "what is not a reader" do
    test "bots are counted apart, whatever they asked for", %{table: t} do
      for agent <- [
            "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
            "curl/8.5.0",
            "python-requests/2.31",
            "Wget/1.21",
            "Slackbot-LinkExpanding 1.0",
            "WhatsApp/2.23",
            "",
            nil
          ] do
        Viewers.observe(t, @day, request(agent))
      end

      assert counts(t, @day) == {0, 0, 8, 0}
    end

    test "a bot that is refused is still a bot hit", %{table: t} do
      Viewers.observe(t, @day, request("Googlebot/2.1", status: 404))
      assert counts(t, @day) == {0, 0, 1, 0}
    end

    test "refreshes are counted apart and are not views", %{table: t} do
      Viewers.observe(t, @day, request(@phone, headers: [{"x-openresults-refresh", "1"}]))
      Viewers.observe(t, @day, request(@phone, headers: [{"sec-fetch-mode", "cors"}]))

      assert counts(t, @day) == {0, 0, 0, 2}
    end

    test "a navigation is a view", %{table: t} do
      Viewers.observe(t, @day, request(@phone, headers: [{"sec-fetch-mode", "navigate"}]))
      assert counts(t, @day) == {1, 1, 0, 0}
    end

    test "answers that are not an HTML page are nothing", %{table: t} do
      Viewers.observe(t, @day, request(@phone, type: "application/json"))
      Viewers.observe(t, @day, request(@phone, status: 404))
      Viewers.observe(t, @day, request(@phone, status: 500))
      Viewers.observe(t, @day, request(@phone, method: "POST"))
      Viewers.observe(t, @day, request(@phone, method: "HEAD"))

      assert counts(t, @day) == {0, 0, 0, 0}
    end

    test "a 304 to a request that wanted a page is a view", %{table: t} do
      conn =
        :get
        |> Plug.Test.conn("/")
        |> put_req_header("user-agent", @phone)
        |> put_req_header("accept", "text/html,application/xhtml+xml")
        |> Map.put(:status, 304)

      Viewers.observe(t, @day, conn)
      assert counts(t, @day) == {1, 1, 0, 0}
    end
  end

  describe "through the telemetry handler" do
    defp served(conn) do
      OpenResultsWeb.StatsTelemetry.handle_request(
        [:bandit, :request, :stop],
        %{duration: 1},
        %{conn: conn},
        nil
      )
    end

    defp today_report do
      [today | _] = Viewers.report().days
      Map.take(today, [:unique_viewers, :page_views, :bot_hits, :refreshes])
    end

    test "admin, API and static requests are not observed" do
      before = today_report()

      for path <- ["/admin/stats", "/api/server", "/assets/app.css"] do
        served(request(@phone, path: path))
      end

      assert today_report() == before
    end

    test "a public page is counted, and neither address nor agent is kept" do
      agent = "Mozilla/5.0 Distinctive-Agent-#{System.unique_integer([:positive])}"
      before = today_report()

      served(request(agent, ip: {198, 51, 100, 222}))

      after_ = today_report()
      assert after_.unique_viewers == before.unique_viewers + 1
      assert after_.page_views == before.page_views + 1

      dump = inspect(:ets.tab2list(Viewers.table()), limit: :infinity, printable_limit: :infinity)
      refute dump =~ "198.51.100.222"
      refute dump =~ "Distinctive-Agent"
    end
  end

  describe "persisting" do
    test "a flush writes the day's totals and the tournament's", %{table: t, pid: pid} do
      Viewers.observe(t, @day, request(@phone, tournament("open")))
      Viewers.observe(t, @day, request(@desktop, tournament("open")))
      Viewers.observe(t, @day, request(@phone))
      Viewers.observe(t, @day, request("Googlebot/2.1"))
      Viewers.observe(t, @day, request(@phone, headers: [{"x-openresults-refresh", "1"}]))

      assert :ok = Viewers.flush(pid)

      date = Viewers.to_date(@day)

      assert %TrafficDay{unique_viewers: 2, page_views: 3, bot_hits: 1, refreshes: 1} =
               Repo.get_by!(TrafficDay, day: date)

      assert %TrafficTournamentDay{unique_viewers: 2, page_views: 2} =
               Repo.get_by!(TrafficTournamentDay, day: date, slug: "open")

      # What was written is no longer owed.
      assert counts(t, @day) == {0, 0, 0, 0}
    end

    test "flushes add to the stored row instead of replacing it", %{table: t, pid: pid} do
      Viewers.observe(t, @day, request(@phone))
      assert :ok = Viewers.flush(pid)
      Viewers.observe(t, @day, request(@phone))
      Viewers.observe(t, @day, request(@desktop))
      assert :ok = Viewers.flush(pid)
      assert :ok = Viewers.flush(pid)

      row = Repo.get_by!(TrafficDay, day: Viewers.to_date(@day))
      # The phone is not counted again within the day; the desktop is new.
      assert {row.unique_viewers, row.page_views} == {2, 3}
    end

    test "at the day's end the hashes and the old salt are forgotten", %{table: t} do
      Viewers.observe(t, @day - 1, request(@phone))
      Viewers.observe(t, @day, request(@phone))
      assert length(:ets.match_object(t, {{:seen, :_, :_}})) == 2

      assert :ok = Viewers.flush_table(t, @day)

      assert [{{:seen, @day, _}}] = :ets.match_object(t, {{:seen, :_, :_}})
      assert [{:salt, @day, _}] = :ets.match_object(t, {:salt, :_, :_})
      assert :ets.lookup(t, {:day, @day - 1}) == []

      yesterday = Repo.get_by!(TrafficDay, day: Viewers.to_date(@day - 1))
      assert yesterday.unique_viewers == 1
    end

    test "rows older than the retention are deleted", %{table: t} do
      old = Viewers.to_date(@day - Viewers.retention_days() - 1)
      kept = Viewers.to_date(@day - Viewers.retention_days() + 1)
      Repo.insert!(%TrafficDay{day: old, unique_viewers: 5})
      Repo.insert!(%TrafficDay{day: kept, unique_viewers: 6})
      Repo.insert!(%TrafficTournamentDay{day: old, slug: "gone", unique_viewers: 1})

      assert :ok = Viewers.flush_table(t, @day)

      assert Repo.get_by(TrafficDay, day: old) == nil
      assert Repo.get_by(TrafficDay, day: kept)
      assert Repo.get_by(TrafficTournamentDay, slug: "gone") == nil
    end

    test "the report fills quiet days with zeros and ranks tournaments", %{table: t, pid: pid} do
      today = Viewers.to_date(@day)

      for {slug, agents} <- [
            {"big", [@phone, @desktop, "Mozilla/5.0 third"]},
            {"small", [@phone]}
          ],
          agent <- agents do
        Viewers.observe(t, @day, request(agent, tournament(slug)))
      end

      assert :ok = Viewers.flush(pid)

      report = Viewers.report(today)

      assert length(report.days) == 30
      assert [%{day: ^today, unique_viewers: 3}, %{unique_viewers: 0} | _] = report.days

      assert [%{slug: "big", unique_viewers: 3}, %{slug: "small", unique_viewers: 1}] =
               report.top.today

      assert report.top.week == report.top.today
      assert report.top.month == report.top.today
    end
  end
end
