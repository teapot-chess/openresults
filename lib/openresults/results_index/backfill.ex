defmodule OpenResults.ResultsIndex.Backfill do
  @moduledoc """
  Brings the results hub's index up to date at boot, in the background.

  The index is written at every publish, so on a running server this finds
  nothing to do. It earns its keep twice: the first boot after the index was
  introduced (every tournament already published is missing from it), and the
  first boot after a deploy that bumped `OpenResults.ResultsIndex.version/0`.
  Either way the site serves while it works - a tournament not yet reindexed
  is merely missing from the listings and player pages for a minute, never
  from its own pages - and it pauses between tournaments so a two-core box
  keeps answering readers.

  Off in the test environment (`config :openresults, :results_index_backfill,
  false`), where every test builds its own index through the ingest path.
  `mix openresults.reindex` does the same work in the foreground.
  """

  use GenServer

  require Logger

  @start_after_ms 5_000
  @pause_ms 20

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    if Application.get_env(:openresults, :results_index_backfill, true) do
      Process.send_after(self(), :run, Keyword.get(opts, :start_after_ms, @start_after_ms))
    end

    {:ok, opts}
  end

  @impl GenServer
  def handle_info(:run, state) do
    started = System.monotonic_time(:millisecond)

    case OpenResults.ResultsIndex.reindex(pause_ms: @pause_ms) do
      0 ->
        :ok

      count ->
        Logger.info(
          "Results index: brought #{count} tournament(s) up to date in " <>
            "#{System.monotonic_time(:millisecond) - started} ms"
        )
    end

    {:noreply, state}
  rescue
    error ->
      Logger.error("Results index backfill failed: #{Exception.message(error)}")
      {:noreply, state}
  end
end
