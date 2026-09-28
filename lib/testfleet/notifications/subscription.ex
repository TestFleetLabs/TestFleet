defmodule TestFleet.Notifications.Subscription do
  @moduledoc """
  Which events of which projects and environments a channel receives (Milestone 8,
  section 5).

  Without a project, the subscription covers all projects; with a project, all its
  environments, or one of them. System events belong to no project, so only a
  subscription without a project can choose them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TestFleet.Environments.Environment
  alias TestFleet.Repo

  @run_events ~w(run.failing run.recovered run.error)
  @system_events ~w(system.docker_unreachable system.docker_recovered system.scheduling_stalled system.scheduling_recovered)

  schema "notification_subscriptions" do
    belongs_to :channel, TestFleet.Notifications.Channel
    belongs_to :project, TestFleet.Projects.Project
    belongs_to :environment, Environment

    field :events, {:array, :string}, default: []

    timestamps(type: :utc_datetime)
  end

  def run_events, do: @run_events
  def system_events, do: @system_events

  @doc "The events a new subscription starts with."
  def default_events, do: @run_events

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:project_id, :environment_id, :events])
    |> update_change(:events, fn events -> events |> Enum.reject(&(&1 == "")) |> Enum.uniq() end)
    |> validate_subset(:events, @run_events ++ @system_events)
    |> validate_some_event()
    |> validate_scope()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:environment_id)
    |> check_constraint(:environment_id, name: :environment_needs_project)
  end

  # Not validate_length: an empty list equals the default, so it is no change, and
  # validations only look at changes.
  defp validate_some_event(changeset) do
    if get_field(changeset, :events) in [nil, []],
      do: add_error(changeset, :events, "choose at least one event"),
      else: changeset
  end

  defp validate_scope(changeset) do
    project_id = get_field(changeset, :project_id)
    environment_id = get_field(changeset, :environment_id)
    events = get_field(changeset, :events) || []

    changeset =
      if project_id && Enum.any?(events, &(&1 in @system_events)),
        do: add_error(changeset, :events, "system events are only for all projects"),
        else: changeset

    cond do
      environment_id == nil ->
        changeset

      project_id == nil ->
        add_error(changeset, :environment_id, "needs a project")

      match?(%Environment{project_id: ^project_id}, Repo.get(Environment, environment_id)) ->
        changeset

      true ->
        add_error(changeset, :environment_id, "does not belong to the project")
    end
  end
end
