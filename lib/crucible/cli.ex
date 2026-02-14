defmodule Crucible.CLI do
  @moduledoc """
  CLI entrypoint for the Crucible library.

  Intended for use in Burrito-wrapped releases (standalone binaries).
  """

  alias Crucible.Logger, as: TrajectoryLogger
  alias Crucible.Providers.Codex
  alias Crucible.Skills

  @type exit_code :: non_neg_integer()

  @doc """
  Run the CLI with argv, returning an exit code.
  """
  @spec main([String.t()]) :: exit_code()
  def main(argv) when is_list(argv) do
    case argv do
      ["run" | rest] -> cmd_run(rest)
      ["skills" | rest] -> cmd_skills(rest)
      ["logs" | rest] -> cmd_logs(rest)
      ["providers" | _rest] -> cmd_providers()
      ["version" | _rest] -> cmd_version()
      ["--help"] -> usage()
      ["-h"] -> usage()
      ["help"] -> usage()
      _ -> usage_error()
    end
  end

  defp cmd_run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv,
        strict: [
          input: :string,
          provider: :string,
          model: :string,
          api_key: :string,
          max_iterations: :integer,
          temperature: :float,
          max_tokens: :integer,
          skills: :boolean,
          skills_db: :string,
          retry: :boolean,
          no_log: :boolean,
          json: :boolean,
          quiet: :boolean
        ],
        aliases: [
          i: :input,
          p: :provider,
          m: :model,
          q: :quiet
        ]
      )

    if invalid != [] do
      IO.puts(:stderr, "Invalid options: #{inspect(invalid)}")
      1
    else
      question =
        case args do
          [q] when is_binary(q) and q != "" -> q
          _ -> nil
        end

      input_path = Keyword.get(opts, :input)

      cond do
        is_nil(question) ->
          IO.puts(:stderr, "Missing required question argument.")
          1

        is_nil(input_path) or input_path == "" ->
          IO.puts(:stderr, "Missing required --input/-i (file path or '-' for stdin).")
          1

        true ->
          quiet? = Keyword.get(opts, :quiet, false) == true
          json? = Keyword.get(opts, :json, false) == true

          case read_input(input_path) do
          {:error, msg} ->
            IO.puts(:stderr, msg)
            1

          {:ok, input} ->
            loop_opts =
              []
              |> maybe_put_provider(Keyword.get(opts, :provider))
              |> maybe_put(:model, Keyword.get(opts, :model))
              |> maybe_put(:api_key, Keyword.get(opts, :api_key))
              |> maybe_put(:max_iterations, Keyword.get(opts, :max_iterations))
              |> maybe_put(:temperature, Keyword.get(opts, :temperature))
              |> maybe_put(:max_tokens, Keyword.get(opts, :max_tokens))
              |> maybe_put(:skills, Keyword.get(opts, :skills))
              |> maybe_put(:skills_db_path, Keyword.get(opts, :skills_db))
              |> maybe_put(:retry_with_backoff, Keyword.get(opts, :retry))
              |> maybe_put(:log_trajectory, not (Keyword.get(opts, :no_log, false) == true))
              |> Keyword.put(:return_meta, true)
              |> maybe_put_on_iteration(quiet?)

            case completion_fun().(question, input, loop_opts) do
              {:ok, answer, meta} ->
                print_run_result(answer, meta, json?, quiet?)
                0

              {:error, :max_iterations, meta} when is_map(meta) ->
                IO.puts(:stderr, inspect(meta))
                1

              other ->
                IO.puts(:stderr, "Unexpected result: #{inspect(other)}")
                1
            end
          end
      end
    end
  end

  defp completion_fun do
    case Application.get_env(:crucible, :completion_fun) do
      fun when is_function(fun, 3) -> fun
      _ -> &Crucible.completion/3
    end
  end

  defp print_run_result(answer, meta, json?, quiet?) do
    answer_str = stringify_answer(answer)
    iterations = Map.get(meta, :iterations)
    trajectory = Map.get(meta, :trajectory)

    if json? do
      IO.puts(
        Jason.encode!(%{
          answer: answer_str,
          iterations: iterations,
          trajectory: trajectory
        })
      )
    else
      if not quiet? and is_integer(iterations) do
        IO.puts(:stderr, "iterations: #{iterations}")
      end

      IO.puts(answer_str)

      if not quiet? and is_binary(trajectory) do
        IO.puts(:stderr, "trajectory: #{trajectory}")
      end
    end
  end

  defp cmd_skills(argv) do
    case argv do
      ["list" | rest] ->
        {opts, _args, invalid} =
          OptionParser.parse(rest,
            strict: [skills_db: :string],
            aliases: []
          )

        if invalid != [] do
          IO.puts(:stderr, "Invalid options: #{inspect(invalid)}")
          1
        else
          db = Keyword.get(opts, :skills_db)

          case Skills.list(maybe_skills_db_opts(db)) do
            {:ok, entries} ->
              entries
              |> Enum.each(fn e ->
                inserted_at = format_unix(e.inserted_at)
                preview = snippet_preview(e.snippet)
                IO.puts("#{inserted_at}\t#{preview}\t#{e.question}")
              end)

              0

            {:error, reason} ->
              IO.puts(:stderr, "Failed to list skills: #{inspect(reason)}")
              1
          end
        end

      ["clear" | rest] ->
        {opts, _args, invalid} =
          OptionParser.parse(rest,
            strict: [skills_db: :string],
            aliases: []
          )

        if invalid != [] do
          IO.puts(:stderr, "Invalid options: #{inspect(invalid)}")
          1
        else
          db = Keyword.get(opts, :skills_db)

          case Skills.clear(maybe_skills_db_opts(db)) do
            {:ok, deleted} ->
              IO.puts("deleted: #{deleted}")
              0

            {:error, reason} ->
              IO.puts(:stderr, "Failed to clear skills: #{inspect(reason)}")
              1
          end
        end

      ["export" | rest] ->
        {opts, _args, invalid} =
          OptionParser.parse(rest,
            strict: [skills_db: :string],
            aliases: []
          )

        if invalid != [] do
          IO.puts(:stderr, "Invalid options: #{inspect(invalid)}")
          1
        else
          db = Keyword.get(opts, :skills_db)

          case Skills.export(maybe_skills_db_opts(db)) do
            {:ok, entries} ->
              IO.puts(Jason.encode!(entries))
              0

            {:error, reason} ->
              IO.puts(:stderr, "Failed to export skills: #{inspect(reason)}")
              1
          end
        end

      _ ->
        IO.puts(:stderr, "Usage: crucible skills (list|clear|export) [--skills-db PATH]")
        1
    end
  end

  defp cmd_logs(argv) do
    case argv do
      ["list" | _rest] ->
        dir = "tmp/rlm_trajectories"

        if File.dir?(dir) do
          dir
          |> File.ls!()
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.sort()
          |> Enum.each(fn f -> IO.puts(Path.join(dir, f)) end)
        end

        0

      ["cleanup" | rest] ->
        {opts, _args, invalid} =
          OptionParser.parse(rest,
            strict: [max_age: :integer],
            aliases: []
          )

        if invalid != [] do
          IO.puts(:stderr, "Invalid options: #{inspect(invalid)}")
          1
        else
          days =
            case Keyword.get(opts, :max_age) do
              n when is_integer(n) and n >= 0 -> n
              _ -> nil
            end

          if is_nil(days) do
            IO.puts(:stderr, "Missing required --max-age DAYS (integer >= 0).")
            1
          else
            case TrajectoryLogger.cleanup(max_age_days: days) do
              {:ok, deleted} ->
                IO.puts("deleted: #{deleted}")
                0

              other ->
                IO.puts(:stderr, "Cleanup failed: #{inspect(other)}")
                1
            end
          end
        end

      _ ->
        IO.puts(:stderr, "Usage: crucible logs (list|cleanup --max-age DAYS)")
        1
    end
  end

  defp cmd_providers do
    rows = [
      provider_row("anthropic", System.get_env("ANTHROPIC_API_KEY"), "ANTHROPIC_API_KEY"),
      provider_row("openai", System.get_env("OPENAI_API_KEY"), "OPENAI_API_KEY"),
      provider_row("openrouter", System.get_env("OPENROUTER_API_KEY"), "OPENROUTER_API_KEY"),
      provider_row("codex", Codex.resolve_codex_token(), Path.expand("~/.codex/auth.json"))
    ]

    IO.puts("provider\tstatus\tsource")
    Enum.each(rows, fn {p, status, source} -> IO.puts("#{p}\t#{status}\t#{source}") end)
    0
  end

  defp cmd_version do
    _ = Application.load(:crucible)
    vsn = Application.spec(:crucible, :vsn) || "unknown"
    IO.puts(to_string(vsn))
    0
  end

  @usage_text """
  Usage:
    crucible run "question" --input file.txt [options]
    crucible skills (list|clear|export)
    crucible logs (list|cleanup --max-age DAYS)
    crucible providers
    crucible version
    crucible --help
  """

  defp usage do
    IO.puts(@usage_text)
    0
  end

  defp usage_error do
    IO.puts(:stderr, @usage_text)
    1
  end

  defp maybe_put(opts, _k, nil), do: opts
  defp maybe_put(opts, _k, false), do: opts
  defp maybe_put(opts, k, v), do: Keyword.put(opts, k, v)

  defp maybe_put_provider(opts, nil), do: opts

  defp maybe_put_provider(opts, provider_str) when is_binary(provider_str) do
    provider =
      case String.downcase(provider_str) do
        "anthropic" -> :anthropic
        "openai" -> :openai
        "openrouter" -> :openrouter
        "codex" -> :codex
        other -> {:error, other}
      end

    case provider do
      {:error, other} ->
        IO.puts(
          :stderr,
          "Error: Invalid --provider: #{inspect(other)} (expected anthropic|openai|openrouter|codex)"
        )

        System.halt(1)

      atom ->
        Keyword.put(opts, :provider, atom)
    end
  end

  defp maybe_put_on_iteration(opts, true), do: opts

  defp maybe_put_on_iteration(opts, false) do
    Keyword.put(opts, :on_iteration, fn iter ->
      IO.write(:stderr, "iteration #{iter}\n")
    end)
  end

  defp read_input("-") do
    {:ok, IO.read(:stdio, :all) || ""}
  end

  defp read_input(path) when is_binary(path) do
    case File.read(path) do
      {:ok, s} -> {:ok, s}
      {:error, reason} -> {:error, "Failed to read input #{inspect(path)}: #{inspect(reason)}"}
    end
  end

  defp stringify_answer(answer) when is_binary(answer), do: answer
  defp stringify_answer(answer), do: inspect(answer)

  defp snippet_preview(snippet) when is_binary(snippet) do
    snippet
    |> String.replace("\n", "\\n")
    |> String.slice(0, 80)
  end

  defp format_unix(unix) when is_integer(unix) do
    case DateTime.from_unix(unix, :second) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      _ -> Integer.to_string(unix)
    end
  end

  defp provider_row(provider, value, source) do
    status = if is_binary(value) and value != "", do: "configured", else: "missing"
    {provider, status, source}
  end

  defp maybe_skills_db_opts(nil), do: []
  defp maybe_skills_db_opts(path), do: [skills_db_path: path]
end
