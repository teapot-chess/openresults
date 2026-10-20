defmodule OpenResults.LiveBoards do
  @moduledoc """
  Live boards: the games of a round, move by move, as a hall relay reports
  them. The contract a relay implements is `docs/live-boards-api.md`.

  ## What is stored, and where it comes from

  The snapshot (`OpenResults.Snapshots`) says who sits where and what the
  arbiter has published. This module holds the other half: what is happening
  on a board right now. They are joined on `(round, board)` at read time and
  never merged - a live game is never part of a snapshot, so a publish cannot
  wipe it and a live update cannot change a published result.

  ## Ingest

  `ingest/3` is idempotent and tolerant of order. It is keyed by
  `(slug, round, board)` and decided by the ply count:

    * an update with a LOWER ply than the stored one is ignored (`applied:
      false`) - the relay's retry of an old message must not undo a newer one;
    * an update with the SAME ply refreshes clocks, status and result, and
      must agree with the moves already held;
    * an update with a HIGHER ply extends the game, and must extend it - the
      stored moves have to be a prefix of the new list;
    * `replace: true` is the full-game resend: it replaces whatever is held,
      keeping only the stored plies that are still identical, so their
      timestamps (and with them the broadcast delay) survive a resend.

  Every move is checked for legality from the start position (or the given
  `start_fen`) by `OpenResults.Chess`; a list with an illegal move is refused
  whole, naming the ply. Only the plies that are new are replayed through the
  engine - the stored ones carry their own positions - so a relay that sends
  the whole list every time costs a string comparison per old ply.

  ## Bounds

  A live game is not a snapshot, so the version cap and the free-disk floor
  never reached it, and a relay could fill the disk one board at a time (the
  2026-10-19 sweep). `bounds/2` turns the current snapshot into the three
  rules `ingest/3` applies when given them - the controller always does:
  only a `(round, board)` the snapshot has (`board_not_published`), at most
  `#{500}` games per round it has (`live_game_limit`), and, for a credential
  the floor applies to, no NEW game while the disk is low (`storage_low`).
  An update to a game already held is never counted or floored.

  ## The broadcast delay

  Organisers may be required to delay what spectators see. Ingest always
  stores real time: each ply records when it was heard. `view/3` is the one
  door every page reads through, and it shows the game as it stood
  `delay` ago: the plies heard by then, the clocks as they were with them,
  and no result before its time. Nothing past the cutoff reaches a page.
  """

  import Ecto.Query, warn: false

  alias OpenResults.Chess
  alias OpenResults.LiveBoards.Game
  alias OpenResults.LiveBoards.Setting
  alias OpenResults.Repo

  @pubsub OpenResults.PubSub
  @results ["1-0", "0-1", "1/2-1/2", "*"]
  @max_plies 700
  @max_clock_ms :timer.hours(24) * 10
  @max_delay_minutes 24 * 60
  @games_per_round 500
  @storage_retry_after 300

  # --- change notices ----------------------------------------------------------

  @doc "The PubSub topic of `slug`'s live boards."
  def topic(slug) when is_binary(slug), do: "live:" <> slug

  @doc "Subscribes the caller to `slug`'s live boards: `{:live_board, slug, round, board}`."
  def subscribe(slug), do: Phoenix.PubSub.subscribe(@pubsub, topic(slug))

  @doc "Says that a board changed."
  def changed(slug, round, board),
    do: Phoenix.PubSub.broadcast(@pubsub, topic(slug), {:live_board, slug, round, board})

  # --- request -----------------------------------------------------------------

  @doc """
  Checks and normalises the body of one board update.

  `{:ok, request}` or `{:error, code, detail}` where `code` is one of
  `:invalid_request`, `:invalid_fen`, `:invalid_moves`, `:ply_mismatch`.
  """
  def parse(params) when is_map(params) do
    with {:ok, round} <- int(params, "round", 1, 999, true),
         {:ok, board} <- int(params, "board", 1, 9999, true),
         {:ok, moves} <- moves(Map.get(params, "moves")),
         {:ok, fen} <- fen(Map.get(params, "fen"), "fen"),
         {:ok, start_fen} <- fen(Map.get(params, "start_fen"), "start_fen"),
         {:ok, ply} <- int(params, "ply", 0, @max_plies * 2, false),
         {:ok, ply} <- ply(ply, moves, fen),
         {:ok, white} <- int(params, "white_ms", 0, @max_clock_ms, false),
         {:ok, black} <- int(params, "black_ms", 0, @max_clock_ms, false),
         {:ok, running} <- running(params),
         {:ok, status} <- status(Map.get(params, "status", "live")),
         {:ok, result} <- result(Map.get(params, "result")),
         {:ok, replace} <- flag(Map.get(params, "replace", false)) do
      {:ok,
       %{
         round: round,
         board: board,
         moves: moves,
         fen: fen,
         start_fen: start_fen,
         ply: ply,
         clocks: clocks(params, white, black, running),
         status: status,
         result: result,
         replace?: replace
       }}
    end
  end

  def parse(_other), do: {:error, :invalid_request, "a board update must be a JSON object"}

  defp int(params, key, min, max, required?) do
    case Map.get(params, key) do
      nil when required? ->
        {:error, :invalid_request, "`#{key}` is required"}

      nil ->
        {:ok, nil}

      n when is_integer(n) and n >= min and n <= max ->
        {:ok, n}

      _other ->
        {:error, :invalid_request, "`#{key}` must be an integer from #{min} to #{max}"}
    end
  end

  defp moves(nil), do: {:ok, nil}

  defp moves(list) when is_list(list) and length(list) <= @max_plies do
    if Enum.all?(list, &(is_binary(&1) and byte_size(&1) in 2..12)),
      do: {:ok, list},
      else: {:error, :invalid_moves, "`moves` must be a list of SAN strings"}
  end

  defp moves(_other),
    do: {:error, :invalid_moves, "`moves` must be a list of at most #{@max_plies} SAN strings"}

  defp fen(nil, _key), do: {:ok, nil}

  defp fen(text, key) when is_binary(text) and byte_size(text) <= 120 do
    case Chess.parse_fen(text) do
      {:ok, _position} -> {:ok, text}
      {:error, message} -> {:error, :invalid_fen, "`#{key}`: #{message}"}
    end
  end

  defp fen(_other, key), do: {:error, :invalid_fen, "`#{key}` must be a FEN string"}

  defp ply(_ply, nil, nil),
    do: {:error, :invalid_request, "send `moves`, or `fen` with `ply`"}

  defp ply(nil, nil, _fen), do: {:error, :invalid_request, "`ply` is required with `fen` alone"}
  defp ply(nil, moves, _fen), do: {:ok, length(moves)}
  defp ply(ply, nil, _fen), do: {:ok, ply}

  defp ply(ply, moves, _fen) when ply == length(moves), do: {:ok, ply}

  defp ply(ply, moves, _fen),
    do: {:error, :ply_mismatch, "`ply` is #{ply} but `moves` holds #{length(moves)} moves"}

  defp running(params) do
    case Map.fetch(params, "running") do
      :error -> {:ok, :absent}
      {:ok, value} when value in [nil, "none", "stopped"] -> {:ok, nil}
      {:ok, value} when value in ["white", "black"] -> {:ok, value}
      {:ok, _other} -> {:error, :invalid_request, "`running` must be white, black or none"}
    end
  end

  defp status(status) when status in ["live", "finished"], do: {:ok, status}
  defp status(_other), do: {:error, :invalid_request, "`status` must be live or finished"}

  defp result(nil), do: {:ok, nil}
  defp result(result) when result in @results, do: {:ok, result}

  defp result(_other),
    do: {:error, :invalid_request, "`result` must be 1-0, 0-1, 1/2-1/2 or *"}

  defp flag(value) when is_boolean(value), do: {:ok, value}
  defp flag(_other), do: {:error, :invalid_request, "`replace` must be true or false"}

  # Only the clock keys the update carried: a partial update leaves the rest.
  defp clocks(params, white, black, running) do
    %{}
    |> put_if(Map.has_key?(params, "white_ms") and white != nil, :white_ms, white)
    |> put_if(Map.has_key?(params, "black_ms") and black != nil, :black_ms, black)
    |> put_if(running != :absent, :running, running)
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, false, _key, _value), do: map

  # --- ingest ------------------------------------------------------------------

  @doc """
  Applies one board update for `slug`.

  `{:ok, %{applied?: boolean, ply: integer, game: Game.t()}}`, or
  `{:error, code, detail}` / `{:error, code, detail, extra}`. `applied?` is
  `false` for an update older than what is held - a success, not an error.
  Broadcasts only when something changed.

  Options: `:boards`, `:max_games` and `:floor?` from `bounds/2` (absent,
  nothing is bounded - only tests and the seed task call it so); `:now_ms`
  is for tests.
  """
  def ingest(slug, params, opts \\ []) when is_binary(slug) do
    now = Keyword.get_lazy(opts, :now_ms, fn -> System.os_time(:millisecond) end)

    with {:ok, req} <- parse(params),
         :ok <- published_board(req, Keyword.get(opts, :boards)) do
      # Immediate, like every other read-then-write here: a deferred
      # transaction that read and then tried to write is refused with
      # "database busy" the moment another board's update has committed in
      # between - and a relay posts every board at once.
      result =
        Repo.transaction(
          fn ->
            case apply_update(slug, req, now, opts) do
              {:ok, outcome} -> outcome
              {:error, _code, _detail} = error -> Repo.rollback(error)
              {:error, _code, _detail, _extra} = error -> Repo.rollback(error)
            end
          end,
          mode: :immediate
        )

      case result do
        {:ok, %{applied?: applied?} = outcome} ->
          if applied?, do: changed(slug, req.round, req.board)
          {:ok, outcome}

        {:error, error} when is_tuple(error) ->
          error
      end
    end
  end

  defp apply_update(slug, req, now, opts) do
    game =
      Repo.get_by(Game, tournament_slug: slug, round: req.round, board: req.board)

    if game && ignorable?(game, req) do
      {:ok, %{applied?: false, ply: game.ply_count, game: game}}
    else
      with :ok <- room_for(game, slug, opts),
           {:ok, change} <- plan(game, req, now) do
        {:ok, save(game, slug, req, change, now)}
      end
    end
  end

  @doc """
  What the current snapshot allows a relay to store, as `ingest/3` options:
  the `(round, board)` pairs it publishes - `rounds[].boards[].board`, and
  a team event's `rounds[].matches[].boards` - and a cap of #{500} games per
  round in it (at least one round's worth). `floor?` says whether the
  free-disk floor applies to the credential: everyone but the operator.
  """
  @spec bounds(map(), keyword()) :: keyword()
  def bounds(payload, opts \\ []) when is_map(payload) do
    rounds = List.wrap(payload["rounds"]) |> Enum.filter(&is_map/1)

    boards =
      for round <- rounds,
          is_integer(round["number"]),
          board <- round_boards(round),
          into: MapSet.new(),
          do: {round["number"], board}

    [
      boards: boards,
      max_games: @games_per_round * max(length(rounds), 1),
      floor?: Keyword.get(opts, :floor?, true)
    ]
  end

  defp round_boards(round) do
    paired = for %{"board" => n} when is_integer(n) <- List.wrap(round["boards"]), do: n

    in_matches =
      for %{"boards" => list} when is_list(list) <- List.wrap(round["matches"]),
          n when is_integer(n) <- list,
          do: n

    paired ++ in_matches
  end

  defp published_board(_req, nil), do: :ok

  defp published_board(req, boards) do
    if MapSet.member?(boards, {req.round, req.board}),
      do: :ok,
      else:
        {:error, :board_not_published,
         "round #{req.round} board #{req.board} is not in the published snapshot; publish the round first"}
  end

  # Only a NEW game takes room: one already held may always be updated.
  defp room_for(%Game{}, _slug, _opts), do: :ok

  defp room_for(nil, slug, opts) do
    max = Keyword.get(opts, :max_games)

    cond do
      Keyword.get(opts, :floor?, false) and OpenResults.DiskSpace.low?() ->
        {:error, :storage_low,
         "this server is low on disk space; games already being followed still update, new boards wait",
         %{retry_after: @storage_retry_after}}

      is_integer(max) and game_count(slug) >= max ->
        {:error, :live_game_limit,
         "this tournament already holds #{max} live games, the most its published rounds allow",
         %{limit: max}}

      true ->
        :ok
    end
  end

  defp game_count(slug),
    do: Repo.aggregate(from(g in Game, where: g.tournament_slug == ^slug), :count)

  # Older than what is held, or a "still live" repeat for a game already
  # finished at that ply. `replace` is the one way back.
  defp ignorable?(_game, %{replace?: true}), do: false
  defp ignorable?(game, req) when req.ply < game.ply_count, do: true

  defp ignorable?(game, req),
    do: req.ply == game.ply_count and game.status == "finished" and req.status == "live"

  # What the new game state is: `%{plies, fen, ply, start_fen, moved?}`.
  defp plan(game, %{moves: nil} = req, _now) do
    # A position without the moves that led to it.
    cond do
      game && game.ply_count == req.ply && not req.replace? ->
        {:ok, keep(game)}

      true ->
        fen = req.fen
        start = (game && game.start_fen) || req.start_fen
        {:ok, %{plies: [], fen: fen, ply: req.ply, start_fen: start, moved?: true}}
    end
  end

  defp plan(game, req, now) do
    start_fen = req.start_fen || (game && game.start_fen)
    start_effective = start_fen || Chess.start_fen()
    held = if game, do: game.plies, else: []
    held_start = game && (game.start_fen || Chess.start_fen())

    replace? = req.replace? or (game != nil and held_start != start_effective)

    with {:ok, plies, diverged} <- entries(start_effective, req.moves, held, now),
         :ok <- check_divergence(diverged, replace?),
         :ok <- check_fen(plies, start_effective, req.fen) do
      fen = plies |> List.last() |> then(&((&1 && &1["fen"]) || start_effective))

      {:ok,
       %{
         plies: plies,
         fen: fen,
         ply: length(plies),
         start_fen: start_fen,
         moved?: game == nil or length(plies) != game.ply_count or diverged != nil
       }}
    end
  end

  defp keep(game),
    do: %{
      plies: game.plies,
      fen: game.fen,
      ply: game.ply_count,
      start_fen: game.start_fen,
      moved?: false
    }

  defp check_divergence(nil, _replace?), do: :ok
  defp check_divergence(_index, true), do: :ok

  defp check_divergence(index, false),
    do:
      {:error, :moves_conflict,
       "move #{index + 1} differs from the one already held for this board; " <>
         "send `replace: true` to replace the whole game"}

  # The FEN, when sent beside the moves, has to be where the moves lead - in
  # the parts a position is made of, not in a move counter a relay may keep
  # differently.
  defp check_fen(_plies, _start, nil), do: :ok

  defp check_fen(plies, start, fen) do
    reached = (List.last(plies) || %{})["fen"] || start

    if position_key(reached) == position_key(fen),
      do: :ok,
      else: {:error, :fen_mismatch, "`fen` is not the position `moves` lead to"}
  end

  defp position_key(fen), do: fen |> String.split() |> Enum.take(2)

  # Every ply of `moves`: reused from `held` while it is the same move, replayed
  # from there on. Returns the entries and the index of the first held ply the
  # new list disagrees with, or `nil`.
  defp entries(start_fen, moves, held, now) do
    held = List.to_tuple(held)

    moves
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, start_fen, [], nil}, fn {raw, i},
                                                       {:ok, fen_before, acc, diverged} ->
      held_entry = if diverged == nil and i < tuple_size(held), do: elem(held, i)

      cond do
        held_entry && held_entry["san"] == raw ->
          {:cont, {:ok, held_entry["fen"], [held_entry | acc], diverged}}

        true ->
          case replay(fen_before, raw, now) do
            {:ok, entry} ->
              cond do
                held_entry && held_entry["san"] == entry["san"] ->
                  {:cont, {:ok, held_entry["fen"], [held_entry | acc], diverged}}

                held_entry ->
                  {:cont, {:ok, entry["fen"], [entry | acc], i}}

                true ->
                  {:cont, {:ok, entry["fen"], [entry | acc], diverged}}
              end

            {:error, message} ->
              {:halt, {:error, :invalid_moves, "ply #{i + 1}: #{message}", %{ply: i + 1}}}
          end
      end
    end)
    |> case do
      {:ok, _fen, acc, diverged} -> {:ok, Enum.reverse(acc), diverged}
      error -> error
    end
  end

  defp replay(fen_before, raw, now) do
    with {:ok, position} <- Chess.parse_fen(fen_before),
         {:ok, move} <- Chess.parse_san(position, raw) do
      next = Chess.apply_move(position, move)

      {:ok,
       %{
         "san" => Chess.san(position, move),
         "fen" => Chess.to_fen(next),
         "from" => move.from,
         "to" => move.to,
         "at" => now
       }}
    end
  end

  defp save(game, slug, req, change, now) do
    attrs =
      %{
        fen: change.fen,
        ply_count: change.ply,
        plies: stamp_clocks(change.plies, game, change, req),
        start_fen: change.start_fen
      }
      |> Map.merge(last_move(change))
      |> Map.merge(clock_attrs(game, req, now))
      |> Map.merge(status_attrs(game, req, change, now))
      |> then(fn attrs ->
        if change.moved? or game == nil, do: Map.put(attrs, :moved_at_ms, now), else: attrs
      end)

    saved =
      case game do
        nil ->
          Repo.insert!(
            struct(
              Game,
              Map.merge(
                %{
                  tournament_slug: slug,
                  round: req.round,
                  board: req.board,
                  started_at_ms: now,
                  moved_at_ms: now
                },
                attrs
              )
            )
          )

        game ->
          game |> Ecto.Changeset.change(attrs) |> Repo.update!()
      end

    %{applied?: true, ply: saved.ply_count, game: saved}
  end

  # The last move, for a game whose list is the whole of it. A game known by
  # position alone has none to show.
  defp last_move(%{plies: plies, ply: ply}) when plies != [] and length(plies) == ply do
    last = List.last(plies)
    %{last_from: last["from"], last_to: last["to"], last_san: last["san"]}
  end

  defp last_move(_change), do: %{last_from: nil, last_to: nil, last_san: nil}

  # The clocks that came with a move belong to that move: the last NEW ply
  # carries the values of this update, so the delayed view can show them when
  # that ply becomes visible.
  defp stamp_clocks(plies, game, change, req) do
    new_from = if game, do: length(game.plies), else: 0

    if req.clocks == %{} or plies == [] or length(plies) <= new_from or not change.moved? do
      plies
    else
      {head, [last]} = Enum.split(plies, -1)

      current = fn key, field ->
        case Map.fetch(req.clocks, key) do
          {:ok, value} -> value
          :error -> game && Map.get(game, field)
        end
      end

      stamped =
        Map.merge(last, %{
          "w" => current.(:white_ms, :white_ms),
          "b" => current.(:black_ms, :black_ms),
          "r" => current.(:running, :running)
        })

      head ++ [stamped]
    end
  end

  defp clock_attrs(_game, %{clocks: clocks}, _now) when clocks == %{}, do: %{}

  defp clock_attrs(_game, %{clocks: clocks}, now) do
    Map.put(clocks, :clock_at_ms, now)
  end

  defp status_attrs(game, req, change, now) do
    reopened? = game != nil and game.status == "finished" and req.status == "live"

    case req.status do
      "finished" ->
        %{
          status: "finished",
          result: req.result || (game && game.result),
          finished_at_ms:
            if(game && game.status == "finished", do: game.finished_at_ms, else: now),
          running: nil,
          clock_at_ms: now
        }

      "live" ->
        base = %{status: "live", finished_at_ms: nil}
        base = if reopened? or change.moved?, do: Map.put(base, :result, nil), else: base
        if req.result, do: Map.put(base, :result, req.result), else: base
    end
  end

  # --- reading -----------------------------------------------------------------

  @doc "One board's stored game, or `nil`."
  def get_game(slug, round, board),
    do: Repo.get_by(Game, tournament_slug: slug, round: round, board: board)

  # What a tile is drawn from. Everything but the move list, which is the
  # heavy column: a long game's list is tens of kilobytes, and a round page
  # re-reads the whole round on a timer for every spectator.
  @light_fields [
    :id,
    :tournament_slug,
    :round,
    :board,
    :start_fen,
    :fen,
    :ply_count,
    :white_ms,
    :black_ms,
    :running,
    :clock_at_ms,
    :last_from,
    :last_to,
    :last_san,
    :status,
    :result,
    :started_at_ms,
    :moved_at_ms,
    :finished_at_ms
  ]

  @doc """
  Every stored game of one round, by board.

  `plies: false` leaves the move lists out (they read as `[]`): enough for
  `view/3` with no delay, which takes the last move from its own columns, and
  not enough for a delayed view, which has to know when each move arrived.
  """
  def games_for_round(slug, round, opts \\ []) do
    query =
      from g in Game,
        where: g.tournament_slug == ^slug and g.round == ^round,
        order_by: g.board

    query =
      if Keyword.get(opts, :plies, true),
        do: query,
        else: from(g in query, select: struct(g, ^@light_fields))

    Repo.all(query)
  end

  @doc "Every stored game of a tournament, by round then board."
  def games(slug) do
    Repo.all(from g in Game, where: g.tournament_slug == ^slug, order_by: [g.round, g.board])
  end

  @doc "The rounds that hold any stored game, newest last."
  def rounds_with_games(slug) do
    Repo.all(
      from g in Game,
        where: g.tournament_slug == ^slug,
        distinct: true,
        order_by: g.round,
        select: g.round
    )
  end

  @doc "Removes every live game of `slug`, and its settings. Part of a takedown."
  def delete_all_for(slug) do
    {games, _} = Repo.delete_all(from g in Game, where: g.tournament_slug == ^slug)
    Repo.delete_all(from s in Setting, where: s.tournament_slug == ^slug)
    games
  end

  # --- the delay ---------------------------------------------------------------

  @doc "How many minutes spectators see behind real time. `0` when none is set."
  @spec delay_minutes(String.t()) :: non_neg_integer()
  def delay_minutes(slug) when is_binary(slug) do
    case Repo.get(Setting, slug) do
      %Setting{delay_minutes: minutes} -> minutes
      nil -> 0
    end
  end

  @doc "The largest delay that can be set, in minutes."
  def max_delay_minutes, do: @max_delay_minutes

  @doc """
  Sets the broadcast delay. `{:ok, minutes}` or `{:error, :invalid}`. `0`
  removes it. Takes effect on the next read; nothing is rewritten, because
  the stored plies hold real time.
  """
  def put_delay(slug, minutes, actor) when is_binary(slug) do
    if is_integer(minutes) and minutes >= 0 and minutes <= @max_delay_minutes do
      row = Repo.get(Setting, slug) || %Setting{tournament_slug: slug}

      row
      |> Ecto.Changeset.change(delay_minutes: minutes, updated_by: actor)
      |> Repo.insert_or_update!()

      Phoenix.PubSub.broadcast(@pubsub, topic(slug), {:live_delay, slug})
      {:ok, minutes}
    else
      {:error, :invalid}
    end
  end

  # --- the spectator's view ----------------------------------------------------

  @doc """
  The game as spectators may see it `delay_ms` ago, at `now_ms`, or `nil`
  when it had not started yet by then.

  A map with `:round, :board, :status, :result, :ply, :fen, :start_fen,
  :plies, :last, :clocks, :clock_at`, where `:clocks` is
  `%{white: ms | nil, black: ms | nil, running: "white" | "black" | nil}` as
  of `now_ms` (a running clock already counted down to this instant),
  `:clock_at` is when those clocks were reported (ms since the epoch, `nil`
  when none were) and `:last` is `{from, to}` square indices or `nil`.
  """
  def view(%Game{} = game, delay_ms, now_ms) do
    cutoff = now_ms - delay_ms

    if delay_ms > 0 and game.started_at_ms > cutoff,
      do: nil,
      else: build_view(game, delay_ms, now_ms, cutoff)
  end

  defp build_view(game, 0, now_ms, _cutoff) do
    start = game.start_fen || Chess.start_fen()

    %{
      round: game.round,
      board: game.board,
      status: game.status,
      result: if(game.status == "finished", do: game.result),
      ply: game.ply_count,
      fen: game.fen,
      start_fen: start,
      plies: game.plies,
      last: if(game.last_from, do: {game.last_from, game.last_to}),
      last_san: game.last_san,
      clocks: clocks(game.white_ms, game.black_ms, game.running, game.clock_at_ms, now_ms),
      clock_at: game.clock_at_ms
    }
  end

  defp build_view(game, _delay, _now_ms, cutoff) do
    start = game.start_fen || Chess.start_fen()
    visible = Enum.take_while(game.plies, &(&1["at"] <= cutoff))
    moves_only? = length(game.plies) == game.ply_count
    all_visible? = length(visible) == length(game.plies)

    {fen, ply} =
      cond do
        not moves_only? and game.moved_at_ms <= cutoff -> {game.fen, game.ply_count}
        not moves_only? -> {start, 0}
        visible == [] -> {start, 0}
        true -> {List.last(visible)["fen"], length(visible)}
      end

    finished? =
      game.status == "finished" and all_visible? and (game.finished_at_ms || 0) <= cutoff

    {white, black, running, at} = delayed_clocks(visible)

    %{
      round: game.round,
      board: game.board,
      status: if(finished?, do: "finished", else: "live"),
      result: if(finished?, do: game.result),
      ply: ply,
      fen: fen,
      start_fen: start,
      plies: visible,
      last: last_squares(visible, ply),
      last_san: last_san(visible, ply),
      clocks: clocks(white, black, if(finished?, do: nil, else: running), at, cutoff),
      clock_at: at
    }
  end

  defp last_san([], _ply), do: nil
  defp last_san(plies, ply) when length(plies) != ply, do: nil
  defp last_san(plies, _ply), do: List.last(plies)["san"]

  defp last_squares([], _ply), do: nil
  defp last_squares(plies, ply) when length(plies) != ply, do: nil

  defp last_squares(plies, _ply) do
    last = List.last(plies)
    {last["from"], last["to"]}
  end

  # The clocks of the newest visible ply that carried any.
  defp delayed_clocks(visible) do
    visible
    |> Enum.reverse()
    |> Enum.find(&(&1["w"] != nil or &1["b"] != nil))
    |> case do
      nil -> {nil, nil, nil, nil}
      entry -> {entry["w"], entry["b"], entry["r"], entry["at"]}
    end
  end

  # Counts a running clock down from when it was reported to `instant` (the
  # moment the viewer is being shown; behind `now` by the delay).
  defp clocks(white, black, running, at, instant, _now \\ nil)

  defp clocks(white, black, running, at, instant, _now) do
    elapsed = if at && running, do: max(instant - at, 0), else: 0

    %{
      white: if(white && running == "white", do: max(white - elapsed, 0), else: white),
      black: if(black && running == "black", do: max(black - elapsed, 0), else: black),
      running: running
    }
    |> unknown_if_stopped_at_zero()
  end

  # A clock that reads zero while the other side's is the one running is not a
  # flag fall - the flag falls on the side whose clock runs. It is a relay that
  # had no reading for that side and said 0, and "0:00" would call it lost.
  defp unknown_if_stopped_at_zero(%{running: "white", black: 0} = clocks),
    do: %{clocks | black: nil}

  defp unknown_if_stopped_at_zero(%{running: "black", white: 0} = clocks),
    do: %{clocks | white: nil}

  defp unknown_if_stopped_at_zero(clocks), do: clocks
end
