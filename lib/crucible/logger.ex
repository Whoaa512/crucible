defmodule Crucible.Logger do
  @moduledoc """
  JSONL trajectory logger for RLM iterations.
  """

  @default_dir "tmp/rlm_trajectories"

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
end
