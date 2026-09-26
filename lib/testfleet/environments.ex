defmodule TestFleet.Environments do
  @moduledoc """
  Environments of a project and their variables.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Environments.{Environment, Variable}
  alias TestFleet.Projects.Project
  alias TestFleet.Repo

  ## Environments

  @doc "Returns a project's environments ordered by name, with `variable_count` set."
  def list_environments(%Project{id: project_id}) do
    counts =
      from v in Variable,
        group_by: v.environment_id,
        select: %{environment_id: v.environment_id, count: count(v.id)}

    from(e in Environment,
      where: e.project_id == ^project_id,
      left_join: c in subquery(counts),
      on: c.environment_id == e.id,
      order_by: [asc: fragment("lower(?)", e.name)],
      select_merge: %{variable_count: coalesce(c.count, 0)}
    )
    |> Repo.all()
  end

  @doc "Gets an environment of a project by slug, with its variables ordered by key."
  def get_environment!(%Project{id: project_id}, slug) do
    Environment
    |> Repo.get_by!(project_id: project_id, slug: slug)
    |> Repo.preload(:variables)
  end

  def create_environment(%Project{} = project, attrs) do
    %Environment{project_id: project.id}
    |> Environment.changeset(attrs)
    |> Repo.insert()
  end

  def update_environment(%Environment{} = environment, attrs) do
    environment
    |> Environment.changeset(attrs)
    |> Repo.update()
  end

  @doc "Deletes an environment with its variables."
  def delete_environment(%Environment{} = environment), do: Repo.delete(environment)

  def change_environment(%Environment{} = environment, attrs \\ %{}) do
    Environment.changeset(environment, attrs)
  end

  ## Variables

  def get_variable!(%Environment{id: environment_id}, id) do
    Repo.get_by!(Variable, environment_id: environment_id, id: id)
  end

  def create_variable(%Environment{} = environment, attrs) do
    %Variable{environment_id: environment.id}
    |> Variable.changeset(attrs)
    |> Repo.insert()
  end

  def update_variable(%Variable{} = variable, attrs) do
    variable
    |> Variable.changeset(attrs)
    |> Repo.update()
  end

  def delete_variable(%Variable{} = variable), do: Repo.delete(variable)

  def change_variable(%Variable{} = variable, attrs \\ %{}) do
    Variable.changeset(variable, attrs)
  end

  @doc """
  Removes the value of a secret, so that a struct handed to a template or a form
  cannot leak it. Non-secret variables are returned unchanged.
  """
  def redact(%Variable{secret: true} = variable), do: %{variable | value: nil}
  def redact(%Variable{} = variable), do: variable
end
