defmodule MicuPoker.Poker.TableSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias MicuPoker.Poker.TableServer

  def start_link(_opts), do: DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok), do: DynamicSupervisor.init(strategy: :one_for_one)

  def ensure_table(room_id) do
    case Registry.lookup(MicuPoker.TableRegistry, room_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {TableServer, room_id}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end
end
