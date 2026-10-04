defmodule TestFleet.Notifications.TransitionsTest do
  # Every row of the rules.
  use ExUnit.Case, async: true

  alias TestFleet.Notifications.Transitions

  defp run(status, id \\ 1), do: %{id: id, status: status}

  # `earlier` is the series before the run, oldest first; picks the two
  # comparisons the way Notifications.evaluate_run/1 queries them.
  defp event(status, earlier) do
    newest_first = Enum.reverse(earlier)
    verdict = Enum.find(newest_first, &(&1.status in Transitions.verdict_statuses()))
    outcome = Enum.find(newest_first, &(&1.status != :cancelled))

    case Transitions.event(run(status, 100), verdict, outcome) do
      :none -> :none
      {event, previous} -> {event, previous && previous.status}
    end
  end

  describe "red" do
    test "after green, or as the first run, is failing" do
      assert event(:failed, [run(:passed)]) == {"run.failing", :passed}
      assert event(:failed, []) == {"run.failing", nil}
      assert event(:timeout, [run(:passed)]) == {"run.failing", :passed}
    end

    test "after red is still failing: nothing" do
      assert event(:failed, [run(:failed)]) == :none
      assert event(:timeout, [run(:failed)]) == :none
      assert event(:failed, [run(:timeout)]) == :none
    end

    test "errors and cancels in between do not count" do
      assert event(:failed, [run(:failed), run(:error), run(:cancelled)]) == :none
      assert event(:failed, [run(:passed), run(:error), run(:error)]) == {"run.failing", :passed}
    end
  end

  describe "green" do
    test "after red is recovered" do
      assert event(:passed, [run(:failed)]) == {"run.recovered", :failed}
      assert event(:passed, [run(:timeout)]) == {"run.recovered", :timeout}
    end

    test "after red with errors in between is recovered" do
      assert event(:passed, [run(:failed), run(:error), run(:cancelled)]) ==
               {"run.recovered", :failed}
    end

    test "after green, or as the first run, is nothing" do
      assert event(:passed, [run(:passed)]) == :none
      assert event(:passed, []) == :none
      assert event(:passed, [run(:passed), run(:error)]) == :none
    end
  end

  describe "error" do
    test "after anything but an error, or as the first run, is reported" do
      assert event(:error, [run(:passed)]) == {"run.error", :passed}
      assert event(:error, [run(:failed)]) == {"run.error", :failed}
      assert event(:error, []) == {"run.error", nil}
    end

    test "after an error is nothing, also with cancels in between" do
      assert event(:error, [run(:error)]) == :none
      assert event(:error, [run(:error), run(:cancelled)]) == :none
    end
  end

  test "a cancelled run is nothing" do
    assert event(:cancelled, [run(:passed)]) == :none
    assert event(:cancelled, [run(:failed)]) == :none
    assert event(:cancelled, []) == :none
  end
end
