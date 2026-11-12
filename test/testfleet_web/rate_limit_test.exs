defmodule TestFleetWeb.RateLimitTest do
  use ExUnit.Case, async: true

  alias TestFleetWeb.RateLimit

  test "allows up to the limit per key and window" do
    key = {:test, make_ref()}

    for _ <- 1..3, do: assert(:ok = RateLimit.hit(key, 3, :timer.hours(1)))
    assert {:error, :rate_limited} = RateLimit.hit(key, 3, :timer.hours(1))

    assert :ok = RateLimit.hit({:test, make_ref()}, 3, :timer.hours(1))
  end
end
