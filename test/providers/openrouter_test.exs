defmodule Crucible.Providers.OpenRouterTest do
  use ExUnit.Case, async: true

  alias Crucible.Providers.OpenRouter

  test "sends OpenRouter chat request and returns content" do
    messages = [%{role: "user", content: "hello"}]

    request_fn = fn req, _opts ->
      send(self(), {:request, req})
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "router-ok"}}]}}}
    end

    assert OpenRouter.complete(messages, api_key: "router-key", request_fn: request_fn) ==
             "router-ok"

    assert_receive {:request, req}
    assert to_string(req.url) == "https://openrouter.ai/api/v1/chat/completions"
    assert req.options[:json][:messages] == messages
    assert req.options[:json][:model] == "anthropic/claude-sonnet-4"
    assert req.headers["authorization"] == ["Bearer router-key"]
  end
end
