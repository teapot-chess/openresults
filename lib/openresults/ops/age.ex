defmodule OpenResults.Ops.Age do
  @moduledoc """
  Public-key file encryption in the age format (age-encryption.org/v1), X25519
  recipients only, written on top of `:crypto`.

  ## Why age, and why public-key at all

  The off-site copy (`OpenResults.Ops.OffsiteBackup`) leaves this machine
  and lands on storage somebody else runs. Encrypting it with a passphrase the
  server knows would mean the server holds the key to every copy it ever sent:
  whoever takes the box takes the archive too. With a public key the server
  can lock and cannot unlock - the secret half lives with the operator, off
  the box, and never needs to come back.

  age because the format is small, specified, and has an ordinary command-line
  tool on every platform: `age -d -i key.txt file.age > file` restores without
  this application, which is the whole point of a backup that outlives it.
  `mix ops.age` does the same from here, for whoever would rather not install
  anything.

  ## What is implemented

  Exactly the parts a backup needs, from the spec at
  https://age-encryption.org/v1:

    * the X25519 recipient stanza (HKDF-SHA-256, ChaCha20-Poly1305 key wrap);
    * the header MAC (HMAC-SHA-256 under a key derived from the file key);
    * the STREAM payload: 64 KiB ChaCha20-Poly1305 chunks, an 11-byte
      big-endian counter and a last-chunk flag as the nonce.

  No passphrase (scrypt) recipients, no SSH keys, no ASCII armour, no plugins.
  A file using any of those is refused rather than half-read.

  Encryption and decryption stream from file to file in 64 KiB pieces, so a
  backup of any size costs the same memory.
  """

  @version_line "age-encryption.org/v1"
  @x25519_info "age-encryption.org/v1/X25519"
  @chunk 64 * 1024
  @tag_size 16
  @public_hrp "age"
  @secret_hrp "age-secret-key-"

  @typedoc "An `age1...` public key."
  @type recipient :: String.t()
  @typedoc "An `AGE-SECRET-KEY-1...` secret key, or the text of a key file holding one."
  @type identity :: String.t()

  # -- keys ------------------------------------------------------------------

  @doc "A fresh key pair: `{secret, public}`, both in age's own spelling."
  @spec generate_identity() :: {identity(), recipient()}
  def generate_identity do
    secret = :crypto.strong_rand_bytes(32)
    {encode_secret(secret), encode_public(x25519_public(secret))}
  end

  @doc "The public key belonging to a secret key (or key file text)."
  @spec public_key(identity()) :: {:ok, recipient()} | {:error, String.t()}
  def public_key(identity) do
    with {:ok, secret} <- parse_identity(identity) do
      {:ok, encode_public(x25519_public(secret))}
    end
  end

  @doc "Checks that `recipient` is a well-formed `age1...` key."
  @spec parse_recipient(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def parse_recipient(recipient) when is_binary(recipient) do
    case OpenResults.Ops.Bech32.decode(String.trim(recipient)) do
      {:ok, {@public_hrp, <<_::binary-size(32)>> = key}} -> {:ok, key}
      _ -> {:error, "not an age X25519 public key (age1...)"}
    end
  end

  def parse_recipient(_), do: {:error, "not an age X25519 public key (age1...)"}

  @doc false
  # Accepts a bare secret key or the whole text of an `age-keygen` file
  # (comment lines and all). Never puts the key itself in an error.
  @spec parse_identity(identity()) :: {:ok, binary()} | {:error, String.t()}
  def parse_identity(text) when is_binary(text) do
    line =
      text
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.find(&String.starts_with?(&1, "AGE-SECRET-KEY-1"))

    case line && OpenResults.Ops.Bech32.decode(line) do
      {:ok, {@secret_hrp, <<_::binary-size(32)>> = secret}} -> {:ok, secret}
      _ -> {:error, "no age secret key (AGE-SECRET-KEY-1...) found"}
    end
  end

  def parse_identity(_), do: {:error, "no age secret key (AGE-SECRET-KEY-1...) found"}

  defp encode_public(key), do: OpenResults.Ops.Bech32.encode(@public_hrp, key)
  defp encode_secret(key), do: String.upcase(OpenResults.Ops.Bech32.encode(@secret_hrp, key))

  defp x25519_public(secret) do
    {public, _} = :crypto.generate_key(:ecdh, :x25519, secret)
    public
  end

  # -- in memory (tests, small things) ----------------------------------------

  @doc "Encrypts a binary to one or more recipients."
  @spec encrypt(binary(), [recipient()]) :: {:ok, binary()} | {:error, String.t()}
  def encrypt(plaintext, recipients) when is_binary(plaintext) do
    with {:ok, file_key, header} <- header(recipients) do
      nonce = :crypto.strong_rand_bytes(16)
      key = hkdf(file_key, nonce, "payload")
      {:ok, IO.iodata_to_binary([header, nonce | seal_all(key, plaintext, 0)])}
    end
  end

  defp seal_all(key, <<chunk::binary-size(@chunk), rest::binary>>, counter) when rest != "" do
    [seal(key, counter, chunk, false) | seal_all(key, rest, counter + 1)]
  end

  defp seal_all(key, last, counter), do: [seal(key, counter, last, true)]

  @doc "Decrypts a binary with a secret key (or key file text)."
  @spec decrypt(binary(), identity()) :: {:ok, binary()} | {:error, String.t()}
  def decrypt(ciphertext, identity) when is_binary(ciphertext) do
    path = tmp_path()
    out = path <> ".out"

    try do
      File.write!(path, ciphertext)

      with :ok <- decrypt_file(path, out, identity) do
        {:ok, File.read!(out)}
      end
    after
      File.rm(path)
      File.rm(out)
    end
  end

  defp tmp_path do
    Path.join(System.tmp_dir!(), "age-#{System.unique_integer([:positive])}")
  end

  # -- files -------------------------------------------------------------------

  @doc """
  Encrypts the file at `source` to `recipients`, writing `target`. On any
  failure `target` is removed, so a half-written file is never mistaken for a
  backup.
  """
  @spec encrypt_file(Path.t(), Path.t(), [recipient()]) :: :ok | {:error, String.t()}
  def encrypt_file(source, target, recipients) do
    with {:ok, file_key, header} <- header(recipients),
         {:ok, input} <- open(source, [:read]),
         {:ok, output} <- open(target, [:write]) do
      result =
        try do
          nonce = :crypto.strong_rand_bytes(16)
          :ok = :file.write(output, [header, nonce])
          stream_seal(input, output, hkdf(file_key, nonce, "payload"), 0, read(input, @chunk))
        after
          File.close(input)
          File.close(output)
        end

      cleanup_on_error(result, target)
    end
  end

  defp stream_seal(input, output, key, counter, current) do
    case read(input, @chunk) do
      "" ->
        :file.write(output, seal(key, counter, current, true))

      next ->
        with :ok <- :file.write(output, seal(key, counter, current, false)) do
          stream_seal(input, output, key, counter + 1, next)
        end
    end
  end

  @doc """
  Decrypts the age file at `source` with `identity`, writing `target`. Every
  chunk is authenticated before it is written; a truncated, reordered or
  altered file fails and leaves no `target` behind.
  """
  @spec decrypt_file(Path.t(), Path.t(), identity()) :: :ok | {:error, String.t()}
  def decrypt_file(source, target, identity) do
    with {:ok, secret} <- parse_identity(identity),
         {:ok, input} <- open(source, [:read, :read_ahead]) do
      result =
        try do
          with {:ok, file_key} <- read_header(input, secret),
               <<nonce::binary-size(16)>> <- read(input, 16),
               {:ok, output} <- open(target, [:write]) do
            try do
              key = hkdf(file_key, nonce, "payload")
              stream_open(input, output, key, 0, read(input, @chunk + @tag_size))
            after
              File.close(output)
            end
          else
            {:error, _} = error -> error
            _ -> {:error, "truncated file: no payload"}
          end
        after
          File.close(input)
        end

      cleanup_on_error(result, target)
    end
  end

  defp stream_open(input, output, key, counter, current) do
    next = read(input, @chunk + @tag_size)
    last? = next == ""

    with {:ok, plain} <- unseal(key, counter, current, last?),
         :ok <- check_chunk(plain, last?, counter),
         :ok <- :file.write(output, plain) do
      if last?, do: :ok, else: stream_open(input, output, key, counter + 1, next)
    end
  end

  # An empty final chunk is only legal when it is the only chunk.
  defp check_chunk("", true, counter) when counter > 0, do: {:error, "malformed payload"}
  defp check_chunk(_plain, _last?, _counter), do: :ok

  defp cleanup_on_error(:ok, _target), do: :ok

  defp cleanup_on_error(error, target) do
    File.rm(target)

    case error do
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "file error: #{inspect(reason)}"}
      other -> {:error, "unexpected: #{inspect(other)}"}
    end
  end

  defp open(path, modes) do
    case File.open(path, [:binary, :raw | modes]) do
      {:ok, io} ->
        {:ok, io}

      {:error, reason} ->
        {:error, "cannot open #{Path.basename(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp read(io, n) do
    case :file.read(io, n) do
      {:ok, data} -> data
      :eof -> ""
    end
  end

  # -- header ----------------------------------------------------------------

  defp header([]), do: {:error, "no recipients"}

  defp header(recipients) when is_list(recipients) do
    with {:ok, keys} <- parse_all(recipients) do
      file_key = :crypto.strong_rand_bytes(16)
      stanzas = Enum.map(keys, &stanza(file_key, &1))
      head = IO.iodata_to_binary([@version_line, "\n", stanzas, "---"])
      mac = :crypto.mac(:hmac, :sha256, hkdf(file_key, "", "header"), head)
      {:ok, file_key, [head, " ", b64(mac), "\n"]}
    end
  end

  defp parse_all(recipients) do
    Enum.reduce_while(recipients, {:ok, []}, fn r, {:ok, acc} ->
      case parse_recipient(r) do
        {:ok, key} -> {:cont, {:ok, acc ++ [key]}}
        error -> {:halt, error}
      end
    end)
  end

  defp stanza(file_key, recipient) do
    {ephemeral_public, ephemeral_secret} = :crypto.generate_key(:ecdh, :x25519)
    shared = :crypto.compute_key(:ecdh, recipient, ephemeral_secret, :x25519)
    wrap_key = hkdf(shared, ephemeral_public <> recipient, @x25519_info)

    {body, tag} =
      :crypto.crypto_one_time_aead(:chacha20_poly1305, wrap_key, <<0::96>>, file_key, "", true)

    ["-> X25519 ", b64(ephemeral_public), "\n", wrap_body(b64(body <> tag))]
  end

  # Stanza bodies are wrapped at 64 columns and always end with a line
  # SHORTER than 64 - an exact multiple gets an empty line after it.
  defp wrap_body(text) do
    lines = for <<line::binary-size(64) <- text>>, do: [line, "\n"]
    rest = binary_part(text, div(byte_size(text), 64) * 64, rem(byte_size(text), 64))
    [lines, rest, "\n"]
  end

  defp read_header(input, secret) do
    with {:ok, @version_line <> "\n" = first} <- read_line(input),
         {:ok, stanzas, mac_line, raw} <- read_stanzas(input, [], first),
         {:ok, file_key} <- unwrap_any(stanzas, secret),
         :ok <- check_mac(file_key, raw, mac_line) do
      {:ok, file_key}
    else
      {:ok, _other} -> {:error, "not an age file (or an armoured one, which is not supported)"}
      {:error, _} = error -> error
    end
  end

  defp read_stanzas(input, acc, raw) do
    case read_line(input) do
      {:ok, "--- " <> mac_line} ->
        {:ok, Enum.reverse(acc), String.trim_trailing(mac_line, "\n"), raw <> "---"}

      {:ok, "-> " <> args = line} ->
        with {:ok, body, body_raw} <- read_body(input, "", "") do
          args = args |> String.trim_trailing("\n") |> String.split(" ")
          read_stanzas(input, [{args, body} | acc], raw <> line <> body_raw)
        end

      _ ->
        {:error, "malformed header"}
    end
  end

  defp read_body(input, acc, raw) do
    case read_line(input) do
      {:ok, line} ->
        text = String.trim_trailing(line, "\n")

        cond do
          byte_size(text) > 64 -> {:error, "malformed header"}
          byte_size(text) == 64 -> read_body(input, acc <> text, raw <> line)
          true -> {:ok, acc <> text, raw <> line}
        end

      error ->
        error
    end
  end

  defp read_line(input) do
    case :file.read_line(input) do
      {:ok, line} -> {:ok, line}
      _ -> {:error, "malformed header"}
    end
  end

  defp unwrap_any(stanzas, secret) do
    our_public = x25519_public(secret)

    Enum.find_value(
      stanzas,
      {:error, "no identity matched: this file was not encrypted to this key"},
      fn
        {["X25519", share], body} -> unwrap(share, body, secret, our_public)
        _ -> nil
      end
    )
  end

  defp unwrap(share, body, secret, our_public) do
    with {:ok, <<_::binary-size(32)>> = ephemeral} <- unb64(share),
         {:ok, <<wrapped::binary-size(16), tag::binary-size(16)>>} <- unb64(body),
         shared when shared != <<0::256>> <-
           :crypto.compute_key(:ecdh, ephemeral, secret, :x25519),
         wrap_key = hkdf(shared, ephemeral <> our_public, @x25519_info),
         <<file_key::binary-size(16)>> <-
           :crypto.crypto_one_time_aead(
             :chacha20_poly1305,
             wrap_key,
             <<0::96>>,
             wrapped,
             "",
             tag,
             false
           ) do
      {:ok, file_key}
    else
      _ -> nil
    end
  end

  defp check_mac(file_key, raw, mac_line) do
    expected = :crypto.mac(:hmac, :sha256, hkdf(file_key, "", "header"), raw)

    case unb64(mac_line) do
      {:ok, mac} when byte_size(mac) == 32 ->
        if :crypto.hash_equals(mac, expected),
          do: :ok,
          else: {:error, "header MAC mismatch: the file was altered"}

      _ ->
        {:error, "malformed header"}
    end
  end

  # -- primitives --------------------------------------------------------------

  defp seal(key, counter, plaintext, last?) do
    {ct, tag} =
      :crypto.crypto_one_time_aead(
        :chacha20_poly1305,
        key,
        nonce(counter, last?),
        plaintext,
        "",
        true
      )

    [ct, tag]
  end

  defp unseal(key, counter, chunk, last?) when byte_size(chunk) >= @tag_size do
    size = byte_size(chunk) - @tag_size
    <<ct::binary-size(^size), tag::binary-size(@tag_size)>> = chunk

    case :crypto.crypto_one_time_aead(
           :chacha20_poly1305,
           key,
           nonce(counter, last?),
           ct,
           "",
           tag,
           false
         ) do
      :error ->
        {:error, "payload authentication failed: wrong key, or the file was truncated or altered"}

      plain ->
        {:ok, plain}
    end
  end

  defp unseal(_key, _counter, _chunk, _last?), do: {:error, "truncated payload"}

  defp nonce(counter, last?), do: <<counter::88, if(last?, do: 1, else: 0)::8>>

  @doc false
  # RFC 5869 with SHA-256, 32 bytes out - all age ever asks for. Public for
  # the RFC test vector.
  def hkdf(ikm, salt, info) do
    salt = if salt == "", do: <<0::256>>, else: salt
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end

  defp b64(bytes), do: Base.encode64(bytes, padding: false)

  defp unb64(text) do
    case Base.decode64(text, padding: false) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, "malformed base64"}
    end
  end
end
