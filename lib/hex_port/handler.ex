defmodule HexPort.Handler do
  @moduledoc """
  Stateful handler builder from expect/stub clauses.

  Builds stateful handler functions from a declarative specification,
  then installs them via `HexPort.Testing.set_stateful_handler/3`.
  Multi-contract expectations can be chained in a single pipeline
  and installed with one call.

  ## Usage

      HexPort.Handler.expect(MyContract, :get_thing, fn [id] -> %Thing{id: id} end)
      |> HexPort.Handler.expect(MyContract, :get_thing, fn [_] -> nil end)
      |> HexPort.Handler.stub(MyContract, :list, fn [_] -> [] end)
      |> HexPort.Handler.install!()

      # ... run code under test ...

      HexPort.Handler.verify!()

  ## Relationship to existing APIs

  This is a higher-level convenience built on `set_stateful_handler`.
  It does not replace `set_fn_handler` or `set_stateful_handler` —
  those remain for cases that don't fit the expect/stub pattern.
  """

  defstruct contracts: %{}

  @type t :: %__MODULE__{
          contracts: %{
            module() => %{
              expects: %{atom() => [:erlang.function()]},
              stubs: %{atom() => :erlang.function()}
            }
          }
        }

  @doc """
  Create an empty handler accumulator.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Add an expectation for a contract operation.

  The function receives `[args]` (the argument list) and returns the
  result. Expectations are consumed in order — the first `expect` for
  an operation handles the first call, the second handles the second,
  and so on.

  ## Options

    * `:times` — enqueue the same function `n` times (default 1).
      Equivalent to calling `expect` `n` times with the same function.
  """
  @spec expect(t(), module(), atom(), function(), keyword()) :: t()
  def expect(acc \\ new(), contract, operation, fun, opts \\ [])
      when is_atom(contract) and is_atom(operation) and is_function(fun, 1) do
    times = Keyword.get(opts, :times, 1)

    if times < 1 do
      raise ArgumentError, "times must be >= 1, got: #{times}"
    end

    funs = List.duplicate(fun, times)

    update_contract(acc, contract, fn contract_data ->
      existing = Map.get(contract_data.expects, operation, [])
      %{contract_data | expects: Map.put(contract_data.expects, operation, existing ++ funs)}
    end)
  end

  @doc """
  Add a stub for a contract operation.

  The function receives `[args]` (the argument list) and returns the
  result. Stubs handle any number of calls and are used after all
  expectations for an operation are consumed. Setting a stub twice
  for the same operation replaces the previous one.
  """
  @spec stub(t(), module(), atom(), function()) :: t()
  def stub(acc \\ new(), contract, operation, fun)
      when is_atom(contract) and is_atom(operation) and is_function(fun, 1) do
    update_contract(acc, contract, fn contract_data ->
      %{contract_data | stubs: Map.put(contract_data.stubs, operation, fun)}
    end)
  end

  # -- Internal: accumulator manipulation --

  defp empty_contract_data do
    %{expects: %{}, stubs: %{}}
  end

  defp update_contract(%__MODULE__{contracts: contracts} = acc, contract, update_fn) do
    contract_data = Map.get(contracts, contract, empty_contract_data())
    updated = update_fn.(contract_data)
    %{acc | contracts: Map.put(contracts, contract, updated)}
  end
end
