defmodule TestFleet.Notifications.Delivery do
  @moduledoc """
  One notification to one channel, sent by
  `TestFleet.Notifications.DeliveryWorker`.

  The message is rendered when it is sent, from `event`, the run, and `data`.
  `dedupe_key` is unique per channel, so an event cannot be delivered twice.
  `last_error` is a short reason; never a URL or a response body.
  """
  use Ecto.Schema

  schema "notification_deliveries" do
    belongs_to :channel, TestFleet.Notifications.Channel
    belongs_to :run, TestFleet.Runs.Run

    field :event, :string
    field :dedupe_key, :string
    field :data, :map, default: %{}
    field :status, Ecto.Enum, values: [:pending, :sent, :failed], default: :pending
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :sent_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end
end
