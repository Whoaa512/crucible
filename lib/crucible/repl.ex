defmodule Crucible.Repl do
  @moduledoc """
  Stateful REPL bindings for evaluating model-generated Elixir code.
  """

  @type state :: map()

  @spec new(String.t()) :: state()
  def new(prompt) when is_binary(prompt) do
    %{
      input: prompt,
      rlm_call: default_rlm_call()
    }
  end

  @spec eval(state(), String.t()) :: {term(), String.t(), state()}
  def eval(state, code) when is_map(state) and is_binary(code) do
    binding = state_to_binding(state)

    {:ok, io} = StringIO.open("")
    {:ok, io_err} = StringIO.open("")
    previous_stdio = Process.get(:stdio)
    previous_group_leader = Process.group_leader()
    previous_stderr = :erlang.whereis(:standard_error)

    Process.put(:stdio, io)
    Process.group_leader(self(), io)

    # Redirect :standard_error to suppress compile warnings/errors to terminal
    if previous_stderr, do: :erlang.unregister(:standard_error)
    :erlang.register(:standard_error, io_err)

    {result, next_state} =
      try do
        {value, new_binding} = Code.eval_string(code, binding, file: "rlm_repl")
        {value, Map.new(new_binding)}
      rescue
        exception ->
          {{:error, Exception.format(:error, exception, __STACKTRACE__)}, state}
      catch
        kind, reason ->
          {{:error, Exception.format(kind, reason, __STACKTRACE__)}, state}
      after
        Process.group_leader(self(), previous_group_leader)

        # Restore :standard_error
        :erlang.unregister(:standard_error)
        if previous_stderr, do: :erlang.register(:standard_error, previous_stderr)

        if previous_stdio do
          Process.put(:stdio, previous_stdio)
        else
          Process.delete(:stdio)
        end
      end

    {_input, output} = StringIO.contents(io)
    {_input, stderr_output} = StringIO.contents(io_err)

    # Append any captured stderr to stdout output so error info isn't lost
    combined_output = if stderr_output == "", do: output, else: output <> stderr_output
    {result, combined_output, next_state}
  end

  @spec get_var(state(), atom() | String.t()) :: term()
  def get_var(state, key) when is_map(state) and is_binary(key) do
    Map.get(state, key, Map.get(state, normalize_key(key)))
  end

  def get_var(state, key) when is_map(state) and is_atom(key), do: Map.get(state, key)

  @spec set_var(state(), atom() | String.t(), term()) :: state()
  def set_var(state, key, value) when is_map(state), do: Map.put(state, normalize_key(key), value)

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> key
    end
  end

  defp state_to_binding(state) do
    state
    |> Enum.filter(fn {key, _value} -> is_atom(key) end)
    |> Enum.sort_by(fn {key, _value} -> Atom.to_string(key) end)
  end

  defp default_rlm_call do
    fn _question, _sub_prompt ->
      raise "rlm_call/2 is not configured"
    end
  end
end
