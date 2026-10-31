defmodule OpenResults.PublicPublishingFixtures do
  @moduledoc """
  Installations, minted slugs and requests made with them, for the public
  publishing tests.

  Slugs are always fresh. The caches these tests touch (`StatusCache`, the
  page cache) are node-wide ETS tables the SQL sandbox knows nothing about, so
  a test that hid the shared fixture slug could hide it for a neighbour.
  """

  import Plug.Conn
  import Phoenix.ConnTest

  alias OpenResults.Installations
  alias OpenResults.SnapshotPayloads
  alias OpenResults.Tournaments

  @endpoint OpenResultsWeb.Endpoint

  @operator "test-ingest-token"

  def operator_token, do: @operator

  def admin, do: %{email: "admin@example.invalid"}

  @doc "A registered installation and its key."
  def installation!(address \\ {198, 51, 100, 20}) do
    {:ok, %{installation: installation, key: key}} =
      Installations.register(%{"client" => "OpenPairings", "client_version" => "0.61.0"}, address)

    {installation, key}
  end

  @doc "A slug minted for `installation`."
  def mint!(installation) do
    {:ok, tournament} = Tournaments.mint(installation)
    tournament.slug
  end

  @doc "A slug nobody has used, the shape an operator would choose."
  def unique_slug(prefix \\ "t"),
    do: "#{prefix}-#{System.unique_integer([:positive])}-#{:rand.uniform(1_000_000)}"

  @doc "The swiss fixture, published under `slug`."
  def payload(slug), do: put_in(SnapshotPayloads.swiss(), ["tournament", "slug"], slug)

  @doc "`payload/1`, dated this week, for a test about the front page."
  def current_payload(slug), do: slug |> payload() |> SnapshotPayloads.current()

  @doc "A publish, with whichever bearer token and tournament key."
  def publish(payload, bearer, tournament_key \\ nil, conn \\ build_conn()) do
    conn
    |> put_req_header("content-type", "application/json")
    |> bearer(bearer)
    |> tournament_key(tournament_key)
    |> post("/api/snapshots", Jason.encode!(payload))
  end

  def history(slug, bearer, conn \\ build_conn()) do
    conn |> bearer(bearer) |> get("/api/tournaments/#{slug}/history?at=2099-01-01T00:00:00Z")
  end

  def registrations(slug, bearer, tournament_key \\ nil, conn \\ build_conn()) do
    conn
    |> bearer(bearer)
    |> tournament_key(tournament_key)
    |> get("/api/tournaments/#{slug}/registrations")
  end

  def takedown(slug, bearer, tournament_key \\ nil, conn \\ build_conn()) do
    conn |> bearer(bearer) |> tournament_key(tournament_key) |> delete("/api/tournaments/#{slug}")
  end

  def mint(bearer, conn \\ build_conn()) do
    conn
    |> put_req_header("content-type", "application/json")
    |> bearer(bearer)
    |> post("/api/tournaments", "{}")
  end

  def bearer(conn, nil), do: conn
  def bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  def tournament_key(conn, nil), do: conn
  def tournament_key(conn, key), do: put_req_header(conn, "x-openresults-key", key)

  @doc "A random tournament key, as OpenPairings generates one."
  def random_key, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
