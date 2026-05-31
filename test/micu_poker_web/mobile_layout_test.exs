defmodule MicuPokerWeb.MobileLayoutTest do
  use ExUnit.Case, async: true

  test "app layout does not render the Phoenix starter header" do
    app_layout = File.read!("lib/micu_poker_web/components/layouts/app.html.heex")

    refute app_layout =~ "@elixirphoenix"
    refute app_layout =~ "Get Started"
    refute app_layout =~ "Application.spec(:phoenix"
  end

  test "mobile CSS switches the poker table from absolute seats to stacked seats" do
    css = File.read!("assets/css/app.css")

    assert css =~ "@media (max-width: 640px)"
    assert css =~ ".seat-9"
    assert css =~ "position: static"
    assert css =~ "grid-template-areas:"
  end
end
