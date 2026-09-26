defmodule TestFleet.Execution.LineBufferTest do
  use ExUnit.Case, async: true

  alias TestFleet.Execution.LineBuffer

  test "emits complete lines" do
    assert {[
              %{stream: :stdout, timestamp: 1, content: "one"},
              %{stream: :stdout, timestamp: 1, content: "two"}
            ], buffer} = LineBuffer.feed(LineBuffer.new(), :stdout, 1, "one\ntwo\n")

    assert buffer == LineBuffer.new()
  end

  test "joins partial lines across feeds and keeps the first fragment's timestamp" do
    {[], buffer} = LineBuffer.feed(LineBuffer.new(), :stdout, 1, "Running te")
    {[], buffer} = LineBuffer.feed(buffer, :stdout, 2, "st ")

    assert {[
              %{timestamp: 1, content: "Running test 1..."},
              %{timestamp: 3, content: "next"}
            ], buffer} = LineBuffer.feed(buffer, :stdout, 3, "1...\nnext\npar")

    assert {[%{timestamp: 3, content: "par"}], _} = LineBuffer.flush(buffer)
  end

  test "keeps separate partial lines per stream" do
    {[], buffer} = LineBuffer.feed(LineBuffer.new(), :stdout, 1, "out-")
    {[], buffer} = LineBuffer.feed(buffer, :stderr, 2, "err-")

    {[%{stream: :stderr, content: "err-end"}], buffer} =
      LineBuffer.feed(buffer, :stderr, 3, "end\n")

    {[%{stream: :stdout, content: "out-end"}], _} = LineBuffer.feed(buffer, :stdout, 4, "end\n")
  end

  test "strips a trailing carriage return" do
    assert {[%{content: "windows"}], _} =
             LineBuffer.feed(LineBuffer.new(), :stdout, 1, "windows\r\n")
  end

  test "keeps empty lines" do
    assert {[%{content: ""}, %{content: ""}], _} =
             LineBuffer.feed(LineBuffer.new(), :stdout, 1, "\n\n")
  end

  test "flush emits partial lines oldest first and resets the buffer" do
    {[], buffer} = LineBuffer.feed(LineBuffer.new(), :stderr, 5, "later")
    {[], buffer} = LineBuffer.feed(buffer, :stdout, 2, "earlier")

    assert {[%{content: "earlier"}, %{content: "later"}], buffer} = LineBuffer.flush(buffer)
    assert {[], _} = LineBuffer.flush(buffer)
  end

  test "replaces invalid UTF-8" do
    assert {[%{content: "bad � byte"}], _} =
             LineBuffer.feed(LineBuffer.new(), :stdout, 1, <<"bad ", 0xFF, " byte\n">>)
  end

  test "emits a partial line that grows past 1 MB" do
    chunk = String.duplicate("x", 600_000)
    {[], buffer} = LineBuffer.feed(LineBuffer.new(), :stdout, 1, chunk)
    {[line], buffer} = LineBuffer.feed(buffer, :stdout, 2, chunk)

    assert byte_size(line.content) == 1_200_000
    assert line.timestamp == 1
    assert buffer == LineBuffer.new()
  end
end
