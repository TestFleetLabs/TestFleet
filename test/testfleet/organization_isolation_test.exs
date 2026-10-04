defmodule TestFleet.OrganizationIsolationTest do
  # One organization never sees another's data, in the contexts.
  use TestFleet.DataCase, async: true

  import TestFleet.EnvironmentsFixtures
  import TestFleet.NotificationsFixtures
  import TestFleet.OrganizationsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RegistriesFixtures
  import TestFleet.RunsFixtures

  alias TestFleet.{Artifacts, Notifications, Projects, Registries, Runs}

  setup do
    other = organization_fixture()
    %{other: other, theirs: org_scope(other)}
  end

  test "projects", %{other: other, theirs: theirs} do
    ours = project_fixture(name: "Shop", slug: "shop")
    _same_slug = project_fixture(name: "Shop", slug: "shop", organization: other)

    assert [%{id: id}] = Projects.list_projects(org_scope())
    assert id == ours.id
    assert Projects.get_project_by_slug!(org_scope(), "shop").id == ours.id
    refute Projects.get_project_by_slug(theirs, "shop").id == ours.id
    assert_raise Ecto.NoResultsError, fn -> Projects.get_project!(theirs, ours.id) end
  end

  test "runs, their figures, and their topic", %{other: other, theirs: theirs} do
    Runs.subscribe(theirs)
    run = run_fixture()

    assert [_] = Runs.list_runs(org_scope())
    assert Runs.list_runs(theirs) == []
    assert Runs.get_run(theirs, run.id) == nil
    assert_raise Ecto.NoResultsError, fn -> Runs.get_run!(theirs, run.id) end
    assert %{queued: 1} = Runs.dashboard_stats(org_scope(), "Etc/UTC")
    assert %{queued: 0} = Runs.dashboard_stats(theirs, "Etc/UTC")
    refute_receive {:run_created, _}

    their_run = run_fixture(project: project_fixture(organization: other))
    assert their_run.organization_id == other.id
    assert_receive {:run_created, %{id: id}}
    assert id == their_run.id
  end

  test "artifacts are found through their run only", %{theirs: theirs} do
    run = run_fixture()
    Artifacts.insert_all(run, [%{path: "report.html", size_bytes: 3}])

    assert Artifacts.get_artifact(run, "report.html")
    refute Runs.get_run(theirs, run.id)
  end

  test "registries, and the credentials a run pulls with", %{other: other, theirs: theirs} do
    ours = registry_fixture(host: "registry.example.com")
    theirs_registry = registry_fixture(host: "registry.example.com", organization: other)

    assert [%{id: id}] = Registries.list_registries(org_scope())
    assert id == ours.id

    assert Registries.get_registry_for_image(org_scope(), "registry.example.com/e2e:1").id ==
             ours.id

    assert Registries.get_registry_for_image(theirs, "registry.example.com/e2e:1").id ==
             theirs_registry.id

    run =
      run_fixture()
      |> Ecto.Changeset.change(image: "registry.example.com/e2e:1")
      |> Repo.update!()

    assert Runs.build_request(run).registry_auth.password == ours.password
    assert Runs.build_request(run).organization_id == run.organization_id
  end

  test "channels only receive their organization's run events", %{other: other, theirs: theirs} do
    ours = channel_fixture()
    their_channel = channel_fixture(organization: other)

    for channel <- [ours, their_channel],
        do: {:ok, _} = Notifications.create_subscription(channel, %{events: ["run.failing"]})

    run = run_fixture()

    assert [%{id: id}] = Notifications.channels_for("run.failing", run)
    assert id == ours.id
    assert [%{id: ^id}] = Notifications.list_channels(org_scope())
    assert_raise Ecto.NoResultsError, fn -> Notifications.get_channel!(theirs, ours.id) end
  end

  test "a subscription cannot name another organization's project", %{other: other} do
    channel = channel_fixture()
    their_project = project_fixture(organization: other)

    assert {:error, changeset} =
             Notifications.create_subscription(channel, %{
               project_id: their_project.id,
               events: ["run.failing"]
             })

    assert %{project_id: ["does not exist"]} = errors_on(changeset)

    environment = environment_fixture(project: their_project)

    assert {:error, _} =
             Notifications.create_subscription(channel, %{
               project_id: their_project.id,
               environment_id: environment.id,
               events: ["run.failing"]
             })
  end
end
