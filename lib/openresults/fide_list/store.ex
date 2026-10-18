defmodule OpenResults.FideList.Store do
  @moduledoc """
  The tables in `OpenResults.FideList.Repo`'s file, and the one move that
  makes a new list live.

  ## Three tables, two of them temporary

    * `fide_players` - the live list, the only one a search reads;
    * `fide_players_new` - the next list, built while the live one answers;
    * `fide_players_old` - the previous list, between the swap and its drop.

  An import fills `fide_players_new` in chunks that each commit on their own,
  indexes it once it is full, and only then renames the pair in one short
  transaction, together with the description of the list that is now live
  (`fide_list_meta`). A search therefore sees the whole old list or the whole
  new one and never a mixture, and a run killed anywhere before the swap -
  a deploy, the watchdog, the kernel - leaves the live list exactly as it
  was, plus a scratch table the next run drops.

  ## Indexes

  The primary key is the FIDE id, which in SQLite is the row id itself: no
  index to build for it. The name is matched through `search_key` (see
  `OpenResults.FideList.Parser.search_key/1`), with one index on it, built
  after the rows are in - an index maintained through a million and a half
  inserts costs several times one built at the end. Index names are global in
  a SQLite file and survive a table rename, so each import takes whichever of
  the two names the live table is not using.
  """

  alias OpenResults.FideList.Repo

  @live "fide_players"
  @scratch "fide_players_new"
  @retired "fide_players_old"
  @index_names ~w(fide_players_key fide_players_key_b)

  @columns ~w(fide_id name search_key federation title birth_year standard_rating rapid_rating blitz_rating)a

  @doc "The meta table, created if missing. Cheap; run at boot."
  def ensure_meta! do
    Repo.query!(
      "CREATE TABLE IF NOT EXISTS fide_list_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
    )

    :ok
  end

  @doc """
  Whether a list has ever been made live here. `false` for a database that
  cannot be opened at all, too: the search then says the list is not there
  yet, which is the truth as far as anybody using the form is concerned.
  """
  @spec available?() :: boolean()
  def available? do
    case Repo.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [@live]) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  rescue
    _unopenable -> false
  catch
    :exit, _not_started -> false
  end

  @doc "Everything in the meta table, as a string-keyed map; `%{}` when unreadable."
  @spec meta() :: %{String.t() => String.t()}
  def meta do
    case Repo.query("SELECT key, value FROM fide_list_meta") do
      {:ok, %{rows: rows}} -> Map.new(rows, fn [key, value] -> {key, value} end)
      _ -> %{}
    end
  rescue
    _unreadable -> %{}
  catch
    :exit, _not_started -> %{}
  end

  @doc "Writes `values` (string keys; `nil` deletes) into the meta table."
  def put_meta!(values) when is_map(values) do
    Enum.each(values, fn
      {key, nil} ->
        Repo.query!("DELETE FROM fide_list_meta WHERE key = ?", [key])

      {key, value} ->
        Repo.query!(
          "INSERT INTO fide_list_meta (key, value) VALUES (?, ?) " <>
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
          [key, to_string(value)]
        )
    end)
  end

  @doc """
  Drops what a killed run left behind. The scratch table was never live; the
  retired one is merely unreclaimed space. Either would make the next
  `begin_scratch!/0` fail.
  """
  def drop_leftovers! do
    Repo.query!("DROP TABLE IF EXISTS #{@scratch}")
    Repo.query!("DROP TABLE IF EXISTS #{@retired}")
    :ok
  end

  @doc "An empty scratch table, replacing any leftover one."
  def begin_scratch! do
    drop_leftovers!()

    Repo.query!("""
    CREATE TABLE #{@scratch} (
      fide_id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      search_key TEXT NOT NULL,
      federation TEXT,
      title TEXT,
      birth_year INTEGER,
      standard_rating INTEGER,
      rapid_rating INTEGER,
      blitz_rating INTEGER
    )
    """)

    :ok
  end

  @doc """
  One chunk of parsed rows into the scratch table, in one statement that
  commits on its own. A duplicate id inside the file replaces the earlier
  line rather than failing the import - FIDE's list should not have one, and
  one bad line is no reason to keep last month's list instead.
  """
  def insert_chunk!([]), do: :ok

  def insert_chunk!(rows) do
    width = length(@columns)
    one = "(" <> Enum.map_join(1..width, ", ", fn _ -> "?" end) <> ")"
    placeholders = Enum.map_join(rows, ", ", fn _ -> one end)

    params =
      Enum.flat_map(rows, fn row -> Enum.map(@columns, &blank_to_nil(Map.get(row, &1))) end)

    Repo.query!(
      "INSERT OR REPLACE INTO #{@scratch} (#{Enum.join(@columns, ", ")}) VALUES " <> placeholders,
      params
    )

    :ok
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc "How many rows the scratch table holds."
  def scratch_count!, do: count!(@scratch)

  @doc "How many players the live list holds; 0 when there is none."
  def live_count do
    if available?(), do: count!(@live), else: 0
  end

  defp count!(table) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM #{table}")
    n
  end

  @doc "The name index on the full scratch table, under the name the live table is not using."
  def index_scratch! do
    %{rows: used} =
      Repo.query!("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ?", [@live])

    used = List.flatten(used)
    name = Enum.find(@index_names, &(&1 not in used))

    Repo.query!("CREATE INDEX #{name} ON #{@scratch} (search_key)")
    :ok
  end

  @doc """
  The swap: the scratch table becomes the live one and `meta` describes it,
  in one transaction. DDL is transactional in SQLite, so a failure anywhere
  in here leaves the old list live. The retired table is dropped after the
  commit, as cleanup; a kill before that is handled by `drop_leftovers!/0`.
  """
  def swap!(meta) when is_map(meta) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        if available?() do
          Repo.query!("ALTER TABLE #{@live} RENAME TO #{@retired}")
        end

        Repo.query!("ALTER TABLE #{@scratch} RENAME TO #{@live}")
        put_meta!(meta)
        :ok
      end)

    Repo.query!("DROP TABLE IF EXISTS #{@retired}")
    :ok
  end

  @doc "Rows whose `search_key` starts with `prefix`, at most `limit`, in key order."
  def prefix(prefix, limit) when is_binary(prefix) and prefix != "" do
    # The highest code point, as UTF-8, sorts after every key that starts
    # with `prefix` and before every one that does not: a range the index
    # answers directly, with no LIKE and no collation to second-guess.
    upper = prefix <> <<0xF4, 0x8F, 0xBF, 0xBF>>

    rows(
      "SELECT #{select()} FROM #{@live} WHERE search_key >= ? AND search_key < ? " <>
        "ORDER BY search_key LIMIT ?",
      [prefix, upper, limit]
    )
  end

  @doc "The player with `fide_id`, as a list of zero or one."
  def by_id(fide_id) when is_integer(fide_id) do
    rows("SELECT #{select()} FROM #{@live} WHERE fide_id = ?", [fide_id])
  end

  defp select, do: Enum.map_join(@columns -- [:search_key], ", ", &Atom.to_string/1)

  defp rows(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)
    fields = @columns -- [:search_key]
    Enum.map(rows, &(fields |> Enum.zip(&1) |> Map.new()))
  end
end
