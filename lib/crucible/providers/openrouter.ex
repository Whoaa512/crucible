defmodule Crucible.Providers.OpenRouter do
  @moduledoc """
  OpenRouter OpenAI-compatible Chat Completions client.
  """

  @endpoint "https://openrouter.ai/api/v1/chat/completions"
  @default_model "anthropic/claude-sonnet-4"
  @default_temperature 0.2
  @default_max_tokens 700

  @type message :: %{required(:role) => String.t(), required(:content) => String.t()}

  @spec complete([message()], keyword()) :: String.t()
  def complete(messages, opts \\ []) when is_list(messages) do
    api_key = Keyword.get(opts, :api_key) || System.fetch_env!("OPENROUTER_API_KEY")

    body = %{
      model: Keyword.get(opts, :model, @default_model),
      messages: messages,
      temperature: Keyword.get(opts, :temperature, @default_temperature),
      max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens)
    }

    req =
      Req.new(
        url: @endpoint,
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"}
        ],
        json: body
      )

    request_fn = Keyword.get(opts, :request_fn, &Req.post/2)

    case request_fn.(req, []) do
      {:ok, %{status: 200, body: body}} ->
        body
        |> get_in(["choices", Access.at(0), "message", "content"])
        |> to_string()

      {:ok, response} ->
        raise "OpenRouter request failed with status #{response.status}: #{inspect(response.body)}"

      {:error, reason} ->
        raise "OpenRouter request error: #{inspect(reason)}"
    end
  end
end
