defmodule DoubleDown.Handler do
  @moduledoc """
  Mox-style expect/stub handler declarations with immediate effect.

  Each `expect` and `stub` call writes directly to NimbleOwnership —
  no builder struct, no `install!` step. Functions return the contract
  module atom for Mimic-style piping.

  ## Basic usage

      DoubleDown.Handler.expect(MyContract, :get_thing, fn [id] -> %Thing{id: id} end)
      DoubleDown.Handler.stub(MyContract, :list, fn [_] -> [] end)

      # ... run code under test ...

      DoubleDown.Handler.verify!()

  ## Piping

  All functions return the contract module, so you can pipe:

      MyContract
      |> DoubleDown.Handler.expect(:get_thing, fn [id] -> %Thing{id: id} end)
      |> DoubleDown.Handler.stub(:list, fn [_] -> [] end)

  ## Sequenced expectations

  Successive calls to `expect` for the same operation queue handlers
  that are consumed in order:

      MyContract
      |> DoubleDown.Handler.expect(:get_thing, fn [_] -> {:error, :not_found} end)
      |> DoubleDown.Handler.expect(:get_thing, fn [id] -> %Thing{id: id} end)

      # First call returns :not_found, second returns the thing

  ## Repeated expectations

  Use `times: n` when the same function should handle multiple calls:

      DoubleDown.Handler.expect(MyContract, :check, fn [_] -> :ok end, times: 3)

  ## Expects + stubs

  When an operation has both expects and a stub, expects are consumed
  first; once exhausted, the stub handles all subsequent calls:

      MyContract
      |> DoubleDown.Handler.expect(:get, fn [_] -> :first end)
      |> DoubleDown.Handler.stub(:get, fn [_] -> :default end)

  ## Contract-wide fallback

  A fallback handles any operation without a specific expect or
  per-operation stub. Three forms are supported:

  ### Function fallback

  A 2-arity `fn operation, args -> result end` — the same signature
  as `set_fn_handler`:

      MyContract
      |> DoubleDown.Handler.expect(:get, fn [id] -> %Thing{id: id} end)
      |> DoubleDown.Handler.stub(fn
        :list, [_] -> []
        :count, [] -> 0
      end)

  ### Stateful fallback

  A 3-arity `fn operation, args, state -> {result, new_state} end` —
  the same signature as `set_stateful_handler`. This integrates a
  stateful fake (like `Repo.InMemory`) into the dispatch chain while
  allowing expects to override specific calls:

      # First insert fails, rest go through the stateful handler
      RepoContract
      |> DoubleDown.Handler.stub(&Repo.InMemory.handler/3, %{})
      |> DoubleDown.Handler.expect(:insert, fn [changeset] ->
        {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
      end)

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

      MyContract
      |> DoubleDown.Handler.expect(:get, fn [_] -> {:error, :not_found} end)
      |> DoubleDown.Handler.stub(MyApp.Impl)

  The module is validated at stub time — all contract operations
  must be exported.

  **Mimic-style limitation:** if the module's `:bar` internally calls
  `:foo`, and you've stubbed `:foo`, the module won't see your stub —
  it calls its own `:foo` directly. For stubs to be visible, the
  module must call through the facade.

  Dispatch priority: expects > per-operation stubs > fallback > raise.
  Function, stateful, and module fallbacks are mutually exclusive —
  setting one replaces the other.

  ## Passthrough expects

  When a fallback is configured, pass `:passthrough` instead of a
  function to delegate to the fallback while still consuming the
  expect for `verify!` counting:

      MyContract
      |> DoubleDown.Handler.stub(MyApp.Impl)
      |> DoubleDown.Handler.expect(:get, :passthrough, times: 2)

  ## Multi-contract

      RepoContract
      |> DoubleDown.Handler.stub(&Repo.InMemory.handler/3, %{})
      |> DoubleDown.Handler.expect(:insert, fn [cs] -> {:error, :taken} end)

      QueriesContract
      |> DoubleDown.Handler.expect(:get_record, fn [id] -> %Record{id: id} end)

  ## Relationship to Mox

  | Mox | DoubleDown.Handler |
  |-----|-----------------|
  | `expect(Mock, :fn, n, fun)` | `expect(Contract, :fn, fun, times: n)` |
  | `stub(Mock, :fn, fun)` | `stub(Contract, :fn, fun)` — per-operation |
  | (no equivalent) | `stub(Contract, fn op, args -> ... end)` — function fallback |
  | (no equivalent) | `stub(Contract, fn op, args, state -> ... end, init)` — stateful fallback |
  | (no equivalent) | `stub(Contract, ImplModule)` — module fallback |
  | `verify!()` | `verify!()` |
  | `verify_on_exit!()` | `verify_on_exit!()` |
  | `Mox.defmock(Mock, for: Behaviour)` | Not needed |
  | `Application.put_env(...)` | Not needed |

  ## Relationship to existing APIs

  This is a higher-level convenience built on `set_stateful_handler`.
  It does not replace `set_fn_handler` or `set_stateful_handler` —
  those remain for cases that don't fit the expect/stub pattern.
  """

  @ownership_server DoubleDown.Dispatch.Ownership
  @contracts_key DoubleDown.Handler.Contracts

  # -- Public API: expect --

  @doc """
  Add an expectation for a contract operation.

  The function receives the argument list and returns the result.
  Expectations are consumed in order — the first `expect` for an
  operation handles the first call, the second handles the second,
  and so on.

  Instead of a function, pass `:passthrough` to delegate to the
  fallback (fn, stateful, or module) while still consuming the
  expect for `verify!` counting.

  Returns the contract module for piping.

  ## Options

    * `:times` — enqueue the same function `n` times (default 1).
      Equivalent to calling `expect` `n` times with the same function.
  """
  @spec expect(module(), atom(), function() | :passthrough, keyword()) :: module()
  def expect(contract, operation, fun_or_passthrough, opts \\ [])

  def expect(contract, operation, fun, opts)
      when is_atom(contract) and is_atom(operation) and is_function(fun, 1) and is_list(opts) do
    do_expect(contract, operation, fun, opts)
  end

  def expect(contract, operation, :passthrough, opts)
      when is_atom(contract) and is_atom(operation) and is_list(opts) do
    do_expect(contract, operation, :passthrough, opts)
  end

  defp do_expect(contract, operation, fun_or_passthrough, opts) do
    times = Keyword.get(opts, :times, 1)

    if times < 1 do
      raise ArgumentError, "times must be >= 1, got: #{times}"
    end

    entries = List.duplicate(fun_or_passthrough, times)

    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      existing = Map.get(state.expects, operation, [])
      %{state | expects: Map.put(state.expects, operation, existing ++ entries)}
    end)

    contract
  end

  # -- Public API: stub --

  @doc """
  Add a stub for a contract operation or a contract-wide fallback.

  ## Per-operation stub (1-arity function)

  The function receives the argument list and returns the result.
  Stubs handle any number of calls and are used after all expectations
  for an operation are consumed. Setting a stub twice for the same
  operation replaces the previous one.

      DoubleDown.Handler.stub(MyContract, :list, fn [_] -> [] end)

  ## Function fallback (2-arity function)

  When the function is 2-arity `fn operation, args -> result end`,
  it acts as a fallback for any operation on the contract that has
  no per-operation expect or stub. This is the same signature as
  `set_fn_handler`, so existing handler functions can be reused:

      DoubleDown.Handler.stub(MyContract, fn
        :list, [_] -> []
        :count, [] -> 0
      end)

  ## Stateful fallback (3-arity function + initial state)

  When a 3-arity `fn operation, args, state -> {result, new_state} end`
  is passed with an initial state, it acts as a stateful fallback.
  This is the same signature as `set_stateful_handler`, allowing
  stateful fakes like `Repo.InMemory` to be integrated:

      DoubleDown.Handler.stub(RepoContract, &Repo.InMemory.handler/3, %{})

  The fallback's state is threaded through calls automatically.
  When an expect short-circuits (e.g. returning an error), the
  fallback state is unchanged.

  ## Module fallback (atom)

  When an atom (module name) is passed, all unhandled operations
  delegate to the module via `apply(module, operation, args)`. The
  module must implement the contract's `@behaviour`:

      DoubleDown.Handler.stub(MyContract, MyApp.Impl)

  The module is validated immediately.

  Function, stateful, and module fallbacks are mutually exclusive —
  setting one replaces the other.

  Dispatch priority: expects > per-operation stubs > fallback > raise.

  Returns the contract module for piping.
  """
  # stub/2 — function fallback or module fallback
  @spec stub(module(), function()) :: module()
  @spec stub(module(), module()) :: module()
  def stub(contract, fun)
      when is_atom(contract) and is_function(fun, 2) do
    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      %{state | fallback: {:fn, fun}}
    end)

    contract
  end

  def stub(contract, module)
      when is_atom(contract) and is_atom(module) do
    validate_module_fallback!(contract, module)
    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      %{state | fallback: {:module, module}}
    end)

    contract
  end

  # stub/3 — per-operation stub or stateful fallback
  @spec stub(module(), atom(), function()) :: module()
  @spec stub(module(), function(), term()) :: module()
  def stub(contract, operation, fun)
      when is_atom(contract) and is_atom(operation) and is_function(fun, 1) do
    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      %{state | stubs: Map.put(state.stubs, operation, fun)}
    end)

    contract
  end

  def stub(contract, fun, init_state)
      when is_atom(contract) and is_function(fun, 3) do
    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      %{state | fallback: {:stateful, fun}, fallback_state: init_state}
    end)

    contract
  end

  # -- Public API: verify --

  @doc """
  Verify that all expectations have been consumed.

  Reads the current handler state for each contract and checks that
  all expect queues are empty. Stubs are not checked — they are
  allowed to be called zero or more times.

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
        DoubleDown.Handler.verify_on_exit!()
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

    ExUnit.Callbacks.on_exit(DoubleDown.Handler, fn ->
      try do
        verify!(pid)
      after
        # Clean up the ownership entries now that verification is done.
        NimbleOwnership.cleanup_owner(@ownership_server, pid)
      end
    end)

    :ok
  end

  # -- Internal: handler installation --

  @initial_state %{contract: nil, expects: %{}, stubs: %{}, fallback: nil, fallback_state: nil}

  defp ensure_handler_installed(contract) do
    state_key = Module.concat(DoubleDown.State, contract)

    # Check if we've already installed the handler for this contract
    case NimbleOwnership.get_owned(@ownership_server, self()) do
      %{^state_key => _} ->
        :ok

      _ ->
        # First touch — install the canonical handler fn
        DoubleDown.Testing.set_stateful_handler(
          contract,
          &canonical_handler/3,
          %{@initial_state | contract: contract}
        )

        register_contract(contract)
    end
  end

  defp register_contract(contract) do
    NimbleOwnership.get_and_update(@ownership_server, self(), @contracts_key, fn
      nil -> {:ok, [contract]}
      existing -> {:ok, Enum.uniq([contract | existing])}
    end)
  end

  defp update_handler_state(contract, update_fn) do
    state_key = Module.concat(DoubleDown.State, contract)

    NimbleOwnership.get_and_update(@ownership_server, self(), state_key, fn state ->
      {:ok, update_fn.(state)}
    end)
  end

  # -- Internal: canonical handler fn --

  # This single function handles all dispatch. It reads expects, stubs,
  # and fallback config from state at dispatch time. Installed once per
  # contract via set_stateful_handler and never replaced — all changes
  # go through state mutations.
  @doc false
  def canonical_handler(operation, args, state) do
    case pop_expect(state, operation) do
      {:ok, :passthrough, new_state} ->
        invoke_fallback_or_raise(new_state, operation, args)

      {:ok, fun, new_state} ->
        {fun.(args), new_state}

      :none ->
        case Map.get(state.stubs, operation) do
          nil ->
            invoke_fallback_or_raise(state, operation, args)

          stub_fun ->
            {stub_fun.(args), state}
        end
    end
  end

  defp pop_expect(%{expects: expects} = state, operation) do
    case Map.get(expects, operation, []) do
      [entry | rest] ->
        new_expects = Map.put(expects, operation, rest)
        {:ok, entry, %{state | expects: new_expects}}

      [] ->
        :none
    end
  end

  defp invoke_fallback_or_raise(state, operation, args) do
    case state.fallback do
      nil ->
        msg = unexpected_call_message(state.contract, state, operation, args)
        {{:defer, fn -> raise msg end}, state}

      {:fn, fallback_fn} ->
        invoke_fn_fallback(fallback_fn, state, operation, args)

      {:stateful, fallback_fn} ->
        invoke_stateful_fallback(fallback_fn, state, operation, args)

      {:module, module} ->
        invoke_module_fallback(module, state, operation, args)
    end
  end

  defp invoke_fn_fallback(fallback_fn, state, operation, args) do
    result = fallback_fn.(operation, args)
    {result, state}
  rescue
    FunctionClauseError ->
      msg = unexpected_call_message(state.contract, state, operation, args)
      {{:defer, fn -> reraise msg, __STACKTRACE__ end}, state}
  end

  defp invoke_stateful_fallback(fallback_fn, state, operation, args) do
    {result, new_fallback_state} = fallback_fn.(operation, args, state.fallback_state)
    {result, %{state | fallback_state: new_fallback_state}}
  rescue
    FunctionClauseError ->
      msg = unexpected_call_message(state.contract, state, operation, args)
      {{:defer, fn -> reraise msg, __STACKTRACE__ end}, state}
  end

  defp invoke_module_fallback(module, state, operation, args) do
    result = apply(module, operation, args)
    {result, state}
  rescue
    UndefinedFunctionError ->
      msg = unexpected_call_message(state.contract, state, operation, args)
      {{:defer, fn -> reraise msg, __STACKTRACE__ end}, state}
  end

  defp unexpected_call_message(contract, %{expects: expects}, operation, args) do
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

    Args: #{inspect(args)}

    No expectations or stubs defined for this operation.

    Remaining expectations for #{inspect(contract)}:
    #{remaining_msg}
    """
  end

  # -- Internal: verification --

  defp do_verify!(pid) do
    owned = NimbleOwnership.get_owned(@ownership_server, pid)

    contracts =
      case owned do
        %{@contracts_key => contracts} ->
          contracts

        _ ->
          raise "DoubleDown.Handler.verify!/0 called but no handlers were installed"
      end

    unconsumed =
      Enum.flat_map(contracts, fn contract ->
        state_key = Module.concat(DoubleDown.State, contract)

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
      DoubleDown.Handler expectations not fulfilled:

      #{details}
      """
    end

    :ok
  end

  # -- Internal: module fallback validation --

  defp validate_module_fallback!(contract, module) do
    unless Code.ensure_loaded?(module) do
      raise ArgumentError,
            "module fallback #{inspect(module)} for #{inspect(contract)} is not loaded"
    end

    Code.ensure_loaded(contract)

    if function_exported?(contract, :__callbacks__, 0) do
      operations = contract.__callbacks__()

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
  end
end
