defmodule Crucible.LoopTest do
  use ExUnit.Case

  alias Crucible.Loop

  setup do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    Application.put_env(:crucible, :mock_llm_agent, pid)

    on_exit(fn ->
      Application.delete_env(:crucible, :mock_llm_agent)
      if Process.alive?(pid), do: Agent.stop(pid)
    end)

    :ok
  end

  test "returns final when model sets final variable" do
    enqueue([fn _messages -> "final = \"done\"" end])

    result =
      Loop.run("Summarize", "some very long prompt",
        llm_module: Crucible.MockLLM,
        log_trajectory: false
      )

    assert result == "done"
  end

  test "retries when eval fails and feeds execution metadata back" do
    enqueue([
      fn _messages -> "this is not valid elixir" end,
      fn messages ->
        last = List.last(messages)
        assert last.role == "user"
        assert String.contains?(last.content, "Execution metadata")
        assert String.contains?(last.content, "error")
        "final = \"recovered\""
      end
    ])

    result =
      Loop.run("Question", "prompt",
        llm_module: Crucible.MockLLM,
        log_trajectory: false,
        max_iterations: 3
      )

    assert result == "recovered"
  end

  test "passes provider options through to llm module" do
    enqueue([
      fn _messages, opts ->
        assert opts[:provider] == :openrouter
        assert opts[:openrouter_api_key] == "router-key"
        "final = \"provider-ok\""
      end
    ])

    result =
      Loop.run("Question", "prompt",
        llm_module: Crucible.MockLLM,
        log_trajectory: false,
        provider: :openrouter,
        openrouter_api_key: "router-key"
      )

    assert result == "provider-ok"
  end

  defp enqueue(functions) do
    pid = Application.fetch_env!(:crucible, :mock_llm_agent)
    Agent.update(pid, fn _ -> functions end)
  end
end

defmodule Crucible.MockLLM do
  def complete(messages, opts) do
    pid = Application.fetch_env!(:crucible, :mock_llm_agent)

    Agent.get_and_update(pid, fn
      [next | rest] ->
        result =
          case :erlang.fun_info(next, :arity) do
            {:arity, 2} -> next.(messages, opts)
            _ -> next.(messages)
          end

        {result, rest}

      [] ->
        raise "Mock queue exhausted"
    end)
  end
end
