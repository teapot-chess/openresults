defmodule OpenResults.Ops.OffsiteBackup do
  @moduledoc """
  Sends the newest local backup somewhere that is not this machine.

  `OpenResults.Backup` writes a backup a day into a
  directory on the same disk as the database it protects, and the deployment
  guide's off-site strategy was a person downloading one "now and then". A
  disk that dies takes both; so does a provider that loses the server. This
  is the "now and then", on a timer.

  ## Encrypted before it leaves, with a key the server does not have

  Every copy is encrypted to one or more age public keys
  (`OpenResults.Ops.Age`) on the way out. The server holds only the PUBLIC
  half, so it can write backups it cannot read: somebody who takes the box
  and the bucket credentials still gets nothing but ciphertext. The secret
  key lives with the operator, offline; `mix ops.age keygen` makes one and
  `age -d` (or `mix ops.age decrypt`) opens a copy. Lose every secret key and
  every off-site copy is noise - keep two, in two places, and list both
  public halves in `OFFSITE_BACKUP_RECIPIENTS`.

  That is on top of `OPENRESULTS_BACKUP_PASSPHRASE`, not instead of it: a backup
  that was already passphrase-encrypted is still passphrase-encrypted inside
  the age file, and restoring it needs both.

  ## Where it goes

  Any S3-compatible bucket (Hetzner Object Storage, Cloudflare R2, Backblaze
  B2, MinIO, AWS itself) by path-style `PUT`, signed with AWS SigV4 by Req -
  no SDK, no extra dependency. The object is
  `<prefix>/<backup file name>.age`. Deleting old ones is the bucket's job:
  set a lifecycle rule (docs/deployment.md, "Off-site backups").

  ## When

  `OpenResults.Ops.OffsiteBackup.Scheduler` looks every hour and sends the
  newest local backup if it has not been sent yet - so a failed send is
  retried within the hour, and a new local backup is off the box within an
  hour of being written. Nothing new, nothing sent.

  ## What it reports

  `status/0` is what `/healthz` and the admin page show:

    * `:disabled` - not configured, which is the default;
    * `:failing` - the most recent attempt failed;
    * `:stale` - nothing has been sent successfully for
      `OFFSITE_BACKUP_STALE_HOURS` (default 36), which is also what a server
      whose LOCAL backups have stopped looks like from here;
    * `:ok` - otherwise.

  Run history is kept (the last #{100}), and no run ever records a key, a
  secret, or a response body - S3 error replies quote the access key id and
  the string that was signed, so only the error code is kept.
  """

  import Ecto.Query

  alias OpenResults.Ops.{Age, OffsiteBackupRun}
  alias OpenResults.Repo

  require Logger

  @keep_runs 100
  @default_stale_hours 36

  # -- configuration ---------------------------------------------------------

  @doc "The configuration, from `config :openresults, :offsite_backup`."
  def config, do: Application.get_env(:openresults, :offsite_backup, [])

  @doc "Whether off-site backups are configured at all."
  def enabled?(config \\ config()) do
    s3 = config[:s3] || []

    config[:recipients] not in [nil, []] and
      Enum.all?([:endpoint, :bucket, :access_key_id, :secret_access_key], &present?(s3[&1]))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc "Hours without a successful send before the status is `:stale`."
  def stale_hours(config \\ config()), do: config[:stale_hours] || @default_stale_hours

  @doc """
  Reads the environment into the keyword list `config/runtime.exs` stores.
  Returns `{:ok, config}`, `:disabled` when none of the variables is set, or
  `{:error, message}` naming what is missing or malformed - never a value.
  """
  @spec from_env((String.t() -> String.t() | nil)) ::
          {:ok, keyword()} | :disabled | {:error, String.t()}
  def from_env(getenv \\ &System.get_env/1) do
    get = fn name -> blank_to_nil(getenv.(name)) end

    required = ~w(OFFSITE_BACKUP_RECIPIENTS OFFSITE_BACKUP_S3_ENDPOINT OFFSITE_BACKUP_S3_BUCKET
                  OFFSITE_BACKUP_S3_ACCESS_KEY_ID OFFSITE_BACKUP_S3_SECRET_ACCESS_KEY)

    case Enum.reject(required, &get.(&1)) do
      ^required ->
        :disabled

      [] ->
        build_config(get)

      missing ->
        {:error, "off-site backups are half configured; missing: " <> Enum.join(missing, ", ")}
    end
  end

  defp build_config(get) do
    recipients =
      get.("OFFSITE_BACKUP_RECIPIENTS") |> String.split([",", " ", "\n"], trim: true)

    with :ok <- check_recipients(recipients),
         {:ok, stale} <-
           positive_int(
             get.("OFFSITE_BACKUP_STALE_HOURS"),
             @default_stale_hours,
             "OFFSITE_BACKUP_STALE_HOURS"
           ),
         :ok <- check_endpoint(get.("OFFSITE_BACKUP_S3_ENDPOINT")) do
      {:ok,
       [
         recipients: recipients,
         stale_hours: stale,
         s3: [
           endpoint: String.trim_trailing(get.("OFFSITE_BACKUP_S3_ENDPOINT"), "/"),
           bucket: get.("OFFSITE_BACKUP_S3_BUCKET"),
           region: get.("OFFSITE_BACKUP_S3_REGION") || "us-east-1",
           prefix: (get.("OFFSITE_BACKUP_S3_PREFIX") || "openresults") |> String.trim("/"),
           access_key_id: get.("OFFSITE_BACKUP_S3_ACCESS_KEY_ID"),
           secret_access_key: get.("OFFSITE_BACKUP_S3_SECRET_ACCESS_KEY")
         ]
       ]}
    end
  end

  defp check_recipients(recipients) do
    case Enum.find_index(recipients, &match?({:error, _}, Age.parse_recipient(&1))) do
      nil -> :ok
      i -> {:error, "OFFSITE_BACKUP_RECIPIENTS entry #{i + 1} is not an age public key (age1...)"}
    end
  end

  defp check_endpoint(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      # Plain http only for a bucket on this machine or the local network
      # (a MinIO next door); anything further away gets TLS or nothing.
      %URI{scheme: "http", host: host} when host in ["localhost", "127.0.0.1"] -> :ok
      _ -> {:error, "OFFSITE_BACKUP_S3_ENDPOINT must be an https:// URL"}
    end
  end

  defp positive_int(nil, default, _name), do: {:ok, default}

  defp positive_int(value, _default, name) do
    case Integer.parse(value) do
      {n, ""} when n >= 1 -> {:ok, n}
      _ -> {:error, "#{name} must be a whole number of at least 1"}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))

  # -- the work ----------------------------------------------------------------

  @doc """
  Sends the newest local backup unless it has already been sent. Returns
  `{:ok, object_key}`, `:nothing_new`, `:disabled`, or `{:error, reason}`;
  every send attempt (not `:nothing_new`) is recorded.

  Options: `:force` sends even when already sent; `:latest` overrides the
  local backup lookup (tests); `:config` overrides the configuration.
  """
  def push(opts \\ []) do
    config = Keyword.get_lazy(opts, :config, &config/0)

    if enabled?(config), do: push_latest(config, opts), else: :disabled
  end

  defp push_latest(config, opts) do
    case Keyword.get_lazy(opts, :latest, &latest_local/0) do
      nil ->
        record_failure(DateTime.utc_now(:second), nil, "no local backup to send")

      path ->
        key = object_key(config, path)

        if not Keyword.get(opts, :force, false) and already_sent?(key) do
          :nothing_new
        else
          send_one(config, path, key)
        end
    end
  end

  # The app's own newest backup. The only line here that knows which app
  # this is.
  defp latest_local do
    case OpenResults.Backup.list() do
      [%{path: path} | _] -> path
      [] -> nil
    end
  end

  defp object_key(config, path) do
    prefix = config[:s3][:prefix] || ""
    name = Path.basename(path) <> ".age"
    if prefix == "", do: name, else: prefix <> "/" <> name
  end

  defp already_sent?(key) do
    Repo.exists?(from r in OffsiteBackupRun, where: r.status == "ok" and r.object_key == ^key)
  end

  defp send_one(config, path, key) do
    started = DateTime.utc_now(:second)
    encrypted = path <> ".age.partial"

    try do
      with :ok <- Age.encrypt_file(path, encrypted, config[:recipients]),
           {:ok, bytes} <- upload(config, encrypted, key) do
        record(%{status: "ok", object_key: key, bytes: bytes, started_at: started})
        Logger.info("Off-site backup sent: #{key} (#{div(bytes, 1_000)} kB)")
        {:ok, key}
      else
        {:error, reason} -> record_failure(started, key, reason)
      end
    rescue
      error -> record_failure(started, key, "unexpected: " <> Exception.message(error))
    after
      File.rm(encrypted)
    end
  end

  defp upload(config, file, key) do
    s3 = config[:s3]
    size = File.stat!(file).size

    options =
      [
        method: :put,
        url: s3[:endpoint] <> "/" <> s3[:bucket] <> "/" <> encode_key(key),
        headers: [
          {"content-length", Integer.to_string(size)},
          {"content-type", "application/octet-stream"}
        ],
        body: File.stream!(file, 64 * 1024),
        aws_sigv4: [
          access_key_id: s3[:access_key_id],
          secret_access_key: s3[:secret_access_key],
          region: s3[:region] || "us-east-1",
          service: :s3
        ],
        retry: :transient,
        max_retries: 2,
        receive_timeout: 120_000,
        decode_body: false
      ]
      |> Keyword.merge(Application.get_env(:openresults, :offsite_backup_req_options, []))

    case Req.request(options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        {:ok, size}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, "storage answered HTTP #{status}" <> s3_code(body)}

      {:error, exception} ->
        {:error, "could not reach the storage: " <> safe_message(exception)}
    end
  end

  defp encode_key(key),
    do:
      key
      |> String.split("/")
      |> Enum.map_join("/", fn part -> URI.encode(part, &URI.char_unreserved?/1) end)

  # Only the <Code>: the rest of an S3 error reply can quote the access key
  # id and the canonical request.
  defp s3_code(body) when is_binary(body) do
    case Regex.run(~r"<Code>([A-Za-z0-9.]{1,64})</Code>", body) do
      [_, code] -> " (#{code})"
      _ -> ""
    end
  end

  defp s3_code(_), do: ""

  defp safe_message(%{reason: reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_message(exception) when is_exception(exception), do: exception.__struct__ |> inspect()
  defp safe_message(_), do: "unknown error"

  defp record_failure(started, key, reason) do
    record(%{
      status: "failed",
      object_key: key,
      error: String.slice(reason, 0, 300),
      started_at: started
    })

    Logger.warning("Off-site backup FAILED: #{reason}")
    {:error, reason}
  end

  defp record(attrs) do
    Repo.insert!(
      struct(OffsiteBackupRun, Map.put(attrs, :finished_at, DateTime.utc_now(:second)))
    )

    keep = from(r in OffsiteBackupRun, order_by: [desc: r.id], limit: @keep_runs, select: r.id)
    Repo.delete_all(from r in OffsiteBackupRun, where: r.id not in subquery(keep))
  end

  # -- reporting --------------------------------------------------------------

  @doc "The most recent runs, newest first."
  def runs(limit \\ 20) do
    Repo.all(from r in OffsiteBackupRun, order_by: [desc: r.id], limit: ^limit)
  end

  @doc "`:disabled`, `:failing`, `:stale` or `:ok` - see the moduledoc."
  def status(config \\ config(), now \\ DateTime.utc_now()) do
    if enabled?(config) do
      last = Repo.one(from r in OffsiteBackupRun, order_by: [desc: r.id], limit: 1)

      last_ok =
        Repo.one(
          from r in OffsiteBackupRun,
            where: r.status == "ok",
            order_by: [desc: r.id],
            limit: 1,
            select: r.finished_at
        )

      cond do
        last && last.status == "failed" -> :failing
        is_nil(last_ok) -> :stale
        DateTime.diff(now, last_ok, :hour) >= stale_hours(config) -> :stale
        true -> :ok
      end
    else
      :disabled
    end
  rescue
    _ -> :failing
  end
end
