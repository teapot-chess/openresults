defmodule OpenResults.ContractCase do
  @moduledoc """
  Loads and applies the cross-repo contracts under `priv/contracts/`.

  The schemas are JSON Schema draft-07, checked with `ex_json_schema`. Their
  `$ref`s point at the files' public GitHub URLs, because that is where a
  consumer reads them from; here every such URL is answered from the local
  directory instead (`resolve_remote/1`). A validator that fetched its own
  contract over the network would pass or fail on the weather.
  """

  import ExUnit.Assertions

  @root Path.expand("../../priv/contracts", __DIR__)
  @url_prefix "https://raw.githubusercontent.com/teapot-chess/openresults/main/priv/contracts/"

  @doc "The directory of `contract`, e.g. `\"publish-v1\"`."
  def dir(contract), do: Path.join(@root, contract)

  @doc "Every file in `contract`'s directory, relative and sorted, as index.json must list them."
  def files_on_disk(contract) do
    base = dir(contract)

    base
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, base))
    |> Enum.sort()
  end

  @doc "A JSON file of `contract`, decoded."
  def read_json!(contract, relative) do
    contract |> dir() |> Path.join(relative) |> File.read!() |> Jason.decode!()
  end

  @doc """
  The schema file an example belongs to. Messages have dots of their own
  (`claim.response`), so `examples/claim.response.unclaimed.json` is tried as
  `claim.response.unclaimed.schema.json` first and `claim.response.schema.json`
  second: the longest name that exists wins. `nil` when none does.
  """
  def schema_for_example(contract, "examples/" <> name) do
    parts = name |> Path.rootname() |> String.split(".")

    length(parts)..1//-1
    |> Enum.map(&(Enum.take(parts, &1) |> Enum.join(".")))
    |> Enum.map(&(&1 <> ".schema.json"))
    |> Enum.find(&File.regular?(Path.join(dir(contract), &1)))
  end

  @doc "`schema_file` of `contract`, resolved, `$ref`s answered locally."
  def schema!(contract, schema_file) do
    Application.put_env(:ex_json_schema, :remote_schema_resolver, {__MODULE__, :resolve_remote})

    contract
    |> read_json!(schema_file)
    |> ExJsonSchema.Schema.resolve()
  end

  @doc "Validates `data` against `schema_file`: `:ok` or `{:error, [{message, path}]}`."
  def validate(contract, schema_file, data) do
    contract |> schema!(schema_file) |> ExJsonSchema.Validator.validate(data)
  end

  @doc "Fails the test, saying where and why, unless `data` follows `schema_file`."
  def assert_valid!(contract, schema_file, data) do
    case validate(contract, schema_file, data) do
      :ok ->
        data

      {:error, errors} ->
        flunk("""
        does not follow #{contract}/#{schema_file}:
        #{Enum.map_join(errors, "\n", fn {message, path} -> "  #{path}: #{message}" end)}
        """)
    end
  end

  @doc false
  # The `:remote_schema_resolver` ex_json_schema calls for a `$ref` outside
  # the file. Only this repo's own contract URLs are answered; anything else
  # is a contract that has started depending on the network, and should fail.
  def resolve_remote(@url_prefix <> relative) do
    path = relative |> String.split("#") |> hd()
    path |> then(&Path.join(@root, &1)) |> File.read!() |> Jason.decode!()
  end

  def resolve_remote(url),
    do: raise("contract schemas resolve locally only; got a $ref to #{url}")
end
