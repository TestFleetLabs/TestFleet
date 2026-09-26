defmodule TestFleetWeb.PageController do
  use TestFleetWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
