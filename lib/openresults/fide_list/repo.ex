defmodule OpenResults.FideList.Repo do
  @moduledoc """
  The FIDE rating list's own database file - see `OpenResults.FideList`.

  A second repo rather than a table in `OpenResults.Repo`, for two reasons
  that are both about the main database:

    * SQLite has one writer per FILE. An import is a million and a half
      inserts; in the main file every chunk would queue in front of a
      publish or an entry, and the main file is the one that matters.
    * The backups copy the main file whole, every day, for a month. The list
      is a public dataset FIDE re-publishes every month; carrying 200 MB of it
      in every backup would be paying to keep something nobody needs kept.

  Not in `:ecto_repos` and without migrations: the schema is created by the
  import itself, which builds each new list from scratch anyway (see
  `OpenResults.FideList.Store`). Losing this file loses nothing the next
  download does not bring back.
  """

  use Ecto.Repo,
    otp_app: :openresults,
    adapter: Ecto.Adapters.SQLite3

  # On a fresh install the file does not exist yet, and every connection in
  # the pool opens it at once and tries to switch it to WAL - which takes a
  # lock, which all but one of them then fail to get, each logging "database
  # is locked" before the pool retries. Harmless, and an alarming first line
  # in a new server's log. So the file is created, in WAL, by one connection
  # before the pool starts.
  @impl true
  def init(_context, config) do
    with path when is_binary(path) <- config[:database],
         false <- File.exists?(path) do
      try do
        File.mkdir_p!(Path.dirname(path))
        {:ok, db} = Exqlite.Sqlite3.open(path)
        Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
        Exqlite.Sqlite3.close(db)
      rescue
        # The pool will fail on the same thing and say so better.
        _ -> :ok
      end
    end

    {:ok, config}
  end
end
