defmodule OpenResultsWeb.Contracts.PublishV1ContractTest do
  @moduledoc """
  The provider side of `priv/contracts/publish-v1/`: what OpenPairings and
  Alnasl send this server, and what it answers them.

  Three kinds of check. The directory is in order (index.json, every schema
  resolvable, every example valid). Every REQUEST example goes through the
  real router and controller and must be accepted. Every RESPONSE the
  controllers actually produce must follow its schema - the examples are
  what a consumer reads, but the code is what a consumer gets.
  """

  # Not async: spends the node-wide rate limiter and moves application env.
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.ContractCase
  import OpenResults.PublicPublishingFixtures

  alias OpenResults.Moderation
  alias OpenResults.RateLimit
  alias OpenResults.Registrations
  alias OpenResultsWeb.ApiError

  @contract "publish-v1"

  setup do
    RateLimit.reset()
    :ok
  end

  defp example(name), do: read_json!(@contract, "examples/" <> name)

  defp with_slug(snapshot, slug), do: put_in(snapshot, ["tournament", "slug"], slug)

  # The swiss example, published under a fresh slug with the operator token,
  # claimed with a fresh key.
  defp published!(key \\ random_key()) do
    slug = unique_slug("contract")
    snapshot = with_slug(example("snapshot.request.json"), slug)
    assert %{"status" => "ok"} = snapshot |> publish(operator_token(), key) |> json_response(200)
    {slug, key}
  end

  defp post_json(path, body, bearer, key \\ nil) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> bearer(bearer)
    |> tournament_key(key)
    |> post(path, Jason.encode!(body))
  end

  defp relay_key!(slug, key) do
    "/api/tournaments/#{slug}/relay-keys"
    |> post_json(example("relay-key.request.json"), operator_token(), key)
    |> json_response(201)
    |> Map.fetch!("relay_key")
  end

  describe "the directory" do
    test "index.json lists exactly the files that are there" do
      index = read_json!(@contract, "index.json")

      assert index["contract"] == "publish"
      assert index["version"] == 1
      assert index["files"] == Enum.sort(index["files"]), "index.json files must be sorted"
      assert index["files"] == files_on_disk(@contract) -- ["index.json"]
    end

    test "every schema is draft-07, names its public URL, and resolves offline" do
      schemas = Enum.filter(files_on_disk(@contract), &String.ends_with?(&1, ".schema.json"))
      assert schemas != []

      for file <- schemas do
        schema = read_json!(@contract, file)
        assert schema["$schema"] == "http://json-schema.org/draft-07/schema#", file

        assert schema["$id"] ==
                 "https://raw.githubusercontent.com/teapot-chess/openresults/main/priv/contracts/#{@contract}/#{file}"

        assert is_binary(schema["title"]) and is_binary(schema["description"]), file
        assert %ExJsonSchema.Schema.Root{} = schema!(@contract, file)
      end
    end

    test "every example follows its schema, and every message has one" do
      files = files_on_disk(@contract)
      examples = Enum.filter(files, &String.starts_with?(&1, "examples/"))

      for example <- examples do
        schema = schema_for_example(@contract, example)
        assert schema, "#{example} belongs to no schema"
        assert_valid!(@contract, schema, read_json!(@contract, example))
      end

      covered = MapSet.new(examples, &schema_for_example(@contract, &1))

      for schema <- files,
          String.ends_with?(schema, ".schema.json"),
          schema != "common.schema.json" do
        assert schema in covered, "#{schema} has no example"
      end
    end

    test "every route in the table exists in the router, and names schemas that exist" do
      files = files_on_disk(@contract)

      for route <- example("routes.json")["routes"] do
        path = String.replace(route["path"], ":slug", "some-slug")

        assert %{} =
                 Phoenix.Router.route_info(
                   OpenResultsWeb.Router,
                   route["method"],
                   path,
                   "localhost"
                 ),
               "#{route["method"]} #{route["path"]} is not routed"

        named =
          [route["request"] | Map.values(route["responses"])]
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&(&1 |> String.split(" ") |> hd()))

        for file <- named, do: assert(file in files, "#{route["path"]} names #{file}")
      end
    end

    test "the snapshots OpenPairings' builder produced (test/fixtures) follow the snapshot schema" do
      fixtures = Path.wildcard(Path.expand("../../fixtures/snapshot_*.json", __DIR__))
      assert length(fixtures) >= 5

      for fixture <- fixtures do
        assert_valid!(
          @contract,
          "snapshot.request.schema.json",
          fixture |> File.read!() |> Jason.decode!()
        )
      end
    end
  end

  describe "the schemas bite" do
    # A validator that resolved nothing would pass every test above. These
    # are the shapes the contract exists to refuse, one through each $ref.
    test "an unknown result token, error code, live status or extra response field is refused" do
      snapshot =
        update_in(example("snapshot.request.json"), ["rounds", Access.at(0), "boards"], fn [
                                                                                             b
                                                                                             | rest
                                                                                           ] ->
          [Map.put(b, "result", "2-0") | rest]
        end)

      refusals = [
        {"snapshot.request.schema.json", snapshot},
        {"snapshot.request.schema.json", Map.put(example("snapshot.request.json"), "version", 2)},
        {"error.response.schema.json", %{"error" => "made_up", "detail" => "x"}},
        {"live-board.request.schema.json",
         Map.put(example("live-board.request.json"), "status", "waiting")},
        {"live-board.request.schema.json", %{"round" => 3, "board" => 1}},
        {"server.response.schema.json", Map.put(example("server.response.json"), "new_field", 1)},
        {"live-board-batch.response.schema.json",
         %{"status" => "ok", "results" => [%{"status" => "error", "applied" => true}]}}
      ]

      for {schema, data} <- refusals do
        assert {:error, [_ | _]} = validate(@contract, schema, data),
               "#{schema} accepted #{inspect(data)}"
      end
    end
  end

  describe "OpenPairings -> POST /api/snapshots" do
    test "every snapshot example is accepted, and the answer follows the schema" do
      for name <- [
            "snapshot.request.json",
            "snapshot.request.team.json",
            "snapshot.request.minimal.json"
          ] do
        slug = unique_slug("contract")
        snapshot = with_slug(example(name), slug)
        body = snapshot |> publish(operator_token(), random_key()) |> json_response(200)

        assert_valid!(@contract, "snapshot.response.schema.json", body)
        assert body["slug"] == slug
        # Stored verbatim, read back whole.
        assert json_response(get(build_conn(), "/api/tournaments/#{slug}"), 200) == snapshot
      end
    end

    test "an installation key publishes to the slug it minted" do
      {:ok, _} = Moderation.put_setting(:registration_open, true, admin())

      registered =
        "/api/installations"
        |> post_json(example("installation.request.json"), nil)
        |> json_response(201)

      assert_valid!(@contract, "installation.response.schema.json", registered)

      minted =
        "/api/tournaments"
        |> post_json(example("mint.request.json"), registered["key"])
        |> json_response(201)

      assert_valid!(@contract, "mint.response.schema.json", minted)

      body =
        "snapshot.request.json"
        |> example()
        |> with_slug(minted["slug"])
        |> publish(registered["key"], random_key())
        |> json_response(200)

      assert_valid!(@contract, "snapshot.response.schema.json", body)
    end

    test "the refusals follow the error schema" do
      {slug, _key} = published!()
      good = with_slug(example("snapshot.request.json"), slug)

      for {payload, key, status, code} <- [
            {Map.put(good, "schema", "something/else"), nil, 422, "wrong_schema"},
            {Map.put(good, "version", 2), nil, 422, "unknown_version"},
            {with_slug(good, "  "), nil, 422, "missing_slug"},
            {good, nil, 403, "key_required"},
            {good, random_key(), 403, "key_mismatch"}
          ] do
        body = payload |> publish(operator_token(), key) |> json_response(status)
        assert_valid!(@contract, "error.response.schema.json", body)
        assert body["error"] == code
      end

      body = good |> publish("not-the-token") |> json_response(401)
      assert_valid!(@contract, "error.response.schema.json", body)
    end
  end

  describe "OpenPairings -> the other publishing routes" do
    test "POST /api/tournaments/:slug/proofs: the publish asks, the upload answers" do
      slug = unique_slug("contract")
      key = random_key()
      snapshot = with_slug(example("snapshot.request.json"), slug)

      asked = snapshot |> publish(operator_token(), key) |> json_response(200)
      assert_valid!(@contract, "snapshot.response.schema.json", asked)
      upload = example("proof.request.json")
      assert asked["proofs_wanted"] == [%{"round" => 1, "sha256" => upload["sha256"]}]

      path = "/api/tournaments/#{slug}/proofs"
      body = path |> post_json(upload, operator_token(), key) |> json_response(200)
      assert_valid!(@contract, "proof.response.schema.json", body)
      assert body["stored"] == true

      again = path |> post_json(upload, operator_token(), key) |> json_response(200)
      assert again["stored"] == false

      # Held now, so the next publish asks for nothing.
      repeat = snapshot |> publish(operator_token(), key) |> json_response(200)
      refute Map.has_key?(repeat, "proofs_wanted")
    end

    test "the proof upload's refusals follow the error schema" do
      {slug, key} = published!()
      path = "/api/tournaments/#{slug}/proofs"
      upload = example("proof.request.json")
      other = Base.encode64(:zlib.gzip("not the announced proof"))

      for {body, status, code} <- [
            {Map.put(upload, "round", 2), 409, "proof_not_announced"},
            {Map.put(upload, "gzip_base64", other), 422, "proof_mismatch"},
            {Map.delete(upload, "sha256"), 422, "invalid_request"}
          ] do
        answer = path |> post_json(body, operator_token(), key) |> json_response(status)
        assert_valid!(@contract, "error.response.schema.json", answer)
        assert answer["error"] == code
      end

      answer = path |> post_json(upload, operator_token(), random_key()) |> json_response(403)
      assert_valid!(@contract, "error.response.schema.json", answer)
    end

    test "GET /api/server" do
      body = json_response(get(build_conn(), "/api/server"), 200)
      assert_valid!(@contract, "server.response.schema.json", body)
    end

    test "GET /api/tournaments/:slug/claim, both answers" do
      {slug, key} = published!()
      unclaimed = unique_slug("contract")

      for {s, k, claim} <- [{slug, key, "tournament_key"}, {unclaimed, random_key(), "unclaimed"}] do
        body =
          build_conn()
          |> bearer(operator_token())
          |> tournament_key(k)
          |> get("/api/tournaments/#{s}/claim")
          |> json_response(200)

        assert_valid!(@contract, "claim.response.schema.json", body)
        assert body["claim"] == claim
      end
    end

    test "POST and DELETE /api/tournaments/:slug/relay-keys" do
      {slug, key} = published!()

      made =
        "/api/tournaments/#{slug}/relay-keys"
        |> post_json(example("relay-key.request.json"), operator_token(), key)
        |> json_response(201)

      assert_valid!(@contract, "relay-key.response.schema.json", made)

      revoked =
        build_conn()
        |> bearer(operator_token())
        |> tournament_key(key)
        |> delete("/api/tournaments/#{slug}/relay-keys?label=openpairings")
        |> json_response(200)

      assert_valid!(@contract, "relay-key-revoke.response.schema.json", revoked)
      assert revoked["revoked"] == 1
    end

    test "GET /api/tournaments/:slug/registrations" do
      {slug, key} = published!()

      entry =
        example("registrations.response.json")["registrations"] |> hd() |> Map.fetch!("payload")

      {:ok, _} = Registrations.ingest(Map.put(entry, "tournament_slug", slug))

      body = slug |> registrations(operator_token(), key) |> json_response(200)
      assert_valid!(@contract, "registrations.response.schema.json", body)
      assert [%{"payload" => %{"player" => %{"name" => "De Vos, Ilse"}}}] = body["registrations"]
    end

    test "DELETE /api/tournaments/:slug" do
      {slug, key} = published!()
      body = slug |> takedown(operator_token(), key) |> json_response(200)
      assert_valid!(@contract, "takedown.response.schema.json", body)
      assert body["deleted"]["snapshots"] == 1
    end

    test "the read routes' refusals follow the error schema" do
      {slug, _key} = published!()

      for {path, bearer, status} <- [
            {"/api/tournaments/#{slug}?at=2026-01-01T00:00:00Z", nil, 403},
            {"/api/tournaments/#{unique_slug("nothing")}", nil, 404},
            {"/api/tournaments/#{slug}/history?at=yesterday", operator_token(), 400}
          ] do
        body = build_conn() |> bearer(bearer) |> get(path) |> json_response(status)
        assert_valid!(@contract, "error.response.schema.json", body)
      end
    end
  end

  describe "Alnasl -> POST /api/tournaments/:slug/live" do
    test "every single-board example is accepted with a relay key, and the answer follows the schema" do
      for name <- [
            "live-board.request.json",
            "live-board.request.finished.json",
            "live-board.request.fen-only.json"
          ] do
        {slug, key} = published!()
        relay = relay_key!(slug, key)

        body =
          "/api/tournaments/#{slug}/live"
          |> post_json(example(name), relay)
          |> json_response(200)

        assert_valid!(@contract, "live-board.response.schema.json", body)
        assert body["applied"] == true
      end
    end

    test "an update older than the one held is still 200, with its reason" do
      {slug, key} = published!()
      relay = relay_key!(slug, key)
      path = "/api/tournaments/#{slug}/live"

      post_json(path, example("live-board.request.finished.json"), relay) |> json_response(200)
      body = path |> post_json(example("live-board.request.json"), relay) |> json_response(200)

      assert_valid!(@contract, "live-board.response.schema.json", body)
      assert body["reason"] == "older_than_stored"
    end

    test "the batch example is accepted, and one result per board follows the schema" do
      {slug, key} = published!()
      relay = relay_key!(slug, key)
      batch = example("live-board-batch.request.json")

      bad = %{"round" => 1, "board" => 1, "moves" => ["e4", "Ke2", "Qh5"]}

      body =
        "/api/tournaments/#{slug}/live"
        |> post_json(
          Map.update!(
            batch,
            "boards",
            &(&1 ++ [bad, %{"round" => 9, "board" => 1, "moves" => ["e4"]}])
          ),
          relay
        )
        |> json_response(200)

      assert_valid!(@contract, "live-board-batch.response.schema.json", body)

      assert [
               %{"status" => "ok"},
               %{"status" => "ok"},
               %{"error" => "invalid_moves"},
               %{"error" => "board_not_published"}
             ] =
               body["results"]
    end

    test "Alnasl's connection test - an empty body with its relay key - is 422 invalid_request" do
      {slug, key} = published!()
      relay = relay_key!(slug, key)

      body = "/api/tournaments/#{slug}/live" |> post_json(%{}, relay) |> json_response(422)
      assert_valid!(@contract, "error.response.schema.json", body)
      assert body["error"] == "invalid_request"
    end

    test "the refusals a relay gets follow the error schema" do
      {slug, key} = published!()
      relay = relay_key!(slug, key)
      path = "/api/tournaments/#{slug}/live"

      for {body, status, code} <- [
            {%{"round" => 9, "board" => 1, "moves" => ["e4"]}, 409, "board_not_published"},
            {%{"round" => 3, "board" => 1, "moves" => ["e4", "e4"]}, 422, "invalid_moves"},
            {%{"round" => 3, "board" => 1, "moves" => ["e4"], "ply" => 2}, 422, "ply_mismatch"},
            {%{"round" => 3, "board" => 1, "fen" => "not a fen", "ply" => 0}, 422, "invalid_fen"}
          ] do
        answer = path |> post_json(body, relay) |> json_response(status)
        assert_valid!(@contract, "error.response.schema.json", answer)
        assert answer["error"] == code
      end

      post_json(path, %{"round" => 3, "board" => 1, "moves" => ["e4", "e5"]}, relay)

      answer =
        path
        |> post_json(%{"round" => 3, "board" => 1, "moves" => ["d4", "d5"]}, relay)
        |> json_response(409)

      assert_valid!(@contract, "error.response.schema.json", answer)
      assert answer["error"] == "moves_conflict"

      other = unique_slug("contract-other")

      for {bearer, status, code} <- [
            {relay, 403, "relay_key_wrong_tournament"},
            {operator_token(), 404, "tournament_not_published"}
          ] do
        answer =
          "/api/tournaments/#{other}/live"
          |> post_json(example("live-board.request.json"), bearer)
          |> json_response(status)

        assert_valid!(@contract, "error.response.schema.json", answer)
        assert answer["error"] == code
      end
    end
  end

  test "every code OpenResultsWeb.ApiError can send is in the contract, with the body it sends" do
    extras = %{
      rate_limited: %{retry_after: 3},
      storage_low: %{retry_after: 300},
      tournament_limit: %{limit: 5},
      live_game_limit: %{limit: 500},
      snapshot_too_large: %{limit_bytes: 3_145_728},
      invalid_moves: %{ply: 3, detail: "ply 3: no"}
    }

    for code <- ApiError.codes() do
      conn = ApiError.send(build_conn(), code, Map.get(extras, code, %{}))
      body = Jason.decode!(conn.resp_body)
      assert_valid!(@contract, "error.response.schema.json", body)
      assert conn.status == ApiError.status(code)
    end
  end
end
