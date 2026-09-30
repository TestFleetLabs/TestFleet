defmodule TestFleetWeb.SetupNotice do
  @moduledoc """
  Logs the first-run setup link on start while there is no user (Milestone 10,
  section 4). Only someone who can read the log can set up an empty installation.

  Runs once after the endpoint started; a failure (the database is down) is logged
  and does not affect the application. Disabled in tests.
  """
  use Task, restart: :temporary

  alias TestFleet.Accounts

  require Logger

  def start_link(_opts), do: Task.start_link(&run/0)

  def run do
    if Accounts.setup_needed?() do
      url = TestFleetWeb.Endpoint.url() <> "/setup?token=" <> Accounts.setup_token()
      Logger.warning("No users yet. Create the first admin at #{url}")
    end
  rescue
    error -> Logger.error("Could not check for the first-run setup: #{Exception.message(error)}")
  end
end
