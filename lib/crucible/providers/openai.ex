defmodule Crucible.Providers.OpenAI do
  @moduledoc """
  OpenAI Chat Completions client.
  """

  @endpoint "https://api.openai.com/v1/chat/completions"
  @default_model "gpt-4o-mini"
  @default_temperature 0.2
  @default_max_tokens 700

  @type message :: %{required(:role) => String.t(), required(:content) => String.t()}

  @spec complete([message()], keyword()) :: String.t()
  def complete(messages, opts \\ []) when is_list(messages) do
    api_key = Keyword.get(opts, :api_key) || System.fetch_env!("OPENAI_API_KEY")

    body = %{
      model: Keyword.get(opts, :model, @default_model),
      messages: messages,
      temperature: Keyword.get(opts, :temperature, @default_temperature),
      max_tokens: Keyword.get(opts, :max_tokens, @default_max_tokens),
      stream: Keyword.get(opts, :stream, false)
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

    if body.stream do
      stream_complete(req, request_fn)
    else
      complete_once(req, request_fn)
    end
  end

  defp complete_once(req, request_fn) do
    case request_fn.(req, []) do
      {:ok, %{status: 200, body: body}} ->
        body
        |> get_in(["choices", Access.at(0), "message", "content"])
        |> to_string()

      {:ok, response} ->
        raise "OpenAI request failed with status #{response.status}: #{inspect(response.body)}"

      {:error, reason} ->
        raise "OpenAI request error: #{inspect(reason)}"
    end
  end

  defp stream_complete(req, request_fn) do
    ref = make_ref()
    Process.put({__MODULE__, ref, :buffer}, "")
    Process.put({__MODULE__, ref, :chunks}, [])

    into = fn
      {:data, data}, {request, response} ->
        parse_stream_chunk(ref, data)
        {:cont, {request, response}}

      {:done, _}, {request, response} ->
        {:cont, {request, response}}
    end

    case request_fn.(req, into: into) do
      {:ok, %{status: 200}} ->
        chunks = Process.get({__MODULE__, ref, :chunks}, [])
        cleanup_stream_state(ref)
        Enum.reverse(chunks) |> Enum.join()

      {:ok, response} ->
        cleanup_stream_state(ref)

        raise "OpenAI stream request failed with status #{response.status}: #{inspect(response.body)}"

      {:error, reason} ->
        cleanup_stream_state(ref)
        raise "OpenAI stream request error: #{inspect(reason)}"
    end
  end

  defp parse_stream_chunk(ref, data) do
    buffer = Process.get({__MODULE__, ref, :buffer}, "") <> data

    lines = String.split(buffer, "\n")

    case lines do
      [] ->
        :ok

      _ ->
        {complete_lines, rest} = Enum.split(lines, max(length(lines) - 1, 0))
        Enum.each(complete_lines, &parse_stream_line(ref, &1))
        Process.put({__MODULE__, ref, :buffer}, List.first(rest) || "")
    end
  end

  defp parse_stream_line(_ref, ""), do: :ok

  defp parse_stream_line(_ref, "data: [DONE]"), do: :ok

  defp parse_stream_line(ref, "data: " <> json) do
    case Jason.decode(json) do
      {:ok, payload} ->
        case get_in(payload, ["choices", Access.at(0), "delta", "content"]) do
          text when is_binary(text) and text != "" ->
            chunks = Process.get({__MODULE__, ref, :chunks}, [])
            Process.put({__MODULE__, ref, :chunks}, [text | chunks])

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp parse_stream_line(_ref, _line), do: :ok

  defp cleanup_stream_state(ref) do
    Process.delete({__MODULE__, ref, :buffer})
    Process.delete({__MODULE__, ref, :chunks})
  end
end
