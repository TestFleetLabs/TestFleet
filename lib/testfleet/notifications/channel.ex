defmodule TestFleet.Notifications.Channel do
  @moduledoc """
  One destination for notifications: email addresses, a
  Slack or Teams webhook, or a generic webhook.

  A webhook URL is a credential (Slack's and Teams' carry their token in the path),
  so `url` and `signing_secret` are encrypted at rest and never sent back to the
  browser. `url_hint` (the host) is what the UI shows instead. When editing, an
  empty URL or signing secret means "keep the current one"; `clear_signing_secret`
  removes the secret.

  The kind is chosen when the channel is created and cannot change.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import TestFleet.Changesets, only: [update_present: 3]

  @type t :: %__MODULE__{}

  @kinds [:email, :slack, :teams, :webhook]
  @max_recipients 20
  @email ~r/\A[^\s@,;<>]+@[^\s@,;<>]+\z/

  schema "notification_channels" do
    field :name, :string
    field :kind, Ecto.Enum, values: @kinds
    field :enabled, :boolean, default: true
    field :email_recipients, {:array, :string}, default: []
    field :url, TestFleet.Encrypted.Binary, source: :url_encrypted, redact: true
    field :url_hint, :string

    belongs_to :organization, TestFleet.Organizations.Organization

    field :signing_secret, TestFleet.Encrypted.Binary,
      source: :signing_secret_encrypted,
      redact: true

    # Form fields
    field :recipients_text, :string, virtual: true
    field :clear_signing_secret, :boolean, virtual: true, default: false
    # Set by `TestFleet.Notifications.redact/1`, which removes the secrets themselves.
    field :signing_secret_set, :boolean, virtual: true, default: false

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  @doc "Whether the channel posts to a URL (everything but email)."
  def url_kind?(kind), do: kind in [:slack, :teams, :webhook]

  @doc false
  def changeset(channel, attrs) do
    channel
    |> cast(attrs, [:name, :enabled, :recipients_text, :clear_signing_secret])
    |> cast_kind(attrs)
    |> update_present(:name, &String.trim/1)
    |> validate_required([:name, :kind])
    |> validate_length(:name, max: 100)
    |> unique_constraint(:name,
      name: :notification_channels_organization_id_name_index,
      message: "is already used by another channel"
    )
    |> put_kind_fields(attrs)
  end

  # The kind is fixed once the channel exists.
  defp cast_kind(%{data: %{id: nil}} = changeset, attrs), do: cast(changeset, attrs, [:kind])
  defp cast_kind(changeset, _attrs), do: changeset

  defp put_kind_fields(changeset, attrs) do
    case get_field(changeset, :kind) do
      :email ->
        changeset
        |> put_recipients()
        |> put_change(:url, nil)
        |> put_change(:url_hint, nil)
        |> put_change(:signing_secret, nil)

      kind when kind in [:slack, :teams] ->
        changeset
        |> put_change(:email_recipients, [])
        |> cast_url(attrs)
        |> put_change(:signing_secret, nil)

      :webhook ->
        changeset
        |> put_change(:email_recipients, [])
        |> cast_url(attrs)
        |> cast_signing_secret(attrs)

      nil ->
        changeset
    end
  end

  defp put_recipients(changeset) do
    text = get_field(changeset, :recipients_text)

    # Without the form field (e.g. an update of `enabled` only), the list stays.
    if text == nil and changeset.data.id != nil do
      changeset
    else
      recipients =
        (text || "")
        |> String.split([",", ";", " ", "\n", "\r", "\t"], trim: true)
        |> Enum.uniq()

      invalid = Enum.reject(recipients, &Regex.match?(@email, &1))

      cond do
        recipients == [] ->
          add_error(changeset, :recipients_text, "enter at least one address")

        invalid != [] ->
          add_error(changeset, :recipients_text, "not an email address: %{addresses}",
            addresses: Enum.join(invalid, ", ")
          )

        length(recipients) > @max_recipients ->
          add_error(changeset, :recipients_text, "at most %{count} addresses",
            count: @max_recipients
          )

        true ->
          put_change(changeset, :email_recipients, recipients)
      end
    end
  end

  # An existing channel keeps its URL when the field is left empty.
  defp cast_url(changeset, attrs) do
    url = attrs |> param(:url) |> trim()

    cond do
      url not in [nil, ""] ->
        case validate_url(url) do
          {:ok, hint} ->
            changeset |> put_change(:url, url) |> put_change(:url_hint, hint)

          {:error, message} ->
            add_error(changeset, :url, message)
        end

      changeset.data.id == nil or changeset.data.kind != get_field(changeset, :kind) ->
        add_error(changeset, :url, "can't be blank")

      true ->
        changeset
    end
  end

  defp cast_signing_secret(changeset, attrs) do
    secret = attrs |> param(:signing_secret) |> trim()

    cond do
      get_field(changeset, :clear_signing_secret) ->
        put_change(changeset, :signing_secret, nil)

      secret not in [nil, ""] ->
        changeset
        |> put_change(:signing_secret, secret)
        |> validate_length(:signing_secret, min: 16, max: 256)

      true ->
        changeset
    end
  end

  defp param(attrs, key), do: attrs[to_string(key)] || attrs[key]

  defp trim(nil), do: nil
  defp trim(value) when is_binary(value), do: String.trim(value)

  @doc """
  Checks a webhook URL. Returns the hint shown instead of it: the host, followed by
  `/…` when the URL has more (the part that holds a token).
  """
  def validate_url(url) do
    case URI.new(url) do
      _ when byte_size(url) > 2048 ->
        {:error, "is too long"}

      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        rest? = uri.path not in [nil, "", "/"] or uri.query != nil
        {:ok, if(rest?, do: host <> "/…", else: host)}

      {:ok, _uri} ->
        {:error, "must start with https:// or http://"}

      {:error, _} ->
        {:error, "is not a valid URL"}
    end
  end
end
