defmodule MicuPokerWeb.UserAuth do
  @moduledoc false

  import Phoenix.Component
  alias MicuPoker.Accounts

  def on_mount(:default, _params, session, socket) do
    user_id = session["guest_user_id"] || session[:guest_user_id]

    case Accounts.ensure_guest_user(user_id) do
      {:ok, user} ->
        {:cont, assign(socket, :current_user, user)}

      _ ->
        {:halt, socket}
    end
  end
end
