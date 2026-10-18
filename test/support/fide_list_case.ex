defmodule OpenResults.FideListCase do
  @moduledoc """
  A FIDE list database of the test's own: a fresh file, a repo started on it,
  and that repo made this process's `OpenResults.FideList.Repo` (a dynamic
  repo, so nothing else - other tests included - ever sees it).

  No sandbox, on purpose. What the list's code does that is worth testing is
  commit chunk by chunk and rename tables in a transaction of its own, and a
  sandbox would wrap all of it in one transaction that never commits.

  The fixture is `test/fixtures/fide/players_list_foa.txt`: eight invented
  players in FIDE's layout, Latin-1 and CRLF as FIDE writes it, with a blank
  line, a line of spaces and a line with no id at the end.
  """

  use ExUnit.CaseTemplate

  alias OpenResults.FideList.{Repo, Run}

  using do
    quote do
      import OpenResults.FideListCase
      alias OpenResults.FideList
    end
  end

  @fixture Path.expand("../fixtures/fide/players_list_foa.txt", __DIR__)

  setup context, do: setup_fide_list(context)

  @doc """
  The setup itself, for a test built on another case template: `setup
  :setup_fide_list` after `import OpenResults.FideListCase`.
  """
  def setup_fide_list(_context) do
    dir = Path.join(root(), "#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    repo =
      ExUnit.Callbacks.start_supervised!(
        {Repo, name: nil, database: Path.join(dir, "fide_list.db"), pool_size: 1},
        id: :fide_list_repo
      )

    Repo.put_dynamic_repo(repo)

    # Best effort - see `root/0` for when it is not enough.
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)

    %{fide_repo: repo, fide_dir: dir}
  end

  @doc """
  Where the tests' list databases go: the project's own `tmp/`, emptied when
  the suite starts (`test/test_helper.exs`). Not the system's temp directory:
  on Windows SQLite's file can still be open for a moment after its repo
  stops, so a test cannot always delete its own, and a leftover there would
  sit next to the next run's - with the counter in its name starting again
  from the same numbers.
  """
  def root do
    Path.expand("../../tmp/fide_list_test#{System.get_env("MIX_TEST_PARTITION")}", __DIR__)
  end

  @doc "The fixture's bytes."
  def fixture_text, do: File.read!(@fixture)

  @doc "`text` as a zip holding `players_list_foa.txt`, as bytes."
  def zip_of(text, name \\ ~c"players_list_foa.txt") do
    {:ok, {_name, zip}} = :zip.create(~c"players_list.zip", [{name, text}], [:memory])
    zip
  end

  @doc """
  Answers every request for the list with `zip` and the given validators;
  `:head` requests get the headers without the body. Returns the stub's
  request log as an Agent, so a test can ask what was asked.
  """
  def serve_list(
        zip,
        headers \\ [{"etag", ~s("v1")}, {"last-modified", "Sat, 01 Nov 2026 06:00:00 GMT"}]
      ) do
    {:ok, log} = Agent.start_link(fn -> [] end)

    Req.Test.stub(OpenResults.FideList.Source, fn conn ->
      Agent.update(log, &[{conn.method, conn.req_headers} | &1])

      conn =
        Enum.reduce(headers, conn, fn {name, value}, conn ->
          Plug.Conn.put_resp_header(conn, name, value)
        end)

      if conn.method == "HEAD",
        do: Plug.Conn.send_resp(conn, 200, ""),
        else: Plug.Conn.send_resp(conn, 200, zip)
    end)

    log
  end

  @doc "The methods the stub saw, oldest first."
  def requests(log), do: log |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(&elem(&1, 0))

  @doc "Runs one check in this process, with the zip in the test's directory."
  def run_once(context, opts \\ []) do
    Run.once(Keyword.merge([work_dir: Path.join(context.fide_dir, "work")], opts))
  end

  @doc "Imports the fixture as the live list."
  def import_fixture!(context) do
    serve_list(zip_of(fixture_text()))
    {:imported, _n} = run_once(context)
    :ok
  end
end
