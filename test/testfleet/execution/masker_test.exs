defmodule TestFleet.Execution.MaskerTest do
  use ExUnit.Case, async: true

  alias TestFleet.Execution.Masker

  defp mask(secrets, content), do: secrets |> Masker.new() |> Masker.mask(content)

  test "masks every occurrence of every secret" do
    assert mask(["s3cret-token", "hunter22"], "token=s3cret-token pw=hunter22 again s3cret-token") ==
             "token=[MASKED] pw=[MASKED] again [MASKED]"
  end

  test "a secret that contains another is masked completely" do
    assert mask(["abcdef", "abcdefghij"], "x abcdefghij y abcdef") == "x [MASKED] y [MASKED]"
  end

  test "a multi-line secret is masked line by line" do
    key = "-----BEGIN KEY-----\nMIIEvQIBADANBg\r\nab\n-----END KEY-----"

    assert mask([key], "-----BEGIN KEY-----") == "[MASKED]"
    assert mask([key], "MIIEvQIBADANBg") == "[MASKED]"
    # Too short to mask without masking ordinary output.
    assert mask([key], "ab") == "ab"
  end

  test "without secrets, lines stay as they are" do
    assert mask([], "nothing to hide") == "nothing to hide"
    assert mask(["short"], "short") == "short"
  end

  test "works on any UTF-8 content" do
    assert mask(["pässwörd-ü"], "→ pässwörd-ü ←") == "→ [MASKED] ←"
  end
end
