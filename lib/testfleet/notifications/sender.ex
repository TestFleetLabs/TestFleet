defmodule TestFleet.Notifications.Sender do
  @moduledoc """
  Sends a message to a channel (Milestone 8, section 8).

  Returns `:ok`, or `{:error, :retry | :permanent, reason}`:

    * `2xx` - sent
    * `429`, `5xx`, and transport errors - worth retrying
    * redirects and other `4xx` - permanent (a revoked Slack URL answers `404` or
      `410`); redirects are not followed

  `reason` is short and safe to store and show: it never contains the URL, the
  signing secret, or a response body.
  """

  alias TestFleet.Mailer
  alias TestFleet.Notifications
  alias TestFleet.Notifications.{Channel, Format, Message}

  @timeout 10_000

  @type result :: :ok | {:error, :retry | :permanent, String.t()}

  @doc "Options: `:delivery_id`, sent to webhooks for idempotency."
  @spec deliver(Channel.t(), Message.t(), keyword()) :: result()
  def deliver(channel, message, opts \\ [])

  def deliver(%Channel{kind: :email} = channel, %Message{} = message, _opts) do
    if Notifications.email_configured?() do
      %{subject: subject, text: text, html: html} = Format.email(message)

      email =
        Swoosh.Email.new(
          to: channel.email_recipients,
          from: {"TestFleet", Notifications.email_from()},
          subject: subject,
          text_body: text,
          html_body: html
        )

      case Mailer.deliver(email) do
        {:ok, _} -> :ok
        {:error, reason} -> email_error(reason)
      end
    else
      {:error, :permanent, "Email is not configured on this server"}
    end
  end

  def deliver(%Channel{kind: :slack} = channel, message, _opts),
    do: post(channel.url, Jason.encode!(Format.slack(message)), [])

  def deliver(%Channel{kind: :teams} = channel, message, _opts),
    do: post(channel.url, Jason.encode!(Format.teams(message)), [])

  def deliver(%Channel{kind: :webhook} = channel, message, opts) do
    delivery_id = opts[:delivery_id]
    body = Jason.encode!(Format.webhook(message, delivery_id))

    post(
      channel.url,
      body,
      Format.webhook_headers(message, body, delivery_id, channel.signing_secret)
    )
  end

  defp post(url, body, headers) do
    options =
      Keyword.merge(
        [
          method: :post,
          url: url,
          body: body,
          headers: [{"content-type", "application/json"} | headers],
          retry: false,
          redirect: false,
          receive_timeout: @timeout,
          connect_options: [timeout: @timeout]
        ],
        Notifications.req_options()
      )

    case Req.request(options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status}} when status == 429 or status >= 500 ->
        {:error, :retry, "HTTP #{status}"}

      {:ok, %Req.Response{status: status}} when status in 300..399 ->
        {:error, :permanent, "HTTP #{status}: redirects are not followed"}

      {:ok, %Req.Response{status: status}} ->
        {:error, :permanent, "HTTP #{status}"}

      # The exception's message names the reason (e.g. "connection refused"), not
      # the URL.
      {:error, exception} ->
        {:error, :retry, Exception.message(exception)}
    end
  end

  # gen_smtp's reasons are tuples that may carry server replies; only their kind is
  # kept.
  defp email_error({:permanent_failure, _host, _reply}),
    do: {:error, :permanent, "the mail server rejected the message"}

  defp email_error(reason) do
    kind =
      case reason do
        {kind, _} when is_atom(kind) -> kind
        {kind, _, _} when is_atom(kind) -> kind
        kind when is_atom(kind) -> kind
        _ -> :unknown
      end

    {:error, :retry, "sending the email failed (#{kind})"}
  end
end
