defmodule TestFleet.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :testfleet

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Restores access for a lost admin account (Milestone 10, section 8): makes `email`
  an active admin, creating the user if needed, and prints a link that sets a new
  password. Runs in the running application:

      bin/testfleet rpc 'TestFleet.Release.invite_admin("ops@example.com")'
  """
  def invite_admin(email) do
    url_fun = &"#{TestFleetWeb.Endpoint.url()}/users/invitations/#{&1}"

    case TestFleet.Accounts.invite_admin(email, url_fun) do
      {:ok, url} ->
        IO.puts("#{email} is an admin. Set a password within 7 days at:\n\n  #{url}\n")

      {:error, changeset} ->
        IO.puts("Could not invite #{email}: #{inspect(changeset.errors)}")
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
