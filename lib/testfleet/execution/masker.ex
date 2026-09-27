defmodule TestFleet.Execution.Masker do
  @moduledoc """
  Replaces secret values in log lines with `[MASKED]` (main spec section 21,
  Milestone 4 section 4).

  A multi-line secret is masked line by line, since log lines never contain a
  newline. Parts shorter than 6 characters are skipped: they cannot be masked
  without masking ordinary output too (the same minimum as for saving a secret).
  Where several secrets match at the same position, the longest one is masked.
  """

  @mask "[MASKED]"
  # Keep in sync with TestFleet.Environments.Variable.min_secret_length/0; execution
  # does not depend on the configuration contexts.
  @min_length 6

  defstruct pattern: nil

  @type t :: %__MODULE__{pattern: :binary.cp() | nil}

  @spec new([String.t()]) :: t()
  def new(secret_values) do
    parts =
      secret_values
      |> Enum.flat_map(&String.split(&1, ["\r\n", "\n"]))
      |> Enum.filter(&(String.length(&1) >= @min_length))
      |> Enum.uniq()

    %__MODULE__{pattern: if(parts != [], do: :binary.compile_pattern(parts))}
  end

  @spec mask(t(), String.t()) :: String.t()
  def mask(%__MODULE__{pattern: nil}, content), do: content

  def mask(%__MODULE__{pattern: pattern}, content),
    do: :binary.replace(content, pattern, @mask, [:global])

  def mask_text, do: @mask
end
