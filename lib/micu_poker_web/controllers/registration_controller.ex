defmodule MicuPokerWeb.RegistrationController do
  use MicuPokerWeb, :controller

  alias MicuPoker.Accounts
  alias MicuPokerWeb.UserAuth

  def new(conn, _params) do
    render(conn, :new,
      changeset: Accounts.registration_changeset(),
      upgrade?: upgrading?(conn),
      page_title: "Create account"
    )
  end

  def create(conn, %{"user" => params}) do
    params = Map.drop(params, ["is_guest", "virtual_chips", "password_hash"])

    case register(conn, params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Account created. You are signed in as #{user.username}.")
        |> UserAuth.log_in_user(user)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:new,
          changeset: %{changeset | action: :insert},
          upgrade?: upgrading?(conn),
          page_title: "Create account"
        )
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Fill in the registration form.")
    |> redirect(to: ~p"/register")
  end

  # A visitor already playing as a guest keeps the same user row, so their
  # seats, hand history and chip ledger entries carry over to the account.
  defp register(conn, params) do
    case conn.assigns[:current_user] do
      %{is_guest: true} = guest -> Accounts.upgrade_guest(guest, params)
      _account_or_nobody -> Accounts.register_user(params)
    end
  end

  defp upgrading?(conn), do: match?(%{is_guest: true}, conn.assigns[:current_user])
end
