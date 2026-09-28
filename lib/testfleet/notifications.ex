defmodule TestFleet.Notifications do
  @moduledoc """
  Notification channels and deliveries (Milestone 8).

  Channels are global: without authentication there are no users to own them.
  Their webhook URLs and signing secrets are credentials: encrypted at rest, and
  removed by `redact/1` before a channel reaches a template, a form, or a stream.
  Deliveries are sent by `TestFleet.Notifications.DeliveryWorker`; Oban job args
  carry the delivery id only, because Oban stores them in plain JSON.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias TestFleet.Notifications.{Channel, Delivery, DeliveryWorker, Message, Sender}
  alias TestFleet.Repo

  ## Configuration

  @doc "Whether email can be sent: SMTP is configured in production (`SMTP_HOST`)."
  def email_configured?, do: config(:email_enabled, false)

  @doc "The sender address of notification emails (`SMTP_FROM`)."
  def email_from, do: config(:email_from, "testfleet@localhost")

  @doc false
  def req_options, do: config(:req_options, [])

  defp config(key, default),
    do: Keyword.get(Application.get_env(:testfleet, __MODULE__, []), key, default)

  ## Channels

  def list_channels do
    Repo.all(from c in Channel, order_by: [asc: fragment("lower(?)", c.name)])
  end

  def get_channel!(id), do: Repo.get!(Channel, id)

  def get_channel(id), do: Repo.get(Channel, id)

  def create_channel(attrs) do
    %Channel{}
    |> Channel.changeset(attrs)
    |> Repo.insert()
  end

  def update_channel(%Channel{} = channel, attrs) do
    channel
    |> Channel.changeset(attrs)
    |> Repo.update()
  end

  def set_channel_enabled(%Channel{} = channel, enabled) when is_boolean(enabled) do
    channel
    |> Ecto.Changeset.change(enabled: enabled)
    |> Repo.update()
  end

  @doc "Deletes a channel, with its deliveries."
  def delete_channel(%Channel{} = channel), do: Repo.delete(channel)

  def change_channel(%Channel{} = channel, attrs \\ %{}), do: Channel.changeset(channel, attrs)

  @doc """
  Removes the URL and the signing secret, so that a struct handed to a template or
  a form cannot leak them. `signing_secret_set` tells whether there is one, and
  `recipients_text` is filled for the form.
  """
  def redact(%Channel{} = channel) do
    %{
      channel
      | url: nil,
        signing_secret: nil,
        signing_secret_set: channel.signing_secret not in [nil, ""],
        recipients_text: Enum.join(channel.email_recipients, ", ")
    }
  end

  @doc """
  Sends a `test` message right away, not through Oban (Milestone 8, section 4).

  `channel` is the stored channel, or a new `%Channel{}`; `attrs` are the form
  values. An empty URL or signing secret uses the stored one, as when saving.
  """
  @spec send_test(Channel.t(), map()) :: :ok | {:error, String.t()}
  def send_test(%Channel{} = channel, attrs \\ %{}) do
    changeset = change_channel(channel, attrs)

    if changeset.valid? do
      channel = Ecto.Changeset.apply_changes(changeset)

      case Sender.deliver(channel, Message.test(channel)) do
        :ok -> :ok
        {:error, _kind, reason} -> {:error, reason}
      end
    else
      {:error, "Fix the form first."}
    end
  end

  ## Deliveries

  @doc """
  Records a delivery of `event` to `channel` and enqueues its job, in one
  transaction. A delivery with the same `dedupe_key` for this channel is not
  created again: returns `{:ok, :duplicate}`.

  Options: `:run_id`, `:data` (a map; never secrets).
  """
  def enqueue_delivery(%Channel{} = channel, event, dedupe_key, opts \\ []) do
    Multi.new()
    |> enqueue_delivery_multi(:delivery, channel, event, dedupe_key, opts)
    |> Repo.transaction()
    |> case do
      {:ok, %{delivery: delivery}} -> {:ok, delivery}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc "The steps of `enqueue_delivery/4`, for callers with their own transaction."
  def enqueue_delivery_multi(multi, name, %Channel{} = channel, event, dedupe_key, opts \\ []) do
    delivery = %Delivery{
      channel_id: channel.id,
      run_id: opts[:run_id],
      event: event,
      dedupe_key: dedupe_key,
      data: opts[:data] || %{}
    }

    multi
    |> Multi.insert({name, :row}, delivery,
      on_conflict: :nothing,
      conflict_target: [:channel_id, :dedupe_key]
    )
    |> Multi.run(name, fn _repo, changes ->
      case changes[{name, :row}] do
        # on_conflict: :nothing returns the struct without an id.
        %Delivery{id: nil} ->
          {:ok, :duplicate}

        # Inside the transaction: the job exists exactly when the delivery does.
        %Delivery{id: id} = delivery ->
          with {:ok, _job} <- Oban.insert(DeliveryWorker.new(%{delivery_id: id})),
               do: {:ok, delivery}
      end
    end)
  end

  def get_delivery(id), do: Repo.get(Delivery, id) |> Repo.preload(:channel)

  @doc """
  Records the outcome of an attempt. `result` is the sender's; `final?` tells
  whether no attempt follows, so a retryable error ends the delivery.
  """
  def record_attempt(%Delivery{} = delivery, attempt, result, final?) do
    changes =
      case result do
        :ok ->
          [status: :sent, sent_at: DateTime.utc_now(), last_error: nil]

        {:error, :retry, reason} ->
          [status: if(final?, do: :failed, else: :pending), last_error: short(reason)]

        {:error, :permanent, reason} ->
          [status: :failed, last_error: short(reason)]
      end

    delivery
    |> Ecto.Changeset.change([attempts: attempt] ++ changes)
    |> Repo.update()
  end

  defp short(reason), do: String.slice(reason, 0, 500)
end
