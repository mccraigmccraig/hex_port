defmodule HexPort.Testing do
  @moduledoc """
  Test helpers for HexPort contracts.

  Start the ownership server in `test/test_helper.exs`:

      HexPort.Testing.start()

  Then in your tests, register handlers per-contract:

      setup do
        HexPort.Testing.set_handler(MyApp.Todos, MyApp.Todos.InMemory)
        :ok
      end

  Handlers are process-scoped via `NimbleOwnership`, so `async: true`
  tests are isolated. Use `allow/3` to share handlers with child processes.
  """

  @ownership_server HexPort.Dispatch.Ownership

  @doc """
  Start the HexPort ownership server.

  Call this once in `test/test_helper.exs`.
  """
  @spec start() :: {:ok, pid()} | {:error, term()}
  def start do
    NimbleOwnership.start_link(name: @ownership_server)
  end

  @doc """
  Register a module as the handler for a contract.

  The module must implement `contract.Behaviour`.
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

  The function receives `(operation, args, state)` and returns
  `{result, new_state}`. State is stored in NimbleOwnership and
  updated atomically on each dispatch.
  """
  @spec set_stateful_handler(module(), (atom(), [term()], term() -> {term(), term()}), term()) ::
          :ok
  def set_stateful_handler(contract, fun, initial_state) when is_function(fun, 3) do
    state_key = Module.concat(HexPort.State, contract)

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
    log_key = Module.concat(HexPort.Log, contract)

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
    log_key = Module.concat(HexPort.Log, contract)

    case NimbleOwnership.get_owned(@ownership_server, self()) do
      %{^log_key => log} -> Enum.reverse(log)
      _ -> []
    end
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
