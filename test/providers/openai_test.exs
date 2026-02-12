defmodule Crucible.Providers.OpenAITest do
  use ExUnit.Case, async: true

  alias Crucible.Providers.OpenAI

  test "sends OpenAI chat completions request and returns content" do
    messages = [%{role: "user", content: "hello"}]

    request_fn = fn req, _opts ->
      send(self(), {:request, req})
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "ok"}}]}}}
    end

    assert OpenAI.complete(messages, api_key: "test-key", request_fn: request_fn) == "ok"

    assert_receive {:request, req}
    assert to_string(req.url) == "https://api.openai.com/v1/chat/completions"
    assert req.options[:json][:messages] == messages
    assert req.options[:json][:model] == "gpt-4o-mini"
    assert req.headers["authorization"] == ["Bearer test-key"]
  end
end
