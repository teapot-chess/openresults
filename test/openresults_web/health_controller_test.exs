defmodule OpenResultsWeb.HealthControllerTest do
  @moduledoc """
  `/healthz`: the shape, the headers, that a monitor polling it is never
  rate-limited or handed a cookie, and that only the database decides the
  status - a failing off-site backup is reported, not obeyed.
  """
  use OpenResultsWeb.ConnCase, async: false

  alias OpenResults.Ops.OffsiteBackupRun
  alias OpenResults.Repo

  test "200, the version and a word per check, and nothing else", %{conn: conn} do
    conn = get(conn, "/healthz")

    assert json_response(conn, 200) == %{
             "status" => "ok",
             "version" => to_string(Application.spec(:openresults, :vsn)),
             "checks" => %{"database" => "ok", "backup" => "disabled"}
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "set-cookie") == []
  end

  test "polled hard, it never answers anything but 200" do
    statuses =
      for _ <- 1..150 do
        build_conn()
        |> Map.put(:remote_ip, {203, 0, 113, 9})
        |> put_req_header("cf-connecting-ip", "203.0.113.9")
        |> get("/healthz")
        |> Map.fetch!(:status)
      end

    assert Enum.uniq(statuses) == [200]
  end

  test "a failing off-site backup is reported and does not flip the status", %{conn: conn} do
    previous = Application.fetch_env(:openresults, :offsite_backup)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:openresults, :offsite_backup, value)
        :error -> Application.delete_env(:openresults, :offsite_backup)
      end
    end)

    {_secret, public} = OpenResults.Ops.Age.generate_identity()

    Application.put_env(:openresults, :offsite_backup,
      recipients: [public],
      s3: [
        endpoint: "https://objects.example.test",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: "s"
      ]
    )

    now = DateTime.utc_now(:second)

    Repo.insert!(%OffsiteBackupRun{
      status: "failed",
      error: "storage answered HTTP 403 (AccessDenied)",
      started_at: now,
      finished_at: now
    })

    body = conn |> get("/healthz") |> json_response(200)

    assert body["status"] == "ok"
    assert body["checks"]["backup"] == "failing"
    refute inspect(body) =~ "objects.example.test"
  end
end
