defmodule Crucible do
  @moduledoc """
  Public API for Recursive Language Model completions.
  """

  alias Crucible.Loop

  @spec completion(String.t(), String.t(), keyword()) :: term()
  def completion(question, prompt, opts \\ [])
      when is_binary(question) and is_binary(prompt) and is_list(opts) do
    Loop.run(question, prompt, opts)
  end
end
