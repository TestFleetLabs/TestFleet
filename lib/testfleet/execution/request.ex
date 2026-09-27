defmodule TestFleet.Execution.Request do
  @moduledoc """
  Everything needed to execute one run (main spec section 14).

  `pull_policy` defaults to `:auto`: images referenced by digest are pulled only when
  missing locally, images referenced by tag are always pulled (main spec section 39).
  `:if_missing` and `:never` exist for locally built images.
  """

  # Holds decrypted variables and registry credentials. `secret_keys` names the
  # variables in `environment` whose values are masked in the output.
  @derive {Inspect, except: [:environment, :registry_auth]}
  @enforce_keys [:run_id, :image]
  defstruct [
    :run_id,
    :image,
    :project_id,
    :environment_name,
    :registry_auth,
    :artifact_path,
    :cpu_limit,
    :memory_limit,
    command: [],
    environment: %{},
    timeout_seconds: 1800,
    stop_grace_seconds: 30,
    shm_size: 2_147_483_648,
    pull_policy: :auto,
    secret_keys: []
  ]

  @type t :: %__MODULE__{
          run_id: pos_integer(),
          image: String.t(),
          project_id: pos_integer() | nil,
          environment_name: String.t() | nil,
          registry_auth: %{username: String.t(), password: String.t()} | nil,
          artifact_path: Path.t() | nil,
          cpu_limit: number() | nil,
          memory_limit: pos_integer() | nil,
          command: [String.t()],
          environment: %{optional(String.t()) => String.t()},
          timeout_seconds: pos_integer(),
          stop_grace_seconds: non_neg_integer(),
          shm_size: pos_integer(),
          pull_policy: :auto | :always | :if_missing | :never,
          secret_keys: [String.t()]
        }

  def new(attrs), do: struct!(__MODULE__, attrs)
end
