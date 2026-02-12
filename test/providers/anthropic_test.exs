defmodule Crucible.Providers.AnthropicTest do
  use ExUnit.Case, async: true

  alias Crucible.Providers.Anthropic

  test "sends Messages API request and returns text blocks" do
    messages = [
      %{role: "system", content: "You are concise."},
      %{role: "user", content: "hello"}
    ]

    request_fn = fn req, _opts ->
      send(self(), {:request, req})

      {:ok,
       %{
         status: 200,
         body: %{
           "content" => [
             %{"type" => "text", "text" => "first "},
             %{"type" => "text", "text" => "second"}
           ]
         }
       }}
    end

    assert Anthropic.complete(messages, api_key: "anthropic-key", request_fn: request_fn) ==
             "first second"

    assert_receive {:request, req}
    assert to_string(req.url) == "https://api.anthropic.com/v1/messages"
    assert req.options[:json][:model] == "claude-sonnet-4-20250514"
    assert req.options[:json][:system] == "You are concise."

    assert req.options[:json][:messages] == [
             %{role: "user", content: [%{type: "text", text: "hello"}]}
           ]

    assert req.headers["x-api-key"] == ["anthropic-key"]
    assert req.headers["anthropic-version"] == ["2023-06-01"]
  end
end
