defmodule MicuPokerWeb.Plugs.GuestSession do
  @moduledoc false

  import Plug.Conn
  alias MicuPoker.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    current_id = get_session(conn, :guest_user_id)

    case Accounts.ensure_guest_user(current_id) do
      {:ok, user} ->
        conn
        |> put_session(:guest_user_id, user.id)
        |> assign(:current_user, user)
        |> assign(
          :socket_token,
          Phoenix.Token.sign(MicuPokerWeb.Endpoint, "user socket", user.id)
        )

      {:error, _changeset} ->
        conn
    end
  end
end
