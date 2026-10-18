defmodule OpenResults.FideList.SourceTest do
  use ExUnit.Case, async: true

  alias OpenResults.FideList.Source

  @stored %{
    "etag" => ~s("abc"),
    "last_modified" => "Sat, 01 Nov 2026 06:00:00 GMT",
    "content_length" => "41000000"
  }

  defp remote(fields),
    do: Map.merge(%{etag: nil, last_modified: nil, content_length: nil}, fields)

  describe "changed?/2" do
    test "nothing imported yet is always new" do
      assert Source.changed?(remote(%{etag: ~s("abc")}), nil)
    end

    test "an ETag decides when both sides have one" do
      refute Source.changed?(remote(%{etag: ~s("abc")}), @stored)
      assert Source.changed?(remote(%{etag: ~s("def")}), @stored)

      # Even against a Last-Modified that moved: the ETag is the stronger
      # validator, and a server that touches the file without changing it
      # should not cost a download.
      refute Source.changed?(
               remote(%{etag: ~s("abc"), last_modified: "Sun, 02 Nov 2026 06:00:00 GMT"}),
               @stored
             )
    end

    test "otherwise the date, and the length where both have one" do
      stored = Map.delete(@stored, "etag")

      refute Source.changed?(
               remote(%{last_modified: @stored["last_modified"], content_length: "41000000"}),
               stored
             )

      refute Source.changed?(remote(%{last_modified: @stored["last_modified"]}), stored)

      assert Source.changed?(
               remote(%{last_modified: "Mon, 01 Dec 2026 06:00:00 GMT"}),
               stored
             )

      assert Source.changed?(
               remote(%{last_modified: @stored["last_modified"], content_length: "42"}),
               stored
             )
    end

    test "a server that dates nothing is downloaded" do
      assert Source.changed?(remote(%{}), @stored)
    end
  end

  test "the address is FIDE's unless one is configured" do
    assert Source.url() == "https://ratings.fide.com/download/players_list.zip"
  end
end
