defmodule Crucible.App do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:crucible, :cli_mode, false) do
      Task.start(fn ->
        code = Crucible.CLI.main(System.argv())
        System.halt(code)
      end)
    else
      Supervisor.start_link([], strategy: :one_for_one, name: Crucible.Supervisor)
    end
  end
end
