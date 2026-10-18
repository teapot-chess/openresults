defmodule OpenResults.FideList.Sync do
  @moduledoc """
  When `OpenResults.FideList.Run` runs, and what happens when it misbehaves.

  ## When

    * **Once a day, at a quiet hour** - `:fide_list_hour` (UTC, default 3),
      seventeen minutes past, so it does not land on the same second as
      every other cron job on the internet. On a day FIDE has not touched
      its file that is one `HEAD` request and nothing else; see
      `OpenResults.FideList.Source`.
    * **Shortly after boot** (`:fide_list_boot_delay_ms`, a minute by
      default), but only when there is no list yet - a fresh install - or the
      last check is more than a day old, which is what a server that was
      down at three in the morning looks like.
    * **An hour after a failed run**, three times in a row at most, then back
      to the daily slot. FIDE being down at 03:17 is a reason to try again
      at 04:17, not to wait until tomorrow; FIDE being down all night is a
      reason to stop knocking.

  ## Never in the way

  The work runs in a process of its own at low priority; this server only
  keeps time and answers `status/0`, so nothing that asks it ever waits on a
  download. A run that reports no progress for five minutes is killed - a
  socket that stopped talking without closing would otherwise hold the
  "running" state forever - and counts as a failed one.

  ## Off

  `config :openresults, :fide_list_sync, false` (tests, dev, and
  `OPENRESULTS_FIDE_LIST_SYNC=off`) starts this process without a timer. A
  list already in the database still answers searches; nothing fetches a new
  one.
  """

  use GenServer

  require Logger

  alias OpenResults.FideList.{Repo, Run, Store}

  @watchdog_ms :timer.minutes(5)
  @retry_ms :timer.hours(1)
  @max_retries 3
  @slot_minute 17
  @stale_after_s 25 * 60 * 60

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  What the server is doing right now, for the admin page: `%{enabled?,
  running?, phase, progress, next_run_at}`. `nil` when the process cannot be
  asked, which the page shows as "unknown" rather than failing.
  """
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, 2_000)
  catch
    :exit, _ -> nil
  end

  @doc "Starts a check now, unless one is running. For a remote console."
  def check_now(server \\ __MODULE__), do: send(server, :run)

  @doc """
  Milliseconds from `now` until the next daily slot at `hour`:17 UTC - later
  today if it is still ahead, otherwise tomorrow.
  """
  @spec ms_until_slot(DateTime.t(), 0..23) :: pos_integer()
  def ms_until_slot(%DateTime{} = now, hour) do
    today = DateTime.new!(DateTime.to_date(now), Time.new!(hour, @slot_minute, 0), "Etc/UTC")
    slot = if DateTime.compare(today, now) == :gt, do: today, else: DateTime.add(today, 1, :day)
    max(DateTime.diff(slot, now, :millisecond), 1)
  end

  @doc """
  Whether a boot should check soon instead of waiting for the slot: no list,
  or no check within the last 25 hours.
  """
  @spec due_at_boot?(boolean(), map(), DateTime.t()) :: boolean()
  def due_at_boot?(available?, meta, now) do
    with true <- available?,
         value when is_binary(value) <- Map.get(meta, "last_check_at"),
         {:ok, at, _offset} <- DateTime.from_iso8601(value) do
      DateTime.diff(now, at) >= @stale_after_s
    else
      _ -> true
    end
  end

  ## GenServer

  @impl true
  def init(opts) do
    state = %{
      enabled?: Keyword.get_lazy(opts, :enabled, &OpenResults.FideList.sync_enabled?/0),
      hour:
        Keyword.get_lazy(opts, :hour, fn ->
          Application.get_env(:openresults, :fide_list_hour, 3)
        end),
      boot_delay:
        Keyword.get_lazy(opts, :boot_delay, fn ->
          Application.get_env(:openresults, :fide_list_boot_delay_ms, :timer.minutes(1))
        end),
      repo: Keyword.get(opts, :repo, Repo),
      runner: Keyword.get(opts, :runner, &Run.once/1),
      phase: :idle,
      progress: nil,
      task: nil,
      watchdog: nil,
      timer: nil,
      next_run_at: nil,
      failures: 0
    }

    if state.enabled?, do: {:ok, state, {:continue, :boot}}, else: {:ok, state}
  end

  @impl true
  def handle_continue(:boot, state) do
    Repo.put_dynamic_repo(state.repo)

    due? =
      try do
        Store.ensure_meta!()
        due_at_boot?(Store.available?(), Store.meta(), DateTime.utc_now())
      rescue
        e ->
          Logger.warning("FIDE list: boot look failed (#{inspect(e.__struct__)}); checking soon")
          true
      end

    state =
      if due?, do: schedule(state, state.boot_delay), else: schedule_slot(state)

    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled?: state.enabled?,
       running?: state.task != nil,
       phase: state.phase,
       progress: state.progress,
       next_run_at: state.next_run_at
     }, state}
  end

  @impl true
  def handle_info(:run, %{task: nil} = state) do
    server = self()
    repo = state.repo
    runner = state.runner

    {pid, ref} =
      spawn_monitor(fn ->
        # A day's job sharing two cores with live tournaments: whatever a
        # request needs, it gets first.
        Process.flag(:priority, :low)
        Repo.put_dynamic_repo(repo)

        result = runner.(report: fn phase, text -> send(server, {:progress, phase, text}) end)
        send(server, {:finished, self(), result})
      end)

    state = cancel_timer(state)

    {:noreply,
     %{
       state
       | task: {pid, ref},
         phase: :checking,
         progress: nil,
         watchdog: arm_watchdog(nil, ref)
     }}
  end

  def handle_info(:run, state), do: {:noreply, state}

  def handle_info({:progress, phase, text}, %{task: {_pid, ref}} = state) do
    {:noreply,
     %{state | phase: phase, progress: text, watchdog: arm_watchdog(state.watchdog, ref)}}
  end

  def handle_info({:progress, _phase, _text}, state), do: {:noreply, state}

  def handle_info({:finished, pid, result}, %{task: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, result)}
  end

  def handle_info({:finished, _pid, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: {_pid2, ref}} = state) do
    reason = "the run stopped unexpectedly (#{exit_kind(reason)})"
    record_failure(state, reason)
    {:noreply, finish(state, {:error, reason})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # Tagged with the run's monitor, so a timer that fired just as its run
  # finished cannot stop the next one.
  def handle_info({:watchdog, ref}, %{task: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])
    Process.exit(pid, :kill)
    reason = "no progress for #{div(@watchdog_ms, 60_000)} minutes; the run was stopped"
    record_failure(state, reason)
    {:noreply, finish(state, {:error, reason})}
  end

  def handle_info({:watchdog, _ref}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  defp finish(state, result) do
    if state.watchdog, do: Process.cancel_timer(state.watchdog)
    state = %{state | task: nil, watchdog: nil, phase: :idle, progress: nil}

    case result do
      {:error, reason} ->
        failures = state.failures + 1
        Logger.warning("FIDE list check failed (#{failures} in a row): #{reason}")
        state = %{state | failures: failures}

        if failures <= @max_retries,
          do: schedule(state, @retry_ms),
          else: schedule_slot(state)

      :unchanged ->
        Logger.info("FIDE list: unchanged since the last import")
        schedule_slot(%{state | failures: 0})

      {:imported, n} ->
        Logger.info("FIDE list: imported #{n} players")
        schedule_slot(%{state | failures: 0})

      _other ->
        schedule_slot(state)
    end
  end

  # A killed run could not write its own last-check line; this writes it.
  defp record_failure(state, reason) do
    Repo.put_dynamic_repo(state.repo)

    Store.put_meta!(%{
      "last_check_at" =>
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "last_check_result" => "failed",
      "last_error" => reason
    })
  rescue
    _ -> :ok
  end

  defp exit_kind({%{__exception__: true} = e, _stack}), do: inspect(e.__struct__)
  defp exit_kind(reason) when is_atom(reason), do: inspect(reason)
  defp exit_kind(_reason), do: "exit"

  defp schedule_slot(state), do: schedule(state, ms_until_slot(DateTime.utc_now(), state.hour))

  defp schedule(state, ms) do
    state = cancel_timer(state)
    timer = Process.send_after(self(), :run, ms)
    %{state | timer: timer, next_run_at: DateTime.add(DateTime.utc_now(), ms, :millisecond)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil, next_run_at: nil}
  end

  defp arm_watchdog(old, ref) do
    if old, do: Process.cancel_timer(old)
    Process.send_after(self(), {:watchdog, ref}, @watchdog_ms)
  end
end
