defmodule TestFleet.RunsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `TestFleet.Runs` context.
  """

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Repo

  @doc """
  Creates a manual run. Pass `:project`, `:test_definition`, and `:environment` to
  reuse them; missing ones are created in the same project. Other attributes, such
  as `:status`, are written directly, bypassing the status transitions.
  """
  def run_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)

    {project, attrs} =
      Map.pop_lazy(attrs, :project, fn ->
        case attrs do
          %{test_definition: %{project_id: id}} -> Repo.get!(TestFleet.Projects.Project, id)
          _ -> project_fixture()
        end
      end)

    {test_definition, attrs} =
      Map.pop_lazy(attrs, :test_definition, fn -> test_definition_fixture(project: project) end)

    {environment, attrs} =
      Map.pop_lazy(attrs, :environment, fn -> environment_fixture(project: project) end)

    {:ok, run} = TestFleet.Runs.create_run(test_definition, environment)

    if attrs == %{} do
      run
    else
      run |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end
  end

  @doc """
  Creates a run and finishes it as `RunExecution` would, with JUnit results.

  `:tests` lists `{name, status}` tuples or maps for `test_case/1`. `:status`
  defaults to `failed` when a test is red, else `passed`; `:image_digest` to
  `"sha256:aaa"`. Other attributes as for `run_fixture/1`.
  """
  def finished_run_fixture(attrs) do
    attrs = Map.new(attrs)
    {tests, attrs} = Map.pop(attrs, :tests, [])
    {image_digest, attrs} = Map.pop(attrs, :image_digest, "sha256:aaa")
    test_results = Enum.map(tests, &test_case/1)

    {status, attrs} =
      Map.pop_lazy(attrs, :status, fn ->
        if Enum.any?(test_results, &(&1.status in [:failed, :error])), do: :failed, else: :passed
      end)

    run = run_fixture(Map.put(attrs, :status, :running))

    {:ok, run} =
      TestFleet.Runs.finish(run.id, %TestFleet.Execution.Result{
        run_id: run.id,
        status: status,
        exit_code: if(status == :passed, do: 0, else: 1),
        finished_at: DateTime.utc_now(),
        image_digest: image_digest,
        test_results: test_results
      })

    run
  end

  @doc """
  A parsed JUnit test case, as `Runs.finish/2` takes it: suite `checkout` and
  classname `Cart` unless given; a red one has a failure message.
  """
  def test_case({name, status}), do: test_case(%{name: name, status: status})

  def test_case(%{status: status} = fields) do
    Map.merge(
      %{
        suite: "checkout",
        classname: "Cart",
        duration_ms: 1_000,
        failure_message: if(status in [:failed, :error], do: "expected 200, got 500"),
        failure_details: nil,
        file: "junit.xml"
      },
      fields
    )
  end
end
