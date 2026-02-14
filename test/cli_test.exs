defmodule Crucible.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Crucible.Test.TmpPath

  alias Crucible.CLI

  setup do
    prev = Application.get_env(:crucible, :completion_fun)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:crucible, :completion_fun)
        _ -> Application.put_env(:crucible, :completion_fun, prev)
      end
    end)

    :ok
  end

  test "--help, -h, and help print usage to stdout with exit 0" do
    for flag <- ["--help", "-h", "help"] do
      stdout =
        capture_io(fn ->
          assert 0 == CLI.main([flag])
        end)

      assert stdout =~ "Usage:"
      assert stdout =~ "crucible run"
      assert stdout =~ "crucible --help"
    end
  end

  test "unknown commands print usage to stderr" do
    stderr =
      capture_io(:stderr, fn ->
        assert 1 == CLI.main([])
      end)

    assert stderr =~ "Usage:"
    assert stderr =~ "crucible run"

    stderr2 =
      capture_io(:stderr, fn ->
        assert 1 == CLI.main(["nope"])
      end)

    assert stderr2 =~ "Usage:"
  end

  test "run: missing question or input are errors" do
    stderr1 =
      capture_io(:stderr, fn ->
        assert 1 == CLI.main(["run", "--input", "file.txt"])
      end)

    assert stderr1 =~ "Missing required question argument."

    stderr2 =
      capture_io(:stderr, fn ->
        assert 1 == CLI.main(["run", "question"])
      end)

    assert stderr2 =~ "Missing required --input"
  end

  test "run: invalid options return exit 1" do
    stderr =
      capture_io(:stderr, fn ->
        assert 1 == CLI.main(["run", "question", "--input", "file.txt", "--not-a-real-flag"])
      end)

    assert stderr =~ "Invalid options:"
    assert stderr =~ "--not-a-real-flag"
  end

  test "run: missing input file errors without calling completion" do
    Application.put_env(:crucible, :completion_fun, fn _, _, _ -> flunk("should not be called") end)

    stderr =
      capture_io(:stderr, fn ->
        assert 1 == CLI.main(["run", "question", "--input", "does-not-exist.txt"])
      end)

    assert stderr =~ "Failed to read input"
  end

  test "run: --quiet suppresses iteration output" do
    dir = unique_tmp_path(["cli_quiet"])
    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(dir)

    input_path = Path.join(dir, "input.txt")
    File.write!(input_path, "INPUT")

    parent = self()

    Application.put_env(:crucible, :completion_fun, fn _q, _i, opts ->
      send(parent, {:opts, opts})
      {:ok, "42", %{iterations: 1, trajectory: nil}}
    end)

    output =
      capture_io(fn ->
        assert 0 == CLI.main(["run", "q", "--input", input_path, "--quiet"])
      end)

    assert output =~ "42"

    assert_receive {:opts, opts}
    refute Keyword.has_key?(opts, :on_iteration)
  end

  test "run: --json outputs valid JSON with answer and metadata" do
    dir = unique_tmp_path(["cli_json"])
    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(dir)

    input_path = Path.join(dir, "input.txt")
    File.write!(input_path, "INPUT")

    Application.put_env(:crucible, :completion_fun, fn _q, _i, _opts ->
      {:ok, "ANSWER", %{iterations: 7, trajectory: "tmp/traj.jsonl"}}
    end)

    stdout =
      capture_io(fn ->
        assert 0 == CLI.main(["run", "q", "--input", input_path, "--json", "--quiet"])
      end)

    {:ok, decoded} = Jason.decode(stdout)
    assert decoded["answer"] == "ANSWER"
    assert decoded["iterations"] == 7
  end

  test "run: options are correctly passed to completion function" do
    dir = unique_tmp_path(["cli_opts"])
    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(dir)

    input_path = Path.join(dir, "input.txt")
    File.write!(input_path, "INPUT")

    parent = self()

    Application.put_env(:crucible, :completion_fun, fn question, input, opts ->
      send(parent, {:call, question, input, opts})
      {:ok, "OK", %{iterations: 1, trajectory: nil}}
    end)

    capture_io(fn ->
      assert 0 ==
               CLI.main([
                 "run", "What is 2+2?", "--input", input_path,
                 "--provider", "openai", "--model", "gpt-test",
                 "--max-iterations", "7", "--temperature", "0.2",
                 "--quiet"
               ])
    end)

    assert_receive {:call, "What is 2+2?", "INPUT", opts}
    assert Keyword.get(opts, :provider) == :openai
    assert Keyword.get(opts, :model) == "gpt-test"
    assert Keyword.get(opts, :max_iterations) == 7
    assert Keyword.get(opts, :temperature) == 0.2
  end

  test "run: non-quiet mode includes on_iteration callback" do
    dir = unique_tmp_path(["cli_iter"])
    on_exit(fn -> File.rm_rf(dir) end)
    File.mkdir_p!(dir)

    input_path = Path.join(dir, "input.txt")
    File.write!(input_path, "INPUT")

    parent = self()

    Application.put_env(:crucible, :completion_fun, fn _q, _i, opts ->
      send(parent, {:opts, opts})
      {:ok, "OK", %{iterations: 1, trajectory: nil}}
    end)

    capture_io(fn ->
      assert 0 == CLI.main(["run", "q", "--input", input_path, "--json"])
    end)

    assert_receive {:opts, opts}
    assert is_function(Keyword.fetch!(opts, :on_iteration), 1)
  end
end
