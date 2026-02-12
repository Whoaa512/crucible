defmodule Crucible.Providers.Codex do
  @moduledoc """
  OpenAI Codex provider using ChatGPT OAuth tokens.

  Uses the OpenAI Responses API with OAuth tokens from the
  Codex CLI (~/.codex/auth.json).

  This allows using ChatGPT Plus/Pro subscription models (gpt-5.2-codex,
  gpt-5.3-codex, etc.) without an API key.
  """

  @endpoint "https://api.openai.com/v1/responses"
  @default_model "gpt-5.3-codex"
  @default_temperature 0.2
  @type message :: %{required(:role) => String.t(), required(:content) => String.t()}

  @spec complete([message()], keyword()) :: String.t()
  def complete(messages, opts \\ []) when is_list(messages) do
    api_key = Keyword.get(opts, :api_key) || resolve_codex_token()

    unless api_key do
      raise "No Codex OAuth token found. Run `codex` CLI to authenticate, or set token manually."
    end

    input = messages_to_input(messages)

    body = %{
      model: Keyword.get(opts, :model, @default_model),
      input: input,
      temperature: Keyword.get(opts, :temperature, @default_temperature)
    }

    request_fn = Keyword.get(opts, :request_fn, &default_request/2)
    request_fn.(body, api_key)
  end

  defp default_request(body, api_key) do
    req =
      Req.new(
        url: @endpoint,
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"}
        ],
        json: body,
        receive_timeout: 120_000
      )

    case Req.post(req) do
      {:ok, %{status: 200, body: body}} ->
        extract_response_text(body)

      {:ok, response} ->
        raise "Codex request failed with status #{response.status}: #{inspect(response.body)}"

      {:error, reason} ->
        raise "Codex request error: #{inspect(reason)}"
    end
  end

  defp messages_to_input(messages) do
    Enum.map(messages, fn
      %{role: "system", content: content} ->
        %{role: "developer", content: content}

      %{role: role, content: content} ->
        %{role: role, content: content}
    end)
  end

  defp extract_response_text(body) when is_map(body) do
    case body do
      %{"output" => output} when is_list(output) ->
        output
        |> Enum.flat_map(fn
          %{"type" => "message", "content" => content} when is_list(content) ->
            Enum.map(content, fn
              %{"type" => "output_text", "text" => text} -> text
              _ -> ""
            end)

          _ ->
            [""]
        end)
        |> Enum.join("")
        |> String.trim()

      _ ->
        raise "Unexpected Codex response format: #{inspect(body)}"
    end
  end

  @doc """
  Resolve Codex CLI OAuth token from ~/.codex/auth.json.
  """
  @spec resolve_codex_token() :: String.t() | nil
  def resolve_codex_token do
    codex_cli_token()
  end

  defp codex_cli_token do
    path = Path.expand("~/.codex/auth.json")

    with true <- File.exists?(path),
         {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json),
         %{"access_token" => token} when is_binary(token) <- Map.get(data, "tokens") do
      token
    else
      _ -> nil
    end
  end
end
