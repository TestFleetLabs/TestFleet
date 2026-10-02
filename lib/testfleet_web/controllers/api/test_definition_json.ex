defmodule TestFleetWeb.API.TestDefinitionJSON do
  @moduledoc "A test definition as the API returns it (Milestone 11, section 6)."

  def show(%{test_definition: test_definition, project: project}) do
    %{
      slug: test_definition.slug,
      name: test_definition.name,
      project: project.slug,
      image: test_definition.image,
      enabled: test_definition.enabled,
      updated_at: test_definition.updated_at
    }
  end
end
