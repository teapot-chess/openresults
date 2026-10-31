defmodule OpenResults.RoundProofs do
  @moduledoc """
  Pairing proofs: per round, the file the pairing engine wrote to show its
  matchings were optimal, kept so a reader of the round page can download it
  and check it with a verifier that owes the engine nothing.

  ## Why not inside the snapshot

  A proof is hundreds of kilobytes gzipped on an ordinary field and
  megabytes on a large one, and the snapshot is resent whole on every
  publish and stored again as a new version each time. Nine rounds of
  proofs inside it would be nine rounds of proofs per version, and an
  installation's snapshot cap would be spent on files nobody reads twice.

  So the snapshot names each proof by digest (`rounds[].proof`: `sha256`,
  `bytes`, `format`, `version`), the answer to the publish lists the ones
  this server does not hold yet (`proofs_wanted`, from `reconcile/2`), and
  the publisher uploads exactly those to `POST /api/tournaments/:slug/proofs`
  (`store/4`). A server that predates this answers without `proofs_wanted`,
  and its publisher uploads nothing.

  ## What is checked

  Only what this server can check: that the current snapshot announces this
  digest for this round, that the bytes are gzip, and that their SHA-256 is
  the announced one. Whether the proof proves anything is the verifier's
  business, not ours - this server never runs it, and the page says so.

  ## What is kept

  The proofs the CURRENT snapshot announces, nothing else. A round paired
  again, or withdrawn, takes its old proof with it at the next publish
  (`reconcile/2`); a takedown takes all of them (`delete_all_for/1`).
  Starting ranks only, no names: a proof is not personal data.
  """

  import Ecto.Query, warn: false

  alias OpenResults.Repo
  alias OpenResults.RoundProofs.RoundProof

  # Gzipped bytes. The largest field the publisher proves (300 players)
  # writes about two megabytes; the base64 of this limit still fits under the
  # JSON parser's eight.
  @max_bytes 5_000_000
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @doc "The largest proof accepted, in gzipped bytes."
  def max_bytes, do: @max_bytes

  @doc """
  The proofs `payload` announces, as `%{round:, sha256:, bytes:}`, in round
  order. A round whose `proof` is not of the contract's shape announces
  nothing; a malformed one is the publisher's bug, not a reason to refuse
  the publish.
  """
  @spec announced(term()) :: [%{round: pos_integer(), sha256: String.t(), bytes: integer() | nil}]
  def announced(%{"rounds" => rounds}) when is_list(rounds) do
    for %{"number" => n, "proof" => %{"sha256" => sha} = proof} <- rounds,
        is_integer(n) and n > 0 and is_binary(sha),
        Regex.match?(@sha256, sha) do
      %{round: n, sha256: sha, bytes: if(is_integer(proof["bytes"]), do: proof["bytes"])}
    end
  end

  def announced(_payload), do: []

  @doc """
  After a publish of `payload` to `slug`: drops every stored proof the
  document no longer announces and returns the announced ones not yet held,
  as `%{"round" => n, "sha256" => digest}` - the publish answer's
  `proofs_wanted`.
  """
  @spec reconcile(String.t(), term()) :: [map()]
  def reconcile(slug, payload) do
    announced = announced(payload)
    keep = MapSet.new(announced, &{&1.round, &1.sha256})
    held = held(slug)

    for {round, sha} = pair <- held, not MapSet.member?(keep, pair) do
      Repo.delete_all(
        from p in RoundProof,
          where: p.tournament_slug == ^slug and p.round == ^round and p.sha256 == ^sha
      )
    end

    held = MapSet.new(held)

    for a <- announced, not MapSet.member?(held, {a.round, a.sha256}) do
      %{"round" => a.round, "sha256" => a.sha256}
    end
  end

  defp held(slug) do
    Repo.all(
      from p in RoundProof,
        where: p.tournament_slug == ^slug,
        select: {p.round, p.sha256}
    )
  end

  @doc """
  Stores the proof of round `round` of `slug`: `gzip`, which must be gzip,
  hash to `sha256`, and be what the current snapshot announces for that
  round. Storing one already held is `{:ok, :already}`, so a retry after a
  lost answer is harmless.
  """
  @spec store(String.t(), term(), term(), binary()) ::
          {:ok, :stored | :already}
          | {:error, :proof_not_announced | :proof_mismatch}
          | {:error, :proof_too_large, map()}
  def store(slug, round, sha256, gzip) when is_binary(gzip) do
    announcement =
      slug
      |> current_payload()
      |> announced()
      |> Enum.find(&(&1.round == round and &1.sha256 == sha256))

    cond do
      byte_size(gzip) > @max_bytes ->
        {:error, :proof_too_large, %{limit_bytes: @max_bytes}}

      is_nil(announcement) ->
        {:error, :proof_not_announced}

      not gzip?(gzip) or digest(gzip) != sha256 or
          (announcement.bytes != nil and announcement.bytes != byte_size(gzip)) ->
        {:error, :proof_mismatch}

      true ->
        insert(slug, round, sha256, gzip)
    end
  end

  defp insert(slug, round, sha256, gzip) do
    {count, _} =
      Repo.insert_all(
        RoundProof,
        [
          %{
            tournament_slug: slug,
            round: round,
            sha256: sha256,
            bytes: byte_size(gzip),
            gzip: gzip,
            inserted_at: DateTime.utc_now()
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:tournament_slug, :round, :sha256]
      )

    {:ok, if(count == 1, do: :stored, else: :already)}
  end

  @doc """
  The stored file for round `round` of `slug` with digest `sha256`, or nil.
  The caller takes the digest from the snapshot it is rendering, so a proof
  is only ever served beside the round it proves.
  """
  @spec fetch(String.t(), integer(), String.t()) :: binary() | nil
  def fetch(slug, round, sha256) do
    Repo.one(
      from p in RoundProof,
        where: p.tournament_slug == ^slug and p.round == ^round and p.sha256 == ^sha256,
        select: p.gzip
    )
  end

  @doc "Removes every proof of `slug`. Only `OpenResults.Takedown.purge/2` calls this."
  @spec delete_all_for(String.t()) :: non_neg_integer()
  def delete_all_for(slug) do
    {count, _} = Repo.delete_all(from p in RoundProof, where: p.tournament_slug == ^slug)
    count
  end

  @doc "The lowercase hex SHA-256 of `bytes`."
  def digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp gzip?(<<0x1F, 0x8B, _rest::binary>>), do: true
  defp gzip?(_other), do: false

  defp current_payload(slug) do
    case OpenResults.Snapshots.latest(slug) do
      %{payload: payload} -> payload
      nil -> nil
    end
  end
end
