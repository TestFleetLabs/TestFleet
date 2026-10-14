defmodule TestFleet.Artifacts.ZipTest do
  use ExUnit.Case, async: true

  alias TestFleet.Artifacts.Zip

  @moduletag :tmp_dir

  defp entry(dir, name, content) do
    path = Path.join(dir, Base.url_encode64(name))
    File.write!(path, content)
    %{name: name, path: path, modified_at: ~U[2026-10-14 12:34:56Z]}
  end

  defp archive(entries) do
    {:ok, pieces} = Zip.reduce(entries, [], fn data, acc -> {:cont, [acc, data]} end)
    IO.iodata_to_binary(pieces)
  end

  test "writes files that unzip to their content", %{tmp_dir: dir} do
    # Larger than one read, and incompressible, so it spans several deflate calls.
    big = :crypto.strong_rand_bytes(200 * 1024)

    entries = [
      entry(dir, "report/index.html", String.duplicate("<p>passed</p>", 1000)),
      entry(dir, "big.bin", big),
      entry(dir, "empty.txt", ""),
      entry(dir, "screenshots/Anmeldung fehlgeschlagen ü.png", "png")
    ]

    {:ok, files} = :zip.unzip(archive(entries), [:memory])

    assert Map.new(files, fn {name, content} -> {:unicode.characters_to_binary(name), content} end) ==
             %{
               "report/index.html" => String.duplicate("<p>passed</p>", 1000),
               "big.bin" => big,
               "empty.txt" => "",
               "screenshots/Anmeldung fehlgeschlagen ü.png" => "png"
             }
  end

  test "keeps the modification time", %{tmp_dir: dir} do
    {:ok, [{:zip_comment, _}, {:zip_file, _, info, _, _, _}]} =
      dir |> entry("a.txt", "a") |> List.wrap() |> archive() |> :zip.list_dir()

    assert elem(info, 5) == {{2026, 10, 14}, {12, 34, 56}}
  end

  test "stops when the receiver halts", %{tmp_dir: dir} do
    entries = [entry(dir, "a.txt", "a"), entry(dir, "b.txt", "b")]

    assert {:halted, 1} = Zip.reduce(entries, 0, fn _data, count -> {:halt, count + 1} end)
  end

  test "fits? stays below the limits of an archive without ZIP64" do
    assert Zip.fits?([%{name: "a", size_bytes: 500 * 1024 * 1024}])
    refute Zip.fits?([%{name: "a", size_bytes: 4 * 1024 * 1024 * 1024}])
    refute Zip.fits?(List.duplicate(%{name: "a", size_bytes: 1}, 0xFFFF))
  end
end
