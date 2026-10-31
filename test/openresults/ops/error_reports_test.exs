defmodule OpenResults.Ops.ErrorReportsTest do
  @moduledoc """
  The sanitizer is the specification: what a crash report may keep, and
  what it must not - arguments, inspected terms, addresses, tokens. Then the
  table: one row per kind, counted, capped. Then the path a real crash takes:
  the logger handler, the recorder, the row.
  """
  use OpenResults.DataCase, async: false

  alias OpenResults.Ops.ErrorReports
  alias OpenResults.Ops.ErrorReports.{LoggerHandler, Recorder}

  defp frame(module, fun, arity_or_args, line \\ 10),
    do: {module, fun, arity_or_args, [file: ~c"lib/thing.ex", line: line]}

  defp report(overrides \\ %{}) do
    Map.merge(
      %{
        fingerprint: "fp-#{System.unique_integer([:positive])}",
        kind: "RuntimeError",
        message: "boom",
        location: "OpenResults.Thing.run/0",
        stacktrace: "OpenResults.Thing.run/0 (lib/thing.ex:10)"
      },
      overrides
    )
  end

  describe "from_crash/1, the sanitizer" do
    test "a FunctionClauseError keeps the arity and drops the arguments" do
      args = ["jane@example.org", %{password: "hunter2"}]

      report =
        ErrorReports.from_crash(
          {%FunctionClauseError{module: OpenResults.Thing, function: :run, arity: 2},
           [frame(OpenResults.Thing, :run, args), frame(Enum, :map, 2)]}
        )

      assert report.kind == "FunctionClauseError"
      assert report.location == "OpenResults.Thing.run/2"
      assert report.stacktrace =~ "OpenResults.Thing.run/2 (lib/thing.ex:10)"
      everything = report.message <> report.stacktrace <> report.location
      refute everything =~ "hunter2"
      refute everything =~ "jane@example.org"
      refute everything =~ "password"
    end

    test "a MatchError keeps its sentence and loses the term" do
      reason = %MatchError{term: %{email: "jane@example.org", name: "Jane Player"}}
      report = ErrorReports.from_crash({reason, [frame(OpenResults.Thing, :run, 0)]})

      assert report.kind == "MatchError"
      assert report.message =~ "no match of right hand side value"
      refute report.message =~ "Jane"
      refute report.message =~ "example.org"
    end

    test "addresses and long tokens are scrubbed out of a message" do
      message =
        "could not notify jane.player@example.org with key " <> String.duplicate("a1B2", 10)

      report = ErrorReports.from_crash({%RuntimeError{message: message}, []})

      assert report.message =~ "[email]"
      assert report.message =~ "[redacted]"
      refute report.message =~ "jane.player"
      refute report.message =~ "a1B2a1B2"
    end

    test "only the first paragraph survives, at most 300 characters" do
      long = String.duplicate("x", 20) <> " " <> String.duplicate("word ", 100)
      message = long <> "\n\nsecond paragraph with the changeset in it"

      sanitized = ErrorReports.sanitize_message(message)

      refute sanitized =~ "second paragraph"
      assert String.length(sanitized) <= 300
    end

    test "an exception Plug maps to a 4xx is not a crash" do
      assert ErrorReports.from_crash({%Plug.BadRequestError{}, []}) == :ignore
    end

    test "an exit and a throw keep their shape, not their contents" do
      exit = ErrorReports.from_crash({{:shutdown, "jane@example.org", 42}, []})
      assert exit.kind == "exit"
      assert exit.message == "exit: {:shutdown, [string], [number]}"

      thrown = ErrorReports.from_crash({{:nocatch, %{secret: "s3cret"}}, []})
      assert thrown.kind == "throw"
      refute thrown.message =~ "s3cret"
    end

    test "the same bug on another line is the same fingerprint" do
      reason = %RuntimeError{message: "boom"}
      a = ErrorReports.from_crash({reason, [frame(OpenResults.Thing, :run, 0, 10)]})
      b = ErrorReports.from_crash({reason, [frame(OpenResults.Thing, :run, 0, 99)]})
      c = ErrorReports.from_crash({reason, [frame(OpenResults.Other, :run, 0, 10)]})

      assert a.fingerprint == b.fingerprint
      refute a.fingerprint == c.fingerprint
    end

    test "the location is the first frame of this app, not of a library" do
      report =
        ErrorReports.from_crash(
          {%RuntimeError{message: "boom"},
           [frame(Enum, :map, 2), frame(OpenResults.Thing, :run, 1), frame(Kernel, :apply, 3)]}
        )

      assert report.location == "OpenResults.Thing.run/1"
    end
  end

  describe "the table" do
    test "a second crash of the same kind counts, it does not add a row" do
      first = report()
      t0 = ~U[2026-10-31 10:00:00Z]
      t1 = ~U[2026-10-31 11:00:00Z]

      assert {:new, _row} = ErrorReports.record(first, t0)
      assert {:seen, row} = ErrorReports.record(%{first | message: "boom again"}, t1)

      assert row.count == 2
      assert [stored] = ErrorReports.list()
      assert stored.count == 2
      assert stored.first_seen_at == t0
      assert stored.last_seen_at == t1
      assert stored.message == "boom again"
    end

    test "at most #{200} rows; the least recently seen go first" do
      max = ErrorReports.max_rows()
      start = ~U[2026-10-01 00:00:00Z]

      for i <- 1..(max + 5) do
        ErrorReports.record(report(%{fingerprint: "cap-#{i}"}), DateTime.add(start, i, :minute))
      end

      rows = ErrorReports.list()
      assert length(rows) == max
      fingerprints = MapSet.new(rows, & &1.fingerprint)
      refute "cap-1" in fingerprints
      refute "cap-5" in fingerprints
      assert "cap-6" in fingerprints
      assert "cap-#{max + 5}" in fingerprints
    end

    test "get, delete and clear" do
      {:new, a} = ErrorReports.record(report())
      {:new, _b} = ErrorReports.record(report())

      assert ErrorReports.get(to_string(a.id)).id == a.id
      assert ErrorReports.get("nope") == nil
      ErrorReports.delete(a.id)
      assert length(ErrorReports.list()) == 1
      ErrorReports.clear()
      assert ErrorReports.list() == []
    end
  end

  describe "a crash, from the logger to the row" do
    test "the handler hands a sanitized report to the recorder, which writes it" do
      pid = start_supervised!({Recorder, name: :error_reports_test_recorder})
      Ecto.Adapters.SQL.Sandbox.allow(OpenResults.Repo, self(), pid)

      event = %{
        level: :error,
        msg: {:string, "crashed"},
        meta: %{
          crash_reason:
            {%RuntimeError{message: "boom for jane@example.org"},
             [frame(OpenResults.Thing, :run, [%{password: "hunter2"}])]}
        }
      }

      assert :ok = LoggerHandler.log(event, %{config: %{recorder: :error_reports_test_recorder}})
      _ = :sys.get_state(pid)

      assert [row] = ErrorReports.list()
      assert row.kind == "RuntimeError"
      assert row.message == "boom for [email]"
      assert row.location == "OpenResults.Thing.run/1"
      refute row.stacktrace =~ "hunter2"
    end

    test "an event without a crash_reason, or a 4xx, is not recorded" do
      pid = start_supervised!({Recorder, name: :error_reports_test_recorder})
      Ecto.Adapters.SQL.Sandbox.allow(OpenResults.Repo, self(), pid)
      config = %{config: %{recorder: :error_reports_test_recorder}}

      assert :ok = LoggerHandler.log(%{level: :error, msg: {:string, "x"}, meta: %{}}, config)

      assert :ok =
               LoggerHandler.log(
                 %{level: :error, meta: %{crash_reason: {%Plug.BadRequestError{}, []}}},
                 config
               )

      _ = :sys.get_state(pid)
      assert ErrorReports.list() == []
    end

    test "a recorder that is not running loses the report and raises nothing" do
      event = %{level: :error, meta: %{crash_reason: {%RuntimeError{message: "boom"}, []}}}
      assert :ok = LoggerHandler.log(event, %{config: %{recorder: :no_such_recorder}})
    end
  end
end
