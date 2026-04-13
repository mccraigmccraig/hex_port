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

  ## Stubs and fakes as fallbacks

  A fallback handles any operation without a specific expect or
  per-operation stub. Stubs and fakes serve different purposes:

  ### Function fallback (stub)

  A stateless 2-arity `fn operation, args -> result end` — canned
  responses, same signature as `set_fn_handler`:

      MyContract
      |> DoubleDown.Double.expect(:get, fn [id] -> %Thing{id: id} end)
      |> DoubleDown.Double.stub(fn
        :list, [_] -> []
        :count, [] -> 0
      end)

  ### Stateful fake

  A 3-arity `fn operation, args, state -> {result, new_state} end`
  or 4-arity `fn operation, args, state, all_states -> {result, new_state} end`
  with real logic and state. Integrates fakes like `Repo.InMemory`
  while allowing expects to override specific calls. 4-arity fakes
  receive a read-only snapshot of all contract states for
  cross-contract state access:

      # First insert fails, rest go through InMemory
      DoubleDown.Repo
      |> DoubleDown.Double.fake(&Repo.InMemory.dispatch/3, Repo.InMemory.new())
      |> DoubleDown.Double.expect(:insert, fn [changeset] ->
        {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
      end)

  When a 1-arity expect short-circuits (e.g. returning an error), the
  fake state is unchanged — correct for error simulation.

  Expects can also be stateful — 2-arity and 3-arity responders
  receive the fake's state and can update it:

      # 2-arity: access and update the fake's state
      |> DoubleDown.Double.expect(:insert, fn [changeset], state ->
        {result, new_state}
      end)

      # 3-arity: cross-contract state access too
      |> DoubleDown.Double.expect(:insert, fn [changeset], state, all_states ->
        {result, new_state}
      end)

  Stateful responders require `fake/3` to be called first (the fake
  provides the state). They must return `{result, new_state}`.

  ### Module fake

  A module implementing the contract's `@behaviour`:

      MyContract
      |> DoubleDown.Double.expect(:get, fn [_] -> {:error, :not_found} end)
      |> DoubleDown.Double.fake(MyApp.Impl)

  **Mimic-style limitation:** if the module's `:bar` internally calls
  `:foo`, and you've stubbed `:foo`, the module won't see your stub —
  it calls its own `:foo` directly. For stubs to be visible, the
  module must call through the facade.

  Dispatch priority: expects > per-operation stubs > fallback/fake > raise.
  Function stub, stateful fake, and module fake are mutually
  exclusive — setting one replaces the other.

  ## Passthrough expects

  When a fallback/fake is configured, pass `:passthrough` instead of
  a function to delegate while still consuming the expect for
  `verify!` counting:

      MyContract
      |> DoubleDown.Double.fake(MyApp.Impl)
      |> DoubleDown.Double.expect(:get, :passthrough, times: 2)

  ## Multi-contract

      DoubleDown.Repo
      |> DoubleDown.Double.fake(&Repo.InMemory.dispatch/3, Repo.InMemory.new())
      |> DoubleDown.Double.expect(:insert, fn [cs] -> {:error, :taken} end)

      QueriesContract
      |> DoubleDown.Double.expect(:get_record, fn [id] -> %Record{id: id} end)

  ## Relationship to Mox

  | Mox | DoubleDown.Double |
  |-----|-----------------|
  | `expect(Mock, :fn, n, fun)` | `expect(Contract, :fn, fun, times: n)` |
  | `stub(Mock, :fn, fun)` | `stub(Contract, :fn, fun)` — per-operation |
  | (no equivalent) | `stub(Contract, fn op, args -> ... end)` — function fallback |
  | (no equivalent) | `fake(Contract, fn op, args, state -> ... end, init)` — stateful fake (3 or 4-arity) |
  | (no equivalent) | `fake(Contract, ImplModule)` — module fake |
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
  @contracts_key DoubleDown.Double.Contracts

  # -- Public API: passthrough sentinel --

  @doc """
  Return a passthrough sentinel for use in expect responders.

  When returned from an expect responder, delegates the call to the
  fallback/fake as if the expect had been registered with `:passthrough`.
  The expect is still consumed for `verify!` counting.

  This enables conditional passthrough — the responder can inspect
  the state and decide whether to handle the call or delegate:

      DoubleDown.Repo
      |> Double.fake(&Repo.InMemory.dispatch/3, Repo.InMemory.new())
      |> Double.expect(:insert, fn [changeset], state ->
        if duplicate?(state, changeset) do
          {{:error, add_error(changeset, :email, "taken")}, state}
        else
          Double.passthrough()
        end
      end)
  """
  @spec passthrough() :: DoubleDown.Dispatch.Passthrough.t()
  def passthrough, do: %DoubleDown.Dispatch.Passthrough{}

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
  @spec expect(module(), atom(), function() | :passthrough, keyword()) :: module()
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
      existing = Map.get(state.expects, operation, [])
      %{state | expects: Map.put(state.expects, operation, existing ++ entries)}
    end)

    contract
  end

  defp validate_stateful_fake_exists!(contract, operation, fun) do
    state_key = Module.concat(DoubleDown.State, contract)

    case NimbleOwnership.get_owned(@ownership_server, self()) do
      %{^state_key => %{fallback: {:stateful, _}}} ->
        :ok

      _ ->
        arity = :erlang.fun_info(fun)[:arity]

        raise ArgumentError, """
        expect for :#{operation} received a #{arity}-arity stateful responder, \
        but no stateful fake is configured on #{inspect(contract)}.

        Stateful responders (2-arity or 3-arity) require a stateful fake \
        set via Double.fake/3 before calling expect. Use a 1-arity \
        fn [args] -> result end for stateless expects.
        """
    end
  end

  # -- Public API: stub --

  @doc """
  Add a stub for a contract operation or a stateless function fallback.

  ## Per-operation stub

  The function receives the argument list and returns the result.
  Stubs handle any number of calls and are used after all expectations
  for an operation are consumed. Setting a stub twice for the same
  operation replaces the previous one.

  The function may be:

    * **1-arity** `fn [args] -> result end` — stateless
    * **2-arity** `fn [args], state -> {result, new_state} end` — stateful
      (requires `fake/3` first)
    * **3-arity** `fn [args], state, all_states -> {result, new_state} end` —
      cross-contract state access (requires `fake/3` first)

  Any arity may return `Double.passthrough()` to delegate to the
  fallback/fake for that specific call.

      DoubleDown.Double.stub(MyContract, :list, fn [_] -> [] end)

  ## Function fallback (2-arity function)

  When the function is 2-arity `fn operation, args -> result end`,
  it acts as a fallback for any operation on the contract that has
  no per-operation expect or stub. This is the same signature as
  `set_fn_handler`, so existing handler functions can be reused:

      DoubleDown.Double.stub(MyContract, fn
        :list, [_] -> []
        :count, [] -> 0
      end)

  ## StubHandler module

  A module implementing `DoubleDown.Dispatch.StubHandler`. The module's
  `new/2` builds a dispatch function from an optional fallback:

      # Writes only — reads will raise
      DoubleDown.Double.stub(MyContract, DoubleDown.Repo.Test)

      # With fallback for reads
      DoubleDown.Double.stub(MyContract, DoubleDown.Repo.Test,
        fn :all, [User] -> [] end)

  For stateful fakes and module delegation, see `fake/2` and `fake/3`.

  Dispatch priority: expects > per-operation stubs > fallback/fake > raise.
  Function fallback, StubHandler, stateful fake, and module fake are
  mutually exclusive — setting one replaces the other.

  Returns the contract module for piping.
  """
  # stub/2 — function fallback or StubHandler module
  @spec stub(module(), function() | module()) :: module()
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
    do_stub_handler(contract, module, nil, [])
  end

  # stub/3 — per-operation stub OR StubHandler module with fallback_fn
  #
  # Disambiguation: if the second arg is an atom and the third is a 2-arity
  # function or nil, check if the second arg is a StubHandler module.
  # Per-operation stubs have a 1/2/3-arity function as the third arg.
  @spec stub(module(), atom(), function() | nil) :: module()
  def stub(contract, module_or_operation, fun_or_fallback)

  def stub(contract, module, fallback_fn)
      when is_atom(contract) and is_atom(module) and is_nil(fallback_fn) do
    # nil third arg — must be StubHandler
    do_stub_handler(contract, module, nil, [])
  end

  def stub(contract, module_or_op, fun)
      when is_atom(contract) and is_atom(module_or_op) and is_function(fun) do
    # Function third arg — could be per-op stub or StubHandler with fallback.
    # Check if second arg is a StubHandler module AND fun is 2-arity (fallback shape).
    if is_function(fun, 2) and stub_handler?(module_or_op) do
      do_stub_handler(contract, module_or_op, fun, [])
    else
      # Per-operation stub
      do_per_op_stub(contract, module_or_op, fun)
    end
  end

  defp do_per_op_stub(contract, operation, fun)
       when is_function(fun, 1) or is_function(fun, 2) or is_function(fun, 3) do
    ensure_handler_installed(contract)

    # Stateful stubs (2-arity, 3-arity) require a stateful fake
    if not is_function(fun, 1) do
      validate_stateful_fake_exists!(contract, operation, fun)
    end

    update_handler_state(contract, fn state ->
      %{state | stubs: Map.put(state.stubs, operation, fun)}
    end)

    contract
  end

  # stub/4 — StubHandler module with fallback_fn and opts
  @spec stub(module(), module(), (atom(), [term()] -> term()) | nil, keyword()) :: module()
  def stub(contract, module, fallback_fn, opts)
      when is_atom(contract) and is_atom(module) and
             (is_function(fallback_fn, 2) or is_nil(fallback_fn)) and
             is_list(opts) do
    do_stub_handler(contract, module, fallback_fn, opts)
  end

  defp do_stub_handler(contract, module, fallback_fn, opts) do
    unless stub_handler?(module) do
      raise ArgumentError, """
      #{inspect(module)} does not implement the DoubleDown.Dispatch.StubHandler behaviour.

      To use a module with Double.stub/2..4, it must implement:
        @behaviour DoubleDown.Dispatch.StubHandler
        @callback new(fallback_fn, opts) :: (atom(), [term()] -> term())
      """
    end

    handler_fn = module.new(fallback_fn, opts)

    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      %{state | fallback: {:fn, handler_fn}}
    end)

    contract
  end

  defp stub_handler?(module) do
    Code.ensure_loaded?(module) and
      implements_behaviour?(module, DoubleDown.Dispatch.StubHandler)
  end

  # -- Public API: fake --

  @doc """
  Set a fake implementation as the fallback for a contract.

  Fakes have real logic — they maintain state or delegate to a real
  implementation module. They handle any operation not covered by an
  `expect` or per-operation `stub`.

  ## FakeHandler module (recommended for stateful fakes)

  A module implementing `DoubleDown.Dispatch.FakeHandler`. The module's
  `new/2` builds initial state, and its `dispatch/3` or `dispatch/4`
  handles operations:

      # Default state
      DoubleDown.Double.fake(MyContract, Repo.InMemory)

      # With seed data
      DoubleDown.Double.fake(MyContract, Repo.InMemory, [%User{id: 1}])

      # With seed data and options
      DoubleDown.Double.fake(MyContract, Repo.InMemory, [%User{id: 1}],
        fallback_fn: fn :all, [User], state -> Map.values(state[User]) end
      )

  ## Module fake

  A module implementing the contract's `@behaviour` (but not FakeHandler).
  All unhandled operations delegate via `apply(module, operation, args)`:

      DoubleDown.Double.fake(MyContract, MyApp.Impl)

  The module is validated immediately — all contract operations must
  be exported.

  **Mimic-style limitation:** if the module's `:bar` internally calls
  `:foo`, and you've stubbed `:foo`, the module won't see your stub —
  it calls its own `:foo` directly. For stubs to be visible, the
  module must call through the facade.

  ## Stateful fake function

  A 3-arity `fn operation, args, state -> {result, new_state} end`
  or 4-arity `fn operation, args, state, all_states -> {result, new_state} end`
  with initial state:

      DoubleDown.Double.fake(MyContract, &handler/3, initial_state)

  The fake's state is threaded through calls automatically. When an
  expect short-circuits (e.g. returning an error), the fake state is
  unchanged — correct for error simulation.

  Dispatch priority: expects > per-operation stubs > fake > raise.
  Function fallback (`stub/2`), module fake, and stateful fake are
  mutually exclusive — setting one replaces the other.

  Returns the contract module for piping.
  """
  # fake/2 — module fake or FakeHandler module with default state
  @spec fake(module(), module()) :: module()
  def fake(contract, module)
      when is_atom(contract) and is_atom(module) do
    if fake_handler?(module) do
      do_fake_handler(contract, module, %{}, [])
    else
      validate_module_fallback!(contract, module)
      ensure_handler_installed(contract)

      update_handler_state(contract, fn state ->
        %{state | fallback: {:module, module}}
      end)

      contract
    end
  end

  # fake/3 — stateful fake function OR FakeHandler module with seed
  @spec fake(module(), function() | module(), term()) :: module()
  def fake(contract, fun, init_state)
      when is_atom(contract) and (is_function(fun, 3) or is_function(fun, 4)) do
    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      %{state | fallback: {:stateful, fun}, fallback_state: init_state}
    end)

    contract
  end

  def fake(contract, module, seed)
      when is_atom(contract) and is_atom(module) do
    do_fake_handler(contract, module, seed, [])
  end

  # fake/4 — FakeHandler module with seed and opts
  @spec fake(module(), module(), term(), keyword()) :: module()
  def fake(contract, module, seed, opts)
      when is_atom(contract) and is_atom(module) and is_list(opts) do
    do_fake_handler(contract, module, seed, opts)
  end

  defp do_fake_handler(contract, module, seed, opts) do
    unless fake_handler?(module) do
      raise ArgumentError, """
      #{inspect(module)} does not implement the DoubleDown.Dispatch.FakeHandler behaviour.

      To use a module with Double.fake/3..4, it must implement:
        @behaviour DoubleDown.Dispatch.FakeHandler
        @callback new(seed, opts) :: state
        @callback dispatch(operation, args, state) :: {result, new_state}
      """
    end

    dispatch_fn = resolve_fake_dispatch(module)
    init_state = module.new(seed, opts)

    ensure_handler_installed(contract)

    update_handler_state(contract, fn state ->
      %{state | fallback: {:stateful, dispatch_fn}, fallback_state: init_state}
    end)

    contract
  end

  defp fake_handler?(module) do
    Code.ensure_loaded?(module) and
      implements_behaviour?(module, DoubleDown.Dispatch.FakeHandler)
  end

  # Prefer dispatch/4 (cross-contract) over dispatch/3
  defp resolve_fake_dispatch(module) do
    cond do
      function_exported?(module, :dispatch, 4) -> &module.dispatch/4
      function_exported?(module, :dispatch, 3) -> &module.dispatch/3
    end
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
    NimbleOwnership.set_owner_to_manual_cleanup(@ownership_server, pid)

    ExUnit.Callbacks.on_exit(DoubleDown.Double, fn ->
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
        # First touch — install the canonical handler fn.
        # Always 4-arity so dispatch passes the global state snapshot,
        # which is forwarded to 4-arity stateful fakes that need it.
        DoubleDown.Testing.set_stateful_handler(
          contract,
          &canonical_handler/4,
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
  def canonical_handler(operation, args, state, all_states) do
    case pop_expect(state, operation) do
      {:ok, :passthrough, new_state} ->
        invoke_fallback_or_raise(new_state, operation, args, all_states)

      {:ok, fun, new_state} ->
        invoke_expect(fun, args, new_state, all_states, operation)

      :none ->
        case Map.get(state.stubs, operation) do
          nil ->
            invoke_fallback_or_raise(state, operation, args, all_states)

          stub_fun ->
            invoke_stub(stub_fun, args, state, all_states, operation)
        end
    end
  end

  # Invoke an expect responder. 1-arity is stateless (bare result).
  # 2-arity and 3-arity are stateful (return {result, new_fallback_state}).
  #
  # Any arity may return %DoubleDown.Dispatch.Passthrough{} to delegate to the
  # fallback/fake. The expect is still consumed for verify! counting.
  defp invoke_expect(fun, args, state, all_states, operation)
       when is_function(fun, 1) do
    case fun.(args) do
      %DoubleDown.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      result ->
        {result, state}
    end
  end

  defp invoke_expect(fun, args, state, all_states, operation)
       when is_function(fun, 2) do
    case fun.(args, state.fallback_state) do
      %DoubleDown.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      {result, new_fallback_state} ->
        {result, %{state | fallback_state: new_fallback_state}}

      other ->
        raise_bad_stateful_responder_return(:expect, operation, 2, other)
    end
  end

  defp invoke_expect(fun, args, state, all_states, operation)
       when is_function(fun, 3) do
    case fun.(args, state.fallback_state, all_states) do
      %DoubleDown.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      {result, new_fallback_state} ->
        {result, %{state | fallback_state: new_fallback_state}}

      other ->
        raise_bad_stateful_responder_return(:expect, operation, 3, other)
    end
  end

  # Invoke a per-operation stub. Same arity dispatch as invoke_expect.
  defp invoke_stub(fun, args, state, all_states, operation)
       when is_function(fun, 1) do
    case fun.(args) do
      %DoubleDown.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      result ->
        {result, state}
    end
  end

  defp invoke_stub(fun, args, state, all_states, operation)
       when is_function(fun, 2) do
    case fun.(args, state.fallback_state) do
      %DoubleDown.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      {result, new_fallback_state} ->
        {result, %{state | fallback_state: new_fallback_state}}

      other ->
        raise_bad_stateful_responder_return(:stub, operation, 2, other)
    end
  end

  defp invoke_stub(fun, args, state, all_states, operation)
       when is_function(fun, 3) do
    case fun.(args, state.fallback_state, all_states) do
      %DoubleDown.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      {result, new_fallback_state} ->
        {result, %{state | fallback_state: new_fallback_state}}

      other ->
        raise_bad_stateful_responder_return(:stub, operation, 3, other)
    end
  end

  defp raise_bad_stateful_responder_return(kind, operation, arity, got) do
    raise ArgumentError, """
    Stateful #{kind} responder for :#{operation} must return {result, new_state}.

    Got: #{inspect(got)}

    #{arity}-arity #{kind} responders must return a {result, new_fallback_state} tuple. \
    Use a 1-arity fn [args] -> result end for stateless #{kind}s that return bare results.
    """
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

  defp invoke_fallback_or_raise(state, operation, args, all_states) do
    case state.fallback do
      nil ->
        msg = unexpected_call_message(state.contract, state, operation, args)
        {%DoubleDown.Dispatch.Defer{fn: fn -> raise msg end}, state}

      {:fn, fallback_fn} ->
        invoke_fn_fallback(fallback_fn, state, operation, args)

      {:stateful, fallback_fn} ->
        invoke_stateful_fallback(fallback_fn, state, operation, args, all_states)

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
      {%DoubleDown.Dispatch.Defer{fn: fn -> reraise msg, __STACKTRACE__ end}, state}
  end

  defp invoke_stateful_fallback(fallback_fn, state, operation, args, all_states) do
    {result, new_fallback_state} =
      if is_function(fallback_fn, 4) do
        fallback_fn.(operation, args, state.fallback_state, all_states)
      else
        fallback_fn.(operation, args, state.fallback_state)
      end

    {result, %{state | fallback_state: new_fallback_state}}
  rescue
    FunctionClauseError ->
      msg = unexpected_call_message(state.contract, state, operation, args)
      {%DoubleDown.Dispatch.Defer{fn: fn -> reraise msg, __STACKTRACE__ end}, state}
  end

  defp invoke_module_fallback(module, state, operation, args) do
    result = apply(module, operation, args)
    {result, state}
  rescue
    UndefinedFunctionError ->
      msg = unexpected_call_message(state.contract, state, operation, args)
      {%DoubleDown.Dispatch.Defer{fn: fn -> reraise msg, __STACKTRACE__ end}, state}
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
          raise "DoubleDown.Double.verify!/0 called but no handlers were installed"
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
      DoubleDown.Double expectations not fulfilled:

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
