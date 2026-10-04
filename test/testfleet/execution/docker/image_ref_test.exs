defmodule TestFleet.Execution.Docker.ImageRefTest do
  use ExUnit.Case, async: true

  alias TestFleet.Execution.Docker.ImageRef

  @digest "sha256:" <> String.duplicate("a", 64)

  test "short Docker Hub names live under library/" do
    assert {:ok,
            %ImageRef{host: "docker.io", repository: "library/e2e", tag: "1.17", digest: nil}} =
             ImageRef.parse("e2e:1.17")
  end

  test "defaults the tag to latest" do
    assert {:ok, %ImageRef{repository: "library/alpine", tag: "latest"}} =
             ImageRef.parse("alpine")
  end

  test "Docker Hub organisations are not hosts" do
    assert {:ok, %ImageRef{host: "docker.io", repository: "testfleet/fixture-suite", tag: "dev"}} =
             ImageRef.parse("testfleet/fixture-suite:dev")
  end

  test "registry hosts" do
    assert {:ok,
            %ImageRef{host: "registry.company.com", repository: "customer-a/e2e", tag: "1.17"}} =
             ImageRef.parse("registry.company.com/customer-a/e2e:1.17")

    assert {:ok, %ImageRef{host: "localhost", repository: "suite"}} =
             ImageRef.parse("localhost/suite")

    assert {:ok,
            %ImageRef{
              host: "localhost:5000",
              repository: "fixture-suite",
              tag: nil,
              digest: @digest
            }} =
             ImageRef.parse("localhost:5000/fixture-suite@" <> @digest)

    assert {:ok, %ImageRef{host: "registry:5000", repository: "suite", tag: "1"}} =
             ImageRef.parse("registry:5000/suite:1")
  end

  test "tag and digest together" do
    assert {:ok, %ImageRef{tag: "1.17", digest: @digest}} = ImageRef.parse("e2e:1.17@" <> @digest)
  end

  test "normalizes explicit Docker Hub hosts" do
    assert {:ok, %ImageRef{host: "docker.io", repository: "library/alpine"}} =
             ImageRef.parse("index.docker.io/alpine")
  end

  test "rejects invalid references" do
    assert {:error, :invalid_reference} = ImageRef.parse("")
    assert {:error, :invalid_reference} = ImageRef.parse("e2e:")
    assert {:error, :invalid_reference} = ImageRef.parse("e2e@")
    assert {:error, :invalid_reference} = ImageRef.parse("registry.company.com/")
  end

  test "name/1 and pull_tag/1 build pull parameters" do
    {:ok, hub} = ImageRef.parse("alpine:3")
    assert {ImageRef.name(hub), ImageRef.pull_tag(hub)} == {"alpine", "3"}

    {:ok, private} = ImageRef.parse("localhost:5000/fixture-suite@" <> @digest)

    assert {ImageRef.name(private), ImageRef.pull_tag(private)} ==
             {"localhost:5000/fixture-suite", @digest}
  end

  test "repo_digest/2 picks the matching repository" do
    {:ok, ref} = ImageRef.parse("localhost:5000/fixture-suite:dev")

    assert ImageRef.repo_digest(ref, [
             "other/image@sha256:1",
             "localhost:5000/fixture-suite@" <> @digest
           ]) ==
             @digest

    assert ImageRef.repo_digest(ref, []) == nil
  end

  describe "put_tag/2" do
    test "replaces the tag and keeps the name as written" do
      assert ImageRef.put_tag("ghcr.io/acme/e2e:1.4", "1.5") == {:ok, "ghcr.io/acme/e2e:1.5"}
      assert ImageRef.put_tag("e2e:1.4", "1.5") == {:ok, "e2e:1.5"}
      assert ImageRef.put_tag("acme/e2e", "v2_rc.1") == {:ok, "acme/e2e:v2_rc.1"}
    end

    test "keeps a registry port and drops a digest" do
      assert ImageRef.put_tag("localhost:5000/suite:dev", "2") == {:ok, "localhost:5000/suite:2"}
      assert ImageRef.put_tag("localhost:5000/suite", "2") == {:ok, "localhost:5000/suite:2"}

      assert ImageRef.put_tag("localhost:5000/suite:dev@" <> @digest, "2") ==
               {:ok, "localhost:5000/suite:2"}

      assert ImageRef.put_tag("localhost:5000/suite@" <> @digest, "2") ==
               {:ok, "localhost:5000/suite:2"}
    end

    test "refuses invalid tags" do
      for tag <- ["", ".1", "-1", "1:2", "a/b", "sha256@x", String.duplicate("a", 129)] do
        assert ImageRef.put_tag("e2e:1", tag) == {:error, :invalid_tag}, inspect(tag)
      end

      assert {:ok, _} = ImageRef.put_tag("e2e:1", String.duplicate("a", 128))
    end
  end
end
