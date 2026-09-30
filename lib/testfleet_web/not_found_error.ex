defmodule TestFleetWeb.NotFoundError do
  @moduledoc """
  Raised for pages that must look like they do not exist, such as `/setup` without
  its token (Milestone 10, section 4). Rendered as a 404.
  """
  defexception message: "not found", plug_status: 404
end
