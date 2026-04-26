defmodule DoubleDown.Log do
  @moduledoc """
  Log-based expectation matcher for DoubleDown dispatch logs.

  Declares expectations against the dispatch log after execution.
  Matches on the full `{contract, operation, args, result}` tuple —
  including results, which is meaningful because DoubleDown handlers
  (especially `Repo.Stub`) do real computation (changeset validation,
  PK autogeneration, timestamps).

  ## Basic usage

      DoubleDown.Log.match(:insert, fn
        {_, _, [%Changeset{data: %Thing{}}], {:ok, %Thing{}}} -> true
      end)
      |> DoubleDown.Log.reject(:delete)
      |> DoubleDown.Log.verify!(MyContract)

  Matcher functions only need the positive matching clauses —
  `FunctionClauseError` is caught and interpreted as "didn't match".
  No need for a `_ -> false` catch-all, though returning `false`
  explicitly can be useful for excluding specific values that are
  hard to exclude with pattern matching alone.

  ## Matching on results

  Unlike Mox/Mimic where asserting on return values would be
  circular (you wrote the stub), DoubleDown handlers do real
  computation. Matching on results is a meaningful assertion:

      DoubleDown.Log.match(:insert, fn
        {_, _, [%Changeset{data: %Thing{}}],
         {:ok, %Thing{id: id}}} when is_binary(id) -> true
      end)
      |> DoubleDown.Log.verify!(RepoContract)

  ## Counting occurrences

      DoubleDown.Log.match(:insert, fn
        {_, _, [%Changeset{data: %Discrepancy{}}], {:ok, _}} -> true
      end, times: 3)
      |> DoubleDown.Log.verify!(DoubleDown.Repo)

  ## Multi-contract

  Build separate matcher chains and verify each against its contract:

      todos_log =
        DoubleDown.Log.match(:create_todo, fn {_, _, _, {:ok, _}} -> true end)

      repo_log =
        DoubleDown.Log.match(:insert, fn {_, _, _, {:ok, _}} -> true end)

      DoubleDown.Log.verify!(todos_log, MyApp.Todos)
      DoubleDown.Log.verify!(repo_log, DoubleDown.Repo)

  ## Matching modes

  ### Loose (default)

  Matchers must be satisfied in order within each operation, but
  other log entries are allowed between them. Different operations
  are matched independently (no cross-operation ordering):

      DoubleDown.Log.match(:insert, matcher)
      |> DoubleDown.Log.match(:update, matcher)
      |> DoubleDown.Log.verify!(MyContract)
      # Passes if log contains an insert and an update,
      # regardless of other entries or relative order.

  ### Strict

  Every log entry for the contract must be matched.
  No unmatched entries allowed:

      DoubleDown.Log.match(:insert, matcher)
      |> DoubleDown.Log.match(:update, matcher)
      |> DoubleDown.Log.verify!(MyContract, strict: true)

  ## Relationship to existing APIs

  Built on `DoubleDown.Testing.get_log/1`. Completely decoupled from
  handler choice — works with `Repo.Stub`, `Repo.OpenInMemory`,
  `set_stateless_handler`, `set_stateful_handler`, or `DoubleDown.Double`.

  Can be used alongside `DoubleDown.Double` — Handler for fail-fast
  validation and producing return values, Log for after-the-fact
  result inspection.
  """

  defstruct expectations: []

  @type matcher :: (tuple() -> boolean())

  @type expectation ::
          {:match, atom(), matcher(), pos_integer()}
          | {:reject, atom()}

  @type t :: %__MODULE__{
          expectations: [expectation()]
        }

  @doc """
  Create an empty log expectation accumulator.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Add a match expectation for an operation.

  The matcher function receives the full log tuple
  `{contract, operation, args, result}` and should return a truthy
  value for entries that match. Write only the clauses that should
  match — `FunctionClauseError` is caught and treated as "didn't
  match".

  The accumulator argument is optional — when omitted, a fresh
  accumulator is created via `new/0`.

  ## Options

    * `:times` — require exactly `n` matching entries (default 1).
  """
  @spec match(t(), atom(), matcher(), keyword()) :: t()
  def match(operation, matcher_fn, opts \\ [])

  def match(operation, matcher_fn, opts)
      when is_atom(operation) and is_function(matcher_fn, 1) and is_list(opts) do
    match(new(), operation, matcher_fn, opts)
  end

  def match(%__MODULE__{} = acc, operation, matcher_fn)
      when is_atom(operation) and is_function(matcher_fn, 1) do
    match(acc, operation, matcher_fn, [])
  end

  def match(%__MODULE__{} = acc, operation, matcher_fn, opts)
      when is_atom(operation) and is_function(matcher_fn, 1) and is_list(opts) do
    times = Keyword.get(opts, :times, 1)

    if times < 1 do
      raise ArgumentError, "times must be >= 1, got: #{times}"
    end

    expectation = {:match, operation, matcher_fn, times}
    %{acc | expectations: acc.expectations ++ [expectation]}
  end

  @doc """
  Add a reject expectation for an operation.

  Verification will fail if the operation appears anywhere in the
  log for the contract.

  The accumulator argument is optional — when omitted, a fresh
  accumulator is created via `new/0`.
  """
  @spec reject(t(), atom()) :: t()
  def reject(operation) when is_atom(operation) do
    reject(new(), operation)
  end

  def reject(%__MODULE__{} = acc, operation) when is_atom(operation) do
    expectation = {:reject, operation}
    %{acc | expectations: acc.expectations ++ [expectation]}
  end

  @doc """
  Verify all expectations against the dispatch log for a contract.

  Reads the dispatch log via `DoubleDown.Testing.get_log/1` and
  checks that all match expectations are satisfied and all reject
  expectations hold.

  ## Options

    * `:strict` — when `true`, every log entry for the contract
      must be matched by some matcher. Unmatched entries cause
      verification to fail. Default `false` (loose mode).

  Returns `{:ok, log}` where `log` is the full dispatch log for the
  contract — useful in the REPL for inspecting what happened.
  """
  @spec verify!(t(), module(), keyword()) :: {:ok, list()}
  def verify!(acc, contract, opts \\ [])

  def verify!(%__MODULE__{expectations: []}, _contract, _opts) do
    raise ArgumentError, "no expectations to verify — call match/3 or reject/1 first"
  end

  def verify!(%__MODULE__{expectations: expectations}, contract, opts)
      when is_atom(contract) do
    strict? = Keyword.get(opts, :strict, false)

    log = DoubleDown.Testing.get_log(contract)

    # Separate match and reject expectations
    {matches, rejects} =
      Enum.split_with(expectations, fn
        {:match, _, _, _} -> true
        {:reject, _} -> false
      end)

    # Group matches by operation, preserving declaration order
    # within each group. Loose-partial means per-operation ordering with
    # independent cursors — no cross-operation ordering enforced.
    matches_by_op =
      Enum.group_by(matches, fn {:match, op, _, _} -> op end)

    # Verify match expectations per operation group
    all_matched_indices =
      Enum.flat_map(matches_by_op, fn {_op, group_matches} ->
        verify_matches(group_matches, log, contract)
      end)

    # Collect matched indices for strict mode
    matched_index_set = MapSet.new(all_matched_indices)

    # Verify reject expectations
    verify_rejects(rejects, log, contract)

    # Strict mode: check for unmatched log entries
    if strict? do
      verify_strict(log, matched_index_set, contract)
    end

    {:ok, log}
  end

  # -- Internal: match verification --

  defp verify_matches(matches, log, contract) do
    indexed_log = Enum.with_index(log)

    {_remaining_log, matched_indices} =
      Enum.reduce(matches, {indexed_log, []}, fn
        {:match, operation, matcher_fn, times}, {remaining, acc} ->
          find_n_matches(remaining, contract, operation, matcher_fn, times, acc, log)
      end)

    matched_indices
  end

  defp find_n_matches(remaining_log, contract, operation, matcher_fn, times, acc_indices, log) do
    Enum.reduce(1..times, {remaining_log, acc_indices}, fn n, {remaining, indices} ->
      case find_next_match(remaining, contract, operation, matcher_fn) do
        {:ok, index, rest} ->
          {rest, [index | indices]}

        :not_found ->
          raise """
          DoubleDown.Log expectation not satisfied:

            #{inspect(contract)}.#{operation} — match #{n} of #{times} not found.

            Searched #{length(remaining)} remaining log entries.

          Tip: check that the handler produced the expected result and that
          the matcher function's pattern matches the log entry shape
          {contract, operation, args, result}.

          Full log for #{inspect(contract)}:
          #{format_log(log)}
          """
      end
    end)
  end

  defp find_next_match([], _contract, _operation, _matcher_fn), do: :not_found

  defp find_next_match([{entry, index} | rest], contract, operation, matcher_fn) do
    {entry_contract, entry_op, _args, _result} = entry

    if entry_contract == contract and entry_op == operation and matches?(matcher_fn, entry) do
      {:ok, index, rest}
    else
      find_next_match(rest, contract, operation, matcher_fn)
    end
  end

  defp matches?(matcher_fn, entry) do
    matcher_fn.(entry)
  rescue
    FunctionClauseError -> false
  end

  defp format_log([]), do: "  (empty)"

  defp format_log(log) do
    Enum.map_join(log, "\n", fn {c, op, args, result} ->
      "  #{inspect(c)}.#{op} args=#{inspect(args)} result=#{inspect(result)}"
    end)
  end

  # -- Internal: reject verification --

  defp verify_rejects(rejects, log, contract) do
    Enum.each(rejects, fn {:reject, operation} ->
      found =
        Enum.find(log, fn {c, op, _args, _result} ->
          c == contract and op == operation
        end)

      if found do
        {_, _, args, result} = found

        raise """
        DoubleDown.Log reject expectation violated:

          #{inspect(contract)}.#{operation} was called but should not have been.

          Args: #{inspect(args)}
          Result: #{inspect(result)}

        Full log for #{inspect(contract)}:
        #{format_log(log)}
        """
      end
    end)
  end

  # -- Internal: strict mode --

  defp verify_strict(log, matched_index_set, contract) do
    unmatched =
      log
      |> Enum.with_index()
      |> Enum.reject(fn {_entry, index} -> MapSet.member?(matched_index_set, index) end)

    if unmatched != [] do
      details =
        Enum.map_join(unmatched, "\n", fn {{c, op, args, result}, _index} ->
          "  #{inspect(c)}.#{op} args=#{inspect(args)} result=#{inspect(result)}"
        end)

      raise """
      DoubleDown.Log strict verification failed — unmatched log entries:

      #{details}

      Full log for #{inspect(contract)}:
      #{format_log(log)}
      """
    end
  end
end
