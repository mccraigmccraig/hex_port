defmodule HexPort.Dispatch do
  @moduledoc """
  Dispatch resolution for HexPort contracts.

  Resolves the implementation for a contract operation via:

  1. **Test handler** — process-scoped via `NimbleOwnership`
     (only checked if the ownership server is running)
  2. **Application config** — `Application.get_env(otp_app, contract)[:impl]`
  3. **Raise** — no handler configured

  In production, the NimbleOwnership server is not started, so dispatch
  goes straight to Application config (one `GenServer.whereis` ETS lookup).
  """

  @ownership_server __MODULE__.Ownership

  @doc """
  Dispatch a port operation to the resolved implementation.

  Called by generated `X.Port` facade functions.
  """
  @spec call(atom() | nil, module(), atom(), [term()]) :: term()
  def call(otp_app, contract, operation, args) do
    case resolve_test_handler(contract) do
      {:ok, owner_pid, handler} ->
        result = invoke_handler(handler, owner_pid, operation, args)
        maybe_log(owner_pid, contract, operation, args, result)
        result

      :none ->
        invoke_from_config(otp_app, contract, operation, args)
    end
  end

  @doc """
  Build a canonical key for test stub matching.

  Keys are normalized so that map/keyword argument order doesn't affect matching.
  """
  @spec key(module(), atom(), [term()]) :: term()
  def key(contract, operation, args) do
    {contract, operation, normalize_args(args)}
  end

  # -- Test handler resolution --

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp resolve_test_handler(contract) do
    case GenServer.whereis(@ownership_server) do
      nil ->
        :none

      _pid ->
        callers = [self() | Process.get(:"$callers", [])]

        case NimbleOwnership.fetch_owner(@ownership_server, callers, contract) do
          {:ok, owner_pid} ->
            case NimbleOwnership.get_owned(@ownership_server, owner_pid) do
              %{^contract => handler_meta} -> {:ok, owner_pid, handler_meta}
              _ -> :none
            end

          {:shared_owner, owner_pid} ->
            case NimbleOwnership.get_owned(@ownership_server, owner_pid) do
              %{^contract => handler_meta} -> {:ok, owner_pid, handler_meta}
              _ -> :none
            end

          :error ->
            :none
        end
    end
  end

  # -- Handler invocation --

  defp invoke_handler(%{type: :module, impl: impl}, _owner_pid, operation, args) do
    apply(impl, operation, args)
  end

  defp invoke_handler(%{type: :fn, fun: fun}, _owner_pid, operation, args) do
    fun.(operation, args)
  end

  defp invoke_handler(
         %{type: :stateful, fun: fun, state_key: state_key},
         owner_pid,
         operation,
         args
       ) do
    # Atomically read state, call handler, update state.
    # Must use owner_pid so allowed child processes can update state.
    #
    # If the handler returns {:defer, deferred_fn}, we skip the state update
    # and call deferred_fn outside the lock. This supports operations like
    # `transact` whose body re-enters the dispatch system (which would
    # otherwise deadlock on the NimbleOwnership GenServer).
    {:ok, result} =
      NimbleOwnership.get_and_update(@ownership_server, owner_pid, state_key, fn state ->
        case fun.(operation, args, state) do
          {:defer, deferred_fn} when is_function(deferred_fn, 0) ->
            {{:defer, deferred_fn}, state}

          {result, new_state} ->
            {result, new_state}
        end
      end)

    case result do
      {:defer, deferred_fn} -> deferred_fn.()
      result -> result
    end
  end

  # -- Dispatch logging --

  defp maybe_log(owner_pid, contract, operation, args, result) do
    log_key = Module.concat(HexPort.Log, contract)

    # Only log if the owner has logging enabled (owns the log key).
    # get_owned returns all keys owned by this pid — check if log_key is present.
    case NimbleOwnership.get_owned(@ownership_server, owner_pid) do
      %{^log_key => _} ->
        NimbleOwnership.get_and_update(@ownership_server, owner_pid, log_key, fn log ->
          {:ok, [{contract, operation, args, result} | log]}
        end)

      _ ->
        :ok
    end
  end

  # -- Config resolution --

  defp invoke_from_config(otp_app, contract, operation, args) do
    impl = resolve_impl_from_config(otp_app, contract)
    apply(impl, operation, args)
  end

  defp resolve_impl_from_config(nil, contract) do
    raise """
    No implementation configured for #{inspect(contract)}.

    Either:
      1. Create a facade module with `use HexPort.Facade, contract: #{inspect(contract)}, otp_app: :my_app`
         and configure:
           config :my_app, #{inspect(contract)}, impl: MyImpl

      2. In tests, use `HexPort.Testing.set_handler/2` to set a test handler.
    """
  end

  defp resolve_impl_from_config(otp_app, contract) do
    case Application.get_env(otp_app, contract) do
      nil ->
        raise """
        No implementation configured for #{inspect(contract)}.

        Add to your config:
          config #{inspect(otp_app)}, #{inspect(contract)}, impl: MyImpl

        Or in tests, use `HexPort.Testing.set_handler/2`.
        """

      config when is_list(config) ->
        case Keyword.get(config, :impl) do
          nil ->
            raise """
            Config for #{inspect(contract)} is missing `:impl` key.

            Expected:
              config #{inspect(otp_app)}, #{inspect(contract)}, impl: MyImpl
            """

          impl ->
            impl
        end

      impl when is_atom(impl) ->
        # Allow config :my_app, MyContract, MyImpl (shorthand)
        impl
    end
  end

  # -- Key normalization --

  defp normalize_args(args) do
    Enum.map(args, &normalize_arg/1)
  end

  defp normalize_arg(arg) when is_map(arg) and not is_struct(arg) do
    arg |> Enum.sort() |> Enum.map(fn {k, v} -> {k, normalize_arg(v)} end)
  end

  defp normalize_arg(arg) when is_list(arg) do
    if Keyword.keyword?(arg) do
      arg |> Enum.sort() |> Enum.map(fn {k, v} -> {k, normalize_arg(v)} end)
    else
      Enum.map(arg, &normalize_arg/1)
    end
  end

  defp normalize_arg(arg) when is_tuple(arg) do
    arg |> Tuple.to_list() |> Enum.map(&normalize_arg/1) |> List.to_tuple()
  end

  defp normalize_arg(arg), do: arg
end
