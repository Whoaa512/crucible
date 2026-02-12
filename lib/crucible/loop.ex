defmodule Crucible.Loop do
  @moduledoc """
  Main Recursive Language Model loop (Algorithm 1 style).
  """

  alias Crucible.LLM
  alias Crucible.Logger, as: TrajectoryLogger
  alias Crucible.Repl

  @default_max_iterations 20

  @spec run(String.t(), String.t(), keyword()) :: term()
  def run(question, prompt, opts \\ []) when is_binary(question) and is_binary(prompt) do
    do_run(question, prompt, opts)
  end

  defp do_run(question, prompt, opts) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    state =
      prompt
      |> Repl.new()
      |> Repl.set_var(:question, question)
      |> Repl.set_var(:rlm_call, build_rlm_call(opts))

    messages = initial_messages(question, prompt)
    log_path = maybe_start_logger(opts)

    iterate(state, messages, 1, max_iterations, opts, log_path)
  end

  defp iterate(_state, _messages, iteration, max_iterations, _opts, _log_path)
       when iteration > max_iterations do
    raise "RLM loop exceeded max iterations (#{max_iterations}) without setting a final answer"
  end

  defp iterate(state, messages, iteration, max_iterations, opts, log_path) do
    code = llm_module(opts).complete(messages, llm_opts(opts))
    code_to_eval = extract_code(code)

    Process.put(:crucible_sub_calls, [])
    {result, stdout, new_state} = Repl.eval(state, code_to_eval)
    sub_calls = Process.get(:crucible_sub_calls, []) |> Enum.reverse()
    Process.delete(:crucible_sub_calls)

    log_iteration(log_path, iteration, code_to_eval, stdout, sub_calls)

    case final_value(new_state) do
      nil ->
        feedback = execution_feedback(result, stdout, new_state)

        next_messages =
          messages ++
            [
              %{role: "assistant", content: code_to_eval},
              %{role: "user", content: feedback}
            ]

        iterate(new_state, next_messages, iteration + 1, max_iterations, opts, log_path)

      final ->
        final
    end
  end

  defp build_rlm_call(opts) do
    fn sub_question, sub_prompt ->
      track_sub_call(sub_question, sub_prompt)

      sub_opts =
        opts
        |> Keyword.put(
          :max_iterations,
          Keyword.get(opts, :max_iterations, @default_max_iterations)
        )

      Task.async(fn -> do_run(sub_question, sub_prompt, sub_opts) end)
      |> Task.await(Keyword.get(opts, :task_timeout, 60_000))
    end
  end

  defp initial_messages(question, prompt) do
    [
      %{role: "system", content: system_prompt()},
      %{role: "user", content: prompt_metadata(question, prompt)}
    ]
  end

  defp prompt_metadata(question, prompt) do
    [
      "Question: #{question}",
      "Input metadata:",
      "- length: #{String.length(prompt)}",
      "- prefix_200: #{inspect(String.slice(prompt, 0, 200))}",
      "Write Elixir code that works only from available variables and metadata."
    ]
    |> Enum.join("\n")
  end

  defp execution_feedback(result, stdout, state) do
    [
      "Execution metadata:",
      "- result: #{inspect(result)}",
      "- stdout_length: #{String.length(stdout)}",
      "- stdout_preview_200: #{inspect(String.slice(stdout, 0, 200))}",
      "- final_set: #{not is_nil(final_value(state))}",
      "Respond with the next Elixir expression(s)."
    ]
    |> Enum.join("\n")
  end

  defp final_value(state) do
    Repl.get_var(state, :final) ||
      Repl.get_var(state, "final") ||
      Repl.get_var(state, "Final") ||
      Repl.get_var(state, :Final)
  end

  defp llm_opts(opts) do
    defaults = [
      model: Keyword.get(opts, :model, "gpt-4o-mini"),
      temperature: Keyword.get(opts, :temperature, 0.2),
      max_tokens: Keyword.get(opts, :max_tokens, 700)
    ]

    passthrough =
      Keyword.take(opts, [
        :provider,
        :api_key,
        :openai_api_key,
        :anthropic_api_key,
        :openrouter_api_key,
        :request_fn,
        :stream
      ])

    Keyword.merge(defaults, passthrough)
  end

  defp llm_module(opts), do: Keyword.get(opts, :llm_module, LLM)

  defp maybe_start_logger(opts) do
    if Keyword.get(opts, :log_trajectory, true) do
      TrajectoryLogger.new_session(opts)
    end
  end

  defp log_iteration(nil, _iteration, _code, _stdout, _sub_calls), do: :ok

  defp log_iteration(log_path, iteration, code, stdout, sub_calls) do
    TrajectoryLogger.log_iteration(log_path, %{
      iteration: iteration,
      code: code,
      stdout_preview: String.slice(stdout, 0, 200),
      sub_calls: sub_calls
    })
  end

  defp track_sub_call(sub_question, sub_prompt) do
    sub_call = %{
      question: sub_question,
      prompt_length: String.length(sub_prompt),
      prompt_prefix: String.slice(sub_prompt, 0, 120)
    }

    sub_calls = Process.get(:crucible_sub_calls, [])
    Process.put(:crucible_sub_calls, [sub_call | sub_calls])
  end

  defp extract_code(text) do
    case Regex.run(~r/```(?:elixir)?\s*(.*?)```/ms, text, capture: :all_but_first) do
      [code] -> String.trim(code)
      _ -> String.trim(text)
    end
  end

  defp system_prompt do
    """
    You are writing Elixir code for an evaluation loop.

    Rules:
    - Output only Elixir expressions, no prose.
    - Never use def, defp, defmodule, or protocol/behaviour declarations.
    - You have variables in scope: input (string prompt), question (task string), rlm_call/2 (recursive helper).
    - Use standard Elixir modules (String, Enum, Regex, Map, Kernel, etc.).
    - To finish, assign final = <answer>.

    Examples of valid patterns:
    - words = String.split(input)
      final = Enum.take(words, 5) |> Enum.join(" ")

    - chunk = String.slice(input, 0, div(String.length(input), 2))
      sub = rlm_call.("Summarize this chunk", chunk)
      final = sub

    Keep code concise and valid Elixir syntax.
    """
    |> String.trim()
  end
end
