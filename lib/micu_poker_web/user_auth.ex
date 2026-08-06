defmodule MicuPokerWeb.UserAuth do
  @moduledoc """
  LiveView mount hooks that resolve the current player from the session.

  These hooks never create a user. A LiveView cannot write back to the session
  cookie, so creating one here would mint a fresh orphan row on every mount and
  on every socket reconnect. `MicuPokerWeb.Plugs.GuestSession` owns creation and
  always runs on the initial HTTP request for these routes.
  """

  use MicuPokerWeb, :verified_routes

  import Phoenix.Component
  import Phoenix.LiveView

  alias MicuPoker.Accounts

  def on_mount(:default, _params, session, socket) do
    case current_user(session) do
      nil ->
        {:halt,
         socket
         |> put_flash(:error, "Your session expired. Start again from the lobby.")
         |> redirect(to: ~p"/")}

      user ->
        {:cont, assign(socket, :current_user, user)}
    end
  end

  defp current_user(session) do
    Accounts.get_user(session["guest_user_id"] || session[:guest_user_id])
  end
end
