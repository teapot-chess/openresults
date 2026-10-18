defmodule OpenResults.FideList.RunTest do
  @moduledoc """
  One check, start to finish, against a stubbed server: what is downloaded,
  when nothing is, and that a bad list never replaces a good one.
  """
  use OpenResults.FideListCase, async: true

  import ExUnit.CaptureLog

  alias OpenResults.FideList.{Repo, Run, Store, ZipLines}

  describe "a fresh install" do
    test "imports the list and makes it searchable", context do
      log = serve_list(zip_of(fixture_text()))

      refute FideList.available?()
      assert {:imported, 8} = run_once(context)
      assert FideList.available?()
      assert requests(log) == ["HEAD", "GET"]

      assert {:ok, [%{"name" => "De Vos, Jan"} | _]} = FideList.search("de vos")
    end

    test "records which list it imported, and when it looked", context do
      import_fixture!(context)

      meta = Store.meta()
      assert meta["etag"] == ~s("v1")
      assert meta["last_modified"] == "Sat, 01 Nov 2026 06:00:00 GMT"
      assert meta["player_count"] == "8"
      assert meta["last_check_result"] == "imported"
      assert {:ok, _, _} = DateTime.from_iso8601(meta["last_check_at"])
      refute Map.has_key?(meta, "last_error")
    end

    test "leaves no zip behind", context do
      import_fixture!(context)
      assert File.ls!(Path.join(context.fide_dir, "work")) == []
    end
  end

  describe "only if new" do
    setup context do
      import_fixture!(context)
      :ok
    end

    test "the same list again costs one HEAD and nothing else", context do
      log = serve_list(zip_of(fixture_text()))

      assert :unchanged = run_once(context)
      assert requests(log) == ["HEAD"]
      assert Store.meta()["last_check_result"] == "unchanged"
    end

    test "a new ETag is a new list", context do
      text = fixture_text() |> String.replace("De Vos, Jan   ", "De Vos, Johan ")
      log = serve_list(zip_of(text), [{"etag", ~s("v2")}])

      assert {:imported, 8} = run_once(context)
      assert requests(log) == ["HEAD", "GET"]
      assert {:ok, [%{"name" => "De Vos, Johan"}]} = FideList.search("de vos johan")
      assert Store.meta()["etag"] == ~s("v2")
    end

    test "a server that refuses HEAD is asked conditionally, and a 304 is nothing new",
         context do
      test_pid = self()

      Req.Test.stub(OpenResults.FideList.Source, fn conn ->
        send(test_pid, {:asked, conn.method, Map.new(conn.req_headers)})

        if conn.method == "HEAD",
          do: Plug.Conn.send_resp(conn, 405, ""),
          else: Plug.Conn.send_resp(conn, 304, "")
      end)

      assert :unchanged = run_once(context)
      assert_received {:asked, "HEAD", _}
      assert_received {:asked, "GET", headers}
      assert headers["if-none-match"] == ~s("v1")
      assert headers["if-modified-since"] == "Sat, 01 Nov 2026 06:00:00 GMT"
    end

    test "an unreachable server is a failed check, not a download", context do
      Req.Test.stub(OpenResults.FideList.Source, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, reason} = run_once(context)
      assert reason =~ "econnrefused"
      assert Store.meta()["last_check_result"] == "failed"
      assert Store.meta()["last_error"] == reason
      # And the list that was there is still there.
      assert {:ok, [_ | _]} = FideList.search("de vos")
    end
  end

  describe "a bad download never replaces a good list" do
    setup context do
      import_fixture!(context)
      :ok
    end

    test "one that is far smaller than the live list", context do
      [header | lines] = :binary.split(fixture_text(), "\r\n", [:global])
      text = Enum.join([header | Enum.take(lines, 2)], "\r\n")
      serve_list(zip_of(text), [{"etag", ~s("short")}])

      assert {:error, reason} = run_once(context)
      assert reason =~ "truncated"
      assert Store.live_count() == 8
      assert Store.meta()["etag"] == ~s("v1")
    end

    test "one that is not a zip", context do
      serve_list("<html>Service Unavailable</html>", [{"etag", ~s("html")}])

      assert {:error, reason} = run_once(context)
      assert reason =~ "not a zip"
      assert Store.live_count() == 8
    end

    test "one whose header is not FIDE's", context do
      serve_list(zip_of("Name;Rating\r\nDe Vos;2000\r\n"), [{"etag", ~s("csv")}])

      assert {:error, reason} = run_once(context)
      assert reason =~ "column"
      assert Store.live_count() == 8
    end

    test "an HTTP error", context do
      Req.Test.stub(OpenResults.FideList.Source, fn conn ->
        if conn.method == "HEAD",
          do: conn |> Plug.Conn.put_resp_header("etag", ~s("v9")) |> Plug.Conn.send_resp(200, ""),
          else: Plug.Conn.send_resp(conn, 503, "busy")
      end)

      assert {:error, "the list's server answered HTTP 503"} = run_once(context)
      assert Store.live_count() == 8
    end
  end

  test "a run killed halfway leaves only a scratch table, which the next run clears",
       context do
    import_fixture!(context)
    # What a kill between two chunks leaves behind.
    Store.begin_scratch!()
    Store.insert_chunk!([%{fide_id: 1, name: "Half, A", search_key: "half a"}])

    # The live list is untouched by it ...
    assert Store.live_count() == 8
    assert {:ok, []} = FideList.search("half")

    # ... and the next real import neither trips over it nor keeps it.
    serve_list(zip_of(fixture_text()), [{"etag", ~s("v2")}])
    assert {:imported, 8} = run_once(context)

    %{rows: tables} =
      Repo.query!("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")

    assert List.flatten(tables) == ["fide_list_meta", "fide_players"]
  end

  test "each import's index takes the name the last one is not using", context do
    import_fixture!(context)
    serve_list(zip_of(fixture_text()), [{"etag", ~s("v2")}])
    {:imported, _} = run_once(context)
    serve_list(zip_of(fixture_text()), [{"etag", ~s("v3")}])
    {:imported, _} = run_once(context)

    %{rows: indexes} =
      Repo.query!(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'fide_players'"
      )

    assert length(indexes) == 1

    # And searches use it rather than reading every row.
    %{rows: plan} =
      Repo.query!(
        "EXPLAIN QUERY PLAN SELECT fide_id FROM fide_players WHERE search_key >= ? AND search_key < ?",
        ["de", "df"]
      )

    assert inspect(plan) =~ ~r/USING (COVERING )?INDEX fide_players_key/
  end

  describe "the zip reader" do
    test "refuses a zip whose text is bigger than anybody's list", context do
      path = Path.join(context.fide_dir, "big.zip")
      File.write!(path, zip_of(:binary.copy("x", 10_000)))

      assert_raise OpenResults.FideList.ImportError, ~r/limit/, fn ->
        path |> ZipLines.stream!(1_000) |> Enum.to_list()
      end
    end

    test "reads lines across chunk boundaries", context do
      lines = for i <- 1..5_000, do: "line #{i} " <> :binary.copy("y", i |> rem(40))
      path = Path.join(context.fide_dir, "lines.zip")
      File.write!(path, zip_of(Enum.join(lines, "\r\n")))

      assert path |> ZipLines.stream!(10_000_000) |> Enum.to_list() == lines
    end

    test "a zip with no text file in it", context do
      path = Path.join(context.fide_dir, "notext.zip")
      File.write!(path, zip_of("hello", ~c"readme.pdf"))

      assert_raise OpenResults.FideList.ImportError, ~r/no .txt/, fn ->
        ZipLines.stream!(path, 1_000)
      end
    end
  end

  test "progress is reported as the run goes", context do
    serve_list(zip_of(fixture_text()))
    test_pid = self()

    {:imported, 8} = run_once(context, report: fn phase, _text -> send(test_pid, phase) end)

    assert_received :checking
    assert_received :downloading
    assert_received :importing
  end

  test "Run.once/1 without a stub never reaches the network" do
    # The suite's `:fide_list_req_options` routes every request to Req.Test;
    # with no stub this test owns, the request fails - it does not go out.
    capture_log(fn ->
      assert {:error, _reason} = Run.once(work_dir: System.tmp_dir!())
    end)
  end
end
