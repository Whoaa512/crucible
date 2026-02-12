defmodule Crucible.LLM do
  @moduledoc """
  Provider dispatcher for LLM completions.
  """

  alias Crucible.Providers.Anthropic
  alias Crucible.Providers.Codex
  alias Crucible.Providers.OpenAI
  alias Crucible.Providers.OpenRouter

  @type provider :: :openai | :anthropic | :openrouter | :codex
  @type message :: %{required(:role) => String.t(), required(:content) => String.t()}

  @spec complete([message()], keyword()) :: String.t()
  def complete(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    provider = resolve_provider(opts)
    provider.complete(messages, provider_opts(provider, opts))
  end

  @spec resolve_provider(keyword()) :: module()
  def resolve_provider(opts \\ []) do
    case Keyword.get(opts, :provider) || default_provider(opts) do
      :openai ->
        OpenAI

      :anthropic ->
        Anthropic

      :openrouter ->
        OpenRouter

      :codex ->
        Codex

      nil ->
        raise "No LLM provider configured. Set ANTHROPIC_API_KEY, OPENAI_API_KEY, or OPENROUTER_API_KEY."

      other ->
        raise "Unsupported provider: #{inspect(other)}"
    end
  end

  defp default_provider(opts) do
    cond do
      anthropic_api_key(opts) -> :anthropic
      codex_token() -> :codex
      openai_api_key(opts) -> :openai
      openrouter_api_key(opts) -> :openrouter
      true -> nil
    end
  end

  defp provider_opts(provider, opts) do
    base_opts =
      opts
      |> Keyword.take([:model, :temperature, :max_tokens, :stream, :request_fn])

    case provider do
      Anthropic -> maybe_put_api_key(base_opts, anthropic_api_key(opts))
      Codex -> maybe_put_api_key(base_opts, codex_token())
      OpenAI -> maybe_put_api_key(base_opts, openai_api_key(opts))
      OpenRouter -> maybe_put_api_key(base_opts, openrouter_api_key(opts))
    end
  end

  defp maybe_put_api_key(opts, nil), do: opts
  defp maybe_put_api_key(opts, api_key), do: Keyword.put(opts, :api_key, api_key)

  defp anthropic_api_key(opts) do
    Keyword.get(opts, :anthropic_api_key) ||
      Keyword.get(opts, :api_key) ||
      System.get_env("ANTHROPIC_API_KEY")
  end

  defp openai_api_key(opts) do
    Keyword.get(opts, :openai_api_key) ||
      Keyword.get(opts, :api_key) ||
      System.get_env("OPENAI_API_KEY")
  end

  defp openrouter_api_key(opts) do
    Keyword.get(opts, :openrouter_api_key) ||
      Keyword.get(opts, :api_key) ||
      System.get_env("OPENROUTER_API_KEY")
  end

  defp codex_token do
    Codex.resolve_codex_token()
  end
end
