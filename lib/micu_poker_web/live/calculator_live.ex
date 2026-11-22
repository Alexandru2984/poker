defmodule MicuPokerWeb.CalculatorLive do
  use MicuPokerWeb, :live_view

  alias MicuPoker.Poker.{Analytics, Card, Deck, HandSummary}

  @impl true
  def mount(_params, _session, socket) do
    full_deck = Deck.new()
    hole = [%Card{rank: 14, suit: :spades}, %Card{rank: 13, suit: :spades}]

    board = [
      %Card{rank: 11, suit: :spades},
      %Card{rank: 10, suit: :hearts},
      %Card{rank: 2, suit: :spades}
    ]

    {:ok,
     socket
     |> assign(:page_title, "Poker Odds & Hand Evaluator Calculator")
     |> assign(:full_deck, full_deck)
     |> assign(:preflop_matrix, Analytics.preflop_matrix())
     |> assign(:target_slot, "board")
     |> assign(:hole_cards, hole)
     |> assign(:board_cards, board)
     |> assign(:pot, 200)
     |> assign(:call_amount, 50)
     |> assign(:stack, 1000)
     |> assign(:big_blind, 10)
     |> recompute()}
  end

  @impl true
  def handle_event("set_target", %{"target" => target}, socket) when target in ~w(hole board) do
    {:noreply, assign(socket, :target_slot, target)}
  end

  def handle_event("select_matrix_hand", %{"r1" => r1_str, "r2" => r2_str}, socket) do
    with {r1, ""} when r1 in 2..14 <- Integer.parse(to_string(r1_str)),
         {r2, ""} when r2 in 2..14 <- Integer.parse(to_string(r2_str)) do
      high = max(r1, r2)
      low = min(r1, r2)

      hole =
        if r1 > r2 do
          [%Card{rank: high, suit: :spades}, %Card{rank: low, suit: :spades}]
        else
          [%Card{rank: high, suit: :spades}, %Card{rank: low, suit: :hearts}]
        end

      # Remove any conflicting cards from the board
      board = Enum.reject(socket.assigns.board_cards, &(&1 in hole))

      {:noreply,
       socket
       |> assign(:hole_cards, hole)
       |> assign(:board_cards, board)
       |> recompute()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("toggle_card", %{"rank" => rank_str, "suit" => suit_str}, socket) do
    with {rank, ""} when rank in 2..14 <- Integer.parse(to_string(rank_str)),
         suit when suit in [:clubs, :diamonds, :hearts, :spades] <- parse_suit(suit_str) do
      card = %Card{rank: rank, suit: suit}
      hole = socket.assigns.hole_cards
      board = socket.assigns.board_cards

      {new_hole, new_board} =
        cond do
          card in hole ->
            {List.delete(hole, card), board}

          card in board ->
            {hole, List.delete(board, card)}

          socket.assigns.target_slot == "hole" and length(hole) < 2 ->
            {hole ++ [card], board}

          socket.assigns.target_slot == "hole" and length(board) < 5 ->
            {hole, board ++ [card]}

          socket.assigns.target_slot == "board" and length(board) < 5 ->
            {hole, board ++ [card]}

          length(hole) < 2 ->
            {hole ++ [card], board}

          true ->
            {hole, board}
        end

      {:noreply,
       socket
       |> assign(:hole_cards, new_hole)
       |> assign(:board_cards, new_board)
       |> recompute()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("random_deal", %{"street" => street}, socket) do
    board_count =
      case street do
        "preflop" -> 0
        "flop" -> 3
        "turn" -> 4
        _ -> 5
      end

    shuffled = Deck.shuffle()
    {hole, rest} = Deck.deal(shuffled, 2)
    {board, _} = Deck.deal(rest, board_count)

    {:noreply,
     socket
     |> assign(:hole_cards, hole)
     |> assign(:board_cards, board)
     |> recompute()}
  end

  def handle_event("clear_cards", _params, socket) do
    {:noreply,
     socket
     |> assign(:hole_cards, [])
     |> assign(:board_cards, [])
     |> assign(:target_slot, "hole")
     |> recompute()}
  end

  def handle_event("update_numbers", params, socket) do
    pot = parse_int(params["pot"], socket.assigns.pot, 0, 1_000_000)
    call_amount = parse_int(params["call_amount"], socket.assigns.call_amount, 0, 1_000_000)
    stack = parse_int(params["stack"], socket.assigns.stack, 1, 1_000_000)
    big_blind = parse_int(params["big_blind"], socket.assigns.big_blind, 1, 10_000)

    {:noreply,
     socket
     |> assign(:pot, pot)
     |> assign(:call_amount, call_amount)
     |> assign(:stack, stack)
     |> assign(:big_blind, big_blind)
     |> recompute()}
  end

  defp recompute(socket) do
    hole = socket.assigns.hole_cards
    board = socket.assigns.board_cards

    spot =
      Analytics.evaluate_spot(
        hole,
        board,
        socket.assigns.pot,
        socket.assigns.call_amount,
        socket.assigns.stack,
        socket.assigns.big_blind
      )

    summary = HandSummary.summarize(hole, board)
    texture = HandSummary.board_texture(board)

    socket
    |> assign(:spot, spot)
    |> assign(:summary, summary)
    |> assign(:texture, texture)
  end

  defp parse_suit("clubs"), do: :clubs
  defp parse_suit("diamonds"), do: :diamonds
  defp parse_suit("hearts"), do: :hearts
  defp parse_suit("spades"), do: :spades
  defp parse_suit(_), do: nil

  defp parse_int(val, default, min, max) do
    case Integer.parse(to_string(val)) do
      {n, ""} -> n |> max(min) |> min(max)
      _ -> default
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app-shell">
      <header class="topbar">
        <div>
          <p class="eyebrow">Play-money simulator tool</p>
          <h1>Texas Hold'em Odds &amp; Hand Calculator</h1>
        </div>
        <nav>
          <.link navigate={~p"/lobby"}>Lobby</.link>
          <.link navigate={~p"/profile"}>Profile</.link>
          <.link navigate={~p"/leaderboard"}>Leaderboard</.link>
          <.link navigate={~p"/docs"}>Docs</.link>
        </nav>
      </header>

      <section class="notice">
        Interactive Texas Hold'em hand evaluator, exact next-street out counter, and pot odds simulator.
      </section>

      <section class="stat-panel" aria-label="Calculated spot analytics">
        <h2 class="eyebrow">Live Spot Read &middot; {@summary.title} ({@summary.detail})</h2>
        <div class="stat-grid">
          <div>
            <strong>{@spot.equity}%</strong>
            <span>Est. Equity ({@spot.tier})</span>
          </div>
          <div>
            <strong>{@spot.pot_odds.percent}%</strong>
            <span>Pot Odds ({@spot.pot_odds.ratio})</span>
          </div>
          <div>
            <strong>{@spot.outs}</strong>
            <span>{@spot.outs_detail}</span>
          </div>
          <div>
            <strong>{@spot.stack_bb} BB</strong>
            <span>Stack Depth {if @spot.spr, do: "(SPR #{@spot.spr})"}</span>
          </div>
          <div>
            <strong>{@texture.title}</strong>
            <span>{@texture.detail}</span>
          </div>
          <div>
            <strong>{@spot.advice}</strong>
            <span>EV Recommendation</span>
          </div>
        </div>
      </section>

      <section class="lobby-layout">
        <aside class="control-panel">
          <h2>Random Deal &amp; Pot Sizing</h2>
          <div class="preset-strip" role="group" aria-label="Random deal presets">
            <button type="button" phx-click="random_deal" phx-value-street="preflop">
              Deal Preflop
            </button>
            <button type="button" phx-click="random_deal" phx-value-street="flop">
              Deal Flop
            </button>
            <button type="button" phx-click="random_deal" phx-value-street="turn">
              Deal Turn
            </button>
            <button type="button" phx-click="random_deal" phx-value-street="river">
              Deal River
            </button>
          </div>
          <button type="button" phx-click="clear_cards" style="width: 100%; margin-bottom: 12px;">
            Clear All Cards
          </button>

          <form id="calc-numbers-form" phx-change="update_numbers" phx-submit="update_numbers">
            <label for="calc-pot">Current Pot (fictional chips)</label>
            <input id="calc-pot" type="number" name="pot" value={@pot} min="0" max="1000000" />

            <label for="calc-call">Bet to Call</label>
            <input
              id="calc-call"
              type="number"
              name="call_amount"
              value={@call_amount}
              min="0"
              max="1000000"
            />

            <label for="calc-stack">Your Remaining Stack</label>
            <input
              id="calc-stack"
              type="number"
              name="stack"
              value={@stack}
              min="1"
              max="1000000"
            />

            <label for="calc-bb">Big Blind Size</label>
            <input
              id="calc-bb"
              type="number"
              name="big_blind"
              value={@big_blind}
              min="1"
              max="10000"
            />
          </form>
        </aside>

        <section class="room-list">
          <div class="rooms-table">
            <div class="segmented">
              <button
                type="button"
                phx-click="set_target"
                phx-value-target="hole"
                class={@target_slot == "hole" && "active"}
              >
                Picking Hole Cards ({length(@hole_cards)}/2)
              </button>
              <button
                type="button"
                phx-click="set_target"
                phx-value-target="board"
                class={@target_slot == "board" && "active"}
              >
                Picking Board Cards ({length(@board_cards)}/5)
              </button>
            </div>

            <div class="calc-cards-row">
              <div>
                <span class="eyebrow">Your Hole Cards</span>
                <div class="board" style="justify-content: flex-start; margin-top: 6px;">
                  <%= for card <- Enum.map(@hole_cards, &Card.public/1) do %>
                    <button
                      type="button"
                      phx-click="toggle_card"
                      phx-value-rank={card.rank}
                      phx-value-suit={card.suit}
                      class={"card #{card.color}"}
                      title="Click to remove"
                    >
                      <span class="card-rank">{card.rank_label}</span>
                      <span class="card-suit">{card.suit_symbol}</span>
                    </button>
                  <% end %>
                  <%= for _ <- 1..(2 - length(@hole_cards))//1 do %>
                    <span class="card empty"></span>
                  <% end %>
                </div>
              </div>

              <div>
                <span class="eyebrow">Community Board</span>
                <div class="board" style="justify-content: flex-start; margin-top: 6px;">
                  <%= for card <- Enum.map(@board_cards, &Card.public/1) do %>
                    <button
                      type="button"
                      phx-click="toggle_card"
                      phx-value-rank={card.rank}
                      phx-value-suit={card.suit}
                      class={"card #{card.color}"}
                      title="Click to remove"
                    >
                      <span class="card-rank">{card.rank_label}</span>
                      <span class="card-suit">{card.suit_symbol}</span>
                    </button>
                  <% end %>
                  <%= for _ <- 1..(5 - length(@board_cards))//1 do %>
                    <span class="card empty"></span>
                  <% end %>
                </div>
              </div>
            </div>

            <h3 class="eyebrow" style="margin-top: 14px;">52-Card Deck Picker (Tap to Toggle)</h3>
            <div class="deck-picker-grid">
              <%= for raw_card <- @full_deck do %>
                <% card = Card.public(raw_card) %>
                <% selected? = raw_card in @hole_cards or raw_card in @board_cards %>
                <button
                  type="button"
                  phx-click="toggle_card"
                  phx-value-rank={card.rank}
                  phx-value-suit={card.suit}
                  class={["card mini", card.color, selected? && "active"]}
                  style={if selected?, do: "opacity: 0.32; outline: 2px solid var(--gold);"}
                  aria-label={card.label}
                >
                  <span class="card-rank">{card.rank_label}</span>
                  <span class="card-suit">{card.suit_symbol}</span>
                </button>
              <% end %>
            </div>

            <h3 class="eyebrow" style="margin-top: 18px;">
              13&times;13 Preflop Starting Hand Matrix (Tap Any Combo to Load)
            </h3>
            <p class="muted-note">
              Diagonal: Pocket Pairs &middot; Upper-right: Suited &middot; Lower-left: Offsuit
            </p>
            <div class="preflop-matrix">
              <%= for row <- @preflop_matrix do %>
                <%= for cell <- row do %>
                  <button
                    type="button"
                    phx-click="select_matrix_hand"
                    phx-value-r1={cell.r1}
                    phx-value-r2={cell.r2}
                    class={["matrix-cell", cell.tier_class]}
                    title={"#{cell.label} · #{cell.tier} (#{cell.equity}% est. equity)"}
                  >
                    {cell.label}
                  </button>
                <% end %>
              <% end %>
            </div>
          </div>
        </section>
      </section>
    </main>
    """
  end
end
