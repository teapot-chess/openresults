defmodule OpenResults.Tombstones do
  @moduledoc """
  Slugs the operator deleted, and the refusal that keeps them deleted.

  `docs/public-publishing.md`, "Deleted tournaments", is the contract.

  ## Why a takedown needed one

  `OpenResults.Takedown` releases the tournament key and drops the status row,
  on purpose: an arbiter withdrawing their own page may publish again under
  the same address. That is exactly wrong for a page the OPERATOR removed. A
  hosted OpenPairings publishes with the operator token, nobody tells it about
  the delete, and its next automatic publish found an unclaimed slug,
  claimed it with the same key, and put the page back - listed, with every
  player on it - within a result or two. The admin panel reported a delete;
  the site reported the tournament.

  So an admin delete writes a row here in the same transaction as the
  takedown, and every publish asks this module first.

  ## Who may get past one

  Nobody by accident. Both credentials are refused with `tournament_deleted`.
  Break-glass - the operator token presented as the tournament key - is the
  one way through, and only on the operator path: it lifts the tombstone,
  logs that it did (`lift_tombstone`, actor `break-glass`), and the publish
  carries on as any break-glass publish does. An installation key never
  lifts one.
  """

  import Ecto.Query, warn: false

  alias OpenResults.Repo
  alias OpenResults.Tombstones.Tombstone
  alias OpenResults.TournamentKeys

  @doc """
  Leaves a tombstone on `slug`. Inside the caller's transaction (the
  takedown's). A slug already tombstoned keeps its first row: the first
  delete is the one that counts.
  """
  @spec put(String.t(), String.t() | nil, String.t(), DateTime.t()) :: :ok
  def put(slug, installation_id, deleted_by, %DateTime{} = at \\ DateTime.utc_now())
      when is_binary(slug) and is_binary(deleted_by) do
    Repo.insert_all(
      Tombstone,
      [
        %{
          slug: slug,
          installation_id: installation_id,
          deleted_by: deleted_by,
          deleted_at: usec(at)
        }
      ],
      on_conflict: :nothing,
      conflict_target: :slug
    )

    :ok
  end

  @doc "The tombstone on `slug`, or `nil`."
  @spec get(String.t()) :: Tombstone.t() | nil
  def get(slug) when is_binary(slug), do: Repo.get(Tombstone, slug)
  def get(_not_a_slug), do: nil

  @doc "Has the operator deleted `slug`?"
  @spec tombstoned?(String.t()) :: boolean()
  def tombstoned?(slug) when is_binary(slug),
    do: Repo.exists?(from t in Tombstone, where: t.slug == ^slug)

  def tombstoned?(_not_a_slug), do: false

  @doc """
  Was `slug` deleted while `installation_id` owned it? What turns that
  installation's `not_owner` into `tournament_deleted`: its arbiter is owed
  the truth, and nobody else is owed anything.
  """
  @spec deleted_from?(String.t(), String.t()) :: boolean()
  def deleted_from?(slug, installation_id) when is_binary(slug) and is_binary(installation_id) do
    Repo.exists?(
      from t in Tombstone, where: t.slug == ^slug and t.installation_id == ^installation_id
    )
  end

  def deleted_from?(_slug, _installation_id), do: false

  @doc """
  May a publish with the operator token go ahead on `slug`, given the key it
  presented? Inside the publish's immediate transaction.

  `:ok` when there is no tombstone, and when the key is the operator token
  itself (break-glass): then the tombstone is lifted and the lift logged.
  `{:error, :tournament_deleted}` otherwise.
  """
  @spec check_operator_publish(String.t(), String.t() | nil) ::
          :ok | {:error, :tournament_deleted}
  def check_operator_publish(slug, presented) do
    cond do
      not tombstoned?(slug) ->
        :ok

      TournamentKeys.break_glass_key?(presented) ->
        lift(slug)

      true ->
        {:error, :tournament_deleted}
    end
  end

  @doc """
  Lifts the tombstone on `slug`, logging it as break-glass. Only
  `check_operator_publish/2` calls this.
  """
  @spec lift(String.t()) :: :ok
  def lift(slug) do
    {count, _} = Repo.delete_all(from t in Tombstone, where: t.slug == ^slug)

    if count > 0,
      do:
        OpenResults.Moderation.log_break_glass_lift(
          slug,
          "the tournament had been deleted by the operator; its tombstone was lifted"
        )

    :ok
  end

  # `insert_all` does not cast, and the column wants microseconds.
  defp usec(%DateTime{microsecond: {us, _}} = at), do: %{at | microsecond: {us, 6}}
end
