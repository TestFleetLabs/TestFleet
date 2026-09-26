defmodule TestFleet.Repo do
  use Ecto.Repo,
    otp_app: :testfleet,
    adapter: Ecto.Adapters.Postgres
end
