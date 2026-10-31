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

  # The word index: an FTS5 table beside the player table, keyed by FIDE id,
  # renamed in step with it. Two columns so a lone word can be asked of the
  # surnames alone. `detail=column` - which column, never where in it: nothing
  # here asks for word positions, and `prefix` because every word typed is the
  # start of one - without it "oswald d" costs a hundred milliseconds instead
  # of one.
  @words_live "fide_names"
  @words_scratch "fide_names_new"
  @words_retired "fide_names_old"

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
    for table <- [@scratch, @retired, @words_scratch, @words_retired] do
      Repo.query!("DROP TABLE IF EXISTS #{table}")
    end

    :ok
  end

  @doc """
  Whether the live list has its word index. A list imported before the index
  existed does not, and `OpenResults.FideList.Run` treats it as stale so the
  next check rebuilds it rather than waiting a month for FIDE to change
  something.
  """
  @spec words_available?() :: boolean()
  def words_available? do
    case Repo.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [@words_live]) do
      {:ok, %{rows: [_ | _]}} -> true
      _ -> false
    end
  rescue
    _unopenable -> false
  catch
    :exit, _not_started -> false
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

    Repo.query!("""
    CREATE VIRTUAL TABLE #{@words_scratch} USING fts5(
      surname, given,
      tokenize = 'unicode61 remove_diacritics 0',
      prefix = '1 2 3',
      detail = column
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

    # FTS5 has no OR REPLACE worth trusting, so a duplicate id goes out first:
    # the same last-line-wins as the table above.
    rows = rows |> Enum.reverse() |> Enum.uniq_by(& &1.fide_id)
    ids = Enum.map(rows, & &1.fide_id)

    Repo.query!(
      "DELETE FROM #{@words_scratch} WHERE rowid IN (#{Enum.map_join(ids, ", ", fn _ -> "?" end)})",
      ids
    )

    Repo.query!(
      "INSERT INTO #{@words_scratch} (rowid, surname, given) VALUES " <>
        Enum.map_join(rows, ", ", fn _ -> "(?, ?, ?)" end),
      Enum.flat_map(
        rows,
        &[&1.fide_id, Map.get(&1, :surname_terms, ""), Map.get(&1, :given_terms, "")]
      )
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

        if words_available?() do
          Repo.query!("ALTER TABLE #{@words_live} RENAME TO #{@words_retired}")
        end

        Repo.query!("ALTER TABLE #{@scratch} RENAME TO #{@live}")
        Repo.query!("ALTER TABLE #{@words_scratch} RENAME TO #{@words_live}")
        put_meta!(meta)
        :ok
      end)

    Repo.query!("DROP TABLE IF EXISTS #{@retired}")
    Repo.query!("DROP TABLE IF EXISTS #{@words_retired}")
    # Every player page's header comes from this list.
    OpenResults.ResultsIndex.Generations.bump(:fide_list)
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

  @doc """
  Rows whose names hold a word starting with each of `words`, in any order,
  at most `limit`. `surname_only: true` asks the surnames alone.

  The words must already be in `OpenResults.FideList.Parser.search_key/1`
  form - letters and digits - and each goes in as a quoted prefix, so nothing
  typed into the form can reach FTS5's own query syntax.
  """
  def words(words, limit, opts \\ []) when is_list(words) and words != [] do
    column = if Keyword.get(opts, :surname_only, false), do: "surname : ", else: ""

    match =
      Enum.map_join(words, " AND ", fn word ->
        column <> ~s(") <> String.replace(word, ~s("), "") <> ~s("*)
      end)

    rows(
      "SELECT #{select("p.")} FROM #{@words_live} " <>
        "JOIN #{@live} p ON p.fide_id = #{@words_live}.rowid " <>
        "WHERE #{@words_live} MATCH ? LIMIT ?",
      [match, limit]
    )
  end

  @doc """
  The players with these FIDE ids, in no particular order - for the results
  hub, which checks a page's worth of appearances at once. Asked in chunks so
  no statement carries more parameters than SQLite allows.
  """
  def by_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.chunk_every(500)
    |> Enum.flat_map(fn chunk ->
      marks = Enum.map_join(chunk, ", ", fn _ -> "?" end)
      rows("SELECT #{select()} FROM #{@live} WHERE fide_id IN (#{marks})", chunk)
    end)
  end

  @doc "The player with `fide_id`, as a list of zero or one."
  def by_id(fide_id) when is_integer(fide_id) do
    rows("SELECT #{select()} FROM #{@live} WHERE fide_id = ?", [fide_id])
  end

  # `search_key` comes back too, for `OpenResults.FideList` to rank by; the
  # form never sees it.
  defp select(alias \\ ""), do: Enum.map_join(@columns, ", ", &(alias <> Atom.to_string(&1)))

  defp rows(sql, params) do
    %{rows: rows} = Repo.query!(sql, params)
    fields = @columns
    Enum.map(rows, &(fields |> Enum.zip(&1) |> Map.new()))
  end
end
