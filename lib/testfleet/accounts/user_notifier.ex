defmodule TestFleet.Accounts.UserNotifier do
  @moduledoc """
  Account emails: invitations, magic links, and email changes. Sent only when SMTP
  is configured, from the address notifications use.
  """
  import Swoosh.Email

  alias TestFleet.Mailer
  alias TestFleet.Notifications

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"TestFleet", Notifications.email_from()})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver an invitation to set a password.
  """
  def deliver_invitation(user, url) do
    deliver(user.email, "You are invited to TestFleet", """

    ==============================

    Hi #{user.email},

    You have been invited to TestFleet. Choose your password here:

    #{url}

    The link is valid for 7 days. If you did not expect this invitation, please ignore it.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end
end
