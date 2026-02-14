defmodule Crucible.Test.TmpPath do
  @moduledoc "Shared temp path helper for tests."

  def unique_tmp_path(parts) do
    base = System.tmp_dir!()
    uniq = Integer.to_string(System.unique_integer([:positive]))
    Path.join([base, "crucible_tests", uniq] ++ parts)
  end
end
