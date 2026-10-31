defmodule OpenResults.ResultsIndex.Generations do
  @moduledoc """
  Counters, in ETS, that say when a cross-tournament page last changed.

  A tournament page is cached under its snapshot id (see
  `OpenResultsWeb.Plugs.Revalidate`). A federation listing or a player page
  has no single snapshot behind it, so it is cached under a GENERATION
  instead: a number that moves whenever something that page shows may have
  moved. The keys:

    * `:all` - anything indexed anywhere; the front page and `/federations`.
    * `{:federation, code}` - a tournament of that federation (or `:none`)
      was indexed, removed, or changed status. A busy Saturday in BEL
      invalidates BEL's listing and nobody else's.
    * `{:player, fide_id}` - a tournament listing that FIDE id was indexed,
      removed or changed status, or the player page was hidden or restored.
    * `:fide_list` - a new FIDE list went live, which changes every player
      page's header.

  Bumped AFTER the commit that changed the data, never before: a reader that
  sees the new number must also find the new rows, or it would cache the old
  page under the new number until the next change. Only keys that were ever
  bumped have an entry; reading one that was not answers 0. Lost on restart
  together with the page cache it keys, and the ETag secret is redrawn at
  boot too, so a browser's tag from before a restart never matches a page
  rendered after it.
  """

  use GenServer

  @table __MODULE__

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The generation of `key`; 0 when it was never bumped."
  @spec get(term()) :: non_neg_integer()
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  @doc "Moves every key in `keys` to its next generation."
  @spec bump([term()] | term()) :: :ok
  def bump(keys) when is_list(keys) do
    keys |> Enum.uniq() |> Enum.each(&bump_one/1)
  end

  def bump(key), do: bump([key])

  defp bump_one(key) do
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  rescue
    ArgumentError -> :ok
  end

  @doc "Forgets everything. For tests."
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl GenServer
  def init(opts) do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

      _exists ->
        :ok
    end

    {:ok, opts}
  end
end
