defmodule MicuPokerWeb.UserAuth do
  @moduledoc """
  Resolves the current player for both plug pipelines and LiveViews.

  Two identity sources share one session:

    * `:user_token` — a registered account, looked up through `user_tokens`
    * `:guest_user_id` — a disposable guest identity

  An account always wins. `MicuPokerWeb.Plugs.GuestSession` runs afterwards on
  app routes and creates a guest only when neither is present.

  LiveView hooks never create a user. A LiveView cannot write back to the
  session cookie, so creating one there would mint a fresh orphan row on every
  mount and every socket reconnect.
  """

  use MicuPokerWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias MicuPoker.Accounts
  alias MicuPokerWeb.UserSocket

  ## Plug pipeline

  def fetch_current_user(conn, _opts) do
    user = account_from_session(conn) || guest_from_session(conn)

    put_identity(conn, user)
  end

  @doc """
  Signs `user` in, rotating the session so a pre-login cookie cannot be replayed.
  """
  def log_in_user(conn, user, params \\ %{}) do
    token = Accounts.generate_session_token(user)
    Accounts.touch_last_login(user)

    conn
    |> renew_session()
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, "user_socket:#{user.id}")
    |> put_identity(user)
    |> redirect(to: post_login_path(params))
  end

  def log_out_user(conn) do
    conn
    |> get_session(:user_token)
    |> Accounts.delete_session_token()

    # Drop any live socket the old identity still holds open.
    if live_socket_id = get_session(conn, :live_socket_id) do
      MicuPokerWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> put_identity(nil)
    |> redirect(to: ~p"/")
  end

  def require_account(conn, _opts) do
    case conn.assigns[:current_user] do
      %{is_guest: false} ->
        conn

      _guest_or_nobody ->
        conn
        |> put_flash(:error, "Sign in to use that page.")
        |> redirect(to: ~p"/login")
        |> halt()
    end
  end

  def redirect_if_authenticated(conn, _opts) do
    case conn.assigns[:current_user] do
      %{is_guest: false} -> conn |> redirect(to: ~p"/lobby") |> halt()
      _guest_or_nobody -> conn
    end
  end

  @doc """
  Attaches a user (or nobody) to the connection.

  The socket token feeds `<meta name="socket-token">`, which is how a raw
  channel client authenticates without replaying the session cookie.
  """
  def put_identity(conn, nil) do
    conn
    |> assign(:current_user, nil)
    |> assign(:socket_token, nil)
  end

  def put_identity(conn, user) do
    conn
    |> assign(:current_user, user)
    |> assign(:socket_token, UserSocket.sign_token(user.id))
  end

  defp account_from_session(conn) do
    conn |> get_session(:user_token) |> Accounts.get_user_by_session_token()
  end

  defp guest_from_session(conn) do
    case Accounts.get_user(get_session(conn, :guest_user_id)) do
      %{is_guest: true} = guest -> guest
      _account_or_missing -> nil
    end
  end

  # Wipes the session contents but keeps the flash, so a stale guest id or a
  # replayed pre-login cookie cannot survive a sign-in or sign-out.
  defp renew_session(conn) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp post_login_path(%{"return_to" => path}) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      path
    else
      ~p"/lobby"
    end
  end

  defp post_login_path(_params), do: ~p"/lobby"

  ## LiveView

  def on_mount(:default, _params, session, socket) do
    case current_user(session) do
      nil ->
        {:halt, halt_to(socket, "Your session expired. Start again from the lobby.", ~p"/")}

      user ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    end
  end

  def on_mount(:require_account, _params, session, socket) do
    case current_user(session) do
      %{is_guest: false} = user ->
        {:cont, Phoenix.Component.assign(socket, :current_user, user)}

      _guest_or_nobody ->
        {:halt, halt_to(socket, "Sign in to use that page.", ~p"/login")}
    end
  end

  def on_mount(:mount_current_user, _params, session, socket) do
    {:cont, Phoenix.Component.assign(socket, :current_user, current_user(session))}
  end

  defp halt_to(socket, message, path) do
    socket
    |> Phoenix.LiveView.put_flash(:error, message)
    |> Phoenix.LiveView.redirect(to: path)
  end

  defp current_user(session) do
    account =
      session
      |> value(:user_token)
      |> Accounts.get_user_by_session_token()

    account || guest(session)
  end

  defp guest(session) do
    case Accounts.get_user(value(session, :guest_user_id)) do
      %{is_guest: true} = guest -> guest
      _account_or_missing -> nil
    end
  end

  defp value(session, key), do: session[to_string(key)] || session[key]
end
