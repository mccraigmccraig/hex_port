defmodule HexPort.Log do
  @moduledoc """
  Log-based expectation matcher for HexPort dispatch logs.

  Declares expectations against the dispatch log after execution.
  Matches on the full `{contract, operation, args, result}` tuple —
  including results, which is meaningful because HexPort handlers
  (especially `Repo.Test`) do real computation (changeset validation,
  PK autogeneration, timestamps).

  ## Usage

      HexPort.Log.match(MyContract, :insert, fn
        {_, _, [%Changeset{data: %Thing{}}], {:ok, %Thing{}}} -> true
      end)
      |> HexPort.Log.match(MyContract, :update, fn
        {_, _, [%Changeset{}], {:ok, _}} -> true
      end)
      |> HexPort.Log.reject(MyContract, :delete)
      |> HexPort.Log.verify!()

  Matcher functions only need the positive matching clauses —
  `FunctionClauseError` is caught and interpreted as "didn't match".
  No need for a `_ -> false` catch-all branch.

  ## Relationship to existing APIs

  Built on `HexPort.Testing.get_log/1`. Completely decoupled from
  handler choice — works with `Repo.Test`, `Repo.InMemory`,
  `set_fn_handler`, `set_stateful_handler`, or `HexPort.Handler`.
  """

  defstruct expectations: []

  @type matcher :: (tuple() -> boolean())

  @type expectation ::
          {:match, module(), atom(), matcher(), pos_integer()}
          | {:reject, module(), atom()}

  @type t :: %__MODULE__{
          expectations: [expectation()]
        }

  @doc """
  Create an empty log expectation accumulator.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Add a match expectation for a contract operation.

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
  @spec match(t(), module(), atom(), matcher(), keyword()) :: t()
  def match(contract, operation, matcher_fn)
      when is_atom(contract) and is_atom(operation) and is_function(matcher_fn, 1) do
    match(new(), contract, operation, matcher_fn, [])
  end

  def match(contract, operation, matcher_fn, opts)
      when is_atom(contract) and is_atom(operation) and is_function(matcher_fn, 1) and
             is_list(opts) do
    match(new(), contract, operation, matcher_fn, opts)
  end

  def match(%__MODULE__{} = acc, contract, operation, matcher_fn)
      when is_atom(contract) and is_atom(operation) and is_function(matcher_fn, 1) do
    match(acc, contract, operation, matcher_fn, [])
  end

  def match(%__MODULE__{} = acc, contract, operation, matcher_fn, opts)
      when is_atom(contract) and is_atom(operation) and is_function(matcher_fn, 1) and
             is_list(opts) do
    times = Keyword.get(opts, :times, 1)

    if times < 1 do
      raise ArgumentError, "times must be >= 1, got: #{times}"
    end

    expectation = {:match, contract, operation, matcher_fn, times}
    %{acc | expectations: acc.expectations ++ [expectation]}
  end

  @doc """
  Add a reject expectation for a contract operation.

  Verification will fail if the operation appears anywhere in the
  log for the given contract.

  The accumulator argument is optional — when omitted, a fresh
  accumulator is created via `new/0`.
  """
  @spec reject(t(), module(), atom()) :: t()
  def reject(contract, operation)
      when is_atom(contract) and is_atom(operation) do
    reject(new(), contract, operation)
  end

  def reject(%__MODULE__{} = acc, contract, operation)
      when is_atom(contract) and is_atom(operation) do
    expectation = {:reject, contract, operation}
    %{acc | expectations: acc.expectations ++ [expectation]}
  end

  @doc """
  Verify all expectations against the dispatch log.

  Reads the dispatch log for each contract referenced in the
  accumulator and checks that all match expectations are satisfied
  and all reject expectations hold.

  ## Options

    * `:strict` — when `true`, every log entry for each referenced
      contract must be matched by some matcher. Unmatched entries
      cause verification to fail. Default `false` (loose mode).

  Returns `:ok` if all expectations are satisfied.
  """
  @spec verify!(t(), keyword()) :: :ok
  def verify!(acc, opts \\ [])

  def verify!(%__MODULE__{expectations: []}, _opts) do
    raise ArgumentError, "no expectations to verify — call match/4 or reject/3 first"
  end

  def verify!(%__MODULE__{expectations: expectations}, opts) do
    strict? = Keyword.get(opts, :strict, false)

    # Collect all contracts referenced
    contracts =
      expectations
      |> Enum.map(fn
        {:match, contract, _op, _fn, _times} -> contract
        {:reject, contract, _op} -> contract
      end)
      |> Enum.uniq()

    # Read logs per contract
    logs = Map.new(contracts, fn contract -> {contract, HexPort.Testing.get_log(contract)} end)

    # Separate match and reject expectations
    {matches, rejects} =
      Enum.split_with(expectations, fn
        {:match, _, _, _, _} -> true
        {:reject, _, _} -> false
      end)

    # Group matches by {contract, operation}, preserving declaration order
    # within each group. Loose-partial means per-operation ordering with
    # independent cursors — no cross-operation ordering enforced.
    matches_by_contract_op =
      Enum.group_by(matches, fn {:match, contract, op, _, _} -> {contract, op} end)

    # Verify match expectations per {contract, operation} group
    all_matched_indices =
      Enum.flat_map(matches_by_contract_op, fn {{contract, _op}, group_matches} ->
        contract_log = Map.get(logs, contract, [])
        verify_matches(group_matches, contract_log, contract)
      end)

    # Collect matched indices by contract for strict mode
    matched_indices_by_contract =
      all_matched_indices
      |> Enum.group_by(fn {contract, _index} -> contract end)
      |> Map.new(fn {contract, pairs} -> {contract, Enum.map(pairs, &elem(&1, 1))} end)

    # Verify reject expectations
    verify_rejects(rejects, logs)

    # Strict mode: check for unmatched log entries
    if strict? do
      verify_strict(contracts, matched_indices_by_contract, logs)
    end

    :ok
  end

  # -- Internal: match verification --

  defp verify_matches(matches, log, contract) do
    indexed_log = Enum.with_index(log)

    {_remaining_log, matched_pairs} =
      Enum.reduce(matches, {indexed_log, []}, fn
        {:match, _contract, operation, matcher_fn, times}, {remaining, acc} ->
          find_n_matches(remaining, contract, operation, matcher_fn, times, acc)
      end)

    matched_pairs
  end

  defp find_n_matches(remaining_log, contract, operation, matcher_fn, times, acc_pairs) do
    Enum.reduce(1..times, {remaining_log, acc_pairs}, fn n, {remaining, pairs} ->
      case find_next_match(remaining, contract, operation, matcher_fn) do
        {:ok, index, rest} ->
          {rest, [{contract, index} | pairs]}

        :not_found ->
          raise """
          HexPort.Log expectation not satisfied:

            #{inspect(contract)}.#{operation} — match #{n} of #{times} not found.

            Searched #{length(remaining)} remaining log entries.

          Tip: check that the handler produced the expected result and that
          the matcher function's pattern matches the log entry shape
          {contract, operation, args, result}.
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

  # -- Internal: reject verification --

  defp verify_rejects(rejects, logs) do
    Enum.each(rejects, fn {:reject, contract, operation} ->
      contract_log = Map.get(logs, contract, [])

      found =
        Enum.find(contract_log, fn {c, op, _args, _result} ->
          c == contract and op == operation
        end)

      if found do
        {_, _, args, result} = found

        raise """
        HexPort.Log reject expectation violated:

          #{inspect(contract)}.#{operation} was called but should not have been.

          Args: #{inspect(args)}
          Result: #{inspect(result)}
        """
      end
    end)
  end

  # -- Internal: strict mode --

  defp verify_strict(contracts, matched_indices_by_contract, logs) do
    Enum.each(contracts, fn contract ->
      log = Map.get(logs, contract, [])
      matched_set = MapSet.new(Map.get(matched_indices_by_contract, contract, []))

      unmatched =
        log
        |> Enum.with_index()
        |> Enum.reject(fn {_entry, index} -> MapSet.member?(matched_set, index) end)

      if unmatched != [] do
        details =
          Enum.map_join(unmatched, "\n", fn {{c, op, args, result}, _index} ->
            "  #{inspect(c)}.#{op} args=#{inspect(args)} result=#{inspect(result)}"
          end)

        raise """
        HexPort.Log strict verification failed — unmatched log entries:

        #{details}
        """
      end
    end)
  end
end
