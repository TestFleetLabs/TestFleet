defmodule TestFleet.Execution.Docker.LogDecoder do
  @moduledoc """
  Demultiplexes Docker's log stream for containers created with `Tty: false`.

  Every frame has an 8-byte header: the stream type (1 = stdout, 2 = stderr), three
  zero bytes, and the payload length as a big-endian uint32. HTTP chunks do not align
  with frames, so the decoder keeps unconsumed bytes until a frame is complete.

  With `timestamps=1`, every payload starts with an RFC 3339 timestamp and a space.
  Timestamps are kept as integer nanoseconds since the epoch: resuming a log stream
  without duplicates needs more precision than `DateTime`'s microseconds.
  """

  @timestamp ~r/\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})\z/

  defstruct buffer: ""

  @type t :: %__MODULE__{buffer: binary()}
  @type frame :: {:stdout | :stderr, binary()}

  def new, do: %__MODULE__{}

  @spec feed(t(), binary()) :: {[frame()], t()}
  def feed(%__MODULE__{buffer: buffer} = decoder, chunk) do
    {frames, rest} = decode(buffer <> chunk, [])
    {frames, %{decoder | buffer: rest}}
  end

  defp decode(<<type, 0, 0, 0, size::32, payload::binary-size(size), rest::binary>>, frames) do
    decode(rest, [{stream(type), payload} | frames])
  end

  defp decode(rest, frames), do: {Enum.reverse(frames), rest}

  # 0 is stdin, which Docker writes to stdout; 3 is Docker's own "systemerr" stream.
  defp stream(type) when type in [0, 1], do: :stdout
  defp stream(_type), do: :stderr

  @doc "Splits the timestamp prefix off a payload. Returns `{nil, payload}` without one."
  @spec split_timestamp(binary()) :: {integer() | nil, binary()}
  def split_timestamp(payload) do
    with [stamp, content] <- :binary.split(payload, " "),
         {:ok, nanoseconds} <- parse_timestamp(stamp) do
      {nanoseconds, content}
    else
      _ -> {nil, payload}
    end
  end

  @spec parse_timestamp(binary()) :: {:ok, integer()} | :error
  def parse_timestamp(stamp) do
    with [_, seconds, fraction, zone] <- Regex.run(@timestamp, stamp),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(seconds <> zone) do
      fraction = fraction |> String.pad_trailing(9, "0") |> String.to_integer()
      {:ok, DateTime.to_unix(datetime) * 1_000_000_000 + fraction}
    else
      _ -> :error
    end
  end

  @doc "Formats nanoseconds as the `since` parameter of the logs endpoint."
  @spec format_since(integer()) :: String.t()
  def format_since(nanoseconds) do
    seconds = div(nanoseconds, 1_000_000_000)

    fraction =
      nanoseconds |> rem(1_000_000_000) |> Integer.to_string() |> String.pad_leading(9, "0")

    "#{seconds}.#{fraction}"
  end
end
