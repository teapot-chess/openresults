defmodule OpenResults.Ops.AgeTest do
  use ExUnit.Case, async: true

  alias OpenResults.Ops.{Age, Bech32}

  describe "bech32" do
    test "accepts the BIP 173 valid vectors" do
      for valid <- [
            "A12UEL5L",
            "a12uel5l",
            "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw",
            "split1checkupstagehandshakeupstreamerranterredcaperred2y9e3w"
          ] do
        assert {:ok, _} = Bech32.decode(valid), valid
      end
    end

    test "refuses a bad checksum and mixed case" do
      assert {:error, :invalid} = Bech32.decode("a12uel5m")
      assert {:error, :invalid} = Bech32.decode("A12uEL5L")
    end

    test "round-trips 32 bytes" do
      bytes = :crypto.strong_rand_bytes(32)
      assert {:ok, {"age", ^bytes}} = "age" |> Bech32.encode(bytes) |> Bech32.decode()
    end
  end

  test "HKDF-SHA-256 matches RFC 5869 test case 1 (first 32 bytes)" do
    ikm = :binary.copy(<<0x0B>>, 22)
    salt = Base.decode16!("000102030405060708090A0B0C")
    info = Base.decode16!("F0F1F2F3F4F5F6F7F8F9")

    assert Base.encode16(Age.hkdf(ikm, salt, info), case: :lower) ==
             "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
  end

  test "keys are spelled the way age spells them" do
    {secret, public} = Age.generate_identity()
    assert "AGE-SECRET-KEY-1" <> _ = secret
    assert "age1" <> _ = public
    assert {:ok, ^public} = Age.public_key(secret)

    assert {:ok, ^public} =
             Age.public_key("# created: today\n# public key: #{public}\n#{secret}\n")

    assert {:ok, <<_::binary-size(32)>>} = Age.parse_recipient(public)
    assert {:error, _} = Age.parse_recipient(secret)
  end

  describe "encrypt/decrypt" do
    setup do
      {secret, public} = Age.generate_identity()
      %{secret: secret, public: public}
    end

    test "round-trips sizes either side of the chunk boundary", %{secret: s, public: p} do
      for size <- [0, 1, 65_535, 65_536, 65_537, 131_072, 200_000] do
        plain = :crypto.strong_rand_bytes(size)
        assert {:ok, cipher} = Age.encrypt(plain, [p])
        assert "age-encryption.org/v1\n-> X25519 " <> _ = cipher
        assert {:ok, ^plain} = Age.decrypt(cipher, s), "size #{size}"
      end
    end

    test "any of several recipients can open it", %{secret: s, public: p} do
      {s2, p2} = Age.generate_identity()
      {:ok, cipher} = Age.encrypt("two keys", [p, p2])
      assert {:ok, "two keys"} = Age.decrypt(cipher, s)
      assert {:ok, "two keys"} = Age.decrypt(cipher, s2)
    end

    test "the wrong key is refused", %{public: p} do
      {other, _} = Age.generate_identity()
      {:ok, cipher} = Age.encrypt("secret", [p])
      assert {:error, "no identity matched" <> _} = Age.decrypt(cipher, other)
    end

    test "a flipped payload byte, a truncation and a header edit all fail", %{
      secret: s,
      public: p
    } do
      {:ok, cipher} = Age.encrypt(:crypto.strong_rand_bytes(70_000), [p])
      size = byte_size(cipher)

      cut = size - 10
      <<head::binary-size(^cut), b, tail::binary>> = cipher
      assert {:error, _} = Age.decrypt(head <> <<Bitwise.bxor(b, 1)>> <> tail, s)
      assert {:error, _} = Age.decrypt(binary_part(cipher, 0, size - 100), s)
      # Truncated exactly at the chunk boundary: the first chunk is not
      # flagged last, so it must not be accepted as a whole file.
      {mac_at, _} = :binary.match(cipher, "\n--- ")
      {nl, _} = :binary.match(cipher, "\n", scope: {mac_at + 1, size - mac_at - 1})
      header_size = nl + 1
      assert {:error, _} = Age.decrypt(binary_part(cipher, 0, header_size + 16 + 65_536 + 16), s)

      tampered = String.replace(cipher, "-> X25519 ", "-> X25519  ", global: false)
      assert {:error, _} = Age.decrypt(tampered, s)
    end

    test "file to file, and a failure leaves no output", %{secret: s, public: p} do
      dir = Path.join(System.tmp_dir!(), "agetest-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      src = Path.join(dir, "plain")
      enc = Path.join(dir, "plain.age")
      out = Path.join(dir, "back")
      File.write!(src, :crypto.strong_rand_bytes(300_000))

      assert :ok = Age.encrypt_file(src, enc, [p])
      assert :ok = Age.decrypt_file(enc, out, s)
      assert File.read!(src) == File.read!(out)

      {wrong, _} = Age.generate_identity()
      File.rm!(out)
      assert {:error, _} = Age.decrypt_file(enc, out, wrong)
      refute File.exists?(out)

      assert {:error, "no recipients"} = Age.encrypt_file(src, enc, [])
      assert {:error, _} = Age.encrypt_file(src, enc, ["age1nope"])
    end
  end
end
