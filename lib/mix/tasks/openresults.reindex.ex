defmodule Mix.Tasks.Openresults.Reindex do
  @shortdoc "Rebuilds the results hub's index from the stored snapshots"

  @moduledoc """
  Rebuilds the results hub's index (`OpenResults.ResultsIndex`) from the
  snapshots this server holds.

      mix openresults.reindex          # only what is missing or stale
      mix openresults.reindex --force  # every tournament, from scratch

  The index is derived data: losing it loses nothing, and this puts it back.
  The boot backfill (`OpenResults.ResultsIndex.Backfill`) does the same in the
  background; this is the foreground version, for after a restore or when
  somebody wants to watch it happen.
  """

  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} = OptionParser.parse(args, strict: [force: :boolean])
    started = System.monotonic_time(:millisecond)

    count =
      OpenResults.ResultsIndex.reindex(
        force: Keyword.get(opts, :force, false),
        progress: fn done, total ->
          if rem(done, 100) == 0 or done == total, do: Mix.shell().info("#{done}/#{total}")
        end
      )

    Mix.shell().info(
      "Reindexed #{count} tournament(s) in #{System.monotonic_time(:millisecond) - started} ms."
    )
  end
end
