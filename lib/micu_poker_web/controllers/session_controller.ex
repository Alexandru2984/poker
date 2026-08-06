defmodule MicuPokerWeb.SessionController do
  use MicuPokerWeb, :controller

  alias MicuPoker.Accounts
  alias MicuPoker.RateLimiter
  alias MicuPokerWeb.Plugs.RemoteIp
  alias MicuPokerWeb.UserAuth

  # Deliberately tight: password verification costs ~200ms of CPU, so an
  # unbounded login endpoint is both a credential-stuffing target and a way to
  # burn the box's schedulers.
  @attempts_per_ip 10
  @attempts_per_username 5
  @window_ms :timer.minutes(15)

  def new(conn, params) do
    render(conn, :new,
      error_message: nil,
      username: "",
      return_to: safe_return_to(params["return_to"]),
      page_title: "Sign in"
    )
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password} = user_params}) do
    return_to = safe_return_to(user_params["return_to"])

    with :ok <- check_rate(conn, username),
         %{} = user <- Accounts.authenticate(username, password) do
      reset_rate(conn, username)

      conn
      |> put_flash(:info, "Welcome back, #{user.username}.")
      |> UserAuth.log_in_user(user, %{"return_to" => return_to})
    else
      {:error, :rate_limited} ->
        deny(conn, username, return_to, "Too many sign-in attempts. Try again later.")

      nil ->
        deny(conn, username, return_to, "That username and password do not match.")
    end
  end

  def create(conn, _params) do
    deny(conn, "", nil, "Enter a username and a password.")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Signed out.")
    |> UserAuth.log_out_user()
  end

  defp deny(conn, username, return_to, message) do
    conn
    |> put_status(:unauthorized)
    |> render(:new,
      error_message: message,
      username: username,
      return_to: return_to,
      page_title: "Sign in"
    )
  end

  # Budgeted per address and per username: the first stops one host from
  # spraying many accounts, the second stops many hosts from targeting one.
  defp check_rate(conn, username) do
    ip = conn.assigns[:client_ip] || RemoteIp.format(conn.remote_ip)

    with {:allow, _} <- RateLimiter.hit({:login_ip, ip}, @attempts_per_ip, @window_ms),
         {:allow, _} <-
           RateLimiter.hit(
             {:login_user, normalize(username)},
             @attempts_per_username,
             @window_ms
           ) do
      :ok
    else
      {:deny, _retry_after} -> {:error, :rate_limited}
    end
  end

  defp reset_rate(conn, username) do
    RateLimiter.reset({:login_ip, conn.assigns[:client_ip] || RemoteIp.format(conn.remote_ip)})
    RateLimiter.reset({:login_user, normalize(username)})
  end

  defp normalize(username), do: username |> to_string() |> String.trim() |> String.downcase()

  defp safe_return_to(path) when is_binary(path) do
    if String.starts_with?(path, "/") and not String.starts_with?(path, "//"), do: path
  end

  defp safe_return_to(_path), do: nil
end
