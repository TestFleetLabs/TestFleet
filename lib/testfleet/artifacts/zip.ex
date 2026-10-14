defmodule TestFleet.Artifacts.Zip do
  @moduledoc """
  Writes files as one ZIP archive, piece by piece, so a run's artifacts are never
  held in memory or copied to a temporary file before the download starts.

  Each entry is deflated while it is read; its CRC and sizes follow the data in a
  data descriptor (general purpose bit 3), so nothing is read twice. Names are
  UTF-8 (bit 11). There is no ZIP64: `fits?/1` tells whether entries stay within
  the 4 GiB and 65,535 entry limits of a plain archive.
  """
  import Bitwise

  @chunk_size 64 * 1024
  # Data descriptor and UTF-8 names.
  @flags 0x0808
  @deflate 8
  @version 20
  # Made by Unix, so `@external_attrs` are read as file permissions (0644).
  @version_made_by 0x0314
  @external_attrs 0o100644 <<< 16
  @max_entries 0xFFFF
  @max_offset 0xFFFFFFFF

  @doc """
  Whether entries (`%{name, size_bytes}`) fit into an archive without ZIP64,
  counting headers and deflate's worst case for data that does not compress.
  """
  def fits?(entries) do
    bytes =
      Enum.sum_by(entries, fn %{name: name, size_bytes: size} ->
        size + div(size, 1000) + 128 + 2 * byte_size(name)
      end)

    length(entries) < @max_entries and bytes < @max_offset
  end

  @doc """
  Writes entries (`%{name, path, modified_at}`) as an archive, handing every piece
  of iodata to `fun`, which returns `{:cont, acc}`, or `{:halt, acc}` to stop (the
  client went away). Returns `{:ok, acc}` or `{:halted, acc}`.
  """
  def reduce(entries, acc, fun) do
    emit = fn data, acc ->
      case fun.(data, acc) do
        {:cont, acc} -> acc
        {:halt, acc} -> throw({__MODULE__, :halt, acc})
      end
    end

    {acc, offset, central} =
      Enum.reduce(entries, {acc, 0, []}, fn entry, {acc, offset, central} ->
        {acc, written, record} = write_entry(entry, offset, acc, emit)
        {acc, offset + written, [record | central]}
      end)

    central = Enum.reverse(central)
    size = IO.iodata_length(central)
    count = length(central)

    end_record =
      <<0x06054B50::little-32, 0::little-16, 0::little-16, count::little-16, count::little-16,
        size::little-32, offset::little-32, 0::little-16>>

    {:ok, emit.([central, end_record], acc)}
  catch
    {__MODULE__, :halt, acc} -> {:halted, acc}
  end

  defp write_entry(%{name: name, path: path, modified_at: modified_at}, offset, acc, emit) do
    {time, date} = dos_date_time(modified_at)

    header =
      <<0x04034B50::little-32, @version::little-16, @flags::little-16, @deflate::little-16,
        time::little-16, date::little-16, 0::little-32, 0::little-32, 0::little-32,
        byte_size(name)::little-16, 0::little-16, name::binary>>

    acc = emit.(header, acc)
    {acc, crc, size, compressed} = deflate_file(path, acc, emit)

    descriptor =
      <<0x08074B50::little-32, crc::little-32, compressed::little-32, size::little-32>>

    acc = emit.(descriptor, acc)

    record =
      <<0x02014B50::little-32, @version_made_by::little-16, @version::little-16,
        @flags::little-16, @deflate::little-16, time::little-16, date::little-16, crc::little-32,
        compressed::little-32, size::little-32, byte_size(name)::little-16, 0::little-16,
        0::little-16, 0::little-16, 0::little-16, @external_attrs::little-32, offset::little-32,
        name::binary>>

    {acc, byte_size(header) + compressed + byte_size(descriptor), record}
  end

  defp deflate_file(path, acc, emit) do
    z = :zlib.open()

    try do
      # Raw deflate (negative window bits): ZIP has its own headers.
      :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)

      {acc, crc, size, compressed} =
        path
        |> File.stream!(@chunk_size)
        |> Enum.reduce({acc, 0, 0, 0}, fn chunk, {acc, crc, size, compressed} ->
          data = :zlib.deflate(z, chunk)

          {emit_data(data, acc, emit), :erlang.crc32(crc, chunk), size + byte_size(chunk),
           compressed + IO.iodata_length(data)}
        end)

      data = :zlib.deflate(z, [], :finish)
      {emit_data(data, acc, emit), crc, size, compressed + IO.iodata_length(data)}
    after
      :zlib.close(z)
    end
  end

  defp emit_data(data, acc, emit) do
    if IO.iodata_length(data) > 0, do: emit.(data, acc), else: acc
  end

  # MS-DOS date and time, two-second precision, from 1980.
  defp dos_date_time(%DateTime{year: year}) when year < 1980, do: {0, 1 <<< 5 ||| 1}

  defp dos_date_time(%DateTime{} = at) do
    {at.hour <<< 11 ||| at.minute <<< 5 ||| div(at.second, 2),
     (at.year - 1980) <<< 9 ||| at.month <<< 5 ||| at.day}
  end
end
