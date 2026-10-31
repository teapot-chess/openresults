defmodule OpenResults.Ops.ErrorReports.LoggerHandler do
  @moduledoc """
  An Erlang `:logger` handler that notices crashes and hands them on.

  A handler runs in the process that logged, so this one does as little as
  possible there: it builds the sanitized report (`ErrorReports.from_crash/1`)
  and casts it to `OpenResults.Ops.ErrorReports.Recorder`. No database work
  happens in the crashing process, and nothing here may raise - `:logger`
  removes a handler that does, and then nobody hears about the next crash
  either.

  Installed by `install/0` at boot when `config :openresults,
  :error_reports` is true (production and dev; not test, where crashes are
  the point of half the suite).
  """

  alias OpenResults.Ops.ErrorReports
  alias OpenResults.Ops.ErrorReports.Recorder

  @id :openresults_error_reports

  @doc "Adds the handler unless it is already there."
  def install(recorder \\ Recorder) do
    case :logger.add_handler(@id, __MODULE__, %{level: :error, config: %{recorder: recorder}}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      error -> error
    end
  end

  @doc "Removes it again."
  def uninstall, do: :logger.remove_handler(@id)

  @doc false
  # The `:logger` callback.
  def log(%{meta: %{crash_reason: reason}}, %{config: %{recorder: recorder}}) do
    case ErrorReports.from_crash(reason) do
      :ignore -> :ok
      report -> Recorder.capture(recorder, report)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def log(_event, _config), do: :ok
end
