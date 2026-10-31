defmodule OpenResults.FideList.SyncTest do
  @moduledoc """
  When the list is looked for. The look itself is `RunTest`'s; here the
  runner is a function that tells the test it was called.
  """
  use OpenResults.FideListCase, async: true

  import ExUnit.CaptureLog

  alias OpenResults.FideList.{Store, Sync}

  describe "ms_until_slot/2" do
    test "later today when the slot is still ahead" do
      assert Sync.ms_until_slot(~U[2026-10-18 01:00:00Z], 3) == :timer.minutes(137)
    end

    test "tomorrow once it has passed" do
      assert Sync.ms_until_slot(~U[2026-10-18 03:17:00Z], 3) == :timer.hours(24)
      assert Sync.ms_until_slot(~U[2026-10-18 22:00:00Z], 3) == :timer.minutes(317)
    end
  end

  describe "due_at_boot?/3" do
    @now ~U[2026-10-18 12:00:00Z]

    test "with no list, always" do
      assert Sync.due_at_boot?(false, %{"last_check_at" => "2026-10-18T11:00:00Z"}, @now)
    end

    test "with a list looked at today, no" do
      refute Sync.due_at_boot?(true, %{"last_check_at" => "2026-10-18T03:17:00Z"}, @now)
    end

    test "with a list nobody has looked at for more than a day, yes" do
      assert Sync.due_at_boot?(true, %{"last_check_at" => "2026-10-17T03:17:00Z"}, @now)
      assert Sync.due_at_boot?(true, %{}, @now)
    end
  end

  defp start_sync(context, opts) do
    test_pid = self()

    runner =
      Keyword.get(opts, :runner, fn report: report ->
        report.(:checking, "looking")
        send(test_pid, :ran)
        :unchanged
      end)

    start_supervised!(
      {Sync,
       Keyword.merge(
         [
           name: nil,
           enabled: true,
           boot_delay: 0,
           hour: 3,
           repo: context.fide_repo,
           runner: runner
         ],
         Keyword.delete(opts, :runner)
       )}
    )
  end

  test "a fresh install looks straight after boot", context do
    start_sync(context, [])
    # Not the default 100 ms: the first look reads the FIDE repo before it
    # runs, and on a CI runner with 32 async cases that took longer once.
    assert_receive :ran, 2_000
  end

  test "a server with a list it looked at today waits for the slot", context do
    import_fixture!(context)
    pid = start_sync(context, [])

    refute_receive :ran, 100
    status = Sync.status(pid)
    refute status.running?
    assert %DateTime{} = status.next_run_at
    assert DateTime.diff(status.next_run_at, DateTime.utc_now(), :hour) <= 24
  end

  test "switched off, it never runs", context do
    pid = start_sync(context, enabled: false)

    refute_receive :ran, 100
    assert %{enabled?: false, next_run_at: nil} = Sync.status(pid)
  end

  test "a failed run is retried in an hour rather than tomorrow", context do
    test_pid = self()

    capture_log(fn ->
      pid =
        start_sync(context,
          runner: fn report: _report ->
            send(test_pid, :ran)
            {:error, "FIDE is having a day"}
          end
        )

      assert_receive :ran
      await_idle(pid)
      state = :sys.get_state(pid)
      assert state.failures == 1
      assert_in_delta DateTime.diff(state.next_run_at, DateTime.utc_now(), :minute), 60, 1
    end)
  end

  test "a run that crashes is recorded as failed and does not take the server with it",
       context do
    test_pid = self()

    capture_log(fn ->
      pid =
        start_sync(context,
          runner: fn report: _report ->
            send(test_pid, :ran)
            raise "boom"
          end
        )

      assert_receive :ran
      await_idle(pid)

      assert %{running?: false} = Sync.status(pid)
      assert Store.meta()["last_check_result"] == "failed"
      assert Store.meta()["last_error"] =~ "RuntimeError"
    end)
  end

  # The crash and its DOWN arrive when they arrive; each `:sys.get_state/1`
  # is a round trip that lets the server handle what is in its mailbox.
  defp await_idle(pid, tries \\ 1_000) do
    cond do
      :sys.get_state(pid).task == nil -> :ok
      tries == 0 -> flunk("the sync server never noticed its run ended")
      true -> await_idle(pid, tries - 1)
    end
  end

  test "status/1 of a server that is not there is nil, not a crash" do
    assert Sync.status(:no_such_sync_server) == nil
  end
end
