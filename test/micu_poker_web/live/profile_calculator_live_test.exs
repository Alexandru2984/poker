defmodule MicuPokerWeb.ProfileCalculatorLiveTest do
  use MicuPokerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MicuPoker.{Accounts, Repo, Rooms}
  alias MicuPoker.Accounts.User

  test "GET /calculator loads odds calculator without creating a guest user row", %{conn: conn} do
    before_count = Repo.aggregate(User, :count)

    {:ok, view, html} = live(conn, ~p"/calculator")

    assert html =~ "Texas Hold&#39;em Odds &amp; Hand Calculator"
    assert html =~ "Est. Equity"
    assert html =~ "Pot Odds"
    assert Repo.aggregate(User, :count) == before_count

    # Random deal flop updates cards and analytics
    flop_html = render_click(view, :random_deal, %{"street" => "flop"})
    assert flop_html =~ "Flop texture"

    # Clear cards resets to 0/2 hole cards
    cleared_html = render_click(view, :clear_cards, %{})
    assert cleared_html =~ "Picking Hole Cards (0/2)"

    # Selecting a combo from the 13x13 preflop matrix loads those hole cards
    matrix_html = render_click(view, :select_matrix_hand, %{"r1" => "14", "r2" => "14"})
    assert matrix_html =~ "Pocket pair"
  end

  test "GET /profile shows career stats, fictional ledger history, and allows display name update",
       %{conn: conn} do
    {:ok, user} = Accounts.create_guest_user()

    {:ok, room} =
      Rooms.create_room(%{"name" => "Profile Ledger Room", "currency" => "FIC-RON"}, user.id)

    Rooms.record_dealer_adjustment(room.id, user.id, 2500, 1500, "dealer_grant")

    conn = Plug.Test.init_test_session(conn, guest_user_id: user.id)
    {:ok, view, html} = live(conn, ~p"/profile")

    assert html =~ "Player Profile &amp; Career"
    assert html =~ "Profile Ledger Room"
    assert html =~ "FIC-RON"
    assert html =~ "+1500"
    assert html =~ "Dealer fictional grant"

    updated_html =
      render_submit(view, :rename, %{"user" => %{"username" => "ProGrinder"}})

    assert updated_html =~ "ProGrinder"
  end
end
