defmodule TestFleet.Notifications do
  @moduledoc """
  Notification channels and deliveries.

  Channels belong to an organization and only receive its events; system events
  are delivered only in `:single` mode. Their webhook URLs and signing secrets are credentials: encrypted at rest, and
  removed by `redact/1` before a channel reaches a template, a form, or a stream.
  Deliveries are sent by `TestFleet.Notifications.DeliveryWorker`; Oban job args
  carry the delivery id only, because Oban stores them in plain JSON.

  Deliveries are broadcast on their organization's `notifications:<organization_id>`
  topic as `{:delivery, delivery}` (with its channel) when they are created and
  after every attempt.
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

  alias TestFleet.Accounts.Scope
  alias TestFleet.Organizations
  alias TestFleet.Projects.Project
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

  @doc "The scope's organization's channels, by name."
  def list_channels(%Scope{} = scope) do
    Repo.all(
      from c in Channel,
        where: c.organization_id == ^organization_id(scope),
        order_by: [asc: fragment("lower(?)", c.name)]
    )
  end

  def get_channel!(%Scope{} = scope, id),
    do: Repo.get_by!(Channel, organization_id: organization_id(scope), id: id)

  def get_channel(%Scope{} = scope, id),
    do: Repo.get_by(Channel, organization_id: organization_id(scope), id: id)

  def create_channel(%Scope{} = scope, attrs) do
    %Channel{organization_id: organization_id(scope)}
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
  Sends a `test` message right away, not through Oban.

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

  @doc "The number of subscriptions per channel id, for the organization's channels."
  def subscription_counts(%Scope{} = scope) do
    Repo.all(
      from s in Subscription,
        join: c in assoc(s, :channel),
        where: c.organization_id == ^organization_id(scope),
        group_by: s.channel_id,
        select: {s.channel_id, count(s.id)}
    )
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

  def get_subscription!(%Channel{id: channel_id}, id),
    do: Repo.get_by!(Subscription, channel_id: channel_id, id: id)

  @doc "Subscribes a channel; the project must belong to the channel's organization."
  def create_subscription(%Channel{id: channel_id, organization_id: organization_id}, attrs) do
    %Subscription{channel_id: channel_id}
    |> Subscription.changeset(attrs)
    |> validate_project_in(organization_id)
    |> Repo.insert()
  end

  defp validate_project_in(changeset, organization_id) do
    Ecto.Changeset.validate_change(changeset, :project_id, fn :project_id, project_id ->
      if Repo.exists?(
           from p in Project, where: p.id == ^project_id and p.organization_id == ^organization_id
         ),
         do: [],
         else: [project_id: "does not exist"]
    end)
  end

  def delete_subscription(%Subscription{} = subscription), do: Repo.delete(subscription)

  def change_subscription(%Subscription{} = subscription, attrs \\ %{}),
    do: Subscription.changeset(subscription, attrs)

  @doc """
  The enabled channels of the run's organization with a subscription to `event`
  that covers `run`: all projects, its project, or its project's environment.
  Each channel once.
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
        where: c.organization_id == ^run.organization_id,
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

        event
        |> channels_for(run)
        |> deliver_to(event, "#{event}:#{run.id}", run_id: run.id, data: data)
    end
  end

  ## System events

  @doc """
  Delivers a system event to every enabled channel with a
  subscription to it; only subscriptions for all projects can have one.
  `dedupe_key` names the episode, so an event is delivered once per episode.
  `data` is stored with the delivery and rendered when it is sent: never secrets.

  System events concern the whole installation: in `:multi` mode they are not
  delivered to organizations; the operators monitor the installation themselves.
  """
  def notify_system(event, dedupe_key, data) do
    if Organizations.multi?(),
      do: {:ok, []},
      else: do_notify_system(event, dedupe_key, data)
  end

  defp do_notify_system(event, dedupe_key, data) do
    Repo.all(
      from c in Channel,
        join: s in Subscription,
        on: s.channel_id == c.id,
        where: c.enabled and is_nil(s.project_id) and fragment("? = ANY(?)", ^event, s.events),
        distinct: true,
        order_by: c.id
    )
    |> deliver_to(event, dedupe_key, data: data)
  end

  # One delivery per channel, all in one transaction; returns the new ones.
  defp deliver_to(channels, event, dedupe_key, opts) do
    {:ok, changes} =
      channels
      |> Enum.reduce(Multi.new(), fn channel, multi ->
        enqueue_delivery_multi(multi, {:delivery, channel.id}, channel, event, dedupe_key, opts)
      end)
      |> Repo.transaction()

    deliveries = for {{:delivery, _id}, %Delivery{} = delivery} <- changes, do: delivery
    Enum.each(deliveries, &broadcast_delivery/1)
    {:ok, deliveries}
  end

  @doc "Deletes deliveries created before `cutoff`. Returns how many."
  def prune_deliveries(%DateTime{} = cutoff) do
    {count, _} = Repo.delete_all(from d in Delivery, where: d.inserted_at < ^cutoff)
    count
  end

  @doc "Renders a system event delivery from its stored data."
  def system_message(%Delivery{event: event, data: data, inserted_at: inserted_at}),
    do: Message.system_event(event, data, inserted_at || DateTime.utc_now())

  @doc "Renders a run event delivery from the run as it is now."
  def run_message(%Delivery{event: event, run_id: run_id, data: data}) do
    run = run_id |> Runs.get_run!() |> Repo.preload([:environment, test_definition: :project])
    Message.run_event(event, run, data, TestFleet.Results.failure_summary(run))
  end

  ## Deliveries

  @doc "Subscribes to the deliveries of the scope's organization's channels."
  def subscribe_deliveries(%Scope{} = scope),
    do: Phoenix.PubSub.subscribe(TestFleet.PubSub, topic(organization_id(scope)))

  defp topic(organization_id), do: "#{@topic}:#{organization_id}"

  # Broadcast deliveries reach pages: their channel is redacted.
  defp broadcast_delivery(%Delivery{} = delivery) do
    delivery = with_channel(delivery)

    Phoenix.PubSub.broadcast(
      TestFleet.PubSub,
      topic(delivery.channel.organization_id),
      {:delivery, delivery}
    )

    delivery
  end

  @doc "The organization's newest deliveries, with their (redacted) channel."
  def list_recent_deliveries(%Scope{} = scope, limit \\ 50) do
    Repo.all(
      from d in Delivery,
        join: c in assoc(d, :channel),
        where: c.organization_id == ^organization_id(scope),
        order_by: [desc: d.id],
        limit: ^limit
    )
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

  defp organization_id(%Scope{organization: %{id: id}}), do: id
end
