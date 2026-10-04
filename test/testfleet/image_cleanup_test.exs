defmodule TestFleet.ImageCleanupTest do
  # Which digests are due, from the database alone.
  use TestFleet.DataCase, async: true

  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.ImageCleanup

  @image "registry.example.com/team/e2e:latest"
  @name "registry.example.com/team/e2e"
  @now ~U[2026-09-28 12:00:00.000000Z]

  setup do
    project = project_fixture()
    %{project: project, test_definition: test_definition_fixture(project: project, image: @image)}
  end

  defp used(context, digest, days_ago, attrs \\ []) do
    run_fixture(
      [
        test_definition: context.test_definition,
        image: @image,
        image_digest: digest,
        inserted_at: DateTime.add(@now, -days_ago, :day)
      ] ++ attrs
    )
  end

  defp disable(context) do
    context.test_definition |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
  end

  test "digests unused for longer than the retention are due", context do
    used(context, "sha256:old", 10)
    used(context, "sha256:recent", 2)
    # The newest digest of an enabled test definition's image, kept regardless.
    used(context, "sha256:latest", 9)

    assert ImageCleanup.due(@now) == ["#{@name}@sha256:old"]
  end

  test "a digest counts as used by its newest run", context do
    used(context, "sha256:reused", 30)
    used(context, "sha256:reused", 1)

    assert ImageCleanup.due(@now) == []
  end

  test "the latest digest of an image no enabled test definition uses is due too", context do
    used(context, "sha256:old", 10)
    used(context, "sha256:latest", 9)
    disable(context)

    assert Enum.sort(ImageCleanup.due(@now)) ==
             ["#{@name}@sha256:latest", "#{@name}@sha256:old"]
  end

  test "runs without a digest are no candidates", context do
    used(context, nil, 30)
    disable(context)

    assert ImageCleanup.due(@now) == []
  end

  test "Docker Hub images use Docker's short name", context do
    # No test definition uses alpine:3.
    used(context, "sha256:alpine", 30, image: "alpine:3")

    assert ImageCleanup.due(@now) == ["alpine@sha256:alpine"]
  end

  test "the retention is configurable, down to zero days", context do
    used(context, "sha256:today", 0)
    disable(context)

    previous = Application.get_env(:testfleet, TestFleet.Execution)
    on_exit(fn -> Application.put_env(:testfleet, TestFleet.Execution, previous) end)

    Application.put_env(
      :testfleet,
      TestFleet.Execution,
      Keyword.put(previous, :image_retention_days, 0)
    )

    assert ImageCleanup.due(DateTime.add(@now, 1, :second)) == ["#{@name}@sha256:today"]
  end
end
