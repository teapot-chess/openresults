defmodule OpenResultsWeb.RelayAccess do
  @moduledoc """
  What a relay key may do: `POST /api/tournaments/:slug/live` for its own
  tournament, and nothing else.

  Called only from `OpenResultsWeb.Plugs.IngestAuth`, with a key it has
  already recognised, and only on a route that opted in with
  `private: %{relay_access: true}`. A route that did not gets the anonymous
  401 before this module is asked, so a relay key reaching somewhere new
  takes a change in the router, not an omission.

  ## Order

  Revoked, then the key's own budget, then address block, then the operator's
  pause, then whether the path's slug is the key's, then whether the
  installation that owns the tournament may still publish. Cheap first, as
  for an installation key. The slug check answers
  `relay_key_wrong_tournament`: the key's holder learns it is pointed at the
  wrong place, a stranger learns nothing, because a stranger has no key.

  The owner check (the 2026-10-19 sweep) closes a side door: suspending an
  installation stopped its publishes and left its hall boxes posting, since
  nothing about a relay key asked after the installation behind it.
  `owner_suspended` / `owner_revoked`. An operator-published tournament has
  no installation and nothing to ask.

  The budget is per KEY, not per tournament or address: two boxes in one hall
  must not spend each other's allowance, and a runaway one must not be able
  to starve the other.
  """

  import Plug.Conn

  alias OpenResults.AddressBlocks
  alias OpenResults.Installations
  alias OpenResults.RateLimit
  alias OpenResults.RelayKeys
  alias OpenResults.RelayKeys.RelayKey
  alias OpenResults.Settings
  alias OpenResults.Tournaments
  alias OpenResultsWeb.ApiError
  alias OpenResultsWeb.ClientAddress

  # A relay posts a board every few seconds; sixty-four boards a batch.
  @per_minute 1200

  @doc false
  @spec authorize(Plug.Conn.t(), RelayKey.t()) :: Plug.Conn.t()
  def authorize(conn, %RelayKey{} = relay_key) do
    with :ok <- status(relay_key),
         :ok <- budget(relay_key),
         :ok <- address_block(conn),
         :ok <- pause(),
         :ok <- tournament(conn, relay_key),
         :ok <- owner(relay_key) do
      # Only a key that got this far counts as used: a refused one is not the
      # box doing its job, and "last used" should answer that question.
      RelayKeys.touch(relay_key)
      assign(conn, :credential, {:relay, relay_key})
    else
      {:error, code} -> ApiError.send(conn, code)
      {:error, code, extra} -> ApiError.send(conn, code, extra)
    end
  end

  defp status(%RelayKey{revoked_at: nil}), do: :ok
  defp status(%RelayKey{}), do: {:error, :relay_key_revoked}

  defp budget(%RelayKey{id: id}) do
    case RateLimit.take({:relay_key, id}, limit: @per_minute, window_ms: :timer.minutes(1)) do
      :ok ->
        :ok

      {:denied, retry_in_ms} ->
        {:error, :rate_limited, %{retry_after: ApiError.retry_seconds(retry_in_ms)}}
    end
  end

  defp address_block(conn) do
    if AddressBlocks.blocked?(ClientAddress.of(conn)), do: {:error, :address_blocked}, else: :ok
  end

  defp pause do
    if Settings.get(:public_publishing_paused), do: {:error, :publishing_paused}, else: :ok
  end

  defp owner(%RelayKey{tournament_slug: slug}) do
    with %{installation_id: id} when is_binary(id) <- Tournaments.get(slug),
         %{status: status} <- Installations.get(id) do
      case status do
        "suspended" -> {:error, :owner_suspended}
        "revoked" -> {:error, :owner_revoked}
        _active -> :ok
      end
    else
      _no_installation -> :ok
    end
  end

  defp tournament(conn, %RelayKey{tournament_slug: slug}) do
    if conn.path_params["slug"] == slug, do: :ok, else: {:error, :relay_key_wrong_tournament}
  end
end
