defmodule Crucible.Skills do
  @moduledoc """
  Opt-in "skill caching" for Crucible runs.

  When enabled (via `skills: true`), Crucible will:

  - Retrieve up to the top-3 most relevant code snippets that previously led to a
    completed run for similar questions.
  - Inject those snippets into the loop's system prompt under
    "Previously successful approaches:".
  - Store the final iteration's evaluated code snippet after the run completes.

  The cache is stored in a SQLite database using `Exqlite`.
  """

  @default_db_path "tmp/crucible_skills.sqlite3"
  @max_examples 3
  @max_rows_considered 500
  @max_snippet_chars 2_000

  @type snippet :: String.t()

  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts) when is_list(opts), do: Keyword.get(opts, :skills, false) == true

  @spec db_path(keyword()) :: String.t()
  def db_path(opts) when is_list(opts), do: Keyword.get(opts, :skills_db_path, @default_db_path)

  @type entry :: %{
          optional(:id) => non_neg_integer(),
          required(:question) => String.t(),
          required(:snippet) => String.t(),
          required(:inserted_at) => non_neg_integer()
        }

  @doc """
  List cached skill entries from the configured SQLite DB.
  """
  @spec list(keyword()) :: {:ok, [entry()]} | {:error, term()}
  def list(opts \\ []) when is_list(opts) do
    path = db_path(opts)

    try do
      entries =
        with_conn(path, fn conn ->
          init_schema(conn)
          fetch_entries(conn)
        end)

      {:ok, entries}
    rescue
      e -> {:error, e}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @doc """
  Delete all cached skill entries from the configured SQLite DB.
  """
  @spec clear(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def clear(opts \\ []) when is_list(opts) do
    path = db_path(opts)

    try do
      deleted =
        with_conn(path, fn conn ->
          init_schema(conn)
          delete_all(conn)
        end)

      {:ok, deleted}
    rescue
      e -> {:error, e}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  @doc """
  Export all cached skill entries as a list of maps (suitable for JSON encoding).
  """
  @spec export(keyword()) :: {:ok, [entry()]} | {:error, term()}
  def export(opts \\ []) when is_list(opts), do: list(opts)

  @spec normalize_question(String.t()) :: String.t()
  def normalize_question(question) when is_binary(question) do
    question
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  @spec retrieve(String.t(), keyword()) :: [snippet()]
  def retrieve(question, opts \\ []) when is_binary(question) and is_list(opts) do
    if enabled?(opts) do
      do_retrieve_examples(question, db_path(opts), max_snippet_chars(opts))
    else
      []
    end
  end

  @spec store(String.t(), String.t(), keyword()) :: :ok
  def store(question, code_snippet, opts \\ [])
      when is_binary(question) and is_binary(code_snippet) and is_list(opts) do
    if enabled?(opts) do
      do_store_success(question, code_snippet, db_path(opts), max_snippet_chars(opts))
    else
      :ok
    end
  end

  defp do_retrieve_examples(question, path, max_snippet_chars)
       when is_integer(max_snippet_chars) and max_snippet_chars > 0 do
    query_norm = normalize_question(question)
    query_tokens = tokens(query_norm)

    rows =
      with_conn(path, fn conn ->
        init_schema(conn)
        fetch_recent(conn, @max_rows_considered)
      end)

    rows
    |> Enum.map(fn %{snippet: snippet, question_norm: qn, inserted_at: inserted_at} ->
      score = similarity(query_tokens, tokens(qn))
      %{snippet: snippet, score: score, inserted_at: inserted_at}
    end)
    |> Enum.filter(fn r -> r.score > 0.0 end)
    |> Enum.sort_by(fn r -> {-r.score, -r.inserted_at} end)
    |> Enum.reduce([], fn r, acc ->
      snippet = String.slice(r.snippet, 0, max_snippet_chars)
      if snippet in acc, do: acc, else: [snippet | acc]
    end)
    |> Enum.reverse()
    |> Enum.take(@max_examples)
  end

  defp do_store_success(question, code_snippet, path, max_snippet_chars)
       when is_integer(max_snippet_chars) and max_snippet_chars > 0 do
    question_norm = normalize_question(question)
    inserted_at = DateTime.utc_now() |> DateTime.to_unix(:second)
    snippet = String.slice(String.trim(code_snippet), 0, max_snippet_chars)

    with_conn(path, fn conn ->
      init_schema(conn)
      insert(conn, question, question_norm, snippet, inserted_at)
      :ok
    end)
  end

  defp tokens(""), do: MapSet.new()

  defp tokens(s) when is_binary(s) do
    words = String.split(s, " ", trim: true)

    bigrams =
      words
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> a <> " " <> b end)

    MapSet.new(words ++ bigrams)
  end

  defp max_snippet_chars(opts) when is_list(opts) do
    case Keyword.get(opts, :skills_max_snippet_chars, @max_snippet_chars) do
      n when is_integer(n) and n > 0 -> n
      _ -> @max_snippet_chars
    end
  end

  defp similarity(a, b) do
    union_size = MapSet.union(a, b) |> MapSet.size()

    if union_size == 0 do
      0.0
    else
      inter_size = MapSet.intersection(a, b) |> MapSet.size()
      inter_size / union_size
    end
  end

  defp with_conn(path, fun) when is_binary(path) and is_function(fun, 1) do
    File.mkdir_p!(Path.dirname(path))

    {:ok, conn} = Exqlite.Sqlite3.open(path)

    try do
      fun.(conn)
    after
      :ok = Exqlite.Sqlite3.close(conn)
    end
  end

  defp init_schema(conn) do
    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        """
        CREATE TABLE IF NOT EXISTS crucible_skills (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          question TEXT NOT NULL,
          question_norm TEXT NOT NULL,
          snippet TEXT NOT NULL,
          inserted_at INTEGER NOT NULL
        );
        """
      )

    :ok =
      Exqlite.Sqlite3.execute(
        conn,
        "CREATE INDEX IF NOT EXISTS crucible_skills_question_norm_idx ON crucible_skills(question_norm);"
      )

    :ok
  end

  defp fetch_recent(conn, limit) when is_integer(limit) and limit > 0 do
    sql =
      "SELECT question_norm, snippet, inserted_at FROM crucible_skills ORDER BY inserted_at DESC LIMIT ?1"

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, [limit])
      fetch_all_rows(conn, stmt, [])
    after
      :ok = Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp fetch_all_rows(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      :done ->
        Enum.reverse(acc)

      {:row, [question_norm, snippet, inserted_at]} ->
        fetch_all_rows(conn, stmt, [
          %{
            question_norm: to_string(question_norm),
            snippet: to_string(snippet),
            inserted_at: inserted_at
          }
          | acc
        ])

      other ->
        raise "Unexpected sqlite step result: #{inspect(other)}"
    end
  end

  defp insert(conn, question, question_norm, snippet, inserted_at) do
    sql =
      "INSERT INTO crucible_skills (question, question_norm, snippet, inserted_at) VALUES (?1, ?2, ?3, ?4)"

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      :ok = Exqlite.Sqlite3.bind(stmt, [question, question_norm, snippet, inserted_at])

      case Exqlite.Sqlite3.step(conn, stmt) do
        :done -> :ok
        other -> raise "Unexpected sqlite insert step result: #{inspect(other)}"
      end
    after
      :ok = Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp fetch_entries(conn) do
    sql =
      "SELECT id, question, snippet, inserted_at FROM crucible_skills ORDER BY inserted_at DESC"

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, sql)

    try do
      fetch_all_entries(conn, stmt, [])
    after
      :ok = Exqlite.Sqlite3.release(conn, stmt)
    end
  end

  defp fetch_all_entries(conn, stmt, acc) do
    case Exqlite.Sqlite3.step(conn, stmt) do
      :done ->
        Enum.reverse(acc)

      {:row, [id, question, snippet, inserted_at]} ->
        fetch_all_entries(conn, stmt, [
          %{
            id: id,
            question: to_string(question),
            snippet: to_string(snippet),
            inserted_at: inserted_at
          }
          | acc
        ])

      other ->
        raise "Unexpected sqlite step result: #{inspect(other)}"
    end
  end

  defp delete_all(conn) do
    :ok = Exqlite.Sqlite3.execute(conn, "DELETE FROM crucible_skills;")
    # Sqlite3 doesn't return row count from execute; use changes/1
    case Exqlite.Sqlite3.changes(conn) do
      {:ok, count} -> count
      _ -> 0
    end
  end
end
