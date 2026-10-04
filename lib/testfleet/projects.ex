defmodule TestFleet.Projects do
  @moduledoc """
  Projects: one per application under test.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Accounts.Scope
  alias TestFleet.Projects.Project
  alias TestFleet.Repo

  @doc "The scope's organization's projects, ordered by name."
  def list_projects(%Scope{} = scope) do
    Project
    |> where([p], p.organization_id == ^organization_id(scope))
    |> order_by([p], asc: fragment("lower(?)", p.name))
    |> Repo.all()
  end

  @doc "Gets a project by its slug. Raises `Ecto.NoResultsError` if the organization has none."
  def get_project_by_slug!(%Scope{} = scope, slug),
    do: Repo.get_by!(Project, organization_id: organization_id(scope), slug: slug)

  @doc "Gets a project of the organization by its slug, or nil."
  def get_project_by_slug(%Scope{} = scope, slug) when is_binary(slug),
    do: Repo.get_by(Project, organization_id: organization_id(scope), slug: slug)

  @doc "Gets a project of the organization by its id. Raises `Ecto.NoResultsError` if there is none."
  def get_project!(%Scope{} = scope, id),
    do: Repo.get_by!(Project, organization_id: organization_id(scope), id: id)

  def create_project(%Scope{} = scope, attrs) do
    %Project{organization_id: organization_id(scope)}
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

  defp organization_id(%Scope{organization: %{id: id}}), do: id
end
