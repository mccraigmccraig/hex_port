defmodule DoubleDown.Testing do
  @moduledoc """
  Test helpers for DoubleDown contracts.

  Start the ownership server in `test/test_helper.exs`:

      DoubleDown.Testing.start()

  Then in your tests, register handlers per-contract:

      setup do
        DoubleDown.Testing.set_module_handler(MyApp.Todos, MyApp.Todos.InMemory)
        :ok
      end

  Handlers are process-scoped via `NimbleOwnership`, so `async: true`
  tests are isolated. Use `allow/3` to share handlers with child processes.
  """

  alias DoubleDown.Contract.Dispatch.HandlerMeta
  alias DoubleDown.Contract.Dispatch.Keys

  @doc """
  Start the DoubleDown ownership server.

  Call this once in `test/test_helper.exs`.
  """
  @spec start() :: {:ok, pid()} | {:error, term()}
  def start do
    NimbleOwnership.start_link(name: Keys.ownership_server())
  end

  @doc """
  Register a module as the handler for a contract.

  The module must implement the contract's `@behaviour`.
  """
  @spec set_module_handler(module(), module()) :: :ok
  def set_module_handler(contract, impl) do
    set_meta(contract, %HandlerMeta.Module{impl: impl})
  end

  @doc """
  Register a function as the handler for a contract.

  The function receives `(contract, operation, args)` and returns the result.
  """
  @spec set_stateless_handler(module(), (module(), atom(), [term()] -> term())) :: :ok
  def set_stateless_handler(contract, fun) when is_function(fun, 3) do
    set_meta(contract, %HandlerMeta.Stateless{fun: fun})
  end

  @doc """
  Register a stateful handler for a contract.

  The function may be 4-arity or 5-arity:

    * **4-arity:** `fn contract, operation, args, state -> {result, new_state} end`
    * **5-arity:** `fn contract, operation, args, state, all_states -> {result, new_state} end`

  5-arity handlers receive a read-only snapshot of all contract states as
  the 5th argument. This enables cross-contract state access (e.g. a Queries
  handler reading the Repo InMemory store). The `all_states` map is keyed by
  contract module and includes a `DoubleDown.Contract.GlobalState` sentinel key.
  The handler must return only its own contract's new state — not the global map.

  State is stored in NimbleOwnership and updated atomically on each dispatch.
  """
  @spec set_stateful_handler(module(), (... -> {term(), term()}), term()) :: :ok
  def set_stateful_handler(contract, fun, initial_state)
      when is_function(fun, 4) or is_function(fun, 5) do
    set_meta(contract, %HandlerMeta.Stateful{fun: fun, state: initial_state})
  end

  @doc """
  Allow a child process to use the current process's handlers.

  Use this when spawning Tasks or other processes that need to
  dispatch through the same test handlers.
  """
  @spec allow(module(), pid() | (-> pid() | [pid()])) :: :ok | {:error, term()}
  @spec allow(module(), pid(), pid() | (-> pid() | [pid()])) :: :ok | {:error, term()}
  def allow(contract, owner_pid \\ self(), child_pid) do
    NimbleOwnership.allow(Keys.ownership_server(), owner_pid, child_pid, contract)
  end

  @doc """
  Enable dispatch logging for a contract.

  After enabling, all dispatches through the contract's facade will be
  recorded. Retrieve with `get_log/1`.
  """
  @spec enable_log(module()) :: :ok
  def enable_log(contract) do
    log_key = Keys.log_key(contract)

    NimbleOwnership.get_and_update(Keys.ownership_server(), self(), log_key, fn _ ->
      {:ok, []}
    end)

    :ok
  end

  @doc """
  Retrieve the dispatch log for a contract.

  Returns a list of `{contract, operation, args, result}` tuples
  in the order they were dispatched.
  """
  @spec get_log(module()) :: [{module(), atom(), [term()], term()}]
  def get_log(contract) do
    log_key = Keys.log_key(contract)

    case NimbleOwnership.get_owned(Keys.ownership_server(), self()) do
      %{^log_key => log} -> Enum.reverse(log)
      _ -> []
    end
  end

  @doc """
  Select private or global mode based on the test context.

  When `async: true` is set on the test module, private mode is used
  (the default — each test process has its own handlers). Otherwise,
  global mode is used (all processes share the calling process's
  handlers).

  Use as a setup callback — this is the recommended way to manage
  mode selection, mirroring Mox's `set_mox_from_context`:

      # In your test module:
      use ExUnit.Case, async: false

      setup :set_mode_from_context

      setup do
        DoubleDown.Testing.set_module_handler(MyApp.Repo, MyApp.Repo.InMemory)
        :ok
      end

  Because `set_mode_from_context` runs at the start of every test,
  it always resets the mode — even if a previous test crashed without
  cleaning up. NimbleOwnership's automatic `:DOWN` handler removes
  owned keys when the test process exits, so no explicit `on_exit`
  cleanup is needed.

  For `async: true` tests, `set_mode_from_context` is a no-op (private
  mode is the default), so it's safe to include unconditionally.
  """
  @spec set_mode_from_context(%{async: boolean()} | map()) :: :ok
  def set_mode_from_context(context \\ %{}) do
    if context[:async] do
      set_mode_to_private()
    else
      set_mode_to_global()
    end
  end

  @doc """
  Set the ownership server to global mode.

  In global mode, all handlers registered by the calling process are
  visible to every process in the VM — no `allow/3` calls needed.
  This is useful for integration-style tests that involve supervision
  trees, named GenServers, Broadway pipelines, or Oban workers where
  individual process pids are not easily accessible.

  The calling process becomes the "shared owner". Only the shared
  owner process can install handlers — calls to `set_*_handler`
  from other processes will raise `ArgumentError`.

  ## Recommended pattern

  Prefer `set_mode_from_context/1` over calling `set_mode_to_global/0`
  directly — it handles mode selection automatically and is more
  robust against stale state from previous tests:

      setup :set_mode_from_context

      setup do
        DoubleDown.Testing.set_module_handler(MyApp.Repo, MyApp.Repo.InMemory)
        :ok
      end

  ## Warning

  Global mode is **incompatible with `async: true`**. When global
  mode is active, all tests share the same handlers, so concurrent
  tests will interfere with each other. Only use global mode in
  tests with `async: false`.

  ## Common mistakes

  **Don't use `setup_all` for global mode.** `setup_all` runs in a
  different process than `setup`/tests, so handlers installed in
  `setup_all` won't be visible to test processes in global mode:

      # BROKEN — setup_all and setup run in different processes
      setup_all do
        DoubleDown.Testing.set_mode_to_global()
        :ok
      end

      setup do
        # This RAISES — self() is not the shared owner
        DoubleDown.Testing.set_module_handler(MyContract, MyImpl)
      end
  """
  @spec set_mode_to_global() :: :ok
  def set_mode_to_global do
    NimbleOwnership.set_mode_to_shared(Keys.ownership_server(), self())
  end

  @doc """
  Restore the ownership server to private (per-process) mode.

  After calling this, handlers are once again scoped to the process
  that registered them. Use this to clean up after `set_mode_to_global/0`.
  """
  @spec set_mode_to_private() :: :ok
  def set_mode_to_private do
    NimbleOwnership.set_mode_to_private(Keys.ownership_server())
  end

  @doc """
  Reset all handlers and logs for a process.

  Clears all NimbleOwnership entries owned by `pid` and reverts
  the ownership server to private mode (in case global mode was
  active). Defaults to `self()`.

  **`on_exit` caveat:** `reset()` (without arguments) uses `self()`,
  which inside an `on_exit` callback is the callback process — not
  the test process. To reset the test process's handlers from
  `on_exit`, capture the pid first:

      setup do
        pid = self()
        on_exit(fn -> DoubleDown.Testing.reset(pid) end)
        :ok
      end

  In most cases you don't need explicit cleanup — NimbleOwnership
  automatically cleans up when the owning process exits.
  """
  @spec reset(pid()) :: :ok
  def reset(pid \\ self()) do
    NimbleOwnership.cleanup_owner(Keys.ownership_server(), pid)
    # Also revert to private mode — cleanup_owner removes keys but
    # leaves the server in shared mode if it was set. This is a no-op
    # if already in private mode.
    NimbleOwnership.set_mode_to_private(Keys.ownership_server())
  end

  # -- Internal --

  defp set_meta(contract, meta) do
    case NimbleOwnership.get_and_update(Keys.ownership_server(), self(), contract, fn
           nil ->
             {:ok, meta}

           existing ->
             {{:error, existing}, existing}
         end) do
      {:ok, {:error, existing}} ->
        raise ArgumentError, """
        A handler is already installed for #{inspect(contract)}.

        Found: #{inspect(existing)}

        Call DoubleDown.Testing.reset() first to clear all handlers \
        before installing a new one.
        """

      {:ok, _} ->
        :ok

      {:error, %NimbleOwnership.Error{} = error} ->
        raise ArgumentError, """
        Failed to install handler for #{inspect(contract)}: \
        #{Exception.message(error)}

        In global mode, only the process that called \
        set_mode_to_global() can install handlers. Ensure \
        set_mode_to_global() and set_*_handler() are called \
        from the same process (typically the test's setup block).
        """
    end
  end
end
