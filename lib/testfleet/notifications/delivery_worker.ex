defmodule TestFleet.Notifications.DeliveryWorker do
  @moduledoc """
  Sends one delivery (Milestone 8, section 8). The args hold the delivery id only:
  Oban stores them in plain JSON, and the message is rendered from current data.

  Up to 5 attempts with Oban's backoff for `429`, `5xx`, and transport errors;
  other failures end the delivery at once (`{:cancel, reason}`). Retrying
  deliveries is not retrying runs: runs are never retried (main spec section 35).
  """
  use Oban.Worker, queue: :notifications, max_attempts: 5

  require Logger

  alias TestFleet.Notifications
  alias TestFleet.Notifications.{Delivery, Message, Sender}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => id}, attempt: attempt, max_attempts: max}) do
    case Notifications.get_delivery(id) do
      nil ->
        {:cancel, "the delivery no longer exists"}

      # Sent, or ended, by an earlier attempt.
      %Delivery{status: status} when status != :pending ->
        :ok

      delivery ->
        deliver(delivery, attempt, attempt >= max)
    end
  end

  defp deliver(delivery, attempt, final?) do
    result =
      with true <- delivery.channel.enabled || {:error, :permanent, "the channel is disabled"},
           {:ok, message} <- message(delivery) do
        Sender.deliver(delivery.channel, message, delivery_id: delivery.id)
      end

    {:ok, _} = Notifications.record_attempt(delivery, attempt, result, final?)

    case result do
      :ok ->
        :ok

      {:error, :retry, reason} ->
        # Names the channel, never its URL.
        Logger.warning(
          "notification #{delivery.id} to #{delivery.channel.name} failed (attempt #{attempt}): #{reason}"
        )

        {:error, reason}

      {:error, :permanent, reason} ->
        Logger.warning(
          "notification #{delivery.id} to #{delivery.channel.name} failed: #{reason}"
        )

        {:cancel, reason}
    end
  end

  defp message(%Delivery{event: "test"} = delivery), do: {:ok, Message.test(delivery.channel)}

  defp message(%Delivery{event: "run." <> _, run_id: run_id} = delivery) when run_id != nil,
    do: {:ok, Notifications.run_message(delivery)}

  defp message(%Delivery{event: "system." <> _} = delivery),
    do: {:ok, Notifications.system_message(delivery)}

  defp message(%Delivery{event: event}), do: {:error, :permanent, "unknown event #{event}"}
end
