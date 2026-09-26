defmodule TestFleet.Execution.Integration.RegistryTest do
  # Spike step 6: pull from a private registry with per-pull credentials.
  # Needs: docker compose --profile spike up -d registry, and the fixture pushed to it.
  use TestFleet.DockerCase, async: true

  alias TestFleet.Execution.Docker.ImageRef

  setup_all do
    {:ok, ref} = ImageRef.parse(registry_image())

    case Command.pull(ref, registry_auth()) do
      :ok ->
        :ok

      {:error, error} ->
        raise "registry fixture unavailable (see spike spec section 9): #{error.message}"
    end
  end

  test "pulls with credentials and records the digest" do
    {result, _} =
      run!(
        image: registry_image(),
        registry_auth: registry_auth(),
        pull_policy: :auto,
        environment: %{"SPIKE_MODE" => "pass"}
      )

    assert result.status == :passed
    assert "sha256:" <> hex = result.image_digest
    assert byte_size(hex) == 64
  end

  test "wrong credentials are an error with the registry's message" do
    {result, _} =
      run!(
        image: registry_image(),
        registry_auth: %{username: "spike", password: "wrong"},
        pull_policy: :auto,
        environment: %{"SPIKE_MODE" => "pass"}
      )

    assert result.status == :error
    assert result.error_message =~ ~r/unauthorized|authentication required|no basic auth/i
    assert result.started_at == nil
  end

  test "an image referenced by digest is not pulled when it is present" do
    {:ok, ref} = ImageRef.parse(registry_image())
    {:ok, image} = Command.inspect_image(registry_image())
    digest = ImageRef.repo_digest(ref, image["RepoDigests"])

    # Wrong credentials would fail any pull, so passing proves there was none.
    {result, _} =
      run!(
        image: "#{ImageRef.name(ref)}@#{digest}",
        registry_auth: %{username: "spike", password: "wrong"},
        pull_policy: :auto,
        environment: %{"SPIKE_MODE" => "pass"}
      )

    assert result.status == :passed
    assert result.image_digest == digest
  end
end
