defmodule TestFleet.Notifications do
  @moduledoc """
  Notification channels and deliveries (Milestone 8).

  Channels are global: without authentication there are no users to own them.
  Their webhook URLs and signing secrets are credentials: encrypted at rest, and
  removed by `redact/1` before a channel reaches a template, a form, or a stream.
  Deliveries are sent by `TestFleet.Notifications.DeliveryWorker`; Oban job args
  carry the delivery id only, because Oban stores them in plain JSON.

  Deliveries are broadcast on the `notifications` topic as `{:delivery, delivery}`
  (with its channel) when they are created and after every attempt.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi

  alias TestFleet.Notifications.{
    Channel,
    Delivery,
    DeliveryWorker,
    Message,
    Sender,
    Subscription,
    Transitions
  }

  alias TestFleet.Repo
  alias TestFleet.Runs
  alias TestFleet.Runs.Run
  alias TestFleet.TestDefinitions.TestDefinition

  @topic "notifications"

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

  @doc "The number of subscriptions per channel id."
  def subscription_counts do
    Repo.all(from s in Subscription, group_by: s.channel_id, select: {s.channel_id, count(s.id)})
    |> Map.new()
  end

  ## Subscriptions

  @doc "A channel's subscriptions, with their project and environment."
  def list_subscriptions(%Channel{id: channel_id}) do
    Repo.all(
      from s in Subscription,
        where: s.channel_id == ^channel_id,
        order_by: [asc: s.id],
        preload: [:project, :environment]
    )
  end

  def get_subscription!(id), do: Repo.get!(Subscription, id)

  def create_subscription(%Channel{id: channel_id}, attrs) do
    %Subscription{channel_id: channel_id}
    |> Subscription.changeset(attrs)
    |> Repo.insert()
  end

  def delete_subscription(%Subscription{} = subscription), do: Repo.delete(subscription)

  def change_subscription(%Subscription{} = subscription, attrs \\ %{}),
    do: Subscription.changeset(subscription, attrs)

  @doc """
  The enabled channels with a subscription to `event` that covers `run`: all
  projects, its project, or its project's environment. Each channel once.
  """
  def channels_for(event, %Run{} = run) do
    project_id =
      Repo.one!(
        from t in TestDefinition, where: t.id == ^run.test_definition_id, select: t.project_id
      )

    Repo.all(
      from c in Channel,
        join: s in Subscription,
        on: s.channel_id == c.id,
        where: c.enabled and fragment("? = ANY(?)", ^event, s.events),
        where:
          is_nil(s.project_id) or
            (s.project_id == ^project_id and
               (is_nil(s.environment_id) or s.environment_id == ^run.environment_id)),
        distinct: true,
        order_by: c.id
    )
  end

  ## Run events

  @doc """
  Decides whether a final run changed its series' state (`Transitions`), and
  creates one delivery per matching channel, in one transaction. Idempotent:
  deliveries are unique per channel and `"<event>:<run id>"`.

  Returns the deliveries created (none when there is no event, no subscriber, or
  everything was delivered before).
  """
  def evaluate_run(run_id) do
    run = Runs.get_run!(run_id)
    previous_verdict = Runs.previous_run(run, Transitions.verdict_statuses())
    previous_outcome = Runs.previous_run(run, Run.final_statuses() -- [:cancelled])

    case Transitions.event(run, previous_verdict, previous_outcome) do
      :none ->
        {:ok, []}

      {event, previous} ->
        data = %{
          "previous_status" => previous && to_string(previous.status),
          "previous_run_id" => previous && previous.id
        }

        {:ok, changes} =
          event
          |> channels_for(run)
          |> Enum.reduce(Multi.new(), fn channel, multi ->
            enqueue_delivery_multi(
              multi,
              {:delivery, channel.id},
              channel,
              event,
              "#{event}:#{run.id}",
              run_id: run.id,
              data: data
            )
          end)
          |> Repo.transaction()

        deliveries = for {{:delivery, _id}, %Delivery{} = delivery} <- changes, do: delivery
        Enum.each(deliveries, &broadcast_delivery/1)
        {:ok, deliveries}
    end
  end

  @doc "Renders a run event delivery from the run as it is now."
  def run_message(%Delivery{event: event, run_id: run_id, data: data}) do
    run = run_id |> Runs.get_run!() |> Repo.preload([:environment, test_definition: :project])
    Message.run_event(event, run, data, TestFleet.Results.failure_summary(run))
  end

  ## Deliveries

  def subscribe_deliveries, do: Phoenix.PubSub.subscribe(TestFleet.PubSub, @topic)

  # Broadcast deliveries reach pages: their channel is redacted.
  defp broadcast_delivery(%Delivery{} = delivery) do
    Phoenix.PubSub.broadcast(TestFleet.PubSub, @topic, {:delivery, with_channel(delivery)})
    delivery
  end

  @doc "The newest deliveries, with their (redacted) channel."
  def list_recent_deliveries(limit \\ 50) do
    Repo.all(from d in Delivery, order_by: [desc: d.id], limit: ^limit)
    |> with_channel()
  end

  @doc "The deliveries a run caused, with their (redacted) channel."
  def list_run_deliveries(%Run{id: run_id}) do
    Repo.all(from d in Delivery, where: d.run_id == ^run_id, order_by: [asc: d.id])
    |> with_channel()
  end

  defp with_channel(deliveries) when is_list(deliveries) do
    deliveries
    |> Repo.preload(:channel, force: true)
    |> Enum.map(&%{&1 | channel: redact(&1.channel)})
  end

  defp with_channel(%Delivery{} = delivery), do: hd(with_channel([delivery]))

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
      {:ok, %{delivery: :duplicate}} -> {:ok, :duplicate}
      {:ok, %{delivery: delivery}} -> {:ok, broadcast_delivery(delivery)}
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

  @doc "A delivery with its channel, secrets included: for sending, never for a page."
  def get_delivery(id), do: Delivery |> Repo.get(id) |> Repo.preload(:channel)

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

    with {:ok, delivery} <-
           delivery
           |> Ecto.Changeset.change([attempts: attempt] ++ changes)
           |> Repo.update() do
      {:ok, broadcast_delivery(delivery)}
    end
  end

  defp short(reason), do: String.slice(reason, 0, 500)
end
