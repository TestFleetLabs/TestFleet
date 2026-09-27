defmodule TestFleet.TestDefinitions do
  @moduledoc """
  Test definitions: the test suites of a project.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Projects.Project
  alias TestFleet.Repo
  alias TestFleet.TestDefinitions.TestDefinition

  @doc "Returns a project's test definitions ordered by name."
  def list_test_definitions(%Project{id: project_id}) do
    Repo.all(
      from t in TestDefinition,
        where: t.project_id == ^project_id,
        order_by: [asc: fragment("lower(?)", t.name)]
    )
  end

  def get_test_definition!(%Project{id: project_id}, id) do
    Repo.get_by!(TestDefinition, project_id: project_id, id: id)
  end

  def create_test_definition(%Project{} = project, attrs) do
    %TestDefinition{project_id: project.id}
    |> TestDefinition.changeset(attrs)
    |> Repo.insert()
  end

  def update_test_definition(%TestDefinition{} = test_definition, attrs) do
    test_definition
    |> TestDefinition.changeset(attrs)
    |> Repo.update()
  end

  def delete_test_definition(%TestDefinition{} = test_definition),
    do: Repo.delete(test_definition)

  @doc "A changeset for the form, with the form fields (minutes, MiB, lines) filled in."
  def change_test_definition(%TestDefinition{} = test_definition, attrs \\ %{}) do
    test_definition
    |> TestDefinition.put_form_fields()
    |> TestDefinition.changeset(attrs)
  end
end
