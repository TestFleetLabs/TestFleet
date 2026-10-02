defmodule TestFleetWeb.UserLive.SettingsTest do
  use TestFleetWeb.ConnCase, async: true

  alias TestFleet.Accounts
  import Phoenix.LiveViewTest
  import TestFleet.AccountsFixtures

  describe "Settings page" do
    test "renders settings page", %{conn: conn} do
      {:ok, _lv, html} =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/settings")

      assert html =~ "Change email"
      assert html =~ "Save password"
    end

    test "redirects if user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/users/settings")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if user is not in sudo mode", %{conn: conn} do
      {:ok, conn} =
        conn
        |> log_in_user(user_fixture(),
          token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
        )
        |> live(~p"/users/settings")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert conn.resp_body =~ "You must re-authenticate to access this page."
    end
  end

  describe "update email form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user email", %{conn: conn, user: user} do
      new_email = unique_user_email()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => new_email}
        })
        |> render_submit()

      assert result =~ "A link to confirm your email"
      assert Accounts.get_user_by_email(user.email)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#email_form")
        |> render_change(%{
          "action" => "update_email",
          "user" => %{"email" => "with spaces"}
        })

      assert result =~ "Change email"
      assert result =~ "must have the @ sign and no spaces"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#email_form", %{
          "user" => %{"email" => user.email}
        })
        |> render_submit()

      assert result =~ "Change email"
      assert result =~ "did not change"
    end
  end

  describe "update password form" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "updates the user password", %{conn: conn, user: user} do
      new_password = valid_user_password()

      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      form =
        form(lv, "#password_form", %{
          "user" => %{
            "email" => user.email,
            "password" => new_password,
            "password_confirmation" => new_password
          }
        })

      render_submit(form)

      new_password_conn = follow_trigger_action(form, conn)

      assert redirected_to(new_password_conn) == ~p"/users/settings"

      assert get_session(new_password_conn, :user_token) != get_session(conn, :user_token)

      assert Phoenix.Flash.get(new_password_conn.assigns.flash, :info) =~
               "Password updated successfully"

      assert Accounts.get_user_by_email_and_password(user.email, new_password)
    end

    test "renders errors with invalid data (phx-change)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> element("#password_form")
        |> render_change(%{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })

      assert result =~ "Save password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end

    test "renders errors with invalid data (phx-submit)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      result =
        lv
        |> form("#password_form", %{
          "user" => %{
            "password" => "too short",
            "password_confirmation" => "does not match"
          }
        })
        |> render_submit()

      assert result =~ "Save password"
      assert result =~ "should be at least 12 character(s)"
      assert result =~ "does not match password"
    end
  end

  describe "single sign-on" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "offers to link when not linked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      assert has_element?(lv, "#sso-unlinked")
      assert has_element?(lv, "#sso-link[href='/auth/oidc/link']")
    end

    test "shows the linked account and unlinks it", %{conn: conn, user: user} do
      {:ok, _} =
        Accounts.link_identity(user, %{
          issuer: TestFleet.Accounts.OIDC.issuer(),
          subject: "abc",
          email: "ann@corp.example"
        })

      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      assert has_element?(lv, "#sso-linked", "ann@corp.example")

      lv |> element("#sso-unlink") |> render_click()
      assert has_element?(lv, "#sso-unlinked")
      refute Accounts.get_identity(user)
    end
  end

  # Milestone 11, section 8
  describe "API tokens" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "creates a token and shows it once", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      assert has_element?(lv, "#api-tokens-empty")

      lv
      |> form("#api-token-form", api_token: %{name: "GitLab deploy", expires_in: "90"})
      |> render_submit()

      [api_token] = Accounts.list_api_tokens(TestFleet.Accounts.Scope.for_user(user))
      value = lv |> element("#new-api-token-value") |> render()
      [_, token] = Regex.run(~r/value="(tf_[^"]+)"/, value)
      assert {_user, _} = Accounts.get_user_by_api_token(token)

      assert has_element?(lv, "#api_tokens-#{api_token.id}", "GitLab deploy")
      assert has_element?(lv, "#api_tokens-#{api_token.id}", api_token.hint)

      lv |> element("#dismiss-new-api-token") |> render_click()
      refute has_element?(lv, "#new-api-token")

      # Not shown again after a reload.
      {:ok, lv, _html} = live(conn, ~p"/users/settings")
      refute has_element?(lv, "#new-api-token")
    end

    test "shows errors", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      html =
        lv
        |> form("#api-token-form", api_token: %{name: ""})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute has_element?(lv, "#new-api-token")
    end

    test "revokes a token", %{conn: conn, user: user} do
      {token, api_token} = api_token_fixture(user)
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      lv |> element("#revoke-api-token-#{api_token.id}") |> render_click()

      refute has_element?(lv, "#api_tokens-#{api_token.id}")
      refute Accounts.get_user_by_api_token(token)
    end

    test "does not show other users' tokens", %{conn: conn} do
      {_token, theirs} = api_token_fixture(user_fixture())
      {:ok, lv, _html} = live(conn, ~p"/users/settings")

      refute has_element?(lv, "#api_tokens-#{theirs.id}")
    end
  end

  describe "confirm email" do
    setup %{conn: conn} do
      user = user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{conn: log_in_user(conn, user), token: token, email: email, user: user}
    end

    test "updates the user email once", %{conn: conn, user: user, token: token, email: email} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")

      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"info" => message} = flash
      assert message == "Email changed successfully."
      refute Accounts.get_user_by_email(user.email)
      assert Accounts.get_user_by_email(email)

      # use confirm token again
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
    end

    test "does not update email with invalid token", %{conn: conn, user: user} do
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/oops")
      assert {:live_redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/settings"
      assert %{"error" => message} = flash
      assert message == "Email change link is invalid or it has expired."
      assert Accounts.get_user_by_email(user.email)
    end

    test "redirects if user is not logged in", %{token: token} do
      conn = build_conn()
      {:error, redirect} = live(conn, ~p"/users/settings/confirm-email/#{token}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => message} = flash
      assert message == "You must log in to access this page."
    end
  end
end
