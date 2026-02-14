defmodule Crucible.LoggerTest do
  use ExUnit.Case, async: true

  test "cleanup/1 deletes old .jsonl files and returns count" do
    dir =
      Path.join([
        "tmp",
        "test_logger_cleanup",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    File.mkdir_p!(dir)

    old_path = Path.join(dir, "old.jsonl")
    new_path = Path.join(dir, "new.jsonl")

    File.write!(old_path, "{}\n")
    File.write!(new_path, "{}\n")

    old_dt =
      NaiveDateTime.utc_now() |> NaiveDateTime.add(-8 * 86_400, :second) |> NaiveDateTime.to_erl()

    :ok = File.touch(old_path, old_dt)

    assert {:ok, 1} = Crucible.Logger.cleanup(log_dir: dir, max_age_days: 7)
    refute File.exists?(old_path)
    assert File.exists?(new_path)
  end

  test "cleanup/1 returns 0 when log_dir does not exist" do
    dir =
      Path.join([
        "tmp",
        "test_logger_cleanup_missing",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    assert {:ok, 0} = Crucible.Logger.cleanup(log_dir: dir, max_age_days: 7)
  end
end
