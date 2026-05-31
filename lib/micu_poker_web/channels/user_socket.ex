defmodule MicuPokerWeb.UserSocket do
  use Phoenix.Socket

  channel "table:*", MicuPokerWeb.TableChannel
  @socket_salt "user socket"

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case Phoenix.Token.verify(MicuPokerWeb.Endpoint, @socket_salt, token, max_age: 86_400) do
      {:ok, user_id} -> {:ok, assign(socket, :user_id, user_id)}
      {:error, _reason} -> :error
    end
  end

  def connect(_params, socket, %{session: session}) do
    case session["guest_user_id"] || session[:guest_user_id] do
      nil -> :error
      user_id -> {:ok, assign(socket, :user_id, user_id)}
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "guest:#{socket.assigns.user_id}"
end
