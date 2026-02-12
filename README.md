# Crucible

Crucible is a Recursive Language Model (RLM) execution engine in Elixir. It gives an LLM a stateful REPL — the model writes Elixir code, that code gets executed, the model sees the result, and the loop continues until the model arrives at a final answer. Think of it as giving an LLM a scratchpad it can actually run.

This is useful for tasks where a single LLM call isn't enough: multi-step reasoning, data transformation, analysis that requires iteration, or problems where the model needs to try something, observe the result, and adjust.

## How it works

1. You provide a **question** (what to solve) and a **prompt** (input data).
2. The model receives metadata about the input and writes Elixir code.
3. Crucible evaluates the code in a sandboxed REPL with persistent bindings.
4. If the model sets `final = <answer>`, the loop returns that value.
5. Otherwise, execution results are fed back and the model writes more code.
6. The model can also call `rlm_call.(sub_question, sub_prompt)` to spawn recursive sub-loops.

The loop runs until convergence or a configurable iteration limit (default: 20).

## Installation

Add `crucible` to your `mix.exs`:

```elixir
def deps do
  [
    {:crucible, "~> 0.1.0"}
  ]
end
```

## Usage

### Basic

```elixir
Crucible.completion("How many words are in this text?", long_text)
# => "42"
```

### With options

```elixir
Crucible.completion("Summarize this", document,
  provider: :anthropic,
  model: "claude-sonnet-4-20250514",
  max_iterations: 10,
  temperature: 0.3
)
```

### Recursive sub-calls

The model has access to `rlm_call/2` inside the REPL. It can split work:

```elixir
# The model might generate code like:
chunks = String.split(input, "\n\n")
summaries = Enum.map(chunks, fn chunk ->
  rlm_call.("Summarize this paragraph", chunk)
end)
final = Enum.join(summaries, "\n")
```

## Provider Configuration

Crucible auto-detects your provider based on available credentials, checked in this order:

1. **Anthropic** — `ANTHROPIC_API_KEY` env var
2. **Codex** — `~/.codex/auth.json` (from OpenAI Codex CLI)
3. **OpenAI** — `OPENAI_API_KEY` env var
4. **OpenRouter** — `OPENROUTER_API_KEY` env var

Or set explicitly:

```elixir
Crucible.completion(question, prompt, provider: :openrouter)
```

You can also pass API keys directly:

```elixir
Crucible.completion(question, prompt,
  provider: :anthropic,
  api_key: "sk-ant-..."
)
```

## Architecture

```
Crucible (public API)
└── Loop (iteration engine)
    ├── LLM (provider dispatch)
    │   ├── Providers.Anthropic
    │   ├── Providers.OpenAI
    │   ├── Providers.OpenRouter
    │   └── Providers.Codex
    ├── Repl (stateful code evaluation)
    └── Logger (JSONL trajectory logging)
```

- **Loop** orchestrates the generate→execute→feedback cycle.
- **Repl** maintains variable bindings across iterations and captures stdout.
- **LLM** routes to the configured provider with consistent options.
- **Logger** writes JSONL trajectory files to `tmp/rlm_trajectories/` (disable with `log_trajectory: false`).

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `:provider` | auto-detect | `:anthropic`, `:openai`, `:openrouter`, `:codex` |
| `:model` | `"gpt-4o-mini"` | Model identifier |
| `:temperature` | `0.2` | Sampling temperature |
| `:max_tokens` | `700` | Max tokens per LLM call |
| `:max_iterations` | `20` | Loop iteration limit |
| `:log_trajectory` | `true` | Write JSONL logs |
| `:task_timeout` | `60_000` | Timeout for sub-calls (ms) |

## License

MIT — see [LICENSE](LICENSE).
