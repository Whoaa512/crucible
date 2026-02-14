defmodule Crucible.SkillsTest do
  use ExUnit.Case, async: true

  alias Crucible.Skills
  import Crucible.Test.TmpPath

  test "retrieve/store are no-ops when skills are disabled" do
    db_path = unique_tmp_path(["skills_disabled", "skills.sqlite3"])

    assert Skills.retrieve("any question", skills: false, skills_db_path: db_path) == []
    assert Skills.store("any question", "snippet", skills: false, skills_db_path: db_path) == :ok

    refute File.exists?(db_path)
  end

  test "store persists a truncated snippet and retrieve returns it for similar questions" do
    db_path = unique_tmp_path(["skills", "skills.sqlite3"])
    on_exit(fn -> File.rm_rf(Path.dirname(db_path)) end)

    opts = [skills: true, skills_db_path: db_path, skills_max_snippet_chars: 10]

    assert :ok = Skills.store("How do I parse JSON in Elixir?", "  0123456789ABCDEFGHIJ  \n", opts)
    assert :ok = Skills.store("completely unrelated topic", "ZZZZZZZZZZ", opts)

    snippets = Skills.retrieve("parse json elixir", opts)
    assert "0123456789" in snippets
    refute "ZZZZZZZZZZ" in snippets
  end

  test "retrieve returns at most 3 unique snippets" do
    db_path = unique_tmp_path(["skills_limit", "skills.sqlite3"])
    on_exit(fn -> File.rm_rf(Path.dirname(db_path)) end)

    opts = [skills: true, skills_db_path: db_path]

    :ok = Skills.store("foo bar baz", "S1", opts)
    :ok = Skills.store("foo bar qux", "S2", opts)
    :ok = Skills.store("foo bar quux", "S2", opts)
    :ok = Skills.store("foo bar corge", "S3", opts)
    :ok = Skills.store("foo bar grault", "S4", opts)

    snippets = Skills.retrieve("foo bar", opts)
    assert length(snippets) == 3
    assert snippets == Enum.uniq(snippets)

    valid = MapSet.new(["S1", "S2", "S3", "S4"])
    assert Enum.all?(snippets, &MapSet.member?(valid, &1))
  end

  test "similar questions return relevant snippets, dissimilar ones don't" do
    db_path = unique_tmp_path(["skills_similarity", "skills.sqlite3"])
    on_exit(fn -> File.rm_rf(Path.dirname(db_path)) end)

    opts = [skills: true, skills_db_path: db_path]

    :ok = Skills.store("How to parse JSON in Elixir?", "Jason.decode!(data)", opts)
    :ok = Skills.store("Configure PostgreSQL database connection", "Repo.config()", opts)

    # Similar question should find the JSON snippet
    json_results = Skills.retrieve("parsing JSON data", opts)
    assert "Jason.decode!(data)" in json_results

    # Completely dissimilar question should not find it
    db_results = Skills.retrieve("setup postgres database pool", opts)
    refute "Jason.decode!(data)" in db_results
  end
end
