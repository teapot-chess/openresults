defmodule OpenResults.Ops.OffsiteBackupTest do
  @moduledoc """
  Off-site backups: the environment is read strictly, a send is a signed PUT
  of age ciphertext that opens back into the local file, a refusal keeps only
  S3's error code, nothing already sent is sent twice, and the status says
  which of the four states it is in. Every PUT goes to a `Req.Test` stub
  (config/test.exs).
  """
  use OpenResults.DataCase, async: false

  @moduletag :capture_log

  alias OpenResults.Ops.{Age, OffsiteBackup, OffsiteBackupRun}
  alias OpenResults.Repo

  @stub OpenResults.Ops.OffsiteBackup

  setup do
    {secret, public} = Age.generate_identity()
    dir = Path.join(System.tmp_dir!(), "offsite-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "openresults-20261031-120000.orbak")
    bytes = "ORBAK1" <> :crypto.strong_rand_bytes(5_000)
    File.write!(path, bytes)

    config = [
      recipients: [public],
      stale_hours: 36,
      s3: [
        endpoint: "https://objects.example.test",
        bucket: "backups",
        region: "eu-central",
        prefix: "openresults",
        access_key_id: "AKIDEXAMPLE",
        secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
      ]
    ]

    {:ok, secret: secret, public: public, path: path, bytes: bytes, config: config}
  end

  defp env(vars), do: fn name -> Map.get(vars, name) end

  defp full_env(public) do
    %{
      "OFFSITE_BACKUP_RECIPIENTS" => public,
      "OFFSITE_BACKUP_S3_ENDPOINT" => "https://objects.example.test/",
      "OFFSITE_BACKUP_S3_BUCKET" => "backups",
      "OFFSITE_BACKUP_S3_ACCESS_KEY_ID" => "AKIDEXAMPLE",
      "OFFSITE_BACKUP_S3_SECRET_ACCESS_KEY" => "secret"
    }
  end

  describe "from_env/1" do
    test "nothing set is disabled" do
      assert OffsiteBackup.from_env(env(%{})) == :disabled
      assert OffsiteBackup.from_env(env(%{"OFFSITE_BACKUP_S3_BUCKET" => "  "})) == :disabled
    end

    test "half a configuration is an error that names what is missing, never a value", %{
      public: public
    } do
      vars = full_env(public) |> Map.delete("OFFSITE_BACKUP_S3_SECRET_ACCESS_KEY")

      assert {:error, message} = OffsiteBackup.from_env(env(vars))
      assert message =~ "OFFSITE_BACKUP_S3_SECRET_ACCESS_KEY"
      refute message =~ "AKIDEXAMPLE"
    end

    test "a recipient that is not an age public key is refused", %{public: public} do
      vars = Map.put(full_env(public), "OFFSITE_BACKUP_RECIPIENTS", public <> ",ssh-ed25519 AAAA")

      assert {:error, message} = OffsiteBackup.from_env(env(vars))
      assert message =~ "entry 2"
    end

    test "plain http is refused for anything but this machine", %{public: public} do
      vars =
        Map.put(full_env(public), "OFFSITE_BACKUP_S3_ENDPOINT", "http://objects.example.test")

      assert {:error, _} = OffsiteBackup.from_env(env(vars))
    end

    test "a full configuration, with the defaults filled in", %{public: public} do
      assert {:ok, config} = OffsiteBackup.from_env(env(full_env(public)))

      assert config[:recipients] == [public]
      assert config[:stale_hours] == 36
      assert config[:s3][:endpoint] == "https://objects.example.test"
      assert config[:s3][:region] == "us-east-1"
      assert config[:s3][:prefix] == "openresults"
      assert OffsiteBackup.enabled?(config)
    end

    test "a stale threshold that is not a positive whole number is refused", %{public: public} do
      vars = Map.put(full_env(public), "OFFSITE_BACKUP_STALE_HOURS", "0")
      assert {:error, message} = OffsiteBackup.from_env(env(vars))
      assert message =~ "OFFSITE_BACKUP_STALE_HOURS"
    end
  end

  describe "push/1" do
    test "a signed PUT of age ciphertext that decrypts back to the local backup", ctx do
      test = self()

      Req.Test.stub(@stub, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
        send(test, {:put, conn.method, conn.request_path, conn.req_headers, body})
        Plug.Conn.send_resp(conn, 200, "")
      end)

      assert {:ok, key} = OffsiteBackup.push(config: ctx.config, latest: ctx.path)
      assert key == "openresults/openresults-20261031-120000.orbak.age"

      assert_received {:put, "PUT", "/backups/openresults/openresults-20261031-120000.orbak.age",
                       headers, body}

      assert {"authorization", "AWS4-HMAC-SHA256" <> _} =
               List.keyfind(headers, "authorization", 0)

      refute body == ctx.bytes
      assert "age-encryption.org/v1" <> _ = body
      assert Age.decrypt(body, ctx.secret) == {:ok, ctx.bytes}

      assert [%OffsiteBackupRun{status: "ok", object_key: ^key, bytes: bytes}] =
               OffsiteBackup.runs()

      assert bytes == byte_size(body)
      # The encrypted copy is not left behind beside the backup.
      refute File.exists?(ctx.path <> ".age.partial")
    end

    test "a refusal keeps the HTTP status and S3's code, nothing else", ctx do
      Req.Test.stub(@stub, fn conn ->
        Plug.Conn.send_resp(conn, 403, """
        <?xml version="1.0" encoding="UTF-8"?>
        <Error><Code>SignatureDoesNotMatch</Code><AccessKeyId>AKIDEXAMPLE</AccessKeyId>
        <StringToSign>AWS4-HMAC-SHA256 secret-ish</StringToSign></Error>
        """)
      end)

      assert {:error, reason} = OffsiteBackup.push(config: ctx.config, latest: ctx.path)
      assert reason == "storage answered HTTP 403 (SignatureDoesNotMatch)"

      assert [%OffsiteBackupRun{status: "failed", error: error}] = OffsiteBackup.runs()
      assert error == reason
      refute error =~ "AKIDEXAMPLE"
    end

    test "what was sent is not sent again, unless forced", ctx do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 200, "") end)

      assert {:ok, _} = OffsiteBackup.push(config: ctx.config, latest: ctx.path)
      assert OffsiteBackup.push(config: ctx.config, latest: ctx.path) == :nothing_new
      assert length(OffsiteBackup.runs()) == 1

      assert {:ok, _} = OffsiteBackup.push(config: ctx.config, latest: ctx.path, force: true)
      assert length(OffsiteBackup.runs()) == 2
    end

    test "nothing configured sends nothing", ctx do
      assert OffsiteBackup.push(config: [], latest: ctx.path) == :disabled
      assert OffsiteBackup.runs() == []
    end
  end

  describe "status/2" do
    defp run!(status, finished_at) do
      Repo.insert!(%OffsiteBackupRun{
        status: status,
        object_key: "openresults/x.orbak.age",
        started_at: finished_at,
        finished_at: finished_at
      })
    end

    test "disabled, stale, ok and failing", %{config: config} do
      now = ~U[2026-10-31 12:00:00Z]

      assert OffsiteBackup.status([], now) == :disabled
      # Configured, and nothing sent yet: stale, not ok.
      assert OffsiteBackup.status(config, now) == :stale

      run!("ok", DateTime.add(now, -2, :hour))
      assert OffsiteBackup.status(config, now) == :ok

      assert OffsiteBackup.status(config, DateTime.add(now, 36, :hour)) == :stale

      run!("failed", now)
      assert OffsiteBackup.status(config, now) == :failing
    end
  end
end
