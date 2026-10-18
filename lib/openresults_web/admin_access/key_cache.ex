defmodule OpenResultsWeb.AdminAccess.KeyCache do
  @moduledoc """
  Cloudflare Access's signing keys, fetched from the team domain and kept.

  ## The policy

  - **Read without asking anyone.** A known `kid` whose key set is fresh is
    an ETS lookup in the request's own process.
  - **Refetch on an unknown `kid`**, once, then answer. Cloudflare rotates
    its signing key every six weeks (the certs document carries the current
    and the previous key), and a token signed with a key this cache has not
    seen yet is what a rotation looks like from here - the one moment a
    fetch is worth making.
  - **Refetch a key set older than an hour** on the next request that uses
    it, so a key Cloudflare has withdrawn stops being accepted here too
    rather than living until the next restart.
  - **Never more than one fetch per `refetch_interval`** (30 s), however many
    requests ask. The `kid` comes from the request, so without this a stream
    of made-up `kid`s would turn this server into a request amplifier
    pointed at Cloudflare. Inside the interval an unknown `kid` is simply
    unknown.
  - **Hold the keys through a failed fetch.** Cloudflare being unreachable
    for a minute must not lock the admins out when the keys already held
    still verify their tokens. A failure is logged and changes nothing.

  Every fetch happens inside this process, so a burst of requests that all
  miss waits for one fetch and then reads its result, instead of each
  starting its own.

  ## The fetcher

  `:admin_access_jwks_fetcher` in the application environment, a
  `fn team_domain -> {:ok, decoded_jwks} | {:error, reason} end`. Unset, it
  is `fetch_jwks/1`, which uses `Req` like `OpenResults.FideList.Source` does.
  Tests put a function there, so no test touches the network.
  """

  use GenServer

  require Logger

  @table __MODULE__

  @refetch_interval_ms 30_000
  @max_age_ms 60 * 60 * 1000

  # Longer than a fetch can take (Req's receive timeout below, plus connect),
  # so a caller waiting on a slow fetch gets its answer rather than an exit.
  @call_timeout_ms 15_000
  @fetch_timeout_ms 5_000

  # RS256 with a smaller modulus is not something Cloudflare publishes, and
  # not something this gate will trust if a key set ever claims otherwise.
  # A 2048-bit modulus has its top bit set, so it is at least 2^2047.
  @min_modulus Integer.pow(2, 2047)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The RSA public key for `kid` under `team_domain`, or `:error`.
  """
  @spec key(String.t(), String.t()) :: {:ok, :public_key.rsa_public_key()} | :error
  def key(team_domain, kid) when is_binary(team_domain) and is_binary(kid) do
    case :ets.lookup(@table, :keys) do
      [{:keys, ^team_domain, keys, fetched_at}] when is_map_key(keys, kid) ->
        if fresh?(fetched_at), do: {:ok, Map.fetch!(keys, kid)}, else: ask(team_domain, kid)

      _miss ->
        ask(team_domain, kid)
    end
  end

  @doc "Forgets every key and the last fetch time. For tests."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @doc """
  Cloudflare's certs document for `team_domain`, decoded.

  The default fetcher. `:admin_access_req_options` is merged in last, the
  same hook `OpenResults.FideList.Source` has, so the HTTP layer can be stubbed
  with `Req.Test` too.
  """
  @spec fetch_jwks(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_jwks(team_domain) do
    [
      url: "https://#{team_domain}/cdn-cgi/access/certs",
      receive_timeout: @fetch_timeout_ms,
      connect_options: [timeout: @fetch_timeout_ms],
      retry: false,
      redirect: false
    ]
    |> Keyword.merge(Application.get_env(:openresults, :admin_access_req_options, []))
    |> Req.request()
    |> case do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The usable keys in a decoded JWKS document, by `kid`.

  Only RSA signing keys meant for RS256: an entry with another `kty`, an
  `alg` other than RS256, a `use` other than `sig`, a missing `kid` or a
  modulus under 2048 bits is skipped rather than trusted.
  """
  @spec keys_from_jwks(term()) :: %{String.t() => :public_key.rsa_public_key()}
  def keys_from_jwks(%{"keys" => entries}) when is_list(entries) do
    for %{"kty" => "RSA", "kid" => kid, "n" => n, "e" => e} = entry <- entries,
        is_binary(kid) and kid != "",
        Map.get(entry, "alg", "RS256") == "RS256",
        Map.get(entry, "use", "sig") == "sig",
        {:ok, key} <- [rsa_key(n, e)],
        into: %{} do
      {kid, key}
    end
  end

  def keys_from_jwks(_document), do: %{}

  defp rsa_key(n, e) when is_binary(n) and is_binary(e) do
    with {:ok, n_bytes} <- Base.url_decode64(n, padding: false),
         {:ok, e_bytes} <- Base.url_decode64(e, padding: false),
         modulus = :binary.decode_unsigned(n_bytes),
         exponent = :binary.decode_unsigned(e_bytes),
         true <- modulus >= @min_modulus and exponent > 1 do
      {:ok, {:RSAPublicKey, modulus, exponent}}
    else
      _ -> :error
    end
  end

  defp rsa_key(_n, _e), do: :error

  defp ask(team_domain, kid) do
    GenServer.call(__MODULE__, {:key, team_domain, kid}, @call_timeout_ms)
  catch
    # Not started, or stuck past the timeout. Refusing is the answer either
    # way; a crashed request would be a 500 that says more than a 404 does.
    :exit, _reason -> :error
  end

  defp fresh?(fetched_at), do: now() - fetched_at < max_age()

  defp now, do: System.monotonic_time(:millisecond)

  defp refetch_interval,
    do: Application.get_env(:openresults, :admin_access_refetch_interval_ms, @refetch_interval_ms)

  defp max_age, do: Application.get_env(:openresults, :admin_access_keys_max_age_ms, @max_age_ms)

  ## Server

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, %{last_attempt: nil}}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | last_attempt: nil}}
  end

  def handle_call({:key, team_domain, kid}, _from, state) do
    held = held_keys(team_domain)

    cond do
      # Somebody queued ahead of this caller already fetched what it needs.
      is_map_key(held.keys, kid) and fresh?(held.fetched_at) ->
        {:reply, {:ok, Map.fetch!(held.keys, kid)}, state}

      cooling_down?(state) ->
        {:reply, Map.fetch(held.keys, kid), state}

      true ->
        state = %{state | last_attempt: now()}
        keys = refresh(team_domain, held)
        {:reply, Map.fetch(keys, kid), state}
    end
  end

  defp held_keys(team_domain) do
    case :ets.lookup(@table, :keys) do
      [{:keys, ^team_domain, keys, fetched_at}] -> %{keys: keys, fetched_at: fetched_at}
      # A different team domain's keys are no keys at all for this one.
      _ -> %{keys: %{}, fetched_at: nil}
    end
  end

  defp cooling_down?(%{last_attempt: nil}), do: false
  defp cooling_down?(%{last_attempt: at}), do: now() - at < refetch_interval()

  defp refresh(team_domain, held) do
    case safe_fetch(team_domain) do
      {:ok, document} ->
        case keys_from_jwks(document) do
          keys when map_size(keys) > 0 ->
            :ets.insert(@table, {:keys, team_domain, keys, now()})
            keys

          _none ->
            Logger.warning(
              "admin panel: Cloudflare Access certs for #{team_domain} held no usable RS256 key; " <>
                "keeping the #{map_size(held.keys)} key(s) already held"
            )

            held.keys
        end

      {:error, reason} ->
        Logger.warning(
          "admin panel: could not fetch Cloudflare Access certs for #{team_domain} " <>
            "(#{inspect(reason)}); keeping the #{map_size(held.keys)} key(s) already held"
        )

        held.keys
    end
  end

  defp safe_fetch(team_domain) do
    fetcher = Application.get_env(:openresults, :admin_access_jwks_fetcher, &fetch_jwks/1)
    fetcher.(team_domain)
  rescue
    exception -> {:error, exception}
  end
end
