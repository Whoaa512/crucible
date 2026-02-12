defmodule Crucible.LLMTest do
  use ExUnit.Case

  alias Crucible.LLM
  alias Crucible.Providers.Anthropic
  alias Crucible.Providers.Codex
  alias Crucible.Providers.OpenAI
  alias Crucible.Providers.OpenRouter

  setup do
    System.delete_env("ANTHROPIC_API_KEY")
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("OPENROUTER_API_KEY")

    on_exit(fn ->
      System.delete_env("ANTHROPIC_API_KEY")
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("OPENROUTER_API_KEY")
    end)

    :ok
  end

  test "uses explicit provider when provided" do
    assert LLM.resolve_provider(provider: :openrouter) == OpenRouter
  end

  test "default provider order is anthropic, then codex, then openai, then openrouter" do
    has_codex = Codex.resolve_codex_token() != nil

    System.put_env("OPENROUTER_API_KEY", "router")
    expected_without_higher = if has_codex, do: Codex, else: OpenRouter
    assert LLM.resolve_provider([]) == expected_without_higher

    System.put_env("OPENAI_API_KEY", "openai")
    expected_with_openai = if has_codex, do: Codex, else: OpenAI
    assert LLM.resolve_provider([]) == expected_with_openai

    System.put_env("ANTHROPIC_API_KEY", "anthropic")
    assert LLM.resolve_provider([]) == Anthropic
  end

  test "explicit codex provider works" do
    assert LLM.resolve_provider(provider: :codex) == Codex
  end
end
