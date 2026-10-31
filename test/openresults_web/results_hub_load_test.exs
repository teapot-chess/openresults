defmodule OpenResultsWeb.ResultsHubLoadTest do
  @moduledoc """
  The results hub at the size it is built for: 10,000 published
  tournaments, ten federations, a pool of 5,000 FIDE ids each playing about
  twenty of them.

  Excluded from the ordinary run (`test/test_helper.exs`); run it with

      mix test --only load_test test/openresults_web/results_hub_load_test.exs

  It prints the timings rather than asserting tight budgets - a laptop and a
  2 vCPU box disagree by a factor - and asserts only ceilings a working
  index clears by an order of magnitude, so a query that lost its index (a
  full scan of 100,000 appearances per request) fails here.

  "Cold" is a request after the page's generation moved, so it renders;
  "warm" is the next one, from the page cache. Medians of `@runs`.
  """
  use OpenResultsWeb.ConnCase, async: false

  @moduletag :load_test
  @moduletag timeout: :infinity

  alias OpenResults.RateLimit
  alias OpenResults.ResultsIndex.Generations
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Snapshots

  @tournaments 10_000
  @pool 5_000
  @federations ~w(BEL NED FRA GER ENG ESP ITA POL CZE HUN)
  @surnames ~w(Peeters Janssens Maes Jacobs Mertens Willems Claes Goossens Wouters Smets
               Dubois Lambert Dupont Martin Simon Laurent Leroy Müller Schmidt Novak)
  @given ~w(Jan Pieter Luc Marc Anna Sofie Lotte Emma Lucas Noah Louis Mila Elise Arthur)
  @runs 15

  defp name(id),
    do:
      "#{Enum.at(@surnames, rem(id, 20))}#{div(id, 400)}, #{Enum.at(@given, rem(div(id, 20), 14))}"

  defp payload(base, n, today) do
    start = Date.add(today, -rem(n * 7, 1100))
    federation = Enum.at(@federations, rem(n, 10))

    players =
      base["players"]
      |> Enum.with_index()
      |> Enum.map(fn {player, i} ->
        id = 100_000 + rem(n * 10 + i * 37, @pool)
        %{player | "fide_id" => id, "name" => name(id), "federation" => federation}
      end)

    base
    |> Map.put("players", players)
    |> put_in(["tournament", "slug"], "load-#{n}")
    |> put_in(["tournament", "name"], "Load Open #{n} #{Enum.at(@surnames, rem(n, 20))}")
    |> put_in(["tournament", "city"], "City #{rem(n, 300)}")
    |> put_in(["tournament", "federation"], federation)
    |> put_in(["tournament", "start_date"], Date.to_iso8601(start))
    |> put_in(["tournament", "end_date"], Date.to_iso8601(Date.add(start, 4)))
  end

  defp ms(fun) do
    {us, result} = :timer.tc(fun)
    {us / 1000, result}
  end

  defp median(list), do: list |> Enum.sort() |> Enum.at(div(length(list), 2))

  defp timed(path, bump) do
    cold =
      for _ <- 1..@runs do
        Generations.bump(bump)
        RateLimit.reset()
        {t, conn} = ms(fn -> get(build_conn(), path) end)
        assert conn.status == 200, "#{path} answered #{conn.status}"
        t
      end

    warm =
      for _ <- 1..@runs do
        {t, conn} = ms(fn -> get(build_conn(), path) end)
        assert conn.status == 200
        t
      end

    {median(cold), median(warm)}
  end

  test "10,000 tournaments" do
    base = SnapshotPayloads.swiss()
    today = Date.utc_today()

    {ingest_ms, _} =
      ms(fn ->
        for n <- 1..@tournaments do
          {:ok, _} = Snapshots.ingest(payload(base, n, today), [])
        end
      end)

    rows = OpenResults.Repo.aggregate(OpenResults.ResultsIndex.Appearance, :count)
    player = 100_000 + 1234

    pages = [
      {"front page", "/", :all},
      {"/federations", "/federations", :all},
      {"/f/BEL", "/f/BEL", {:federation, "BEL"}},
      {"/f/BEL?page=10", "/f/BEL?page=10", {:federation, "BEL"}},
      {"player page", "/players/#{player}", {:player, player}}
    ]

    page_times = for {label, path, key} <- pages, do: {label, timed(path, key)}

    searches = ["load open", "peeters", "city 12", "#{player}", "zzzqqq"]

    search_times =
      for q <- searches do
        times =
          for _ <- 1..@runs do
            RateLimit.reset()
            {t, conn} = ms(fn -> get(build_conn(), "/search", q: q) end)
            assert conn.status == 200
            t
          end

        {q, median(times)}
      end

    report =
      [
        "results hub load test: #{@tournaments} tournaments, #{rows} appearances",
        "  ingest: #{round(ingest_ms)} ms total, #{Float.round(ingest_ms / @tournaments, 2)} ms each"
      ] ++
        for(
          {label, {cold, warm}} <- page_times,
          do: "  #{label}: cold #{Float.round(cold, 1)} ms, warm #{Float.round(warm, 1)} ms"
        ) ++
        for {q, t} <- search_times, do: "  search #{inspect(q)}: #{Float.round(t, 1)} ms"

    IO.puts("\n" <> Enum.join(report, "\n"))

    for {label, {cold, warm}} <- page_times do
      assert cold < 1_000, "#{label} took #{cold} ms to render"
      assert warm < 100, "#{label} took #{warm} ms from the cache"
    end

    for {q, t} <- search_times, do: assert(t < 500, "search #{q} took #{t} ms")
  end
end
