defmodule MicuPokerWeb.UserSocket do
  use Phoenix.Socket

  alias MicuPoker.Accounts
  alias MicuPoker.RateLimiter
  alias MicuPokerWeb.Plugs.RemoteIp

  channel "table:*", MicuPokerWeb.TableChannel

  @socket_salt "user socket"
  @token_max_age 86_400

  @connect_limit 60
  @connect_window_ms :timer.minutes(1)

  @doc """
  Signs the short-lived token embedded in `<meta name="socket-token">`.
  """
  def sign_token(user_id) do
    Phoenix.Token.sign(MicuPokerWeb.Endpoint, @socket_salt, user_id)
  end

  @impl true
  def connect(params, socket, connect_info) do
    if connect_allowed?(connect_info) do
      authenticate(params, socket, connect_info)
    else
      :error
    end
  end

  defp authenticate(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case Phoenix.Token.verify(MicuPokerWeb.Endpoint, @socket_salt, token, max_age: @token_max_age) do
      {:ok, user_id} -> assign_existing_user(socket, user_id)
      {:error, _reason} -> :error
    end
  end

  defp authenticate(_params, socket, %{session: session}) when is_map(session) do
    case session["guest_user_id"] || session[:guest_user_id] do
      nil -> :error
      user_id -> assign_existing_user(socket, user_id)
    end
  end

  defp authenticate(_params, _socket, _connect_info), do: :error

  # A token stays valid for a day, but the user behind it may have been removed
  # by the guest janitor in the meantime. Reject rather than seat a ghost.
  defp assign_existing_user(socket, user_id) do
    case Accounts.get_user(user_id) do
      nil -> :error
      user -> {:ok, assign(socket, :user_id, user.id)}
    end
  end

  defp connect_allowed?(connect_info) do
    key = {:socket_connect, RemoteIp.from_connect_info(connect_info)}

    match?({:allow, _remaining}, RateLimiter.hit(key, @connect_limit, @connect_window_ms))
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.user_id}"
end
