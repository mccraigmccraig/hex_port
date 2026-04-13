defmodule DoubleDown.Testing do
  @moduledoc """
  Test helpers for DoubleDown contracts.

  Start the ownership server in `test/test_helper.exs`:

      DoubleDown.Testing.start()

  Then in your tests, register handlers per-contract:

      setup do
        DoubleDown.Testing.set_handler(MyApp.Todos, MyApp.Todos.InMemory)
        :ok
      end

  Handlers are process-scoped via `NimbleOwnership`, so `async: true`
  tests are isolated. Use `allow/3` to share handlers with child processes.
  """

  @ownership_server DoubleDown.Dispatch.Ownership

  @doc """
  Start the DoubleDown ownership server.

  Call this once in `test/test_helper.exs`.
  """
  @spec start() :: {:ok, pid()} | {:error, term()}
  def start do
    NimbleOwnership.start_link(name: @ownership_server)
  end

  @doc """
  Register a module as the handler for a contract.

  The module must implement the contract's `@behaviour`.
  """
  @spec set_handler(module(), module()) :: :ok
  def set_handler(contract, impl) do
    set_meta(contract, %{type: :module, impl: impl})
  end

  @doc """
  Register a function as the handler for a contract.

  The function receives `(operation, args)` and returns the result.
  """
  @spec set_fn_handler(module(), (atom(), [term()] -> term())) :: :ok
  def set_fn_handler(contract, fun) when is_function(fun, 2) do
    set_meta(contract, %{type: :fn, fun: fun})
  end

  @doc """
  Register a stateful handler for a contract.

  The function may be 3-arity or 4-arity:

    * **3-arity:** `fn operation, args, state -> {result, new_state} end`
    * **4-arity:** `fn operation, args, state, all_states -> {result, new_state} end`

  4-arity handlers receive a read-only snapshot of all contract states as
  the 4th argument. This enables cross-contract state access (e.g. a Queries
  handler reading the Repo InMemory store). The `all_states` map is keyed by
  contract module and includes a `DoubleDown.Contract.GlobalState` sentinel key.
  The handler must return only its own contract's new state — not the global map.

  State is stored in NimbleOwnership and updated atomically on each dispatch.
  """
  @spec set_stateful_handler(module(), (... -> {term(), term()}), term()) :: :ok
  def set_stateful_handler(contract, fun, initial_state)
      when is_function(fun, 3) or is_function(fun, 4) do
    state_key = Module.concat(DoubleDown.State, contract)

    # Store the initial state
    NimbleOwnership.get_and_update(@ownership_server, self(), state_key, fn _ ->
      {:ok, initial_state}
    end)

    set_meta(contract, %{type: :stateful, fun: fun, state_key: state_key})
  end

  @doc """
  Allow a child process to use the current process's handlers.

  Use this when spawning Tasks or other processes that need to
  dispatch through the same test handlers.
  """
  @spec allow(module(), pid(), pid() | (-> pid() | [pid()])) :: :ok | {:error, term()}
  def allow(contract, owner_pid \\ self(), child_pid) do
    NimbleOwnership.allow(@ownership_server, owner_pid, child_pid, contract)
  end

  @doc """
  Enable dispatch logging for a contract.

  After enabling, all dispatches through `X.Port` will be recorded.
  Retrieve with `get_log/1`.
  """
  @spec enable_log(module()) :: :ok
  def enable_log(contract) do
    log_key = Module.concat(DoubleDown.Log, contract)

    NimbleOwnership.get_and_update(@ownership_server, self(), log_key, fn _ ->
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
    log_key = Module.concat(DoubleDown.Log, contract)

    case NimbleOwnership.get_owned(@ownership_server, self()) do
      %{^log_key => log} -> Enum.reverse(log)
      _ -> []
    end
  end

  @doc """
  Set the ownership server to global mode.

  In global mode, all handlers registered by the calling process are
  visible to every process in the VM — no `allow/3` calls needed.
  This is useful for integration-style tests that involve supervision
  trees, named GenServers, Broadway pipelines, or Oban workers where
  individual process pids are not easily accessible.

  The calling process becomes the "shared owner". Any handlers set
  by this process (before or after calling `set_mode_to_global/0`)
  are accessible to all processes.

  ## Warning

  Global mode is **incompatible with `async: true`**. When global
  mode is active, all tests share the same handlers, so concurrent
  tests will interfere with each other. Only use global mode in
  tests with `async: false`.

  Call `set_mode_to_private/0` to restore per-process isolation.

  ## Example

      setup do
        DoubleDown.Testing.set_mode_to_global()
        DoubleDown.Testing.set_handler(MyApp.Repo, MyApp.Repo.InMemory)
        on_exit(fn -> DoubleDown.Testing.set_mode_to_private() end)
        :ok
      end
  """
  @spec set_mode_to_global() :: :ok
  def set_mode_to_global do
    NimbleOwnership.set_mode_to_shared(@ownership_server, self())
  end

  @doc """
  Restore the ownership server to private (per-process) mode.

  After calling this, handlers are once again scoped to the process
  that registered them. Use this to clean up after `set_mode_to_global/0`.
  """
  @spec set_mode_to_private() :: :ok
  def set_mode_to_private do
    NimbleOwnership.set_mode_to_private(@ownership_server)
  end

  @doc """
  Reset all handlers and logs for the current process.
  """
  @spec reset() :: :ok
  def reset do
    NimbleOwnership.cleanup_owner(@ownership_server, self())
  end

  # -- Internal --

  defp set_meta(contract, meta) do
    NimbleOwnership.get_and_update(@ownership_server, self(), contract, fn _ ->
      {:ok, meta}
    end)

    :ok
  end
end
