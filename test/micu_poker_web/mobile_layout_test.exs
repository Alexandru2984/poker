defmodule MicuPokerWeb.MobileLayoutTest do
  @moduledoc """
  Guardrails for the stylesheet.

  Cheap structural checks, not a substitute for looking at the thing. They exist
  so a later edit cannot silently drop the properties that make the table usable
  on a phone.
  """

  use ExUnit.Case, async: true

  @css File.read!("assets/css/app.css")
  @table_template File.read!("lib/micu_poker_web/live/table_live.html.heex")
  @app_layout File.read!("lib/micu_poker_web/components/layouts/app.html.heex")

  test "the app layout does not render the Phoenix starter header" do
    refute @app_layout =~ "@elixirphoenix"
    refute @app_layout =~ "Get Started"
    refute @app_layout =~ "Application.spec(:phoenix"
  end

  test "seats are placed from layout-computed custom properties" do
    # The old stylesheet hard-coded .seat-1 … .seat-9, which could neither rotate
    # the table to the viewer nor fit a table with fewer than nine seats.
    assert @css =~ "left: var(--seat-x)"
    assert @css =~ "top: var(--seat-y)"
    refute @css =~ ".seat-9"
  end

  test "the table template asks the layout module for seat placement" do
    assert @table_template =~ "MicuPokerWeb.TableLayout.seat_style"
  end

  test "interactive targets meet a minimum tap size" do
    assert @css =~ "--tap: 44px"
    assert @css =~ "min-height: var(--tap)"
  end

  test "the layout respects device safe areas" do
    assert @css =~ "env(safe-area-inset-bottom"
    assert @css =~ "env(safe-area-inset-top"
    assert @css =~ "var(--safe-bottom)"
  end

  test "the action bar stays reachable at the bottom of a phone screen" do
    assert @css =~ ".action-bar"
    assert @css =~ "position: sticky"
  end

  test "the page never scrolls sideways" do
    assert @css =~ "overflow-x: hidden"
  end

  test "there is both a mobile breakpoint and a desktop one" do
    assert @css =~ "@media (max-width: 640px)"
    assert @css =~ "@media (min-width: 1024px)"
  end

  test "long content scrolls inside its own panel rather than the page" do
    assert @css =~ "overflow-y: auto"
    assert @css =~ "overflow-wrap: anywhere"
  end

  test "decorative motion is disabled for users who ask for that" do
    assert @css =~ "@media (prefers-reduced-motion: reduce)"
  end

  test "focus stays visible for keyboard users" do
    assert @css =~ ":focus-visible"
  end
end
