defmodule TestFleet.Changesets do
  @moduledoc """
  Changeset helpers shared by the schemas.
  """

  @doc """
  Like `Ecto.Changeset.update_change/3`, but leaves a `nil` change alone.

  `cast/4` turns an emptied field into a `nil` change; `update_change/3` would
  pass that `nil` to `fun`, and `String.trim(nil)` crashes the form instead of
  showing "can't be blank".
  """
  def update_present(changeset, field, fun) do
    Ecto.Changeset.update_change(changeset, field, fn
      nil -> nil
      value -> fun.(value)
    end)
  end
end
