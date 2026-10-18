defmodule OpenResults.ServerSettings do
  @moduledoc """
  The server settings an operator can change from the admin panel without a
  deploy: the operator's name, terms link and contact address, and the
  numbers that bound public publishing. `docs/public-publishing.md`, "Defaults".

  ## Precedence

  For every setting, the first of these that exists is in force:

    1. **panel** - a value saved in the admin panel (a row in
       `server_settings`);
    2. **environment** - what `config/runtime.exs` read from the setting's
       `OPENRESULTS_*` variable, or a config file set;
    3. **default** - the built-in value the contract documents.

  "Reset to default" deletes the panel's row, so the environment's value -
  or the default - is in force again. `describe/1` says which of the three a
  value came from.

  ## Validation

  `validate/2` is the one set of rules, and `config/runtime.exs` applies the
  same ranges to the environment at boot (`test/openresults/server_settings_test.exs`
  holds the two together): an input the panel refuses is one the boot
  refuses, and the other way round. A stored value that no longer passes -
  the rules tightened after it was saved - is ignored rather than trusted.

  ## What is never here

  `OPENRESULTS_PUBLIC_PUBLISHING`, the three admin-panel variables, the
  ingest token, the backup passphrase and retention, and every database,
  host and secret setting. They are security boundaries, or a mistake made
  with them in the panel could lock the operator out of the panel itself.
  `locked/0` lists them for the settings page: names, and whether each is
  set - never a secret's value.

  ## The cache

  These are read on hot paths - every publish reads a rate limit, a size cap
  and a version cap - so they are held in ETS and the database is read once:
  at boot, or on the first request after the cache was emptied. A change
  made through `OpenResults.Moderation` calls `refresh/0` after it commits,
  which re-reads and OVERWRITES; a reader filling a miss only inserts where
  nothing is, so a reader that read before a change committed cannot put the
  old values back over the writer's (the rule `OpenResults.Tournaments.StatusCache`
  sets out). The environment and defaults are not cached: they are
  application config, already in memory, and a test moves them with
  `Application.put_env/3`.

  The public notice (`OpenResults.PublicNotice`) is stored in the same table
  under `public_notice`, and cached with the rest.
  """

  use GenServer

  require Logger

  import Ecto.Query, warn: false

  alias OpenResults.Repo
  alias OpenResults.ServerSettings.Setting

  @table __MODULE__
  @notice_key "public_notice"

  # Order is the settings page's order.
  @specs [
    operator_name: %{
      label: "Operator name",
      type: :text,
      max: 100,
      default: nil,
      variable: "OPENRESULTS_OPERATOR_NAME",
      help: "Shown in OpenPairings' consent dialog and returned by GET /api/server."
    },
    terms_url: %{
      label: "Terms page",
      type: :https_url,
      max: 2000,
      default: nil,
      variable: "OPENRESULTS_TERMS_URL",
      help:
        "Linked from OpenPairings' consent dialog and returned by GET /api/server. With none " <>
          "set, GET /api/server reports this server's own /terms page."
    },
    contact_email: %{
      label: "Contact email",
      type: :email,
      max: 254,
      default: nil,
      variable: "OPENRESULTS_CONTACT_EMAIL",
      help:
        "Shown on the public /terms page as a direct way to reach the operator. With none set, " <>
          "that page offers only the report form."
    },
    installation_max_versions: %{
      label: "Versions kept per installation tournament",
      type: :integer,
      min: 1,
      max: nil,
      default: 20,
      variable: "OPENRESULTS_INSTALLATION_MAX_VERSIONS",
      help: "Older stored versions are pruned at the tournament's next installation publish."
    },
    min_free_disk_percent: %{
      label: "Free-disk floor (%)",
      type: :integer,
      min: 0,
      max: 100,
      default: 10,
      variable: "OPENRESULTS_MIN_FREE_DISK_PERCENT",
      help: "Below this free space, installation keys get storage_low. 0 switches it off."
    },
    registrations_per_address: %{
      label: "Registrations per address per 24 hours",
      type: :integer,
      min: 0,
      max: nil,
      default: 10,
      variable: "OPENRESULTS_REGISTRATIONS_PER_ADDRESS",
      help: "An IPv6 client counts by its /64."
    },
    registrations_per_day: %{
      label: "Registrations per 24 hours, in all",
      type: :integer,
      min: 0,
      max: nil,
      default: 200,
      variable: "OPENRESULTS_REGISTRATIONS_PER_DAY",
      help: "Across every address."
    },
    installation_publishes_per_minute: %{
      label: "Publishes per installation per minute",
      type: :integer,
      min: 1,
      max: nil,
      default: 30,
      variable: "OPENRESULTS_INSTALLATION_PUBLISHES_PER_MINUTE",
      help: "Mints and publishes share this one budget. An installation may have its own."
    },
    installation_max_tournaments: %{
      label: "Pending and listed tournaments per installation",
      type: :integer,
      min: 0,
      max: nil,
      default: 50,
      variable: "OPENRESULTS_INSTALLATION_MAX_TOURNAMENTS",
      help: "Minting past it is refused tournament_limit. An installation may have its own."
    },
    installation_max_snapshot_bytes: %{
      label: "Largest snapshot from an installation (bytes)",
      type: :integer,
      min: 1,
      max: 8_000_000,
      default: 3_145_728,
      variable: "OPENRESULTS_INSTALLATION_MAX_SNAPSHOT_BYTES",
      help:
        "Measured off the wire; larger is refused snapshot_too_large. At most the parser's " <>
          "8,000,000."
    }
  ]

  @keys Keyword.keys(@specs)
  @by_name Map.new(@keys, &{Atom.to_string(&1), &1})

  # Never editable from the panel. {variable, config key or nil, secret?}
  @locked [
    {"OPENRESULTS_PUBLIC_PUBLISHING", :public_publishing, false},
    {"OPENRESULTS_ADMIN_ACCESS_TEAM_DOMAIN", :admin_access_team_domain, false},
    {"OPENRESULTS_ADMIN_ACCESS_AUD", :admin_access_aud, false},
    {"OPENRESULTS_ADMIN_EMAILS", :admin_emails, false},
    {"OPENRESULTS_INGEST_TOKEN", :ingest_token, true},
    {"OPENRESULTS_BACKUP_PASSPHRASE", :backup_passphrase, true},
    {"BACKUP_RETENTION", :backup_retention, false},
    {"BACKUP_DIR", :backup_dir, false},
    {"DATABASE_PATH", nil, false},
    {"POOL_SIZE", nil, false},
    {"SECRET_KEY_BASE", nil, true},
    {"PHX_HOST", nil, false},
    {"PHX_ALLOWED_HOSTS", nil, false},
    {"PHX_REDIRECT_HOSTS", nil, false},
    {"PHX_SHORT_HOST", nil, false},
    {"PORT", nil, false},
    {"OPENRESULTS_FIDE_LIST_SYNC", nil, false},
    {"OPENRESULTS_FIDE_LIST_HOUR", nil, false},
    {"FIDE_LIST_URL", :fide_list_url, false},
    {"FIDE_LIST_DATABASE_PATH", nil, false}
  ]

  @type key ::
          :operator_name
          | :terms_url
          | :contact_email
          | :installation_max_versions
          | :min_free_disk_percent
          | :registrations_per_address
          | :registrations_per_day
          | :installation_publishes_per_minute
          | :installation_max_tournaments
          | :installation_max_snapshot_bytes

  @type source :: :panel | :environment | :default

  # ---------------------------------------------------------------------------
  # What there is

  @doc "Every setting the panel can change, in the settings page's order."
  @spec keys() :: [key()]
  def keys, do: @keys

  @doc "The key named by `name`, or `:error`. Never makes an atom from request text."
  @spec key(term()) :: {:ok, key()} | :error
  def key(name) when is_atom(name), do: if(name in @keys, do: {:ok, name}, else: :error)
  def key(name) when is_binary(name), do: Map.fetch(@by_name, name)
  def key(_other), do: :error

  @doc "A setting's label, type, range, default, variable and help text."
  @spec spec(key()) :: map()
  def spec(key), do: Keyword.fetch!(@specs, key)

  # ---------------------------------------------------------------------------
  # Reading

  @doc "The value in force for `key`. An ETS read and a config read: safe on any hot path."
  @spec get(key()) :: term()
  def get(key) when key in @keys do
    case Map.fetch(panel(), key) do
      {:ok, value} -> value
      :error -> env_or_default(key)
    end
  end

  @doc """
  One setting as the settings page shows it:

      %{key: key, value: term, source: :panel | :environment | :default,
        panel: term | nil, environment: term | nil, default: term,
        variable: String.t(), updated_by: String.t() | nil}
  """
  @spec describe(key()) :: map()
  def describe(key) when key in @keys do
    spec = spec(key)
    panel = Map.fetch(panel(), key)
    environment = environment(key)

    {value, source} =
      cond do
        match?({:ok, _}, panel) -> {elem(panel, 1), :panel}
        environment != nil -> {environment, :environment}
        true -> {spec.default, :default}
      end

    %{
      key: key,
      value: value,
      source: source,
      panel: if(match?({:ok, _}, panel), do: elem(panel, 1)),
      environment: environment,
      default: spec.default,
      variable: spec.variable
    }
  end

  @doc """
  What would be in force for `key` with no panel value:
  `%{value: term, source: :environment | :default}`.
  """
  @spec fallback(key()) :: %{value: term(), source: :environment | :default}
  def fallback(key) when key in @keys do
    case environment(key) do
      nil -> %{value: spec(key).default, source: :default}
      value -> %{value: value, source: :environment}
    end
  end

  @doc "Every setting, described."
  @spec all() :: [map()]
  def all, do: Enum.map(@keys, &describe/1)

  @doc """
  The variables the panel never changes, for the settings page to show:
  `%{variable: name, set?: boolean, secret?: boolean, value: String.t() | nil}`.
  `value` is only ever filled for `OPENRESULTS_PUBLIC_PUBLISHING`, whose
  state the page must show; no other value leaves this function.
  """
  @spec locked() :: [map()]
  def locked do
    for {variable, config_key, secret?} <- @locked do
      set? =
        System.get_env(variable) not in [nil, ""] or
          (config_key != nil and Application.get_env(:openresults, config_key) not in [nil, ""])

      value =
        if variable == "OPENRESULTS_PUBLIC_PUBLISHING" do
          if OpenResults.PublicPublishing.enabled?(), do: "enabled", else: "not enabled"
        end

      %{variable: variable, set?: set?, secret?: secret?, value: value}
    end
  end

  # ---------------------------------------------------------------------------
  # Validation - the boot's rules. `config/runtime.exs` mirrors every range.

  @doc """
  Checks panel input for `key`: `{:ok, value}` with the value as it will be
  stored and used, or `{:error, sentence}` saying what is wrong with it.
  """
  @spec validate(key(), term()) :: {:ok, term()} | {:error, String.t()}
  def validate(key, raw) when key in @keys do
    spec = spec(key)
    check(spec.type, spec, raw)
  end

  defp check(:integer, spec, raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {n, ""} -> in_range(spec, n)
      _ -> {:error, integer_sentence(spec)}
    end
  end

  defp check(:integer, spec, n) when is_integer(n), do: in_range(spec, n)
  defp check(:integer, spec, _other), do: {:error, integer_sentence(spec)}

  defp check(:text, spec, raw) when is_binary(raw) do
    text = String.trim(raw)

    cond do
      text == "" ->
        {:error,
         "Enter the #{String.downcase(spec.label)}. To use the environment's value or none, " <>
           "reset it to default instead."}

      String.length(text) > spec.max ->
        {:error, "#{spec.label} is at most #{spec.max} characters."}

      Regex.match?(~r/[\x00-\x1F\x7F]/u, text) ->
        {:error, "#{spec.label} is one line of plain text."}

      true ->
        {:ok, text}
    end
  end

  defp check(:https_url, spec, raw) when is_binary(raw) do
    text = String.trim(raw)

    case URI.new(text) do
      {:ok, %URI{scheme: "https", host: host}}
      when is_binary(host) and host != "" and byte_size(text) <= 2000 ->
        if String.match?(text, ~r/\s/),
          do: {:error, https_sentence(spec)},
          else: {:ok, text}

      _ ->
        {:error, https_sentence(spec)}
    end
  end

  defp check(:email, spec, raw) when is_binary(raw) do
    text = String.trim(raw)

    cond do
      text == "" ->
        {:error,
         "Enter the #{String.downcase(spec.label)}. To use the environment's value or none, " <>
           "reset it to default instead."}

      String.length(text) > spec.max ->
        {:error, "#{spec.label} is at most #{spec.max} characters."}

      not Regex.match?(email_pattern(), text) ->
        {:error, "#{spec.label} is one email address, like operator@example.org."}

      true ->
        {:ok, text}
    end
  end

  defp check(_type, spec, _raw), do: {:error, "#{spec.label} cannot take that value."}

  @doc """
  The shape a contact address must have. The report form's rule
  (`OpenResults.Reports.Report`) - something, an `@`, something with a dot -
  with the characters a `mailto:` link or an HTML attribute would have to
  escape refused as well, because this address is printed on a public page.
  `config/runtime.exs` repeats it for `OPENRESULTS_CONTACT_EMAIL`.
  """
  @spec email_pattern() :: Regex.t()
  def email_pattern,
    do:
      ~r/\A[^\s\x00-\x1F\x7F@<>"'(),;:\x5C\[\]?#&%]+@[^\s\x00-\x1F\x7F@<>"'(),;:\x5C\[\]?#&%]+\.[^\s\x00-\x1F\x7F@<>"'(),;:\x5C\[\]?#&%]+\z/u

  defp in_range(%{min: min, max: max} = spec, n) do
    if n >= min and (is_nil(max) or n <= max),
      do: {:ok, n},
      else: {:error, integer_sentence(spec)}
  end

  defp integer_sentence(%{label: label, min: min, max: nil}),
    do: "#{label} is a whole number of at least #{min}."

  defp integer_sentence(%{label: label, min: min, max: max}),
    do: "#{label} is a whole number from #{min} to #{max}."

  defp https_sentence(%{label: label}),
    do: "#{label} is a full https:// address, like https://example.org/terms."

  # ---------------------------------------------------------------------------
  # Writing - for `OpenResults.Moderation`, inside its transaction. Call
  # `refresh/0` after the commit.

  @doc false
  @spec put(key() | String.t(), String.t(), String.t() | nil) :: :ok
  def put(key, stored, updated_by) when is_binary(stored) do
    now = DateTime.utc_now()
    name = if is_atom(key), do: Atom.to_string(key), else: key

    Repo.insert!(
      %Setting{
        key: name,
        value: stored,
        updated_by: updated_by,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [set: [value: stored, updated_by: updated_by, updated_at: now]],
      conflict_target: :key
    )

    :ok
  end

  @doc false
  @spec delete(key() | String.t()) :: non_neg_integer()
  def delete(key) do
    name = if is_atom(key), do: Atom.to_string(key), else: key
    {count, _} = Repo.delete_all(from s in Setting, where: s.key == ^name)
    count
  end

  @doc false
  # How a validated value is written to the text column.
  def encode(value) when is_integer(value), do: Integer.to_string(value)
  def encode(value) when is_binary(value), do: value

  @doc false
  # The notice's stored JSON document, decoded, or nil. From the cache.
  def notice_document, do: Map.get(panel(), :public_notice)

  @doc false
  def notice_key, do: @notice_key

  # ---------------------------------------------------------------------------
  # The cache

  @doc """
  Re-reads every saved setting and overwrites the cache. A writer calls this
  once its change has committed.
  """
  @spec refresh() :: :ok
  def refresh do
    case load() do
      {:ok, panel} -> safe(fn -> :ets.insert(@table, {:panel, panel}) end)
      :error -> clear_cache()
    end

    :ok
  end

  @doc "Empties the cache; the next read loads again. For tests."
  @spec clear_cache() :: :ok
  def clear_cache do
    safe(fn -> :ets.delete(@table, :panel) end)
    :ok
  end

  defp panel do
    case safe(fn -> :ets.lookup(@table, :panel) end) do
      [{:panel, panel}] ->
        panel

      _miss ->
        case load() do
          {:ok, panel} ->
            safe(fn -> :ets.insert_new(@table, {:panel, panel}) end)
            panel

          # The database could not be read - not migrated yet, or a process
          # the test sandbox does not know. Nothing is cached, so the next
          # read tries again, and the environment and defaults stand in.
          :error ->
            %{}
        end
    end
  end

  defp load do
    rows = Repo.all(from s in Setting, select: {s.key, s.value})

    panel =
      Enum.reduce(rows, %{}, fn
        {@notice_key, json}, acc ->
          case Jason.decode(json) do
            {:ok, %{} = doc} -> Map.put(acc, :public_notice, doc)
            _unreadable -> acc
          end

        {name, stored}, acc ->
          with {:ok, key} <- Map.fetch(@by_name, name),
               {:ok, value} <- validate(key, stored) do
            Map.put(acc, key, value)
          else
            _unknown_or_invalid -> acc
          end
      end)

    {:ok, panel}
  rescue
    error ->
      Logger.debug("server settings not read from the database: #{Exception.message(error)}")
      :error
  end

  defp safe(fun) do
    fun.()
  rescue
    ArgumentError -> nil
  end

  # What config says, when it says something the rules accept - which, since
  # `config/runtime.exs` refuses anything else at boot, is whenever it is set.
  defp environment(key) do
    spec = spec(key)

    case Application.get_env(:openresults, key) do
      nil ->
        nil

      value when is_binary(value) ->
        if String.trim(value) == "", do: nil, else: ok_or_nil(check(spec.type, spec, value))

      value ->
        ok_or_nil(check(spec.type, spec, value))
    end
  end

  defp ok_or_nil({:ok, value}), do: value
  defp ok_or_nil(_error), do: nil

  defp env_or_default(key) do
    case environment(key) do
      nil -> spec(key).default
      value -> value
    end
  end

  # ---------------------------------------------------------------------------

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    # Warm, so the first publish after a boot does not pay for the query.
    # Harmless where it cannot read (a test's sandbox): nothing is cached.
    _ = panel()
    {:ok, opts}
  end
end
