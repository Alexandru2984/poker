defmodule MicuPokerWeb.HealthControllerTest do
  use MicuPokerWeb.ConnCase

  test "GET /health returns basic JSON", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert json_response(conn, 200) == %{"status" => "ok", "service" => "micupoker"}
  end
end
