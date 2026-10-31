defmodule OpenResults.Ops.OffsiteBackup.Scheduler do
  @moduledoc """
  Looks once an hour for a local backup that has not left the box yet, and
  sends it (`OpenResults.Ops.OffsiteBackup.push/1`).

  Hourly, not daily, because the local backups already decide the rhythm:
  this only has to notice a new one, and notice soon enough that a failed
  send gets another go the same morning. A look that finds nothing new costs
  one indexed query.

  Idle - started, never ticking - when off-site backups are not configured,
  and in the test environment (`interval: :disabled`), where `push/1` is
  called directly.
  """
  use GenServer

  alias OpenResults.Ops.OffsiteBackup

  @interval :timer.hours(1)
  @first_run :timer.minutes(10)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    interval =
      Keyword.get_lazy(opts, :interval, fn ->
        Application.get_env(:openresults, :offsite_backup_interval, @interval)
      end)

    if interval != :disabled and OffsiteBackup.enabled?() do
      Process.send_after(self(), :tick, @first_run)
    end

    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:tick, state) do
    # push/1 records its own failures and never raises for the ordinary ones;
    # this catch is for the extraordinary, so the timer survives them.
    try do
      OffsiteBackup.push()
    rescue
      _ -> :error
    end

    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end
end
