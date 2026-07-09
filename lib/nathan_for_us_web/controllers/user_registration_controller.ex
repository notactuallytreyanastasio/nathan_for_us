defmodule NathanForUsWeb.UserRegistrationController do
  use NathanForUsWeb, :controller

  alias NathanForUs.Accounts
  alias NathanForUs.Accounts.User
  alias NathanForUsWeb.UserAuth

  def new(conn, _params) do
    changeset = Accounts.change_user_registration(%User{})

    conn
    |> assign(:page_title, "Create an account")
    |> assign(
      :page_description,
      "Create a Framecut account to make, post, and vote on GIFs."
    )
    |> render(:new, changeset: changeset)
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_user_confirmation_instructions(
            user,
            &url(~p"/users/confirm/#{&1}")
          )

        # log_in_user sends its own redirect, honoring :user_return_to. A
        # redirect/2 after it raises AlreadySentError (which is also why the
        # previous explicit redirect here never took effect).
        conn
        |> put_flash(:info, "Welcome! Grab the desktop tool and rip your first video.")
        |> put_session(:show_welcome_modal, true)
        |> put_session(:user_return_to, ~p"/setup")
        |> UserAuth.log_in_user(user)

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> assign(:page_title, "Create an account")
        |> assign(
          :page_description,
          "Create a Framecut account to make, post, and vote on GIFs."
        )
        |> render(:new, changeset: changeset)
    end
  end
end
