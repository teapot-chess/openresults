defmodule OpenResultsWeb.RoundProofTest do
  # Not async: the page cache and the rate limiter are node-wide.
  use OpenResultsWeb.ConnCase, async: false

  import OpenResults.PublicPublishingFixtures

  alias OpenResults.RateLimit
  alias OpenResults.RoundProofs

  setup do
    RateLimit.reset()
    :ok
  end

  @proof_text ~s({"type":"round","format":"ainalrami-pairing-proof","version":2}\n{"type":"end"}\n)

  defp gzip, do: :zlib.gzip(@proof_text)

  # The swiss fixture with round 1 paired by Ainalrami and carrying a proof,
  # published under the operator token.
  defp publish_with_proof!(slug, key, gz \\ gzip()) do
    snapshot = with_proof(payload(slug), gz)
    body = snapshot |> publish(operator_token(), key) |> json_response(200)
    {snapshot, body}
  end

  defp with_proof(snapshot, gz) do
    update_in(snapshot, ["rounds", Access.at(0)], fn round ->
      Map.merge(round, %{
        "engine" => %{"name" => "ainalrami", "version" => "0.48.0"},
        "proof" => %{
          "sha256" => RoundProofs.digest(gz),
          "bytes" => byte_size(gz),
          "format" => "ainalrami-pairing-proof",
          "version" => 2,
          "compression" => "gzip"
        }
      })
    end)
  end

  defp upload(slug, key, gz) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> bearer(operator_token())
    |> tournament_key(key)
    |> post(
      "/api/tournaments/#{slug}/proofs",
      Jason.encode!(%{
        "round" => 1,
        "sha256" => RoundProofs.digest(gz),
        "gzip_base64" => Base.encode64(gz)
      })
    )
  end

  test "an announced, uploaded proof is a pill on the round page and a download" do
    slug = unique_slug("proof")
    key = random_key()
    {_snapshot, body} = publish_with_proof!(slug, key)
    assert [%{"round" => 1}] = body["proofs_wanted"]
    assert json_response(upload(slug, key, gzip()), 200)["stored"]

    document =
      build_conn() |> get("/t/#{slug}/round/1") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("#round-proof-1") |> Enum.count() == 1
    assert document |> LazyHTML.query("#round-proof-1") |> LazyHTML.text() =~ "Ainalrami 0.48.0"
    download = ~s(#round-proof-download-1[href="/t/#{slug}/round/1/proof"])
    assert document |> LazyHTML.query(download) |> Enum.count() == 1

    conn = get(build_conn(), "/t/#{slug}/round/1/proof")
    assert conn.status == 200
    assert conn.resp_body == gzip()
    assert :zlib.gunzip(conn.resp_body) == @proof_text
    assert get_resp_header(conn, "content-type") == ["application/gzip"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "#{slug}-round-1.proof.jsonl.gz"
  end

  test "a round without a proof shows no pill, and has no download" do
    slug = unique_slug("proof")
    payload(slug) |> publish(operator_token(), random_key()) |> json_response(200)

    document =
      build_conn() |> get("/t/#{slug}/round/1") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query(".round-proof") |> Enum.empty?()
    assert get(build_conn(), "/t/#{slug}/round/1/proof").status == 404
  end

  test "announced but not yet uploaded: the file is a 404, not somebody else's" do
    slug = unique_slug("proof")
    publish_with_proof!(slug, random_key())
    assert get(build_conn(), "/t/#{slug}/round/1/proof").status == 404
  end

  test "a republish that no longer announces the proof drops it" do
    slug = unique_slug("proof")
    key = random_key()
    publish_with_proof!(slug, key)
    json_response(upload(slug, key, gzip()), 200)

    payload(slug) |> publish(operator_token(), key) |> json_response(200)
    assert RoundProofs.fetch(slug, 1, RoundProofs.digest(gzip())) == nil

    # A different proof for the same round replaces it, by asking again.
    other = :zlib.gzip(@proof_text <> ~s({"type":"end"}\n))
    {_snapshot, body} = publish_with_proof!(slug, key, other)
    assert body["proofs_wanted"] == [%{"round" => 1, "sha256" => RoundProofs.digest(other)}]
  end

  test "bytes that are not the announced proof are refused" do
    slug = unique_slug("proof")
    key = random_key()
    publish_with_proof!(slug, key)

    assert json_response(upload(slug, key, :zlib.gzip("something else")), 409)["error"] ==
             "proof_not_announced"

    assert RoundProofs.store(slug, 1, RoundProofs.digest(gzip()), "plain text") ==
             {:error, :proof_mismatch}
  end

  test "a takedown takes the proofs with it" do
    slug = unique_slug("proof")
    key = random_key()
    publish_with_proof!(slug, key)
    json_response(upload(slug, key, gzip()), 200)

    slug |> takedown(operator_token(), key) |> json_response(200)
    assert RoundProofs.fetch(slug, 1, RoundProofs.digest(gzip())) == nil
  end
end
