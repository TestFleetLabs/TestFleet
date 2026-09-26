defmodule TestFleet.Execution.Docker.RegistryAuthTest do
  use ExUnit.Case, async: true

  alias TestFleet.Execution.Docker.RegistryAuth

  test "anonymous pulls send no header" do
    assert RegistryAuth.headers(nil, "localhost:5000") == []
  end

  test "encodes credentials as URL-safe base64 JSON" do
    auth = %{username: "spike", password: "p?ss>word/+"}
    [{"x-registry-auth", header}] = RegistryAuth.headers(auth, "localhost:5000")

    refute header =~ ~r/[+\/]/

    assert header |> Base.url_decode64!() |> Jason.decode!() == %{
             "username" => "spike",
             "password" => "p?ss>word/+",
             "serveraddress" => "localhost:5000"
           }
  end

  test "Docker Hub uses its index address" do
    [{_, header}] = RegistryAuth.headers(%{username: "u", password: "p"}, "docker.io")

    assert %{"serveraddress" => "https://index.docker.io/v1/"} =
             header |> Base.url_decode64!() |> Jason.decode!()
  end
end
