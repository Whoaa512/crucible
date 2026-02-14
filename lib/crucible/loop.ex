defmodule Crucible.Loop do
  @moduledoc """
  Main Recursive Language Model loop (Algorithm 1 style).
  """

  alias Crucible.LLM
  alias Crucible.Logger, as: TrajectoryLogger
  alias Crucible.Repl
  alias Crucible.Skills

  @default_max_iterations 20
  @default_llm_retries 3
  @default_llm_backoff_ms 200

  @type max_iterations_error ::
          {:error, :max_iterations,
           %{
             required(:partial) => map() | nil,
             required(:iterations) => non_neg_integer(),
             required(:trajectory) => String.t() | nil
           }}

  @type run_result :: term() | max_iterations_error()

  @spec run(String.t(), String.t(), keyword()) :: run_result()
  def run(question, prompt, opts \\ [])
      when is_binary(question) and is_binary(prompt) and is_list(opts) do
    do_run(question, prompt, opts)
  end

  defp do_run(question, prompt, opts) do
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    state =
      prompt
      |> Repl.new()
      |> Repl.set_var(:question, question)
      |> Repl.set_var(:rlm_call, build_rlm_call(opts))

    messages = initial_messages(question, prompt, opts)
    log_path = maybe_start_logger(opts)

    iterate(state, messages, 1, max_iterations, opts, log_path, nil, question)
  end

  defp iterate(
         _state,
         _messages,
         iteration,
         max_iterations,
         _opts,
         log_path,
         last_result,
         _question
       )
       when iteration > max_iterations do
    {:error, :max_iterations,
     %{
       partial: last_result,
       iterations: max(iteration - 1, 0),
       trajectory: log_path
     }}
  end

  defp iterate(state, messages, iteration, max_iterations, opts, log_path, _last_result, question) do
    maybe_call_on_iteration(opts, iteration)

    code = llm_complete(messages, opts)
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

        iterate(
          new_state,
          next_messages,
          iteration + 1,
          max_iterations,
          opts,
          log_path,
          %{result: result, stdout: stdout, code: code_to_eval},
          question
        )

      final ->
        :ok = Skills.store(question, code_to_eval, opts)
        maybe_wrap_success(final, iteration, log_path, opts)
    end
  end

  defp maybe_wrap_success(final, iteration, log_path, opts) do
    if Keyword.get(opts, :return_meta, false) do
      {:ok, final, %{iterations: iteration, trajectory: log_path}}
    else
      final
    end
  end

  defp maybe_call_on_iteration(opts, iteration) when is_list(opts) and is_integer(iteration) do
    case Keyword.get(opts, :on_iteration) do
      fun when is_function(fun, 1) ->
        try do
          fun.(iteration)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

      _ ->
        :ok
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

  defp initial_messages(question, prompt, opts) do
    [
      %{role: "system", content: system_prompt(question, opts)},
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

  defp system_prompt(question, opts) when is_binary(question) and is_list(opts) do
    examples = Skills.retrieve(question, opts)

    skills_section =
      if examples == [] do
        ""
      else
        rendered =
          examples
          |> Enum.with_index(1)
          |> Enum.map(fn {snippet, idx} ->
            [
              "#{idx}.",
              "```elixir",
              snippet,
              "```"
            ]
            |> Enum.join("\n")
          end)
          |> Enum.join("\n\n")

        "\n\nPreviously successful approaches:\n\n" <> rendered
      end

    ("""
     You are writing Elixir code for an evaluation loop.

     Rules:
     - Output only Elixir expressions, no prose.
     - Never use def, defp, defmodule, or protocol/behaviour declarations.
     - You have variables in scope: input (string prompt), question (task string), rlm_call/2 (recursive helper).
     - Use standard Elixir modules (String, Enum, Regex, Map, Kernel, etc.).
     - To finish, assign final = <answer>.
     """ <>
       skills_section <>
       """

       Examples of valid patterns:
       - words = String.split(input)
         final = Enum.take(words, 5) |> Enum.join(" ")

       - chunk = String.slice(input, 0, div(String.length(input), 2))
         sub = rlm_call.("Summarize this chunk", chunk)
         final = sub

       Keep code concise and valid Elixir syntax.
       """)
    |> String.trim()
  end

  defp llm_complete(messages, opts) when is_list(messages) and is_list(opts) do
    mod = llm_module(opts)
    llm_opts = llm_opts(opts)

    if Keyword.get(opts, :retry_with_backoff, false) do
      retries = Keyword.get(opts, :llm_retries, @default_llm_retries)
      base_ms = Keyword.get(opts, :llm_retry_backoff_ms, @default_llm_backoff_ms)
      complete_with_backoff(mod, messages, llm_opts, retries, base_ms, 0)
    else
      mod.complete(messages, llm_opts)
    end
  end

  defp complete_with_backoff(mod, messages, llm_opts, retries_left, base_ms, attempt)
       when is_integer(retries_left) and retries_left >= 0 and is_integer(base_ms) and
              base_ms >= 0 and
              is_integer(attempt) and attempt >= 0 do
    try do
      mod.complete(messages, llm_opts)
    rescue
      exception ->
        if retries_left > 0 and transient_error?(exception) do
          sleep_ms = trunc(base_ms * :math.pow(2, attempt))
          if sleep_ms > 0, do: Process.sleep(sleep_ms)
          complete_with_backoff(mod, messages, llm_opts, retries_left - 1, base_ms, attempt + 1)
        else
          reraise exception, __STACKTRACE__
        end
    catch
      kind, reason ->
        exception =
          cond do
            is_exception(reason) -> reason
            true -> RuntimeError.exception(Exception.format(kind, reason, __STACKTRACE__))
          end

        if retries_left > 0 and transient_error?(exception) do
          sleep_ms = trunc(base_ms * :math.pow(2, attempt))
          if sleep_ms > 0, do: Process.sleep(sleep_ms)
          complete_with_backoff(mod, messages, llm_opts, retries_left - 1, base_ms, attempt + 1)
        else
          :erlang.raise(kind, reason, __STACKTRACE__)
        end
    end
  end

  defp transient_error?(exception) do
    msg = Exception.message(exception)

    Regex.match?(~r/\bstatus\s+(429|500|502|503|504)\b/i, msg) or
      Regex.match?(~r/\bhttp\s+(429|500|502|503|504)\b/i, msg) or
      Regex.match?(~r/(timed?\s*out|timeout|etimedout|:timeout)\b/i, msg)
  end

end
