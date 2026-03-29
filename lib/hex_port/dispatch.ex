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
      {:ok, handler} ->
        invoke_handler(handler, operation, args)

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

  defp resolve_test_handler(contract) do
    case GenServer.whereis(@ownership_server) do
      nil ->
        :none

      _pid ->
        callers = [self() | Process.get(:"$callers", [])]

        case NimbleOwnership.fetch_owner(@ownership_server, callers, contract) do
          {:ok, _owner} ->
            case NimbleOwnership.get_owned(@ownership_server, get_owner(callers, contract)) do
              %{^contract => handler_meta} -> {:ok, handler_meta}
              _ -> :none
            end

          {:shared_owner, _owner} ->
            case NimbleOwnership.get_owned(@ownership_server, get_shared_owner()) do
              %{^contract => handler_meta} -> {:ok, handler_meta}
              _ -> :none
            end

          :error ->
            :none
        end
    end
  end

  defp get_owner(callers, contract) do
    case NimbleOwnership.fetch_owner(@ownership_server, callers, contract) do
      {:ok, owner} -> owner
      {:shared_owner, owner} -> owner
      :error -> self()
    end
  end

  defp get_shared_owner do
    # In shared mode, we need the shared owner — for now this is a placeholder
    self()
  end

  # -- Handler invocation --

  defp invoke_handler(%{type: :module, impl: impl}, operation, args) do
    apply(impl, operation, args)
  end

  defp invoke_handler(%{type: :fn, fun: fun}, operation, args) do
    fun.(operation, args)
  end

  defp invoke_handler(%{type: :stateful, fun: fun, state_key: state_key}, operation, args) do
    # Atomically read state, call handler, update state
    {:ok, result} =
      NimbleOwnership.get_and_update(@ownership_server, self(), state_key, fn state ->
        {result, new_state} = fun.(operation, args, state)
        {result, new_state}
      end)

    result
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
      1. Set `otp_app` in `use HexPort, otp_app: :my_app` and configure:
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
