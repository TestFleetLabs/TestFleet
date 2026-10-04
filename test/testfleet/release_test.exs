defmodule TestFleet.ReleaseTest do
  # The release command for a lost admin account.
  use TestFleet.DataCase, async: true

  import ExUnit.CaptureIO
  import TestFleet.AccountsFixtures, only: [role: 1]

  alias TestFleet.Accounts

  test "invite_admin/1 prints a working link" do
    output = capture_io(fn -> TestFleet.Release.invite_admin("ops@example.com") end)

    assert output =~ "ops@example.com is an admin"
    [_, token] = Regex.run(~r{/users/invitations/(\S+)}, output)
    assert token |> Accounts.get_user_by_invitation_token() |> role() == :admin
  end

  test "invite_admin/1 reports an invalid email" do
    assert capture_io(fn -> TestFleet.Release.invite_admin("nope") end) =~ "Could not invite"
  end
end
