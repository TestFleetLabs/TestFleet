defmodule TestFleet.TestDefinitions do
  @moduledoc """
  Test definitions: the test suites of a project.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Execution.Docker.ImageRef
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

  @doc "Gets a test definition of a project by slug, or nil."
  def get_test_definition_by_slug(%Project{id: project_id}, slug) when is_binary(slug) do
    Repo.get_by(TestDefinition, project_id: project_id, slug: slug)
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

  @doc """
  Updates only the image, from CI (Milestone 11, section 6): `{:image, reference}`
  replaces the whole reference, `{:tag, tag}` only its tag. Validated like the form.
  Runs created from then on use the new image; queued and running runs keep theirs.

      {:ok, test_definition} | {:error, changeset}
  """
  def update_image(%TestDefinition{} = test_definition, {:image, image}) when is_binary(image),
    do: update_test_definition(test_definition, %{image: image})

  def update_image(%TestDefinition{} = test_definition, {:tag, tag}) when is_binary(tag) do
    case ImageRef.put_tag(test_definition.image, tag) do
      {:ok, image} ->
        update_test_definition(test_definition, %{image: image})

      {:error, :invalid_tag} ->
        {:error,
         test_definition
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.add_error(:tag, "is not a valid tag")
         |> Map.put(:action, :update)}
    end
  end

  @doc """
  Deletes a test definition with its schedules. One with runs cannot be deleted:
  `{:error, :has_runs}`.
  """
  def delete_test_definition(%TestDefinition{} = test_definition) do
    if TestFleet.Runs.has_runs?(test_definition),
      do: {:error, :has_runs},
      else: Repo.delete(test_definition)
  end

  @doc "A changeset for the form, with the form fields (minutes, MiB, lines) filled in."
  def change_test_definition(%TestDefinition{} = test_definition, attrs \\ %{}) do
    test_definition
    |> TestDefinition.put_form_fields()
    |> TestDefinition.changeset(attrs)
  end
end
