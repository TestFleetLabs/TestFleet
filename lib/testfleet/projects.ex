defmodule TestFleet.Projects do
  @moduledoc """
  Projects: one per application under test.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Projects.Project
  alias TestFleet.Repo

  @doc "Returns all projects, ordered by name."
  def list_projects do
    Project
    |> order_by([p], asc: fragment("lower(?)", p.name))
    |> Repo.all()
  end

  def get_project!(id), do: Repo.get!(Project, id)

  @doc "Gets a project by its slug. Raises `Ecto.NoResultsError` if there is none."
  def get_project_by_slug!(slug), do: Repo.get_by!(Project, slug: slug)

  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a project together with its test definitions, environments, variables,
  and schedules. A project with runs cannot be deleted: `{:error, :has_runs}`.
  """
  def delete_project(%Project{} = project) do
    if TestFleet.Runs.has_runs?(project),
      do: {:error, :has_runs},
      else: Repo.delete(project)
  end

  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, attrs)
  end
end
