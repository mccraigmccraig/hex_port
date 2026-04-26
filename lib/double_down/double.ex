defmodule DoubleDown.Double do
  @moduledoc """
  Mox-style expect/stub handler declarations with immediate effect.

  Each `expect` and `stub` call writes directly to NimbleOwnership —
  no builder struct, no `install!` step. Functions return the contract
  module atom for Mimic-style piping.

  ## Basic usage

      DoubleDown.Double.expect(MyContract, :get_thing, fn [id] -> %Thing{id: id} end)
      DoubleDown.Double.stub(MyContract, :list, fn [_] -> [] end)

      # ... run code under test ...

      DoubleDown.Double.verify!()

  ## Piping

  All functions return the contract module, so you can pipe:

      MyContract
      |> DoubleDown.Double.expect(:get_thing, fn [id] -> %Thing{id: id} end)
      |> DoubleDown.Double.stub(:list, fn [_] -> [] end)

  ## Sequenced expectations

  Successive calls to `expect` for the same operation queue handlers
  that are consumed in order:

      MyContract
      |> DoubleDown.Double.expect(:get_thing, fn [_] -> {:error, :not_found} end)
      |> DoubleDown.Double.expect(:get_thing, fn [id] -> %Thing{id: id} end)

      # First call returns :not_found, second returns the thing

  ## Repeated expectations

  Use `times: n` when the same function should handle multiple calls:

      DoubleDown.Double.expect(MyContract, :check, fn [_] -> :ok end, times: 3)

  ## Expects + stubs

  When an operation has both expects and a stub, expects are consumed
  first; once exhausted, the stub handles all subsequent calls:

      MyContract
      |> DoubleDown.Double.expect(:get, fn [_] -> :first end)
      |> DoubleDown.Double.stub(:get, fn [_] -> :default end)

  ## Fallback handlers

  A fallback handles any operation without a specific expect, per-op
  fake, or per-op stub. Use `Double.fallback/2..4` to install one:

      # StatefulHandler module (recommended)
      DoubleDown.Repo
      |> DoubleDown.Double.fallback(Repo.OpenInMemory)
      |> DoubleDown.Double.expect(:insert, fn [changeset] ->
        {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
      end)

      # Stateless function fallback
      MyContract
      |> DoubleDown.Double.fallback(fn _contract, operation, args ->
        case {operation, args} do
          {:list, [_]} -> []
          {:count, []} -> 0
        end
      end)

  See `fallback/2` for all supported forms (StatefulHandler module,
  StatelessHandler module, module implementation, stateful function,
  stateless function).

  Dispatch priority: expects > per-op fakes > per-op stubs > fallback > raise.
  Fallback types are mutually exclusive — setting one replaces the other.

  ## Passthrough expects

  When a fallback/fake is configured, pass `:passthrough` instead of
  a function to delegate while still consuming the expect for
  `verify!` counting:

      MyContract
      |> DoubleDown.Double.fallback(MyApp.Impl)
      |> DoubleDown.Double.expect(:get, :passthrough, times: 2)

  ## Multi-contract

      DoubleDown.Repo
      |> DoubleDown.Double.fallback(&Repo.OpenInMemory.dispatch/4, Repo.OpenInMemory.new())
      |> DoubleDown.Double.expect(:insert, fn [cs] -> {:error, :taken} end)

      QueriesContract
      |> DoubleDown.Double.expect(:get_record, fn [id] -> %Record{id: id} end)

  ## Relationship to Mox

  | Mox | DoubleDown.Double |
  |-----|-----------------|
  | `expect(Mock, :fn, n, fun)` | `expect(Contract, :fn, fun, times: n)` |
  | `stub(Mock, :fn, fun)` | `stub(Contract, :fn, fun)` — per-operation |
  | (no equivalent) | `fallback(Contract, fn op, args -> ... end)` — stateless fallback |
  | (no equivalent) | `fallback(Contract, fn op, args, state -> ... end, init)` — stateful fallback |
  | (no equivalent) | `fallback(Contract, ImplModule)` — module fallback |
  | `verify!()` | `verify!()` |
  | `verify_on_exit!()` | `verify_on_exit!()` |
  | `Mox.defmock(Mock, for: Behaviour)` | Not needed |
  | `Application.put_env(...)` | Not needed |

  ## Relationship to existing APIs

  This is a higher-level convenience built on `set_stateful_handler`.
  It does not replace `set_stateless_handler` or `set_stateful_handler` —
  those remain for cases that don't fit the expect/stub/fake/fallback pattern.

  ## Known limitations

  **FunctionClauseError in fallback bodies:** When a stub or fake
  fallback function has no matching clause for an operation, DoubleDown
  catches the `FunctionClauseError` and raises a helpful "Unexpected
  call" error instead. However, if a fallback clause *does* match but
  its body internally calls a function that raises `FunctionClauseError`,
  that exception is also caught and misreported as "Unexpected call".
  This is a known limitation shared with Mox. If you see a surprising
  "Unexpected call" error, check whether your fallback body contains
  code that might raise `FunctionClauseError`.
  """

  alias DoubleDown.Contract.Dispatch.HandlerMeta
  alias DoubleDown.Contract.Dispatch.Keys
  alias DoubleDown.Double.CanonicalHandlerState

  # -- Public API: passthrough sentinel --

  @doc """
  Return a passthrough sentinel for use in expect responders.

  When returned from an expect responder, delegates the call to the
  fallback/fake as if the expect had been registered with `:passthrough`.
  The expect is still consumed for `verify!` counting.

  This enables conditional passthrough — the responder can inspect
  the state and decide whether to handle the call or delegate:

      DoubleDown.Repo
      |> Double.fallback(&Repo.OpenInMemory.dispatch/4, Repo.OpenInMemory.new())
      |> Double.expect(:insert, fn [changeset], state ->
        if duplicate?(state, changeset) do
          {{:error, add_error(changeset, :email, "taken")}, state}
        else
          Double.passthrough()
        end
      end)
  """
  @spec passthrough() :: DoubleDown.Contract.Dispatch.Passthrough.t()
  def passthrough, do: DoubleDown.Contract.Dispatch.Passthrough.new()

  # -- Public API: expect --

  @doc """
  Add an expectation for a contract operation.

  The responder function may be:

    * **1-arity** `fn [args] -> result end` — stateless, returns a bare result
    * **2-arity** `fn [args], state -> {result, new_state} end` — reads and
      updates the stateful fake's state. Requires `fake/3` first.
    * **3-arity** `fn [args], state, all_states -> {result, new_state} end` —
      same as 2-arity plus a read-only snapshot of all contract states for
      cross-contract access. Requires `fake/3` first.

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
  @spec expect(module(), atom(), DoubleDown.Double.Types.expect_fun() | :passthrough, keyword()) ::
          module()
  def expect(contract, operation, fun_or_passthrough, opts \\ [])

  def expect(contract, operation, fun, opts)
      when is_atom(contract) and is_atom(operation) and
             (is_function(fun, 1) or is_function(fun, 2) or is_function(fun, 3)) and
             is_list(opts) do
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

    # Stateful responders (2-arity, 3-arity) require a stateful fake
    # to be configured first, so there's a fallback_state to pass.
    if is_function(fun_or_passthrough) and
         not is_function(fun_or_passthrough, 1) do
      validate_stateful_fake_exists!(contract, operation, fun_or_passthrough)
    end

    update_handler_state(contract, fn state ->
      CanonicalHandlerState.add_expects(state, operation, entries)
    end)

    contract
  end

  defp validate_stateful_fake_exists!(contract, operation, fun) do
    case NimbleOwnership.get_owned(Keys.ownership_server(), self()) do
      %{^contract => %HandlerMeta.Stateful{state: %CanonicalHandlerState{} = chs}} ->
        unless CanonicalHandlerState.stateful_fallback?(chs) do
          raise_no_stateful_fake(contract, operation, fun)
        end

      _ ->
        raise_no_stateful_fake(contract, operation, fun)
    end
  end

  defp raise_no_stateful_fake(contract, operation, fun) do
    arity = :erlang.fun_info(fun)[:arity]

    raise ArgumentError, """
    expect for :#{operation} received a #{arity}-arity stateful responder, \
    but no stateful fake is configured on #{inspect(contract)}.

    Stateful responders (2-arity or 3-arity) require a stateful fallback \
    set via Double.fallback/3 before calling expect. Use a 1-arity \
    fn [args] -> result end for stateless expects.
    """
  end

  # -- Public API: stub --

  @doc """
  Add a per-operation stub for a contract operation.

  The function receives the argument list and returns the result.
  Stubs are stateless — for stateful per-operation overrides, use
  `fake/3` or `expect/4` with a 2-arity or 3-arity responder.

  Stubs handle any number of calls and are used after all expectations
  for an operation are consumed. Setting a stub twice for the same
  operation replaces the previous one.

  The stub may return `Double.passthrough()` to delegate to the
  fallback for that specific call.

      DoubleDown.Double.stub(MyContract, :list, fn [_] -> [] end)

  For whole-contract fallback handlers, see `fallback/2..4`.

  Dispatch priority: expects > per-op fakes > per-op stubs > fallback > raise.

  Returns the contract module for piping.
  """
  @spec stub(module(), atom(), DoubleDown.Double.Types.stub_fun()) :: module()
  def stub(contract, operation, fun)
      when is_atom(contract) and is_atom(operation) and is_function(fun, 1) do
    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      CanonicalHandlerState.put_stub(state, operation, fun)
    end)

    contract
  end

  # -- Public API: fake --

  @doc """
  Add a per-operation fake for a contract operation.

  Overrides a single operation with a stateful function that reads
  and updates the fallback's state. Requires a stateful fallback
  to be installed first via `fallback/3`:

      DoubleDown.Repo
      |> DoubleDown.Double.fallback(&Repo.OpenInMemory.dispatch/4, Repo.OpenInMemory.new())
      |> DoubleDown.Double.fake(:insert, fn [changeset], state ->
        {{:error, add_error(changeset, :email, "taken")}, state}
      end)

  The function may be:

    * **2-arity** `fn [args], state -> {result, new_state} end`
    * **3-arity** `fn [args], state, all_states -> {result, new_state} end`
      (cross-contract state access)

  Per-op fakes are permanent (not consumed like expects) and can
  return `Double.passthrough()` to delegate to the fallback.
  Setting a per-op fake twice for the same operation replaces the
  previous one.

  For whole-contract fallback handlers, see `fallback/2..4`.

  Dispatch priority: expects > per-op fakes > per-op stubs > fallback > raise.

  Returns the contract module for piping.
  """
  @spec fake(module(), atom(), DoubleDown.Double.Types.fake_fun()) :: module()
  def fake(contract, operation, fun)
      when is_atom(contract) and is_atom(operation) and
             (is_function(fun, 2) or is_function(fun, 3)) do
    ensure_handler_installed(contract)
    validate_stateful_fake_exists!(contract, operation, fun)

    update_handler_state(contract, fn state ->
      CanonicalHandlerState.put_fake(state, operation, fun)
    end)

    contract
  end

  # -- Public API: fallback --

  @doc """
  Install a whole-contract fallback handler.

  The fallback handles any operation not covered by an `expect`,
  per-op `fake`, or per-op `stub`. Several forms are supported:

  ## StatefulHandler module (recommended for stateful fallbacks)

  A module implementing `DoubleDown.Contract.Dispatch.StatefulHandler`.
  The module's `new/2` builds initial state, and its `dispatch/4` or
  `dispatch/5` handles operations:

      # Default state
      DoubleDown.Double.fallback(MyContract, Repo.OpenInMemory)

      # With seed data
      DoubleDown.Double.fallback(MyContract, Repo.OpenInMemory, [%User{id: 1}])

      # With seed data and options
      DoubleDown.Double.fallback(MyContract, Repo.OpenInMemory, [%User{id: 1}],
        fallback_fn: fn _contract, :all, [User], state -> Map.values(state[User]) end
      )

  ## StatelessHandler module

  A module implementing `DoubleDown.Contract.Dispatch.StatelessHandler`.
  The module's `new/2` builds a stateless dispatch function:

      # Writes only — reads will raise
      DoubleDown.Double.fallback(MyContract, DoubleDown.Repo.Stub)

      # With a fallback function for reads
      DoubleDown.Double.fallback(MyContract, DoubleDown.Repo.Stub,
        fn _contract, :all, [User] -> [] end)

  ## Module implementation

  A module implementing the contract's `@behaviour` (but not a
  StatefulHandler or StatelessHandler). All operations delegate via
  `apply(module, operation, args)`:

      DoubleDown.Double.fallback(MyContract, MyApp.Impl)

  **Mimic-style limitation:** if the module's `:bar` internally calls
  `:foo`, and you've stubbed `:foo`, the module won't see your stub —
  it calls its own `:foo` directly.

  ## Stateful function

  A 4-arity `fn contract, operation, args, state -> {result, new_state} end`
  or 5-arity `fn contract, operation, args, state, all_states -> {result, new_state} end`
  with initial state:

      DoubleDown.Double.fallback(MyContract, &handler/4, initial_state)

  ## Stateless function

  A 3-arity `fn contract, operation, args -> result end`:

      DoubleDown.Double.fallback(MyContract, fn _contract, operation, args ->
        case {operation, args} do
          {:list, [_]} -> []
          {:count, []} -> 0
        end
      end)

  Fallback types are mutually exclusive — setting one replaces the other.

  Dispatch priority: expects > per-op fakes > per-op stubs > fallback > raise.

  Returns the contract module for piping.
  """
  # fallback/2 — stateless function, module implementation,
  #              StatefulHandler with default state, or StatelessHandler
  @spec fallback(module(), function() | module()) :: module()
  def fallback(contract, fun)
      when is_atom(contract) and is_function(fun, 3) do
    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      CanonicalHandlerState.set_stateless_fallback(state, fun)
    end)

    contract
  end

  def fallback(contract, module)
      when is_atom(contract) and is_atom(module) do
    cond do
      stateful_handler?(module) ->
        do_stateful_handler(contract, module, %{}, [])

      stateless_handler?(module) ->
        do_stateless_handler(contract, module, nil, [])

      true ->
        validate_module_fallback!(contract, module)
        ensure_handler_installed(contract)

        update_handler_state(contract, fn state ->
          CanonicalHandlerState.set_module_fallback(state, module)
        end)

        contract
    end
  end

  # fallback/3 — stateful function with initial state,
  #              StatefulHandler with seed, or StatelessHandler with fallback_fn
  @spec fallback(module(), function() | module(), term()) :: module()
  def fallback(contract, fun, init_state)
      when is_atom(contract) and (is_function(fun, 4) or is_function(fun, 5)) do
    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      CanonicalHandlerState.set_stateful_fallback(state, fun, init_state)
    end)

    contract
  end

  def fallback(contract, module, seed_or_fallback_fn)
      when is_atom(contract) and is_atom(module) do
    cond do
      stateful_handler?(module) ->
        do_stateful_handler(contract, module, seed_or_fallback_fn, [])

      stateless_handler?(module) ->
        do_stateless_handler(contract, module, seed_or_fallback_fn, [])

      true ->
        raise ArgumentError, """
        #{inspect(module)} is not a StatefulHandler or StatelessHandler module.

        For module implementations, use fallback/2: Double.fallback(contract, module)
        For seed data, the module must implement StatefulHandler or StatelessHandler.
        """
    end
  end

  # fallback/4 — StatefulHandler or StatelessHandler with seed/fallback_fn and opts
  @spec fallback(module(), module(), term(), keyword()) :: module()
  def fallback(contract, module, seed_or_fallback_fn, opts)
      when is_atom(contract) and is_atom(module) and is_list(opts) do
    cond do
      stateful_handler?(module) ->
        do_stateful_handler(contract, module, seed_or_fallback_fn, opts)

      stateless_handler?(module) ->
        do_stateless_handler(contract, module, seed_or_fallback_fn, opts)

      true ->
        raise ArgumentError, """
        #{inspect(module)} is not a StatefulHandler or StatelessHandler module.

        To use with Double.fallback/4, it must implement one of:
          @behaviour DoubleDown.Contract.Dispatch.StatefulHandler
          @behaviour DoubleDown.Contract.Dispatch.StatelessHandler
        """
    end
  end

  defp do_stateful_handler(contract, module, seed, opts) do
    dispatch_fn = resolve_stateful_dispatch(module)
    init_state = module.new(seed, opts)

    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      CanonicalHandlerState.set_stateful_fallback(state, dispatch_fn, init_state)
    end)

    contract
  end

  defp do_stateless_handler(contract, module, fallback_fn, opts) do
    handler_fn = module.new(fallback_fn, opts)

    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      CanonicalHandlerState.set_stateless_fallback(state, handler_fn)
    end)

    contract
  end

  defp stateful_handler?(module) do
    Code.ensure_loaded?(module) and
      implements_behaviour?(module, DoubleDown.Contract.Dispatch.StatefulHandler)
  end

  defp stateless_handler?(module) do
    Code.ensure_loaded?(module) and
      implements_behaviour?(module, DoubleDown.Contract.Dispatch.StatelessHandler)
  end

  # Prefer dispatch/5 (cross-contract) over dispatch/4
  defp resolve_stateful_dispatch(module) do
    cond do
      function_exported?(module, :dispatch, 5) -> &module.dispatch/5
      function_exported?(module, :dispatch, 4) -> &module.dispatch/4
      true -> raise ArgumentError, "#{inspect(module)} must export dispatch/4 or dispatch/5"
    end
  end

  # -- Public API: dynamic --

  @doc """
  Set up a dynamically-faked module with its original implementation
  as the fallback.

  Requires the module to have been set up with
  `DoubleDown.DynamicFacade.setup/1`. Layer expects and stubs on top:

      SomeClient
      |> DoubleDown.Double.dynamic()
      |> DoubleDown.Double.expect(:fetch, fn [_] -> {:error, :timeout} end)

  Calls without a matching expect or stub delegate to the original
  module's implementation.

  Returns the module for piping.
  """
  @spec dynamic(module()) :: module()
  def dynamic(module) when is_atom(module) do
    unless DoubleDown.DynamicFacade.setup?(module) do
      raise ArgumentError, """
      #{inspect(module)} has not been set up for dynamic dispatch.

      Call DoubleDown.DynamicFacade.setup(#{inspect(module)}) in test_helper.exs \
      before ExUnit.start().
      """
    end

    fallback(module, DoubleDown.DynamicFacade.original_module(module))
  end

  # -- Public API: allow --

  @doc """
  Allow a child process to use the current process's test doubles.

  Delegates to `DoubleDown.Testing.allow/3`. Use this when spawning
  Tasks or other processes that need to dispatch through the same
  test handlers.

      {:ok, pid} = MyApp.Worker.start_link([])
      DoubleDown.Double.allow(MyContract, pid)

  Also accepts a lazy pid function for processes that don't exist
  yet at setup time:

      DoubleDown.Double.allow(MyContract, fn -> GenServer.whereis(MyWorker) end)
  """
  @spec allow(module(), pid() | (-> pid() | [pid()])) :: :ok | {:error, term()}
  @spec allow(module(), pid(), pid() | (-> pid() | [pid()])) :: :ok | {:error, term()}
  defdelegate allow(contract, owner_pid \\ self(), child_pid), to: DoubleDown.Testing

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
        DoubleDown.Double.verify_on_exit!()
      end

  The verification runs in the on_exit callback (a separate process),
  using the test pid captured at setup time.
  """
  @spec verify_on_exit!(map()) :: :ok
  def verify_on_exit!(_context \\ %{}) do
    pid = self()

    # Prevent NimbleOwnership from cleaning up when the test process
    # exits — the data must survive until the on_exit callback runs.
    NimbleOwnership.set_owner_to_manual_cleanup(Keys.ownership_server(), pid)

    ExUnit.Callbacks.on_exit(DoubleDown.Double, fn ->
      try do
        verify!(pid)
      after
        # Clean up the ownership entries now that verification is done.
        NimbleOwnership.cleanup_owner(Keys.ownership_server(), pid)
      end
    end)

    :ok
  end

  # -- Internal: handler installation --

  defp ensure_handler_installed(contract) do
    # Check if we've already installed the handler for this contract
    case NimbleOwnership.get_owned(Keys.ownership_server(), self()) do
      %{^contract => %HandlerMeta.Stateful{state: %CanonicalHandlerState{}}} ->
        :ok

      %{^contract => other} ->
        raise ArgumentError, """
        Cannot use Double API on #{inspect(contract)} — a non-Double handler \
        is already installed via Testing.set_*_handler.

        Found: #{inspect(other)}

        Double.expect/stub/fake require the canonical handler installed by \
        Double itself. Remove the Testing.set_*_handler call and use the \
        Double API exclusively, or use Testing.set_*_handler exclusively.
        """

      _ ->
        # First touch — install the canonical handler fn.
        # Always 5-arity so dispatch passes the global state snapshot,
        # which is forwarded to 5-arity stateful fakes that need it.
        DoubleDown.Testing.set_stateful_handler(
          contract,
          &DoubleDown.Double.Dispatch.canonical_handler/5,
          CanonicalHandlerState.new(contract)
        )

        register_contract(contract)
    end
  end

  defp register_contract(contract) do
    NimbleOwnership.get_and_update(Keys.ownership_server(), self(), Keys.contracts_key(), fn
      nil -> {:ok, [contract]}
      existing -> {:ok, Enum.uniq([contract | existing])}
    end)
  end

  defp update_handler_state(contract, update_fn) do
    NimbleOwnership.get_and_update(
      Keys.ownership_server(),
      self(),
      contract,
      fn %HandlerMeta.Stateful{} = meta ->
        {:ok, HandlerMeta.Stateful.update_state(meta, update_fn)}
      end
    )
  end

  # -- Internal: verification --

  defp do_verify!(pid) do
    owned = NimbleOwnership.get_owned(Keys.ownership_server(), pid)
    contracts_key = Keys.contracts_key()

    case owned do
      %{^contracts_key => contracts} ->
        verify_contracts!(owned, contracts)

      _ ->
        # No Double-managed handlers installed — nothing to verify.
        :ok
    end
  end

  defp verify_contracts!(owned, contracts) do
    unconsumed =
      Enum.flat_map(contracts, fn contract ->
        case owned do
          %{^contract => %HandlerMeta.Stateful{state: %CanonicalHandlerState{expects: expects}}} ->
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
      DoubleDown.Double expectations not fulfilled:

      #{details}
      """
    end

    :ok
  end

  # -- Internal: behaviour detection --

  defp implements_behaviour?(module, behaviour) do
    case module.__info__(:attributes)[:behaviour] do
      nil -> false
      behaviours when is_list(behaviours) -> behaviour in behaviours
    end
  rescue
    _ -> false
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
