defmodule OpenResultsWeb.DefaultDenyTest.Reached do
  @moduledoc false
  # Stands in for a controller: if a request gets here, the gate let it in.
  def init(action), do: action
  def call(conn, _action), do: Plug.Conn.send_resp(conn, 200, "reached")
end

defmodule OpenResultsWeb.DefaultDenyTest.LaterRouter do
  @moduledoc false
  use Phoenix.Router

  pipeline :ingest do
    plug OpenResultsWeb.Plugs.IngestAuth
  end

  scope "/api" do
    pipe_through :ingest

    # Somebody adds a route next year and does not know about installation
    # keys.
    get "/tournaments/:slug/something-new", OpenResultsWeb.DefaultDenyTest.Reached, :show
    post "/tournaments/:slug/also-new", OpenResultsWeb.DefaultDenyTest.Reached, :create

    # And somebody opts in with a typo.
    get "/tournaments/:slug/typo", OpenResultsWeb.DefaultDenyTest.Reached, :show,
      private: %{installation_access: :pubilsh}
  end
end

defmodule OpenResultsWeb.DefaultDenyTest do
  @moduledoc """
  The router's promise - "a route added here later is authenticated by default
  rather than by remembering" - kept for installation keys.

  Two halves. The first walks the real router, so a route added to the ingest
  scope tomorrow is checked by this file without anybody editing it. The
  second builds a router with a route that forgot to opt in, because the real
  one has none today and a property that is only ever tested vacuously is not
  tested.
  """

  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.RateLimit
  alias OpenResultsWeb.InstallationAccess
  alias OpenResultsWeb.Plugs.IngestAuth

  @unauthorized %{"error" => "unauthorized", "detail" => "a valid credential is required"}

  setup do
    RateLimit.reset()
    {installation, key} = installation!()
    slug = mint!(installation)
    slug |> payload() |> publish(key, random_key()) |> json_response(200)
    {:ok, key: key, slug: slug}
  end

  describe "the real router" do
    test "every route that names an installation action is behind the ingest gate, with a known action" do
      # Written out, so opting a route in is a change somebody makes here on
      # purpose and a reviewer sees in the diff.
      assert routes()
             |> Enum.filter(& &1.access)
             |> Enum.map(&{&1.verb, &1.path, &1.access})
             |> Enum.sort() ==
               Enum.sort([
                 {:post, "/api/tournaments", :mint},
                 {:post, "/api/snapshots", :publish},
                 {:get, "/api/tournaments/:slug/history", :history},
                 {:delete, "/api/tournaments/:slug", :delete},
                 {:get, "/api/tournaments/:slug/registrations", :registrations},
                 {:post, "/api/tournaments/:slug/live", :live},
                 {:post, "/api/tournaments/:slug/relay-keys", :relay_key},
                 {:delete, "/api/tournaments/:slug/relay-keys", :relay_key_revoke},
                 {:post, "/api/tournaments/:slug/proofs", :proof}
               ])

      for route <- routes(), not is_nil(route.access) do
        action = route.access

        assert :ingest in route.pipe_through,
               "#{route.verb} #{route.path} opts in to installation keys without the ingest pipeline"

        assert action in InstallationAccess.actions(),
               "#{route.verb} #{route.path} names an installation action nothing checks: #{inspect(action)}"
      end
    end

    test "every ingest route either opts in, or refuses an installation key with the anonymous 401",
         %{key: key, slug: slug} do
      ingest_routes = Enum.filter(routes(), &(:ingest in &1.pipe_through))

      assert length(ingest_routes) >= 5, "no ingest routes found - has the pipeline been renamed?"

      for route <- ingest_routes, is_nil(route.access) do
        path = String.replace(route.path, ":slug", slug)

        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{key}")
          |> put_req_header("content-type", "application/json")
          |> dispatch(@endpoint, route.verb, path, "{}")

        assert json_response(conn, 401) == @unauthorized,
               "#{route.verb} #{route.path} let an installation key in without opting in"
      end
    end
  end

  describe "relay keys" do
    test "exactly one route opts in to one: the live endpoint" do
      assert routes() |> Enum.filter(& &1.relay) |> Enum.map(&{&1.verb, &1.path}) ==
               [{:post, "/api/tournaments/:slug/live"}]
    end

    test "every other ingest route refuses a valid relay key with the anonymous 401", %{
      slug: slug
    } do
      {:ok, %{key: relay}} =
        OpenResults.Moderation.create_relay_key(slug, "box", %{email: "a@example.org"})

      for route <- routes(), :ingest in route.pipe_through, route.relay != true do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{relay}")
          |> put_req_header("content-type", "application/json")
          |> dispatch(@endpoint, route.verb, String.replace(route.path, ":slug", slug), "{}")

        assert json_response(conn, 401) == @unauthorized,
               "#{route.verb} #{route.path} let a relay key in"
      end
    end

    test "on a route that did not opt in, even the right key is the anonymous 401", %{slug: slug} do
      {:ok, %{key: relay}} =
        OpenResults.Moderation.create_relay_key(slug, "box", %{email: "a@example.org"})

      conn = later(:get, "/api/tournaments/#{slug}/something-new", relay)
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == @unauthorized
    end
  end

  describe "a route that did not opt in" do
    test "refuses a valid, active installation key on its own tournament with the anonymous 401",
         %{key: key, slug: slug} do
      for {method, path} <- [
            {:get, "/api/tournaments/#{slug}/something-new"},
            {:post, "/api/tournaments/#{slug}/also-new"}
          ] do
        conn = later(method, path, key)

        assert conn.status == 401
        assert Jason.decode!(conn.resp_body) == @unauthorized
        refute conn.resp_body == "reached"
      end
    end

    test "still admits the operator token, as every ingest route always has", %{slug: slug} do
      conn = later(:get, "/api/tournaments/#{slug}/something-new", operator_token())
      assert conn.status == 200
      assert conn.resp_body == "reached"
    end

    test "an action nobody checks is refused rather than trusted", %{key: key, slug: slug} do
      conn = later(:get, "/api/tournaments/#{slug}/typo", key)
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == @unauthorized
    end
  end

  test "IngestAuth, called bare on a conn with no opt-in, refuses the key", %{key: key} do
    conn =
      Plug.Test.conn(:get, "/anything")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{key}")
      |> IngestAuth.call(IngestAuth.init([]))

    assert conn.halted
    assert conn.status == 401
  end

  # Every route in the real router, with the two facts `__routes__/0` does
  # not expose: its pipelines and its `installation_access`. Both are read the
  # way the router itself reads them on a request - by matching a concrete
  # path and running the route's own `prepare` step - so this cannot disagree
  # with what a request would see.
  defp routes do
    for route <- OpenResultsWeb.Router.__routes__() do
      segments =
        route.path
        |> String.split("/", trim: true)
        |> Enum.map(&if(String.starts_with?(&1, ":"), do: "sample", else: &1))

      verb = route.verb |> to_string() |> String.upcase()

      {metadata, prepare, _pipeline, _dispatch} =
        OpenResultsWeb.Router.__match_route__(verb, segments, "example.com")

      assert metadata.route == route.path, "#{verb} #{route.path} matched #{metadata.route}"

      conn = prepare.(%Plug.Conn{}, metadata)

      %{
        verb: route.verb,
        path: route.path,
        pipe_through: metadata.pipe_through,
        access: conn.private[:installation_access],
        relay: conn.private[:relay_access]
      }
    end
  end

  defp later(method, path, token) do
    method
    |> Plug.Test.conn(path)
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> OpenResultsWeb.DefaultDenyTest.LaterRouter.call(
      OpenResultsWeb.DefaultDenyTest.LaterRouter.init([])
    )
  end
end
