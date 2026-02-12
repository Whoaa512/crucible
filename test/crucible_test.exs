defmodule CrucibleTest do
  use ExUnit.Case

  test "completion delegates to loop" do
    result = Crucible.completion("question", "prompt", llm_module: MockLLM, log_trajectory: false)
    assert result == "ok"
  end
end

defmodule MockLLM do
  def complete(_messages, _opts), do: "final = \"ok\""
end
