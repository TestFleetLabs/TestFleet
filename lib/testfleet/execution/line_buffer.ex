defmodule TestFleet.Execution.LineBuffer do
  @moduledoc """
  Turns log fragments into lines, with one partial-line buffer per stream.

  Docker splits long lines into several messages and may deliver output without a
  trailing newline, so a line is emitted only when its `\\n` arrives, or on `flush/1`.
  A line carries the timestamp of its first fragment. A partial line that grows past
  1 MB without a newline is emitted as is, so a suite printing progress without
  newlines cannot grow the buffer without bound.
  """

  @max_line_bytes 1_048_576

  defstruct partial: %{}

  @type stream :: :stdout | :stderr
  @type line :: %{stream: stream(), timestamp: integer() | nil, content: String.t()}
  @type t :: %__MODULE__{partial: %{optional(stream()) => {integer() | nil, binary()}}}

  def new, do: %__MODULE__{}

  @spec feed(t(), stream(), integer() | nil, binary()) :: {[line()], t()}
  def feed(%__MODULE__{partial: partial} = buffer, stream, timestamp, data) do
    {pending_timestamp, pending} = Map.get(partial, stream, {timestamp, ""})
    [rest | complete] = (pending <> data) |> :binary.split("\n", [:global]) |> Enum.reverse()

    lines =
      complete
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn
        {content, 0} -> line(stream, pending_timestamp, content)
        {content, _} -> line(stream, timestamp, content)
      end)

    rest_timestamp = if complete == [], do: pending_timestamp, else: timestamp
    {overflow, partial} = keep(partial, stream, rest_timestamp, rest)

    {lines ++ overflow, %{buffer | partial: partial}}
  end

  @doc "Emits all partial lines, oldest first."
  @spec flush(t()) :: {[line()], t()}
  def flush(%__MODULE__{partial: partial}) do
    lines =
      partial
      |> Enum.sort_by(fn {_stream, {timestamp, _}} -> timestamp || 0 end)
      |> Enum.map(fn {stream, {timestamp, content}} -> line(stream, timestamp, content) end)

    {lines, new()}
  end

  defp keep(partial, stream, _timestamp, ""), do: {[], Map.delete(partial, stream)}

  defp keep(partial, stream, timestamp, rest) when byte_size(rest) >= @max_line_bytes do
    {[line(stream, timestamp, rest)], Map.delete(partial, stream)}
  end

  defp keep(partial, stream, timestamp, rest) do
    {[], Map.put(partial, stream, {timestamp, rest})}
  end

  defp line(stream, timestamp, content) do
    content =
      if String.ends_with?(content, "\r"),
        do: binary_part(content, 0, byte_size(content) - 1),
        else: content

    %{stream: stream, timestamp: timestamp, content: String.replace_invalid(content)}
  end
end
