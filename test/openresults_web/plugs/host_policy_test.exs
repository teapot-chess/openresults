defmodule OpenResultsWeb.Plugs.HostPolicyTest do
  @moduledoc """
  The hostname settings: which hosts may open the websocket, the opt-in 301
  from an old host to the canonical one, and the short-link host.

  The runtime half evaluates the real `config/runtime.exs`, as
  `OpenResults.ServerSettingsTest` does.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias OpenResultsWeb.Plugs.CanonicalHost
  alias OpenResultsWeb.Plugs.ShortHost

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)
  @names ~w(PHX_HOST PHX_ALLOWED_HOSTS PHX_REDIRECT_HOSTS PHX_SHORT_HOST DATABASE_PATH SECRET_KEY_BASE)

  defp boot(vars) do
    vars =
      Map.merge(
        %{"DATABASE_PATH" => "/srv/or.db", "SECRET_KEY_BASE" => String.duplicate("k", 64)},
        vars
      )

    previous = Map.new(@names, &{&1, System.get_env(&1)})
    Enum.each(@names, &System.delete_env/1)
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    try do
      Config.Reader.read!(@runtime, env: :prod)
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  describe "runtime settings" do
    test "check_origin is PHX_HOST alone when nothing else is set" do
      config = boot(%{"PHX_HOST" => "openresults.example.org"})

      assert config[:openresults][OpenResultsWeb.Endpoint][:check_origin] ==
               ["//openresults.example.org"]

      assert config[:openresults][:host_policy] ==
               [canonical: "openresults.example.org", redirect_hosts: [], short_host: nil]
    end

    test "accepts the canonical, allowed and redirected hosts" do
      config =
        boot(%{
          "PHX_HOST" => "openresults.cloud",
          "PHX_ALLOWED_HOSTS" => "Other.Example.org",
          "PHX_REDIRECT_HOSTS" => "openresults.zerotwo.cloud, openresults.cloud",
          "PHX_SHORT_HOST" => "pairings.cloud"
        })

      assert config[:openresults][OpenResultsWeb.Endpoint][:check_origin] ==
               ["//openresults.cloud", "//other.example.org", "//openresults.zerotwo.cloud"]

      assert config[:openresults][:host_policy] ==
               [
                 canonical: "openresults.cloud",
                 redirect_hosts: ["openresults.zerotwo.cloud"],
                 short_host: "pairings.cloud"
               ]
    end

    test "bad values stop the boot" do
      assert_raise RuntimeError, ~r/PHX_REDIRECT_HOSTS/, fn ->
        boot(%{"PHX_HOST" => "a.example.org", "PHX_REDIRECT_HOSTS" => "https://old.example.org"})
      end

      assert_raise RuntimeError, ~r/PHX_SHORT_HOST takes exactly one/, fn ->
        boot(%{"PHX_HOST" => "a.example.org", "PHX_SHORT_HOST" => "s.example.org,t.example.org"})
      end

      assert_raise RuntimeError, ~r/same as PHX_HOST/, fn ->
        boot(%{"PHX_HOST" => "a.example.org", "PHX_SHORT_HOST" => "A.example.org"})
      end
    end
  end

  describe "plugs" do
    setup do
      previous = Application.get_env(:openresults, :host_policy)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:openresults, :host_policy, previous),
          else: Application.delete_env(:openresults, :host_policy)
      end)
    end

    defp policy(opts) do
      Application.put_env(
        :openresults,
        :host_policy,
        Keyword.merge([canonical: "openresults.cloud", redirect_hosts: [], short_host: nil], opts)
      )
    end

    defp run(plug, method, host, path, query \\ "") do
      conn(method, path <> query) |> Map.put(:host, host) |> plug.call([])
    end

    test "CanonicalHost does nothing with no policy or an empty list" do
      Application.delete_env(:openresults, :host_policy)
      refute run(CanonicalHost, :get, "openresults.zerotwo.cloud", "/t/x").halted
      policy([])
      refute run(CanonicalHost, :get, "openresults.zerotwo.cloud", "/t/x").halted
    end

    test "CanonicalHost 301s GET and HEAD on a listed host, keeping path and query" do
      policy(redirect_hosts: ["openresults.zerotwo.cloud"])

      conn =
        run(
          CanonicalHost,
          :get,
          "OpenResults.ZeroTwo.Cloud",
          "/t/spring-open/round/2",
          "?lang=nl"
        )

      assert conn.status == 301

      assert get_resp_header(conn, "location") == [
               "https://openresults.cloud/t/spring-open/round/2?lang=nl"
             ]

      assert run(CanonicalHost, :head, "openresults.zerotwo.cloud", "/").status == 301
    end

    test "CanonicalHost leaves publishing (POST/PUT) and other hosts alone" do
      policy(redirect_hosts: ["openresults.zerotwo.cloud"])
      refute run(CanonicalHost, :post, "openresults.zerotwo.cloud", "/api/tournaments/x").halted
      refute run(CanonicalHost, :put, "openresults.zerotwo.cloud", "/api/tournaments/x").halted
      refute run(CanonicalHost, :get, "openresults.cloud", "/t/x").halted
      # The API answers on any host, GET included (2026-10-19 sweep).
      refute run(CanonicalHost, :get, "openresults.zerotwo.cloud", "/api/server").halted
      refute run(CanonicalHost, :head, "openresults.zerotwo.cloud", "/api/tournaments/x").halted
      refute run(CanonicalHost, :get, "127.0.0.1", "/t/x").halted
    end

    test "ShortHost forwards / and /t/... to the canonical host" do
      policy(short_host: "pairings.cloud")

      conn = run(ShortHost, :get, "pairings.cloud", "/t/spring-open", "?x=1")
      assert conn.status == 301
      assert get_resp_header(conn, "location") == ["https://openresults.cloud/t/spring-open?x=1"]

      assert get_resp_header(run(ShortHost, :get, "pairings.cloud", "/t/a/round/3"), "location") ==
               ["https://openresults.cloud/t/a/round/3"]

      assert get_resp_header(run(ShortHost, :get, "pairings.cloud", "/"), "location") ==
               ["https://openresults.cloud/"]

      assert run(ShortHost, :head, "pairings.cloud", "/t/a").status == 301
    end

    test "ShortHost serves nothing else under the short name" do
      policy(short_host: "pairings.cloud")

      for {method, path} <- [
            get: "/api/server",
            get: "/admin",
            get: "/terms",
            get: "/tx/a",
            post: "/t/a"
          ] do
        conn = run(ShortHost, method, "pairings.cloud", path)
        assert conn.status == 404, "#{method} #{path}"
        assert conn.halted
      end
    end

    test "ShortHost ignores every other host, and is off by default" do
      policy(short_host: "pairings.cloud")
      refute run(ShortHost, :get, "openresults.cloud", "/t/a").halted
      policy([])
      refute run(ShortHost, :get, "pairings.cloud", "/t/a").halted
    end
  end
end
