defmodule OpenResults.Ops.ErrorReports.Recorder do
  @moduledoc """
  The one process that writes crash reports, so the crashing ones never do.

  Two guards, both against the same failure - the thing that records crashes
  becoming the crash:

    * `ErrorReports.record/2` rescues everything, so a locked or missing
      database is a lost report, not a restart. A recorder that crashed on a
      bad database would log a crash, which it would be asked to record, on
      the same bad database.
    * the mailbox is capped: when a hundred reports are already waiting (a
      crash loop somewhere), further ones are dropped until it drains. The
      count on the row will be low; the page will still show the row.

  No e-mail, unlike the arbiter app's: this server sends no mail at all, and
  growing an SMTP client to announce its own crashes would be one more thing
  to crash. The admin page is where they are read.
  """
  use GenServer

  alias OpenResults.Ops.ErrorReports

  @max_queue 100

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Hands a sanitized report over. Never blocks, never raises."
  def capture(server \\ __MODULE__, report) do
    case GenServer.whereis(server) do
      nil ->
        :ok

      pid ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, n} when n < @max_queue -> GenServer.cast(pid, {:capture, report})
          _ -> :ok
        end
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:capture, report}, state) do
    ErrorReports.record(report)
    {:noreply, state}
  end
end
