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

  @ownership_server HexPort.Dispatch.Ownership
  @contracts_key HexPort.Handler.Contracts

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

  @doc """
  Install all accumulated expectations and stubs.

  Groups expectations by contract, builds a stateful handler function
  for each, and registers them via `HexPort.Testing.set_stateful_handler/3`.

  Returns `:ok`.
  """
  @spec install!(t()) :: :ok
  def install!(%__MODULE__{contracts: contracts}) when contracts == %{} do
    raise ArgumentError, "no expectations or stubs to install — call expect/5 or stub/4 first"
  end

  def install!(%__MODULE__{contracts: contracts}) do
    contract_modules = Map.keys(contracts)

    for {contract, %{expects: expects, stubs: stubs}} <- contracts do
      handler_fn = build_handler_fn(contract, stubs)
      initial_state = %{expects: expects}

      HexPort.Testing.set_stateful_handler(contract, handler_fn, initial_state)
    end

    # Store the list of installed contracts so verify!/0 can find them
    store_installed_contracts(contract_modules)

    :ok
  end

  @doc """
  Verify that all expectations have been consumed.

  Reads the current handler state for each contract installed via
  `install!/1` and checks that all expect queues are empty. Stubs
  are not checked — they are allowed to be called zero or more times.

  Raises with a descriptive message if any expectations remain
  unconsumed.

  Returns `:ok` if all expectations are satisfied.
  """
  @spec verify!() :: :ok
  def verify! do
    owned = NimbleOwnership.get_owned(@ownership_server, self())

    contracts =
      case owned do
        %{@contracts_key => contracts} ->
          contracts

        _ ->
          raise "HexPort.Handler.verify!/0 called but no handlers were installed via install!/1"
      end

    unconsumed =
      Enum.flat_map(contracts, fn contract ->
        state_key = Module.concat(HexPort.State, contract)

        case owned do
          %{^state_key => %{expects: expects}} ->
            expects
            |> Enum.reject(fn {_op, queue} -> queue == [] end)
            |> Enum.map(fn {op, queue} -> {contract, op, length(queue)} end)

          _ ->
            []
        end
      end)

    if unconsumed != [] do
      details =
        unconsumed
        |> Enum.map(fn {contract, op, count} ->
          "  #{inspect(contract)}.#{op}: #{count} expected call(s) not made"
        end)
        |> Enum.join("\n")

      raise """
      HexPort.Handler expectations not fulfilled:

      #{details}
      """
    end

    :ok
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

  # -- Internal: handler construction --

  defp build_handler_fn(contract, stubs) do
    fn operation, args, state ->
      case pop_expect(state, operation) do
        {:ok, fun, new_state} ->
          {fun.(args), new_state}

        :none ->
          case Map.get(stubs, operation) do
            nil ->
              raise_unexpected_call(contract, operation, args, state)

            stub_fun ->
              {stub_fun.(args), state}
          end
      end
    end
  end

  defp pop_expect(%{expects: expects} = state, operation) do
    case Map.get(expects, operation, []) do
      [fun | rest] ->
        new_expects = Map.put(expects, operation, rest)
        {:ok, fun, %{state | expects: new_expects}}

      [] ->
        :none
    end
  end

  defp raise_unexpected_call(contract, operation, args, %{expects: expects}) do
    remaining =
      expects
      |> Enum.reject(fn {_op, queue} -> queue == [] end)
      |> Enum.map(fn {op, queue} -> "  #{op}: #{length(queue)} expected call(s) remaining" end)

    remaining_msg =
      if remaining == [] do
        "  (no expectations remaining)"
      else
        Enum.join(remaining, "\n")
      end

    raise """
    Unexpected call to #{inspect(contract)}.#{operation}/#{length(args)}.

    No expectations or stubs defined for this operation.

    Remaining expectations for #{inspect(contract)}:
    #{remaining_msg}
    """
  end

  defp store_installed_contracts(contract_modules) do
    NimbleOwnership.get_and_update(@ownership_server, self(), @contracts_key, fn
      nil -> {:ok, contract_modules}
      existing -> {:ok, Enum.uniq(existing ++ contract_modules)}
    end)
  end
end
