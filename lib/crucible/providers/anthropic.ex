defmodule Crucible.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages API client.
  """

  @endpoint "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-20250514"
  @default_temperature 0.2
  @default_max_tokens 700

  @type message :: %{required(:role) => String.t(), required(:content) => String.t()}

  @spec complete([message()], keyword()) :: String.t()
  def complete(messages, opts \\ []) when is_list(messages) do
    api_key = Keyword.get(opts, :api_key) || System.get_env("ANTHROPIC_API_KEY") ||
      raise "No Anthropic API key found. Set ANTHROPIC_API_KEY or pass :api_key option."

    {system_messages, conversation_messages} = split_system_messages(messages)

    body = %{
      model: Keyword.get(opts, :model, @default_model),
      messages: conversation_messages,
      temperature: Keyword.get(opts, :temperature, @default_temperature),
      max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens)
    }

    body =
      if system_messages == "" do
        body
      else
        Map.put(body, :system, system_messages)
      end

    req =
      Req.new(
        url: @endpoint,
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"},
          {"accept", "application/json"},
          {"content-type", "application/json"}
        ],
        json: body,
        receive_timeout: 300_000,
        pool_timeout: 10_000,
        retry: false,
        connect_options: [protocols: [:http1]]
      )

    request_fn = Keyword.get(opts, :request_fn, &Req.post/2)

    case request_fn.(req, []) do
      {:ok, %{status: 200, body: body}} ->
        extract_text(body)

      {:ok, response} ->
        raise "Anthropic request failed with status #{response.status}: #{inspect(response.body)}"

      {:error, reason} ->
        raise "Anthropic request error: #{inspect(reason)}"
    end
  end

  defp split_system_messages(messages) do
    system =
      messages
      |> Enum.filter(&(&1.role == "system"))
      |> Enum.map(& &1.content)
      |> Enum.join("\n\n")

    conversation =
      messages
      |> Enum.reject(&(&1.role == "system"))
      |> Enum.map(fn %{role: role, content: content} ->
        %{role: role, content: [%{type: "text", text: content}]}
      end)

    {system, conversation}
  end

  defp extract_text(body) do
    body
    |> Map.get("content", [])
    |> Enum.reduce([], fn item, acc ->
      case item do
        %{"type" => "text", "text" => text} when is_binary(text) -> [text | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
    |> Enum.join()
  end
end
