defmodule TestFleet.Notifications.Message do
  @moduledoc """
  What a notification says, independent of where it goes (Milestone 8, section 8).
  `TestFleet.Notifications.Format` turns it into an email, Slack blocks, an Adaptive
  Card, or webhook JSON.

    * `title` - one line, e.g. "Customer Portal E2E is failing on production"
    * `summary` - one or two sentences
    * `facts` - `{label, value}` pairs
    * `link` - `%{label: ..., url: ...}`, absolute, or `nil`
    * `payload` - the event-specific part of the webhook JSON

  Messages never carry secrets, environment variables, log output, or test failure
  messages: channels are read by more people than the run page.
  """

  use Phoenix.VerifiedRoutes, endpoint: TestFleetWeb.Endpoint, router: TestFleetWeb.Router

  alias TestFleet.Notifications.Channel

  @enforce_keys [:event, :title]
  defstruct [:event, :title, :summary, :link, facts: [], payload: %{}, occurred_at: nil]

  @type t :: %__MODULE__{
          event: String.t(),
          title: String.t(),
          summary: String.t() | nil,
          facts: [{String.t(), String.t()}],
          link: %{label: String.t(), url: String.t()} | nil,
          payload: map(),
          occurred_at: DateTime.t() | nil
        }

  @doc "The message of \"Send test\"."
  def test(%Channel{} = channel, now \\ DateTime.utc_now()) do
    %__MODULE__{
      event: "test",
      title: "Test notification from TestFleet",
      summary: "The channel #{channel.name} is set up correctly.",
      facts: [{"Channel", channel.name}],
      link: %{label: "Open notifications", url: url(~p"/notifications")},
      payload: %{"channel" => %{"name" => channel.name}},
      occurred_at: DateTime.truncate(now, :second)
    }
  end
end
