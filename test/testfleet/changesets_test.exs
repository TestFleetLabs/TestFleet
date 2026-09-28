defmodule TestFleet.ChangesetsTest do
  # An emptied field is a nil change after cast: the forms must show an error, not
  # crash on normalizing nil (TestFleet.Changesets.update_present/3).
  use TestFleet.DataCase, async: true

  alias TestFleet.Environments.Variable
  alias TestFleet.Notifications.{Channel, Subscription}
  alias TestFleet.Registries.Registry
  alias TestFleet.Schedules.Schedule
  alias TestFleet.TestDefinitions.TestDefinition

  test "registry: name, host, and username" do
    registry = %Registry{id: 1, name: "GitLab", host: "registry.example.com", username: "deploy"}
    changeset = Registry.changeset(registry, %{"name" => "", "host" => "", "username" => " "})

    assert %{name: ["can't be blank"], host: ["can't be blank"], username: ["can't be blank"]} =
             errors_on(changeset)
  end

  test "variable: key" do
    changeset = Variable.changeset(%Variable{id: 1, key: "BASE_URL", value: "x"}, %{"key" => ""})
    assert "can't be blank" in errors_on(changeset).key
  end

  test "test definition: image" do
    test_definition = %TestDefinition{id: 1, name: "E2E", slug: "e2e", image: "suite:1"}
    changeset = TestDefinition.changeset(test_definition, %{"image" => ""})
    assert "can't be blank" in errors_on(changeset).image
  end

  test "schedule: cron expression and time zone" do
    schedule = %Schedule{
      id: 1,
      test_definition_id: 1,
      environment_id: 1,
      cron_expression: "0 6 * * *",
      timezone: "Europe/Vienna"
    }

    changeset =
      Schedule.changeset(schedule, %{"cron_expression" => "", "timezone" => ""},
        test_definition_ids: [1],
        environment_ids: [1],
        now: ~U[2026-09-28 12:00:00Z]
      )

    assert %{cron_expression: ["can't be blank"], timezone: ["can't be blank"]} =
             errors_on(changeset)
  end

  test "notification channel: name" do
    channel = %Channel{id: 1, name: "Alerts", kind: :slack, url: "https://hooks.slack.com/x"}
    changeset = Channel.changeset(channel, %{"name" => ""})
    assert "can't be blank" in errors_on(changeset).name
  end

  test "subscription: events" do
    changeset = Subscription.changeset(%Subscription{}, %{"events" => nil})
    assert "choose at least one event" in errors_on(changeset).events
  end
end
