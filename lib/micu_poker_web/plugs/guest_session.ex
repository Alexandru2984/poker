defmodule MicuPokerWeb.Plugs.GuestSession do
  @moduledoc """
  Establishes the play-money identity for app routes.

  A visitor with a valid session keeps it. A visitor without one gets a fresh
  guest user, but that path is rate limited per client IP: without a limit,
  anyone could insert an unbounded number of `users` rows just by requesting
  `/lobby` in a loop with no cookie jar.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias MicuPoker.Accounts
  alias MicuPoker.RateLimiter
  alias MicuPokerWeb.Plugs.RemoteIp

  @guest_creation_limit 30
  @guest_creation_window_ms :timer.hours(1)

  def init(opts), do: opts

  def call(conn, _opts) do
    case Accounts.get_user(get_session(conn, :guest_user_id)) do
      nil -> create_guest(conn)
      user -> assign_identity(conn, user)
    end
  end

  defp create_guest(conn) do
    if guest_creation_allowed?(conn) do
      case Accounts.create_guest_user() do
        {:ok, user} -> assign_identity(conn, user)
        {:error, _changeset} -> halt_with_error(conn, "Could not start a guest session.")
      end
    else
      halt_with_error(
        conn,
        "Too many guest sessions from this network. Try again later or sign in."
      )
    end
  end

  defp assign_identity(conn, user) do
    conn
    |> put_session(:guest_user_id, user.id)
    |> assign(:current_user, user)
    |> assign(:socket_token, MicuPokerWeb.UserSocket.sign_token(user.id))
  end

  defp guest_creation_allowed?(conn) do
    key = {:guest_create, conn.assigns[:client_ip] || RemoteIp.format(conn.remote_ip)}

    match?(
      {:allow, _remaining},
      RateLimiter.hit(key, @guest_creation_limit, @guest_creation_window_ms)
    )
  end

  defp halt_with_error(conn, message) do
    conn
    |> put_status(:too_many_requests)
    |> put_flash(:error, message)
    |> redirect(to: "/")
    |> halt()
  end
end
