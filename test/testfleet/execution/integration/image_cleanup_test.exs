defmodule TestFleet.Execution.Integration.ImageCleanupTest do
  # Removing images by digest against real Docker.
  #
  # Each test commits its own image from the fixture and pushes it to the fixture
  # registry, so it has a digest reference no other test uses.
  use TestFleet.DataCase, async: true

  import TestFleet.DockerCase, only: [ensure_docker!: 0, fixture_image: 0, registry_auth: 0]
  import TestFleet.RunsFixtures

  alias TestFleet.Execution
  alias TestFleet.Execution.Docker.{Client, Command, RegistryAuth}
  alias TestFleet.ImageCleanup

  @moduletag :docker
  @repository "localhost:5055/testfleet-cleanup"

  setup_all do
    ensure_docker!()
  end

  # Returns `{image, digest}`, e.g. `{"localhost:5055/testfleet-cleanup:t123", "sha256:..."}`.
  defp pushed_image! do
    tag = "t#{System.unique_integer([:positive])}"

    {:ok, container} =
      Command.create("TestFleet-test-commit-#{tag}", %{"Image" => fixture_image()})

    on_exit(fn -> Command.remove(container) end)

    # A commit has its own creation time, so its image id is unique. The socket
    # proxy does not allow commits (TestFleet never needs them), so this one fixture
    # step uses the CLI, with DOCKER_HOST unset so it talks to the engine directly
    # instead of through the proxy.
    {output, 0} =
      System.cmd("docker", ["commit", container, "#{@repository}:#{tag}"],
        env: [{"DOCKER_HOST", nil}]
      )

    image_id = String.trim(output)

    on_exit(fn ->
      Client.request(method: :delete, url: "/images/#{image_id}", params: [force: true])
    end)

    {:ok, %{status: 200, body: progress}} =
      Client.request(
        method: :post,
        url: "/images/#{@repository}/push",
        params: [tag: tag],
        headers: RegistryAuth.headers(registry_auth(), "localhost:5055"),
        decode_body: false
      )

    refute progress =~ ~s("error")

    {:ok, %{"RepoDigests" => digests}} = Command.inspect_image(image_id)
    "#{@repository}@" <> digest = Enum.find(digests, &String.starts_with?(&1, @repository <> "@"))
    {"#{@repository}:#{tag}", digest}
  end

  defp local?(reference) do
    {:ok, references} = Execution.local_digest_references()
    MapSet.member?(references, reference)
  end

  test "removes a digest reference; removing it again is fine" do
    {image, digest} = pushed_image!()
    reference = Execution.digest_reference(image, digest)
    assert local?(reference)

    assert :ok = Command.remove_image(reference)
    refute local?(reference)
    assert :ok = Command.remove_image(reference)
  end

  test "an image a container still uses is refused with 409" do
    {image, digest} = pushed_image!()
    reference = Execution.digest_reference(image, digest)

    {:ok, container} =
      Command.create("TestFleet-test-uses-#{System.unique_integer([:positive])}", %{
        "Image" => reference
      })

    on_exit(fn -> Command.remove(container) end)

    assert {:error, %{status: 409}} = Command.remove_image(reference)
    assert local?(reference)
  end

  test "the cleanup removes a due digest and keeps a recent one" do
    {old_image, old_digest} = pushed_image!()
    {recent_image, recent_digest} = pushed_image!()
    now = DateTime.utc_now()

    run_fixture(
      image: old_image,
      image_digest: old_digest,
      inserted_at: DateTime.add(now, -30, :day)
    )

    run_fixture(image: recent_image, image_digest: recent_digest)

    assert {:ok, %{removed: 1, in_use: 0}} = ImageCleanup.run(now)
    refute local?(Execution.digest_reference(old_image, old_digest))
    assert local?(Execution.digest_reference(recent_image, recent_digest))
  end
end
