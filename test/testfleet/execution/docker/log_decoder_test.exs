defmodule TestFleet.Execution.Docker.LogDecoderTest do
  use ExUnit.Case, async: true

  alias TestFleet.Execution.Docker.LogDecoder

  defp frame(type, payload), do: <<type, 0, 0, 0, byte_size(payload)::32, payload::binary>>

  describe "feed/2" do
    test "decodes a single frame" do
      assert {[{:stdout, "hello\n"}], %LogDecoder{buffer: ""}} =
               LogDecoder.feed(LogDecoder.new(), frame(1, "hello\n"))
    end

    test "decodes several frames in one chunk" do
      chunk = frame(1, "out\n") <> frame(2, "err\n") <> frame(1, "more\n")

      assert {[{:stdout, "out\n"}, {:stderr, "err\n"}, {:stdout, "more\n"}], _} =
               LogDecoder.feed(LogDecoder.new(), chunk)
    end

    test "reassembles frames split at every byte offset" do
      stream = frame(1, "first line\n") <> frame(2, "second\n") <> frame(1, "")

      for offset <- 0..byte_size(stream) do
        <<a::binary-size(^offset), b::binary>> = stream
        {frames_a, decoder} = LogDecoder.feed(LogDecoder.new(), a)
        {frames_b, decoder} = LogDecoder.feed(decoder, b)

        assert frames_a ++ frames_b == [
                 {:stdout, "first line\n"},
                 {:stderr, "second\n"},
                 {:stdout, ""}
               ],
               "split at offset #{offset}"

        assert decoder.buffer == ""
      end
    end

    test "maps stdin to stdout and Docker's system error stream to stderr" do
      assert {[{:stdout, "a"}, {:stderr, "b"}], _} =
               LogDecoder.feed(LogDecoder.new(), frame(0, "a") <> frame(3, "b"))
    end
  end

  describe "split_timestamp/1" do
    test "splits a nanosecond timestamp from the content" do
      assert {1_790_417_703_123_456_789, "Running test 1..."} =
               LogDecoder.split_timestamp("2026-09-26T10:15:03.123456789Z Running test 1...")
    end

    test "pads short fractions and accepts missing ones" do
      assert {1_790_417_703_120_000_000, "x"} =
               LogDecoder.split_timestamp("2026-09-26T10:15:03.12Z x")

      assert {1_790_417_703_000_000_000, "x"} =
               LogDecoder.split_timestamp("2026-09-26T10:15:03Z x")
    end

    test "applies offsets" do
      assert {1_790_417_703_000_000_000, "x"} =
               LogDecoder.split_timestamp("2026-09-26T12:15:03+02:00 x")
    end

    test "keeps content with spaces and an empty content" do
      assert {_, "a b  c"} = LogDecoder.split_timestamp("2026-09-26T10:15:03Z a b  c")
      assert {_, ""} = LogDecoder.split_timestamp("2026-09-26T10:15:03Z ")
    end

    test "returns the payload unchanged without a timestamp" do
      assert {nil, "no timestamp here"} = LogDecoder.split_timestamp("no timestamp here")
      assert {nil, "noSpace"} = LogDecoder.split_timestamp("noSpace")
    end
  end

  test "format_since/1 round-trips through parse_timestamp/1" do
    {:ok, ns} = LogDecoder.parse_timestamp("2026-09-26T10:15:03.000000042Z")
    assert LogDecoder.format_since(ns) == "1790417703.000000042"
  end
end
