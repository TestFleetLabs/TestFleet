defmodule TestFleet.Runs.Deployment do
  @moduledoc """
  What a pipeline deployed before it started an API run: the application's
  `version`, its `commit`, and a `url` (the pipeline run, the release, or the
  commit). Every field is optional; a run without any has no deployment.

  It is what the pipeline says, not something TestFleet checks: it lets a failure
  be traced to the deploy that preceded it.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @fields [:version, :commit, :url]
  @max_url 2_048

  @primary_key false
  embedded_schema do
    field :version, :string
    field :commit, :string
    field :url, :string
  end

  @doc "The fields, as the API names them."
  def fields, do: Enum.map(@fields, &Atom.to_string/1)

  @doc """
  The deployment of `params` (string keys), `nil` when no field is given:

      {:ok, %Deployment{} | nil} | {:error, changeset}
  """
  def new(nil), do: {:ok, nil}

  def new(params) when is_map(params) do
    changeset =
      %__MODULE__{}
      |> cast(params, @fields)
      |> update_change(:version, &String.trim/1)
      |> update_change(:commit, &(&1 |> String.trim() |> String.downcase()))
      |> update_change(:url, &String.trim/1)
      |> validate_length(:version, min: 1, max: 100)
      |> validate_format(:version, ~r/\A[^\p{C}]*\z/u, message: "has control characters")
      |> validate_format(:commit, ~r/\A[0-9a-f]{7,64}\z/,
        message: "must be a commit hash of 7 to 64 hexadecimal characters"
      )
      |> validate_length(:url, max: @max_url)
      |> validate_change(:url, &validate_url/2)

    case apply_action(changeset, :insert) do
      {:ok, %__MODULE__{version: nil, commit: nil, url: nil}} -> {:ok, nil}
      result -> result
    end
  end

  # Rendered as a link: only absolute http(s) URLs, never javascript: or relative ones.
  defp validate_url(:url, url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        []

      _ ->
        [url: "must be an http or https URL"]
    end
  end

  @doc """
  A short name for lists and messages: the version and the short commit,
  `"1.4.2 (9fceb02)"`, either alone, or nil without both.
  """
  def label(nil), do: nil

  def label(%__MODULE__{version: version, commit: commit}) do
    case {version, short_commit(commit)} do
      {nil, nil} -> nil
      {version, nil} -> version
      {nil, commit} -> commit
      {version, commit} -> "#{version} (#{commit})"
    end
  end

  @doc "The first 7 characters of a commit hash, as git shows it."
  def short_commit(nil), do: nil
  def short_commit(commit), do: String.slice(commit, 0, 7)

  @doc "The host of the URL, to name the link (`github.com`)."
  def url_host(%__MODULE__{url: url}) when is_binary(url), do: URI.parse(url).host
  def url_host(_deployment), do: nil

  @doc "The deployment as JSON, with every field, or nil."
  def to_json(nil), do: nil

  def to_json(%__MODULE__{} = deployment),
    do: %{"version" => deployment.version, "commit" => deployment.commit, "url" => deployment.url}
end
