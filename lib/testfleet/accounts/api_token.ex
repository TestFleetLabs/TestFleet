defmodule TestFleet.Accounts.APIToken do
  @moduledoc """
  A user's API token: `tf_` and 32 random bytes,
  base64url. Only its SHA-256 is stored, with its last 4 characters as a hint; the
  token itself is shown once, when created.

  The expiry is chosen as `expires_in`: 30, 90, or 365 days, or `never`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @prefix "tf_"
  @expiries ~w(30 90 365 never)

  schema "api_tokens" do
    field :name, :string
    field :token_hash, :binary, redact: true
    field :hint, :string
    field :expires_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :expires_in, :string, virtual: true, default: "365"

    belongs_to :user, TestFleet.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The choices of `expires_in`."
  def expiries, do: @expiries

  @doc false
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:name, :expires_in])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :expires_in])
    |> validate_length(:name, max: 100)
    |> validate_inclusion(:expires_in, @expiries)
  end

  @doc """
  Fills in a new token: returns `{token, changeset}`, with the hash, the hint, and
  the expiry put into the changeset.
  """
  def generate(changeset, now \\ DateTime.utc_now(:second)) do
    token = @prefix <> (32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false))

    changeset =
      changeset
      |> put_change(:token_hash, hash(token))
      |> put_change(:hint, String.slice(token, -4, 4))
      |> put_change(:expires_at, expires_at(get_field(changeset, :expires_in), now))

    {token, changeset}
  end

  defp expires_at("never", _now), do: nil
  defp expires_at(days, now), do: DateTime.add(now, String.to_integer(days), :day)

  @doc "The stored hash of a token."
  def hash(token) when is_binary(token), do: :crypto.hash(:sha256, token)

  @doc "Whether `token` looks like an API token at all."
  def well_formed?(@prefix <> rest), do: byte_size(rest) == 43
  def well_formed?(_token), do: false

  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) != :gt
end
