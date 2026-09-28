defmodule TestFleet.Artifacts.OrphansTest do
  # Milestone 7, section 8. Each test has its own root, so the files of other
  # tests' runs are never in sight.
  use TestFleet.DataCase, async: true

  import TestFleet.RunsFixtures

  alias TestFleet.Artifacts.Orphans

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp dir!(root, name) do
    File.mkdir_p!(Path.join([root, name, "screenshots"]))
    File.write!(Path.join([root, name, "screenshots", "a.png"]), "png")
  end

  defp file!(root, name), do: File.write!(Path.join(root, name), "tar")

  defp names(root), do: root |> File.ls!() |> Enum.sort()

  # An id no run has: larger than any run in this sandbox.
  defp unknown_id, do: run_fixture().id + 1_000_000

  test "deletes the directories of runs this database does not have", %{tmp_dir: root} do
    run = run_fixture(status: :passed)
    unknown = unknown_id()
    dir!(root, "#{run.id}")
    dir!(root, "#{unknown}")

    assert Orphans.run(root) == ["#{unknown}"]
    assert names(root) == ["#{run.id}"]
  end

  test "deletes leftovers of an interrupted collection, unless the run is active",
       %{tmp_dir: root} do
    finished = run_fixture(status: :failed)
    running = run_fixture(status: :running)
    queued = run_fixture()
    unknown = unknown_id()

    for id <- [finished.id, running.id, queued.id, unknown] do
      file!(root, "#{id}.tar")
      dir!(root, "#{id}.extract")
    end

    assert root |> Orphans.run() |> Enum.sort() ==
             Enum.sort(
               ~w(#{finished.id}.tar #{finished.id}.extract #{unknown}.tar #{unknown}.extract)
             )

    assert names(root) ==
             Enum.sort(
               ~w(#{running.id}.tar #{running.id}.extract #{queued.id}.tar #{queued.id}.extract)
             )
  end

  test "leaves the directory of an active run alone", %{tmp_dir: root} do
    run = run_fixture(status: :running)
    dir!(root, "#{run.id}")

    assert Orphans.run(root) == []
  end

  test "leaves names that are not run ids alone", %{tmp_dir: root} do
    dir!(root, "notes")
    file!(root, "12ab.tar")
    file!(root, "README")
    dir!(root, String.duplicate("9", 25))

    assert Orphans.run(root) == []
    assert length(names(root)) == 4
  end

  test "a missing root is nothing to do", %{tmp_dir: root} do
    assert Orphans.run(Path.join(root, "missing")) == []
  end
end
