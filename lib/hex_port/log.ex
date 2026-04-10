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
end
