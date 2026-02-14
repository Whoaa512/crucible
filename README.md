<p align="center">
  <img src="assets/banner.png" alt="Crucible — Recursive LLM Code Execution for Elixir" width="700" />
</p>

<p align="center">
  <a href="https://hex.pm/packages/crucible"><img src="https://img.shields.io/hexpm/v/crucible.svg" alt="Hex.pm" /></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License" /></a>
</p>

---

> ⚠️ **Security Warning:** Crucible executes LLM-generated code via `Code.eval_string` with no sandbox. The model can access the full Elixir standard library, file system, network, and OS commands. **Do not run Crucible with untrusted input in production environments** without additional safeguards.

Crucible is a Recursive Language Model (RLM) execution engine for Elixir. It gives an LLM a stateful REPL — the model writes Elixir code, that code gets executed, the model sees the result, and the loop continues until the model arrives at a final answer.

## How it works

1. You provide a **question** (what to solve) and **input** (data to work with)
2. Crucible sends both to an LLM provider
3. The model writes Elixir code, which Crucible evaluates in a stateful REPL
4. Results feed back to the model for the next iteration
5. The loop continues until the model sets `final = "answer"` or hits the iteration limit

## Installation

### As a library

Add to your `mix.exs`:

```elixir
{:crucible, "~> 1.0"}
```

### Standalone binary (Burrito)

Crucible uses [Burrito](https://github.com/burrito-elixir/burrito) for standalone binaries:

```bash
git clone https://github.com/Whoaa512/crucible.git
cd crucible
mix deps.get
MIX_ENV=prod mix release crucible
```

Binaries are output to `burrito_out/` for your platform.

## CLI Usage

```bash
crucible run "Summarize the key points" --input data.txt --provider openai --model gpt-4o
crucible skills list                    # View cached skill snippets
crucible skills clear                   # Clear skill cache
crucible logs list                      # List trajectory logs
crucible logs cleanup --max-age 7       # Delete logs older than 7 days
crucible providers                      # List available providers
crucible version                        # Print version
crucible --help                         # Show usage
```

### Run options

| Option | Description |
|--------|-------------|
| `--input FILE` | **Required.** Input file (or `-` for stdin) |
| `--provider NAME` | LLM provider: `openai`, `anthropic`, `openrouter`, `codex` |
| `--model NAME` | Model name (provider-specific) |
| `--api-key KEY` | API key (or set via env: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, etc.) |
| `--max-iterations N` | Maximum REPL loop iterations (default: 10) |
| `--temperature F` | Sampling temperature |
| `--max-tokens N` | Max tokens per response |
| `--skills` | Enable skill caching (retrieves similar past solutions) |
| `--skills-db PATH` | Custom SQLite path for skill cache |
| `--retry` | Enable retry with exponential backoff |
| `--no-log` | Disable trajectory logging |
| `--json` | Output result as JSON |
| `--quiet` | Suppress iteration progress output |

## Library Usage

```elixir
{:ok, answer, meta} = Crucible.completion(
  "What is the average of these numbers?",
  "4, 8, 15, 16, 23, 42",
  provider: :openai,
  model: "gpt-4o",
  return_meta: true
)
```

## Skill Caching

When `--skills` is enabled, Crucible stores successful (question, code) pairs in a SQLite database. On subsequent runs, it retrieves the top-3 most similar past solutions and injects them into the system prompt, helping the model solve similar problems faster.

## Providers

| Provider | Env Variable | Notes |
|----------|-------------|-------|
| OpenAI | `OPENAI_API_KEY` | GPT-4o, GPT-4, etc. |
| Anthropic | `ANTHROPIC_API_KEY` | Claude models |
| OpenRouter | `OPENROUTER_API_KEY` | Multi-provider gateway |
| Codex | `OPENAI_API_KEY` | Codex models |

## License

MIT
