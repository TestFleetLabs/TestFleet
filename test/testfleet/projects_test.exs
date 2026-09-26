defmodule TestFleet.ProjectsTest do
  use TestFleet.DataCase, async: true

  import TestFleet.ProjectsFixtures

  alias TestFleet.Projects
  alias TestFleet.Projects.Project

  describe "create_project/1" do
    test "generates the slug from the name when it is empty" do
      assert {:ok, %Project{slug: "customer-portal"}} =
               Projects.create_project(%{name: "Customer Portal"})

      assert {:ok, %Project{slug: "cafe-muller-web"}} =
               Projects.create_project(%{name: "Café Müller  Web!", slug: ""})
    end

    test "keeps a slug entered by hand" do
      assert {:ok, %Project{slug: "portal"}} =
               Projects.create_project(%{name: "Customer Portal", slug: "portal"})
    end

    test "validates the slug instead of rewriting it" do
      assert {:error, changeset} = Projects.create_project(%{name: "X", slug: "Not A Slug"})
      assert %{slug: ["use lowercase letters, digits, and single dashes"]} = errors_on(changeset)

      assert {:error, changeset} = Projects.create_project(%{name: "X", slug: "new"})
      assert %{slug: ["is reserved"]} = errors_on(changeset)
    end

    test "requires a name" do
      assert {:error, changeset} = Projects.create_project(%{name: ""})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects a slug that is taken" do
      project_fixture(%{slug: "portal"})
      assert {:error, changeset} = Projects.create_project(%{name: "Other", slug: "portal"})
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end
  end

  test "update_project/2 keeps the slug when the name changes" do
    project = project_fixture(%{name: "Customer Portal"})

    assert {:ok, %Project{name: "Customer Portal 2", slug: "customer-portal"}} =
             Projects.update_project(project, %{name: "Customer Portal 2"})
  end

  test "list_projects/0 orders by name, ignoring case" do
    b = project_fixture(%{name: "billing"})
    a = project_fixture(%{name: "Accounts"})
    c = project_fixture(%{name: "Checkout"})

    assert Projects.list_projects() |> Enum.map(& &1.id) == [a.id, b.id, c.id]
  end

  test "get_project_by_slug!/1" do
    project = project_fixture(%{slug: "portal"})
    assert Projects.get_project_by_slug!("portal").id == project.id
    assert_raise Ecto.NoResultsError, fn -> Projects.get_project_by_slug!("missing") end
  end

  test "delete_project/1" do
    project = project_fixture()
    assert {:ok, _} = Projects.delete_project(project)
    assert_raise Ecto.NoResultsError, fn -> Projects.get_project!(project.id) end
  end
end
