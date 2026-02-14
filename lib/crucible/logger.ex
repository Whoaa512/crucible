defmodule Crucible.Logger do
  @moduledoc """
  JSONL trajectory logger for RLM iterations.
  """

  @default_dir "tmp/rlm_trajectories"
  @default_max_age_days 7

  @spec new_session(keyword()) :: String.t()
  def new_session(opts \\ []) do
    dir = Keyword.get(opts, :log_dir, @default_dir)
    File.mkdir_p!(dir)

    timestamp = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    unique = System.unique_integer([:positive])
    path = Path.join(dir, "trajectory_#{timestamp}_#{unique}.jsonl")

    File.write!(path, "")
    path
  end

  @spec log_iteration(String.t(), map()) :: :ok
  def log_iteration(path, entry) when is_binary(path) and is_map(entry) do
    payload =
      entry
      |> Map.put_new(:timestamp, DateTime.utc_now() |> DateTime.to_iso8601())
      |> Jason.encode!()

    File.write!(path, payload <> "\n", [:append])
    :ok
  end

  @spec cleanup(keyword()) :: {:ok, non_neg_integer()}
  def cleanup(opts \\ []) when is_list(opts) do
    dir = Keyword.get(opts, :log_dir, @default_dir)

    max_age_days =
      case Keyword.get(opts, :max_age_days, @default_max_age_days) do
        n when is_integer(n) and n >= 0 -> n
        _ -> @default_max_age_days
      end

    max_age_seconds = max_age_days * 86_400
    now_unix = DateTime.utc_now() |> DateTime.to_unix(:second)

    if File.dir?(dir) do
      deleted =
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.reduce(0, fn filename, acc ->
          path = Path.join(dir, filename)

          case File.stat(path, time: :posix) do
            {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) ->
              age_seconds = now_unix - mtime

              if age_seconds > max_age_seconds do
                case File.rm(path) do
                  :ok -> acc + 1
                  _ -> acc
                end
              else
                acc
              end

            _ ->
              acc
          end
        end)

      {:ok, deleted}
    else
      {:ok, 0}
    end
  end
end
