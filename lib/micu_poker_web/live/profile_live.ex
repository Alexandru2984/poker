defmodule MicuPokerWeb.ProfileLive do
  use MicuPokerWeb, :live_view

  alias MicuPoker.{Accounts, RateLimiter, Stats}

  @rate_limit 10
  @rate_window_ms 60_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "#{user.username} · Profile & Career")
     |> assign(:stats, Stats.player_stats(user.id))
     |> assign(:ledger, Stats.player_ledger_history(user.id, 25))
     |> assign(:name_form, to_form(%{"username" => user.username}, as: :user))
     |> assign(
       :password_form,
       to_form(
         %{"current_password" => "", "password" => "", "password_confirmation" => ""},
         as: :password
       )
     )}
  end

  @impl true
  def handle_event("rename", %{"user" => %{"username" => username}}, socket) do
    user = socket.assigns.current_user

    case RateLimiter.hit({:rename_user, user.id}, @rate_limit, @rate_window_ms) do
      {:allow, _} ->
        case Accounts.rename_user(user, username) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:current_user, updated)
             |> assign(:page_title, "#{updated.username} · Profile & Career")
             |> assign(:name_form, to_form(%{"username" => updated.username}, as: :user))
             |> put_flash(:info, "Display name updated to #{updated.username}.")}

          {:error, _changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Use 2-24 letters, numbers, spaces, dashes, or underscores."
             )}
        end

      {:deny, _} ->
        {:noreply, put_flash(socket, :error, "Too many updates. Wait a moment and try again.")}
    end
  end

  def handle_event(
        "change_password",
        %{
          "password" => %{
            "current_password" => current_password,
            "password" => new_password,
            "password_confirmation" => confirmation
          }
        },
        socket
      ) do
    user = socket.assigns.current_user

    if user.is_guest do
      {:noreply, put_flash(socket, :error, "Upgrade your guest seat to set a password.")}
    else
      case RateLimiter.hit({:password_change, user.id}, 5, @rate_window_ms) do
        {:allow, _} ->
          attrs = %{
            "username" => user.username,
            "password" => new_password,
            "password_confirmation" => confirmation
          }

          case Accounts.change_password(user, current_password, attrs) do
            {:ok, updated} ->
              {:noreply,
               socket
               |> assign(:current_user, updated)
               |> assign(
                 :password_form,
                 to_form(
                   %{"current_password" => "", "password" => "", "password_confirmation" => ""},
                   as: :password
                 )
               )
               |> put_flash(:info, "Password updated.")}

            {:error, changeset} ->
              {:noreply,
               put_flash(socket, :error, "Password update failed: #{first_error(changeset)}")}
          end

        {:deny, _} ->
          {:noreply, put_flash(socket, :error, "Too many password attempts. Wait a minute.")}
      end
    end
  end

  defp first_error(changeset) do
    changeset.errors
    |> Enum.map(fn
      {:base, {message, _}} -> message
      {field, {message, _}} -> "#{field} #{message}"
    end)
    |> List.first()
    |> Kernel.||("invalid values")
  end

  defp signed(n) when is_integer(n) and n > 0, do: "+#{n}"
  defp signed(n), do: to_string(n)

  defp sign_class(n) when is_integer(n) and n > 0, do: "up"
  defp sign_class(n) when is_integer(n) and n < 0, do: "down"
  defp sign_class(_), do: ""

  defp format_reason("showdown"), do: "Showdown pot"
  defp format_reason("uncontested"), do: "Uncontested pot"
  defp format_reason("rebuy"), do: "Table rebuy"
  defp format_reason("dealer_grant"), do: "Dealer fictional grant"
  defp format_reason("dealer_adjust"), do: "Dealer stack adjustment"
  defp format_reason("dealer_reset"), do: "Dealer stack reset"
  defp format_reason(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app-shell">
      <header class="topbar">
        <div>
          <p class="eyebrow">Play-money only</p>
          <h1>Player Profile &amp; Career</h1>
        </div>
        <nav>
          <.link navigate={~p"/lobby"}>Lobby</.link>
          <.link navigate={~p"/calculator"}>Odds Calculator</.link>
          <.link navigate={~p"/leaderboard"}>Leaderboard</.link>
          <.link navigate={~p"/docs"}>Docs</.link>
        </nav>
      </header>

      <section class="notice">
        Virtual demo balances only. No deposits, withdrawals, card payments, or real-world value.
      </section>

      <section class="stat-panel" aria-label="Career poker statistics">
        <h2 class="eyebrow">Career Simulator Analytics &middot; {@current_user.username}</h2>
        <div class="stat-grid">
          <div>
            <strong class={sign_class(@stats.net_chips)}>{signed(@stats.net_chips)}</strong>
            <span>Net hand profit</span>
          </div>
          <div>
            <strong>{@stats.hands_played}</strong>
            <span>Hands played</span>
          </div>
          <div>
            <strong>{@stats.hands_won}</strong>
            <span>Hands won</span>
          </div>
          <div>
            <strong>{@stats.win_rate}%</strong>
            <span>Win rate</span>
          </div>
          <div>
            <strong>{@stats.vpip}%</strong>
            <span>VPIP</span>
          </div>
          <div>
            <strong>{@stats.pfr}%</strong>
            <span>PFR (Preflop Raise)</span>
          </div>
          <div>
            <strong>{@stats.biggest_pot}</strong>
            <span>Biggest pot won</span>
          </div>
          <div>
            <strong>{@stats.rebuys}</strong>
            <span>Rebuys</span>
          </div>
          <div>
            <strong>{@stats.dealer_grants}</strong>
            <span>Dealer grants</span>
          </div>
        </div>
      </section>

      <section class="lobby-layout">
        <aside class="control-panel">
          <h2>Identity &amp; Security</h2>
          <p class="identity-chip">
            <strong>{@current_user.username}</strong>
            <span class="badge">
              {if @current_user.is_guest, do: "guest seat", else: "registered"}
            </span>
          </p>

          <.form for={@name_form} id="profile-rename-form" phx-submit="rename">
            <.input field={@name_form[:username]} label="Display name" />
            <button type="submit">Save Display Name</button>
          </.form>

          <%= if @current_user.is_guest do %>
            <p class="range" style="margin-top: 16px;">
              You are playing on a temporary guest cookie.
              <.link navigate={~p"/register"} style="color: var(--gold);">
                Upgrade to a permanent account
              </.link>
              to protect your name and stats with a password.
            </p>
          <% else %>
            <h2>Change Password</h2>
            <.form for={@password_form} id="profile-password-form" phx-submit="change_password">
              <.input
                type="password"
                field={@password_form[:current_password]}
                label="Current password"
                required
              />
              <.input
                type="password"
                field={@password_form[:password]}
                label="New password (10+ chars)"
                required
              />
              <.input
                type="password"
                field={@password_form[:password_confirmation]}
                label="Confirm new password"
                required
              />
              <button type="submit">Update Password</button>
            </.form>
          <% end %>
        </aside>

        <section class="room-list">
          <div class="rooms-table">
            <h2 class="eyebrow">Recent Fictional Chip Ledger</h2>
            <div class="rooms-head">
              <span>Table</span><span>Currency</span><span>Delta</span><span>Event</span><span>Time (UTC)</span>
            </div>
            <%= for item <- @ledger do %>
              <div class="rooms-row">
                <strong>{item.room_name}</strong>
                <span><span class="currency-pill">{item.currency}</span></span>
                <span class={sign_class(item.delta)}>{signed(item.delta)}</span>
                <span>{format_reason(item.reason)}</span>
                <span>{Calendar.strftime(item.created_at, "%Y-%m-%d %H:%M")}</span>
              </div>
            <% end %>
            <%= if @ledger == [] do %>
              <div class="empty">
                No hands or fictional ledger events recorded yet. Join a table from the lobby!
              </div>
            <% end %>
          </div>
        </section>
      </section>
    </main>
    """
  end
end
