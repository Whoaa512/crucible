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

  test "returns error tuple on max_iterations instead of raising" do
    enqueue([
      fn _messages -> "x = 1" end,
      fn _messages -> "x = 2" end
    ])

    result =
      Loop.run("Question", "prompt",
        llm_module: Crucible.MockLLM,
        log_trajectory: false,
        max_iterations: 2
      )

    assert {:error, :max_iterations, meta} = result
    assert meta.iterations == 2
    assert meta.trajectory == nil
    assert %{code: "x = 2"} = meta.partial
  end

  test "retries LLM errors with exponential backoff when enabled" do
    enqueue([
      fn _messages -> raise "request failed with status 429: rate limited" end,
      fn _messages -> raise "request failed with status 502: bad gateway" end,
      fn _messages -> "final = \"ok\"" end
    ])

    result =
      Loop.run("Question", "prompt",
        llm_module: Crucible.MockLLM,
        log_trajectory: false,
        retry_with_backoff: true,
        llm_retries: 3,
        llm_retry_backoff_ms: 0
      )

    assert result == "ok"
  end

  defp enqueue(functions) do
    pid = Application.fetch_env!(:crucible, :mock_llm_agent)
    Agent.update(pid, fn _ -> functions end)
  end
end

defmodule Crucible.MockLLM do
  def complete(messages, opts) do
    pid = Application.fetch_env!(:crucible, :mock_llm_agent)

    next =
      Agent.get_and_update(pid, fn
        [next | rest] -> {next, rest}
        [] -> {nil, []}
      end)

    if is_nil(next) do
      raise "Mock queue exhausted"
    end

    case :erlang.fun_info(next, :arity) do
      {:arity, 2} -> next.(messages, opts)
      _ -> next.(messages)
    end
  end
end
