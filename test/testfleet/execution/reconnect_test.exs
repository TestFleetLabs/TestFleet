defmodule TestFleet.Execution.ReconnectTest do
  use ExUnit.Case, async: true

  alias TestFleet.Execution.Reconnect

  @window 120_000
  @unreachable {:error, %{status: nil, message: "Docker Engine unreachable: econnrefused"}}

  test "a running container is followed again" do
    assert Reconnect.decide({:ok, %{"State" => %{"Running" => true}}}, 0, @window) == :follow
  end

  test "an exited container is finished" do
    inspect = {:ok, %{"State" => %{"Running" => false, "ExitCode" => 143}}}
    assert Reconnect.decide(inspect, 0, @window) == :exited
  end

  test "a missing container is finished as missing" do
    assert Reconnect.decide({:error, %{status: 404, message: "No such container"}}, 0, @window) ==
             :missing
  end

  test "without an answer, it asks again until the window has passed" do
    assert Reconnect.decide(@unreachable, 0, @window) == :retry
    assert Reconnect.decide(@unreachable, @window - 1, @window) == :retry
    assert Reconnect.decide(@unreachable, @window, @window) == :give_up
  end

  test "Docker's answer counts, however late" do
    assert Reconnect.decide({:ok, %{"State" => %{"Running" => true}}}, @window * 2, @window) ==
             :follow
  end
end
