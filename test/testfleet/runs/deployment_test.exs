defmodule TestFleet.Runs.DeploymentTest do
  # What a pipeline reports it deployed (spec section 7).
  use ExUnit.Case, async: true

  alias TestFleet.Runs.Deployment

  @commit "9fceb02d0ae598e95dc970b74767f19372d61af8"

  defp errors(params) do
    {:error, changeset} = Deployment.new(params)
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end

  describe "new/1" do
    test "takes the version, the commit, and a link" do
      assert {:ok, %Deployment{version: "1.4.2", commit: @commit, url: url}} =
               Deployment.new(%{
                 "version" => " 1.4.2 ",
                 "commit" => String.upcase(@commit),
                 "url" => "https://github.com/acme/portal/actions/runs/12"
               })

      assert url == "https://github.com/acme/portal/actions/runs/12"
    end

    test "every field is optional; none at all is no deployment" do
      assert {:ok, %Deployment{version: nil, commit: "9fceb02", url: nil}} =
               Deployment.new(%{"commit" => "9fceb02"})

      assert Deployment.new(nil) == {:ok, nil}
      assert Deployment.new(%{}) == {:ok, nil}
      assert Deployment.new(%{"version" => " ", "commit" => nil}) == {:ok, nil}
    end

    test "refuses what it cannot show safely" do
      assert %{commit: [_]} = errors(%{"commit" => "main"})
      assert %{commit: [_]} = errors(%{"commit" => "9fce"})
      assert %{url: [_]} = errors(%{"url" => "javascript:alert(1)"})
      assert %{url: [_]} = errors(%{"url" => "/actions/runs/12"})
      assert %{url: [_]} = errors(%{"url" => "https://" <> String.duplicate("a", 2_048)})
      assert %{version: [_]} = errors(%{"version" => String.duplicate("1", 101)})
      assert %{version: [_]} = errors(%{"version" => "1.4\n2"})
    end
  end

  test "label/1 names it briefly" do
    assert Deployment.label(%Deployment{version: "1.4.2", commit: @commit}) == "1.4.2 (9fceb02)"
    assert Deployment.label(%Deployment{version: "1.4.2"}) == "1.4.2"
    assert Deployment.label(%Deployment{commit: @commit}) == "9fceb02"
    assert Deployment.label(%Deployment{url: "https://ci.example.com/1"}) == nil
    assert Deployment.label(nil) == nil
  end
end
