defmodule TestFleet.Execution.PullCoordinatorTest do
  # One pull per image reference.
  use ExUnit.Case, async: true

  alias TestFleet.Execution.PullCoordinator

  setup do
    %{server: start_supervised!({PullCoordinator, name: nil})}
  end

  # A pull that reports its start to the test and waits for `{:finish, result}`.
  defp blocking_pull(test, name) do
    fn ->
      send(test, {:started, name, self()})

      receive do
        {:finish, result} -> result
      end
    end
  end

  defp call_async(server, reference, pull) do
    Task.async(fn -> PullCoordinator.pull(reference, pull, server) end)
  end

  test "concurrent callers of one reference share one pull and its result", %{server: server} do
    test = self()
    callers = for _ <- 1..3, do: call_async(server, "suite:dev", blocking_pull(test, :one))

    assert_receive {:started, :one, pull}
    # The others joined instead of starting their own.
    _ = :sys.get_state(server)
    refute_received {:started, :one, _}

    send(pull, {:finish, :ok})
    assert Task.await_many(callers) == [:ok, :ok, :ok]
  end

  test "different references pull in parallel", %{server: server} do
    test = self()
    a = call_async(server, "a:1", blocking_pull(test, :a))
    b = call_async(server, "b:1", blocking_pull(test, :b))

    assert_receive {:started, :a, pull_a}
    assert_receive {:started, :b, pull_b}

    send(pull_b, {:finish, {:ok, :b}})
    assert Task.await(b) == {:ok, :b}
    send(pull_a, {:finish, {:ok, :a}})
    assert Task.await(a) == {:ok, :a}
  end

  test "an error reaches every waiter", %{server: server} do
    test = self()
    callers = for _ <- 1..2, do: call_async(server, "private:1", blocking_pull(test, :p))
    assert_receive {:started, :p, pull}
    _ = :sys.get_state(server)

    error = {:error, %{status: 200, message: "unauthorized", reason: :pull_failed}}
    send(pull, {:finish, error})
    assert Task.await_many(callers) == [error, error]
  end

  @tag :capture_log
  test "a crashing pull is an error for every waiter", %{server: server} do
    callers = for _ <- 1..2, do: call_async(server, "broken:1", fn -> raise "boom" end)

    for result <- Task.await_many(callers) do
      assert {:error, %{message: "image pull crashed"}} = result
    end
  end

  test "a waiter that leaves does not affect the others", %{server: server} do
    test = self()
    leaving = call_async(server, "suite:dev", blocking_pull(test, :one))
    assert_receive {:started, :one, pull}
    staying = call_async(server, "suite:dev", blocking_pull(test, :one))
    _ = :sys.get_state(server)

    # What a run's pull timeout or cancel does to its preparing task.
    Task.shutdown(leaving, :brutal_kill)

    send(pull, {:finish, :ok})
    assert Task.await(staying) == :ok
  end

  test "a finished pull is not reused: the next caller pulls again", %{server: server} do
    test = self()
    first = call_async(server, "suite:dev", blocking_pull(test, :first))
    assert_receive {:started, :first, pull}
    send(pull, {:finish, :ok})
    assert Task.await(first) == :ok

    second = call_async(server, "suite:dev", blocking_pull(test, :second))
    assert_receive {:started, :second, pull}
    send(pull, {:finish, :ok})
    assert Task.await(second) == :ok
  end
end
