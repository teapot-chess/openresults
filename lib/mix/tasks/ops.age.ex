defmodule Mix.Tasks.Ops.Age do
  @shortdoc "Makes an off-site backup key, or opens an off-site backup"
  @moduledoc """
  The operator's half of `OpenResults.Ops.OffsiteBackup`, run on the
  operator's own machine - never on the server, which must not hold a secret
  key.

      mix ops.age keygen --out backup-key.txt
      mix ops.age public --identity backup-key.txt
      mix ops.age decrypt --identity backup-key.txt openresults-....orbak.age [OUT]

  `keygen` writes a new key file in `age-keygen`'s format and prints only the
  PUBLIC key, which is what goes in `OFFSITE_BACKUP_RECIPIENTS`. It refuses
  to overwrite a file. Keep the key file offline, and keep a second copy
  somewhere else: without it the off-site backups cannot be read by anyone.

  `decrypt` writes `OUT` (default: the input without `.age`), which is an
  ordinary local backup again - restore it the way docs/deployment.md,
  "Restoring a backup", says. The standard tool does the same:
  `age -d -i backup-key.txt -o OUT IN`.
  """
  use Mix.Task

  alias OpenResults.Ops.Age

  @impl true
  def run(args) do
    Mix.Task.run("compile")

    {opts, rest, _} = OptionParser.parse(args, strict: [out: :string, identity: :string])

    case {rest, opts} do
      {["keygen"], opts} ->
        keygen(opts[:out])

      {["public"], opts} ->
        with_identity(opts, &public/1)

      {["decrypt", input], opts} ->
        with_identity(opts, &decrypt(&1, input, String.replace_suffix(input, ".age", "")))

      {["decrypt", input, output], opts} ->
        with_identity(opts, &decrypt(&1, input, output))

      _ ->
        Mix.raise(
          "usage: mix ops.age keygen --out FILE | public --identity FILE | decrypt --identity FILE IN [OUT]"
        )
    end
  end

  defp keygen(nil), do: Mix.raise("keygen needs --out FILE; the secret key is never printed")

  defp keygen(path) do
    if File.exists?(path), do: Mix.raise("#{path} already exists; not overwriting a key")

    {secret, public} = Age.generate_identity()
    stamp = DateTime.utc_now(:second) |> DateTime.to_iso8601()
    File.write!(path, "# created: #{stamp}\n# public key: #{public}\n#{secret}\n")
    # Owner-only where the platform has the notion; Windows ignores it.
    File.chmod(path, 0o600)

    Mix.shell().info("Wrote #{path}. Public key (for OFFSITE_BACKUP_RECIPIENTS):\n#{public}")
  end

  defp with_identity(opts, fun) do
    path = opts[:identity] || Mix.raise("--identity FILE is required")

    case File.read(path) do
      {:ok, text} -> fun.(text)
      {:error, reason} -> Mix.raise("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp public(identity) do
    case Age.public_key(identity) do
      {:ok, public} -> Mix.shell().info(public)
      {:error, message} -> Mix.raise(message)
    end
  end

  defp decrypt(_identity, input, input),
    do: Mix.raise("give an output path; it would overwrite the input")

  defp decrypt(identity, input, output) do
    if File.exists?(output), do: Mix.raise("#{output} already exists; not overwriting it")

    case Age.decrypt_file(input, output, identity) do
      :ok -> Mix.shell().info("Wrote #{output}")
      {:error, message} -> Mix.raise(message)
    end
  end
end
