defmodule Crucible.ReplTest do
  use ExUnit.Case, async: true

  alias Crucible.Repl

  test "evals simple expressions and returns result" do
    state = Repl.new("hello")
    {result, stdout, new_state} = Repl.eval(state, "String.length(input)")

    assert result == 5
    assert stdout == ""
    assert Repl.get_var(new_state, :input) == "hello"
  end

  test "preserves bindings across evaluations" do
    state = Repl.new("abc")
    {_result, _stdout, state} = Repl.eval(state, "count = String.length(input)")
    {result, _stdout, state} = Repl.eval(state, "count + 2")

    assert result == 5
    assert Repl.get_var(state, :count) == 3
  end

  test "captures stdout from evaluated code" do
    state = Repl.new("anything")
    {result, stdout, _state} = Repl.eval(state, "IO.puts(\"line\")\n:ok")

    assert result == :ok
    assert stdout == "line\n"
  end
end
