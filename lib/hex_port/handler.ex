defmodule HexPort.Handler do
  @moduledoc """
  Stateful handler builder from expect/stub clauses.

  Builds stateful handler functions from a declarative specification,
  then installs them via `HexPort.Testing.set_stateful_handler/3`.
  Multi-contract expectations can be chained in a single pipeline
  and installed with one call.

  This is essentially Mox's expect/stub model, but:

  - **Multi-contract** — one pipeline across multiple contracts
  - **No mock modules** — handlers installed directly on contracts
  - **Built on `set_stateful_handler`** — doesn't replace or limit
    the existing general-purpose handler APIs

  ## Basic usage

      HexPort.Handler.expect(MyContract, :get_thing, fn [id] -> %Thing{id: id} end)
      |> HexPort.Handler.stub(MyContract, :list, fn [_] -> [] end)
      |> HexPort.Handler.install!()

      # ... run code under test ...

      HexPort.Handler.verify!()

  ## Sequenced expectations

  Successive calls to `expect` for the same operation queue handlers
  that are consumed in order:

      HexPort.Handler.expect(MyContract, :get_thing, fn [_] -> {:error, :not_found} end)
      |> HexPort.Handler.expect(MyContract, :get_thing, fn [id] -> %Thing{id: id} end)
      |> HexPort.Handler.install!()

      # First call returns :not_found, second returns the thing

  ## Repeated expectations

  Use `times: n` when the same function should handle multiple calls:

      HexPort.Handler.expect(MyContract, :check, fn [_] -> :ok end, times: 3)
      |> HexPort.Handler.install!()

  ## Expects + stubs

  When an operation has both expects and a stub, expects are consumed
  first; once exhausted, the stub handles all subsequent calls:

      HexPort.Handler.expect(MyContract, :get, fn [_] -> :first end)
      |> HexPort.Handler.stub(MyContract, :get, fn [_] -> :default end)
      |> HexPort.Handler.install!()

  ## Contract-wide fallback

  A fallback handles any operation without a specific expect or
  per-operation stub. Two forms are supported:

  ### Function fallback

  A 2-arity `fn operation, args -> result end` — the same signature
  as `set_fn_handler`:

      HexPort.Handler.expect(MyContract, :get, fn [id] -> %Thing{id: id} end)
      |> HexPort.Handler.stub(MyContract, fn
        :list, [_] -> []
        :count, [] -> 0
      end)
      |> HexPort.Handler.install!()

  ### Stateful fallback

  A 3-arity `fn operation, args, state -> {result, new_state} end` —
  the same signature as `set_stateful_handler`. This integrates a
  stateful fake (like `Repo.InMemory`) into the dispatch chain while
  allowing expects to override specific calls:

      # First insert fails, rest go through the stateful handler
      HexPort.Handler.expect(RepoContract, :insert, fn [changeset] ->
        {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
      end)
      |> HexPort.Handler.stub(RepoContract, &Repo.InMemory.handler/3, %{})
      |> HexPort.Handler.install!()

  The fallback's state is managed alongside the expect queue state.
  When an expect short-circuits (e.g. returning an error), the
  fallback state is unchanged — correct for error simulation.

  **Limitation: no inline passthrough.** Expects and per-operation
  stubs cannot delegate to the stateful fallback inline — they
  produce return values directly without access to the fallback's
  state. This is a deliberate design choice: providing a
  `passthrough` callback that threads mutable state through a
  user-provided function is fundamentally an algebraic effects
  problem. Without an effects library, any solution is either
  janky (process dictionary side-channel) or leaky (exposing
  `{result, state}` tuples to the user).

  In practice, the main use case — error simulation — doesn't need
  passthrough: the expect returns an error, the fallback never runs,
  and its state is correctly unchanged. For wrapping or transforming
  fallback results, [Skuld](https://github.com/mccraigmccraig/skuld)
  provides algebraic effects that handle this naturally.

  ### Module fallback

  A module implementing the contract's `@behaviour` — all operations
  delegate to the module via `apply(module, operation, args)`:

      HexPort.Handler.expect(MyContract, :get, fn [_] -> {:error, :not_found} end)
      |> HexPort.Handler.stub(MyContract, MyApp.Impl)
      |> HexPort.Handler.install!()

  The module is validated at `install!` time — all contract operations
  must be exported.

  **Mimic-style limitation:** if the module's `:bar` internally calls
  `:foo`, and you've stubbed `:foo`, the module won't see your stub —
  it calls its own `:foo` directly. For stubs to be visible, the
  module must call through the facade.

  Dispatch priority: expects > per-operation stubs > fallback > raise.
  Function, stateful, and module fallbacks are mutually exclusive —
  setting one replaces the other.

  ## Multi-contract

      HexPort.Handler.expect(TodosContract, :create, fn [p] -> {:ok, struct!(Todo, p)} end)
      |> HexPort.Handler.stub(RepoContract, :one, fn [_] -> nil end)
      |> HexPort.Handler.install!()

  ## Relationship to Mox

  | Mox | HexPort.Handler |
  |-----|-----------------|
  | `expect(Mock, :fn, n, fun)` | `expect(Contract, :fn, fun, times: n)` |
  | `stub(Mock, :fn, fun)` | `stub(Contract, :fn, fun)` — per-operation |
  | (no equivalent) | `stub(Contract, fn op, args -> ... end)` — function fallback |
  | (no equivalent) | `stub(Contract, fn op, args, state -> ... end, init)` — stateful fallback |
  | (no equivalent) | `stub(Contract, ImplModule)` — module fallback |
  | `verify!()` | `verify!()` |
  | `verify_on_exit!()` | `verify_on_exit!()` |
  | `Mox.defmock(Mock, for: Behaviour)` | Not needed |
  | `Application.put_env(...)` | `install!()` |

  ## Relationship to existing APIs

  This is a higher-level convenience built on `set_stateful_handler`.
  It does not replace `set_fn_handler` or `set_stateful_handler` —
  those remain for cases that don't fit the expect/stub pattern.
  """

  @ownership_server HexPort.Dispatch.Ownership
  @contracts_key HexPort.Handler.Contracts

  defstruct contracts: %{}

  @type fallback ::
          nil
          | {:fn, :erlang.function()}
          | {:stateful, :erlang.function(), term()}
          | {:module, module()}

  @type t :: %__MODULE__{
          contracts: %{
            module() => %{
              expects: %{atom() => [:erlang.function()]},
              stubs: %{atom() => :erlang.function()},
              fallback: fallback()
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

  The function receives the argument list and returns the result.
  Expectations are consumed in order — the first `expect` for an
  operation handles the first call, the second handles the second,
  and so on.

  Instead of a function, pass `:passthrough` to delegate to the
  fallback (fn, stateful, or module) while still consuming the
  expect for `verify!` counting:

      HexPort.Handler.expect(MyContract, :get, :passthrough, times: 2)
      |> HexPort.Handler.stub(MyContract, MyApp.Impl)
      |> HexPort.Handler.install!()

  The accumulator argument is optional — when omitted, a fresh
  accumulator is created via `new/0`.

  ## Options

    * `:times` — enqueue the same function `n` times (default 1).
      Equivalent to calling `expect` `n` times with the same function.
  """
  @spec expect(t(), module(), atom(), function() | :passthrough, keyword()) :: t()
  def expect(contract, operation, fun) when is_atom(contract) do
    expect(new(), contract, operation, fun, [])
  end

  def expect(contract, operation, fun, opts)
      when is_atom(contract) and is_atom(operation) and is_list(opts) do
    expect(new(), contract, operation, fun, opts)
  end

  def expect(%__MODULE__{} = acc, contract, operation, fun)
      when is_atom(contract) and is_atom(operation) and
             (is_function(fun, 1) or fun == :passthrough) do
    expect(acc, contract, operation, fun, [])
  end

  def expect(%__MODULE__{} = acc, contract, operation, fun, opts)
      when is_atom(contract) and is_atom(operation) and
             (is_function(fun, 1) or fun == :passthrough) and is_list(opts) do
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
  Add a stub for a contract operation or a contract-wide fallback.

  ## Per-operation stub (1-arity function)

  The function receives the argument list and returns the result.
  Stubs handle any number of calls and are used after all expectations
  for an operation are consumed. Setting a stub twice for the same
  operation replaces the previous one.

      HexPort.Handler.stub(MyContract, :list, fn [_] -> [] end)

  ## Function fallback (2-arity function)

  When the function is 2-arity `fn operation, args -> result end`,
  it acts as a fallback for any operation on the contract that has
  no per-operation expect or stub. This is the same signature as
  `set_fn_handler`, so existing handler functions can be reused:

      HexPort.Handler.stub(MyContract, fn
        :list, [_] -> []
        :count, [] -> 0
      end)

  ## Stateful fallback (3-arity function + initial state)

  When a 3-arity `fn operation, args, state -> {result, new_state} end`
  is passed with an initial state, it acts as a stateful fallback.
  This is the same signature as `set_stateful_handler`, allowing
  stateful fakes like `Repo.InMemory` to be integrated:

      HexPort.Handler.stub(RepoContract, &Repo.InMemory.handler/3, %{})

  The fallback's state is threaded through calls automatically.
  When an expect short-circuits (e.g. returning an error), the
  fallback state is unchanged.

  ## Module fallback (atom)

  When an atom (module name) is passed, all unhandled operations
  delegate to the module via `apply(module, operation, args)`. The
  module must implement the contract's `@behaviour`:

      HexPort.Handler.stub(MyContract, MyApp.Impl)

  The module is validated at `install!` time.

  Function, stateful, and module fallbacks are mutually exclusive —
  setting one replaces the other.

  Dispatch priority: expects > per-operation stubs > fallback > raise.

  The accumulator argument is optional — when omitted, a fresh
  accumulator is created via `new/0`.
  """
  @spec stub(module(), function()) :: t()
  @spec stub(module(), module()) :: t()
  @spec stub(t(), module(), function()) :: t()
  @spec stub(t(), module(), module()) :: t()
  @spec stub(module(), atom(), function()) :: t()
  @spec stub(module(), function(), term()) :: t()
  @spec stub(t(), module(), atom(), function()) :: t()
  @spec stub(t(), module(), function(), term()) :: t()
  def stub(contract, fun)
      when is_atom(contract) and is_function(fun, 2) do
    stub(new(), contract, fun)
  end

  def stub(contract, module)
      when is_atom(contract) and is_atom(module) do
    stub(new(), contract, module)
  end

  def stub(contract, operation, fun)
      when is_atom(contract) and is_atom(operation) and is_function(fun, 1) do
    stub(new(), contract, operation, fun)
  end

  def stub(contract, fun, init_state)
      when is_atom(contract) and is_function(fun, 3) do
    stub(new(), contract, fun, init_state)
  end

  def stub(%__MODULE__{} = acc, contract, fun)
      when is_atom(contract) and is_function(fun, 2) do
    update_contract(acc, contract, fn contract_data ->
      %{contract_data | fallback: {:fn, fun}}
    end)
  end

  def stub(%__MODULE__{} = acc, contract, module)
      when is_atom(contract) and is_atom(module) do
    update_contract(acc, contract, fn contract_data ->
      %{contract_data | fallback: {:module, module}}
    end)
  end

  def stub(%__MODULE__{} = acc, contract, fun, init_state)
      when is_atom(contract) and is_function(fun, 3) do
    update_contract(acc, contract, fn contract_data ->
      %{contract_data | fallback: {:stateful, fun, init_state}}
    end)
  end

  def stub(%__MODULE__{} = acc, contract, operation, fun)
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

    for {contract, %{expects: expects, stubs: stubs, fallback: fallback}} <- contracts do
      validate_fallback!(contract, fallback)
      handler_fn = build_handler_fn(contract, stubs, fallback)

      initial_state =
        case fallback do
          {:stateful, _fun, init_state} -> %{expects: expects, fallback_state: init_state}
          _ -> %{expects: expects}
        end

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
  def verify!, do: do_verify!(self())

  @doc """
  Verify expectations for a specific process.

  Same as `verify!/0` but checks the expectations owned by `pid`
  instead of the calling process. Used internally by `verify_on_exit!/0`.
  """
  @spec verify!(pid()) :: :ok
  def verify!(pid) when is_pid(pid), do: do_verify!(pid)

  @doc """
  Register an `on_exit` callback that verifies expectations after
  each test.

  Call this in a `setup` block so that tests which forget to call
  `verify!/0` explicitly still fail on unconsumed expectations:

      setup :verify_on_exit!

  Or equivalently:

      setup do
        HexPort.Handler.verify_on_exit!()
      end

  The verification runs in the on_exit callback (a separate process),
  using the test pid captured at setup time.
  """
  @spec verify_on_exit!(map()) :: :ok
  def verify_on_exit!(_context \\ %{}) do
    pid = self()

    # Prevent NimbleOwnership from cleaning up when the test process
    # exits — the data must survive until the on_exit callback runs.
    NimbleOwnership.set_owner_to_manual_cleanup(@ownership_server, pid)

    ExUnit.Callbacks.on_exit(HexPort.Handler, fn ->
      try do
        verify!(pid)
      after
        # Clean up the ownership entries now that verification is done.
        NimbleOwnership.cleanup_owner(@ownership_server, pid)
      end
    end)

    :ok
  end

  defp do_verify!(pid) do
    owned = NimbleOwnership.get_owned(@ownership_server, pid)

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
        Enum.map_join(unconsumed, "\n", fn {contract, op, count} ->
          "  #{inspect(contract)}.#{op}: #{count} expected call(s) not made"
        end)

      raise """
      HexPort.Handler expectations not fulfilled:

      #{details}
      """
    end

    :ok
  end

  # -- Internal: accumulator manipulation --

  defp empty_contract_data do
    %{expects: %{}, stubs: %{}, fallback: nil}
  end

  defp update_contract(%__MODULE__{contracts: contracts} = acc, contract, update_fn) do
    contract_data = Map.get(contracts, contract, empty_contract_data())
    updated = update_fn.(contract_data)
    %{acc | contracts: Map.put(contracts, contract, updated)}
  end

  # -- Internal: handler construction --

  defp build_handler_fn(contract, stubs, fallback) do
    fn operation, args, state ->
      case pop_expect(state, operation) do
        {:ok, :passthrough, new_state} ->
          # Delegate to fallback, consuming the expect for verify! counting
          invoke_fallback_or_raise(fallback, contract, operation, args, new_state)

        {:ok, fun, new_state} ->
          {fun.(args), new_state}

        :none ->
          case Map.get(stubs, operation) do
            nil ->
              invoke_fallback_or_raise(fallback, contract, operation, args, state)

            stub_fun ->
              {stub_fun.(args), state}
          end
      end
    end
  end

  defp invoke_fallback_or_raise(nil, contract, operation, args, state) do
    # Defer the raise so it happens in the calling process,
    # not inside the NimbleOwnership GenServer.
    msg = unexpected_call_message(contract, operation, args, state)
    {{:defer, fn -> raise msg end}, state}
  end

  defp invoke_fallback_or_raise({:fn, fallback_fn}, contract, operation, args, state) do
    result = fallback_fn.(operation, args)
    {result, state}
  rescue
    FunctionClauseError ->
      # FunctionClauseError from the fallback fn means it doesn't handle
      # this operation — defer the raise to the calling process.
      msg = unexpected_call_message(contract, operation, args, state)
      {{:defer, fn -> reraise msg, __STACKTRACE__ end}, state}
  end

  defp invoke_fallback_or_raise({:stateful, fallback_fn, _init}, contract, operation, args, state) do
    fallback_state = state.fallback_state
    {result, new_fallback_state} = fallback_fn.(operation, args, fallback_state)
    {result, %{state | fallback_state: new_fallback_state}}
  rescue
    FunctionClauseError ->
      msg = unexpected_call_message(contract, operation, args, state)
      {{:defer, fn -> reraise msg, __STACKTRACE__ end}, state}
  end

  defp invoke_fallback_or_raise({:module, module}, contract, operation, args, state) do
    result = apply(module, operation, args)
    {result, state}
  rescue
    UndefinedFunctionError ->
      # The module doesn't implement this operation.
      msg = unexpected_call_message(contract, operation, args, state)
      {{:defer, fn -> reraise msg, __STACKTRACE__ end}, state}
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

  defp unexpected_call_message(contract, operation, args, %{expects: expects}) do
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

    """
    Unexpected call to #{inspect(contract)}.#{operation}/#{length(args)}.

    No expectations or stubs defined for this operation.

    Remaining expectations for #{inspect(contract)}:
    #{remaining_msg}
    """
  end

  defp validate_fallback!(_contract, nil), do: :ok
  defp validate_fallback!(_contract, {:fn, _fun}), do: :ok
  defp validate_fallback!(_contract, {:stateful, _fun, _init}), do: :ok

  defp validate_fallback!(contract, {:module, module}) do
    unless Code.ensure_loaded?(module) do
      raise ArgumentError,
            "module fallback #{inspect(module)} for #{inspect(contract)} is not loaded"
    end

    # Check that the module exports the contract's operations
    Code.ensure_loaded(contract)

    if function_exported?(contract, :__port_operations__, 0) do
      operations = contract.__port_operations__()

      missing =
        Enum.reject(operations, fn %{name: name, arity: arity} ->
          function_exported?(module, name, arity)
        end)

      if missing != [] do
        details =
          Enum.map_join(missing, ", ", fn %{name: name, arity: arity} ->
            "#{name}/#{arity}"
          end)

        raise ArgumentError,
              "module fallback #{inspect(module)} for #{inspect(contract)} " <>
                "is missing functions: #{details}"
      end
    end

    :ok
  end

  defp store_installed_contracts(contract_modules) do
    NimbleOwnership.get_and_update(@ownership_server, self(), @contracts_key, fn
      nil -> {:ok, contract_modules}
      existing -> {:ok, Enum.uniq(existing ++ contract_modules)}
    end)
  end
end
