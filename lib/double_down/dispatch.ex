defmodule DoubleDown.Dispatch do
  @moduledoc """
  Dispatch resolution for DoubleDown contracts.

  Three dispatch paths are available, selected at compile time by the
  `:test_dispatch?` and `:static_dispatch?` options on
  `use DoubleDown.Facade`:

  ### `call/4` — test-aware dispatch (default in non-prod)

  1. **Test handler** — process-scoped via `NimbleOwnership`
     (only checked if the ownership server is running)
  2. **Application config** — `Application.get_env(otp_app, contract)[:impl]`
  3. **Raise** — no handler configured

  ### `call_config/4` — config-only dispatch

  1. **Application config** — `Application.get_env(otp_app, contract)[:impl]`
  2. **Raise** — no handler configured

  No `NimbleOwnership` code is referenced in the generated facade
  functions, eliminating the `GenServer.whereis` lookup entirely.

  ### Static dispatch (default in prod when config available)

  The implementation module is resolved at compile time and the
  generated facade calls it directly — no `NimbleOwnership`, no
  `Application.get_env`. Zero dispatch overhead. Falls back to
  `call_config/4` if the config is not available at compile time.
  """

  @ownership_server __MODULE__.Ownership

  @doc """
  Dispatch a port operation to the resolved implementation.

  Called by generated facade functions when `test_dispatch?: true`
  (the default in non-production environments). Checks for a
  process-scoped test handler via `NimbleOwnership` before falling
  back to application config.
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
  Dispatch a port operation directly from application config.

  Called by generated facade functions when `test_dispatch?: false`
  (the default in production). Skips the `NimbleOwnership` test
  handler lookup entirely — zero overhead beyond `Application.get_env`.
  """
  @spec call_config(atom() | nil, module(), atom(), [term()]) :: term()
  def call_config(otp_app, contract, operation, args) do
    invoke_from_config(otp_app, contract, operation, args)
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
    case apply(impl, operation, args) do
      %DoubleDown.Defer{fn: deferred_fn} -> deferred_fn.()
      result -> result
    end
  end

  defp invoke_handler(%{type: :fn, fun: fun}, _owner_pid, operation, args) do
    case fun.(operation, args) do
      %DoubleDown.Defer{fn: deferred_fn} -> deferred_fn.()
      result -> result
    end
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
    # If the handler returns %DoubleDown.Defer{fn: deferred_fn}, we skip
    # the state update and call deferred_fn outside the lock. This supports
    # operations like `transact` whose body re-enters the dispatch system
    # (which would otherwise deadlock on the NimbleOwnership GenServer).
    {:ok, result} =
      NimbleOwnership.get_and_update(@ownership_server, owner_pid, state_key, fn state ->
        case fun.(operation, args, state) do
          {%DoubleDown.Defer{} = defer, new_state} ->
            {defer, new_state}

          {result, new_state} ->
            {result, new_state}
        end
      end)

    case result do
      %DoubleDown.Defer{fn: deferred_fn} -> deferred_fn.()
      result -> result
    end
  end

  # -- Dispatch logging --

  defp maybe_log(owner_pid, contract, operation, args, result) do
    log_key = Module.concat(DoubleDown.Log, contract)

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

  defp resolve_impl(otp_app, contract) do
    case Application.get_env(otp_app, contract) do
      nil ->
        :error

      config when is_list(config) ->
        case Keyword.get(config, :impl) do
          nil -> :error
          impl -> {:ok, impl}
        end

      impl when is_atom(impl) ->
        {:ok, impl}
    end
  end

  defp invoke_from_config(otp_app, contract, operation, args) do
    case resolve_impl(otp_app, contract) do
      {:ok, impl} -> apply(impl, operation, args)
      :error -> raise_no_impl(otp_app, contract)
    end
  end

  defp raise_no_impl(otp_app, contract) do
    if testing?() do
      raise """
      No test handler set for #{inspect(contract)}.

      In your test setup, call one of:

          DoubleDown.Testing.set_handler(#{inspect(contract)}, MyImpl)
          DoubleDown.Testing.set_fn_handler(#{inspect(contract)}, fn operation, args -> ... end)
          DoubleDown.Testing.set_stateful_handler(#{inspect(contract)}, handler_fn, initial_state)

      If you want to use the production implementation in this test:
          DoubleDown.Testing.set_handler(#{inspect(contract)}, MyProductionImpl)
      """
    else
      config_example =
        if otp_app do
          "config #{inspect(otp_app)}, #{inspect(contract)}, impl: MyImpl"
        else
          ~s'use DoubleDown.Facade, contract: #{inspect(contract)}, otp_app: :my_app\n' <>
            "    then: config :my_app, #{inspect(contract)}, impl: MyImpl"
        end

      raise """
      No implementation configured for #{inspect(contract)}.

      Add to your config:
          #{config_example}
      """
    end
  end

  defp testing? do
    GenServer.whereis(@ownership_server) != nil
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
