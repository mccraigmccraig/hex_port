defmodule DoubleDown.Double.Dispatch do
  @moduledoc """
  Dispatch-time logic for `DoubleDown.Double`'s canonical handler.

  This module contains the runtime dispatch functions that execute
  inside `NimbleOwnership.get_and_update` when a contract operation
  is called. It reads expects, per-op fakes, per-op stubs, and
  fallback config from `CanonicalHandlerState` at dispatch time.

  Separated from `DoubleDown.Double` (setup-time API) for clarity —
  setup code is called by tests, dispatch code runs inside the
  NimbleOwnership GenServer.

  ## Dispatch priority

  expects > per-op fakes > per-op stubs > fallback > raise
  """

  alias DoubleDown.Double.CanonicalHandlerState

  # -- Canonical handler --

  # The contract parameter from Contract.Dispatch is unused — the
  # contract is already available as state.contract, set at installation
  # time by CanonicalHandlerState.new/1. Fallback handlers that need it
  # (invoke_fn_fallback, invoke_stateful_fallback) read it from there.
  @doc false
  def canonical_handler(_contract, operation, args, %CanonicalHandlerState{} = state, all_states) do
    case CanonicalHandlerState.pop_expect(state, operation) do
      {:ok, :passthrough, new_state} ->
        invoke_fallback_or_raise(new_state, operation, args, all_states)

      {:ok, fun, new_state} ->
        invoke_expect(fun, args, new_state, all_states, operation)

      :none ->
        case Map.get(state.fakes, operation) do
          nil ->
            case Map.get(state.stubs, operation) do
              nil ->
                invoke_fallback_or_raise(state, operation, args, all_states)

              stub_fun ->
                invoke_stub(stub_fun, args, state, all_states, operation)
            end

          op_fake_fun ->
            invoke_op_fake(op_fake_fun, args, state, all_states, operation)
        end
    end
  end

  # -- Expect invocation --

  # 1-arity is stateless (bare result).
  # 2-arity and 3-arity are stateful (return {result, new_fallback_state}).
  #
  # Any arity may return %Passthrough{} to delegate to the fallback.
  # The expect is still consumed for verify! counting.
  defp invoke_expect(fun, args, state, all_states, operation)
       when is_function(fun, 1) do
    case fun.(args) do
      %DoubleDown.Contract.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      result ->
        {result, state}
    end
  end

  defp invoke_expect(fun, args, state, all_states, operation)
       when is_function(fun, 2) do
    case fun.(args, state.fallback_state) do
      %DoubleDown.Contract.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      {result, new_fallback_state} ->
        {result, CanonicalHandlerState.put_fallback_state(state, new_fallback_state)}

      other ->
        raise_bad_stateful_responder_return(:expect, operation, 2, other)
    end
  end

  defp invoke_expect(fun, args, state, all_states, operation)
       when is_function(fun, 3) do
    case fun.(args, state.fallback_state, all_states) do
      %DoubleDown.Contract.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      {result, new_fallback_state} ->
        {result, CanonicalHandlerState.put_fallback_state(state, new_fallback_state)}

      other ->
        raise_bad_stateful_responder_return(:expect, operation, 3, other)
    end
  end

  # -- Per-operation fake invocation --

  # 2-arity receives (args, fallback_state),
  # 3-arity receives (args, fallback_state, all_states). Both return
  # {result, new_fallback_state}. May return passthrough() to delegate.
  defp invoke_op_fake(fun, args, state, all_states, operation)
       when is_function(fun, 2) do
    case fun.(args, state.fallback_state) do
      %DoubleDown.Contract.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      {result, new_fallback_state} ->
        {result, CanonicalHandlerState.put_fallback_state(state, new_fallback_state)}

      other ->
        raise_bad_stateful_responder_return(:fake, operation, 2, other)
    end
  end

  defp invoke_op_fake(fun, args, state, all_states, operation)
       when is_function(fun, 3) do
    case fun.(args, state.fallback_state, all_states) do
      %DoubleDown.Contract.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      {result, new_fallback_state} ->
        {result, CanonicalHandlerState.put_fallback_state(state, new_fallback_state)}

      other ->
        raise_bad_stateful_responder_return(:fake, operation, 3, other)
    end
  end

  # -- Per-operation stub invocation --

  # Always 1-arity (stateless).
  defp invoke_stub(fun, args, state, all_states, operation)
       when is_function(fun, 1) do
    case fun.(args) do
      %DoubleDown.Contract.Dispatch.Passthrough{} ->
        invoke_fallback_or_raise(state, operation, args, all_states)

      result ->
        {result, state}
    end
  end

  # -- Fallback invocation --

  defp invoke_fallback_or_raise(state, operation, args, all_states) do
    case state.fallback do
      nil ->
        msg = unexpected_call_message(state.contract, state, operation, args)
        {%DoubleDown.Contract.Dispatch.Defer{fun: fn -> raise msg end}, state}

      {:stateless, fallback_fn} ->
        invoke_fn_fallback(fallback_fn, state, operation, args)

      {:stateful, fallback_fn} ->
        invoke_stateful_fallback(fallback_fn, state, operation, args, all_states)

      {:module, module} ->
        invoke_module_fallback(module, state, operation, args)
    end
  end

  defp invoke_fn_fallback(fallback_fn, state, operation, args) do
    result = fallback_fn.(state.contract, operation, args)
    {result, state}
  rescue
    # NOTE: This rescue cannot distinguish between a FunctionClauseError from
    # the top-level fallback_fn (no matching clause) and one raised deeper in
    # the call stack (a bug in the fallback body). See "Known limitations" in
    # the DoubleDown.Double moduledoc.
    FunctionClauseError ->
      msg = unexpected_call_message(state.contract, state, operation, args)
      {%DoubleDown.Contract.Dispatch.Defer{fun: fn -> reraise msg, __STACKTRACE__ end}, state}
  end

  defp invoke_stateful_fallback(fallback_fn, state, operation, args, all_states) do
    handler_result =
      if is_function(fallback_fn, 5) do
        fallback_fn.(state.contract, operation, args, state.fallback_state, all_states)
      else
        fallback_fn.(state.contract, operation, args, state.fallback_state)
      end

    case handler_result do
      {result, new_fallback_state} ->
        {result, CanonicalHandlerState.put_fallback_state(state, new_fallback_state)}

      other ->
        raise_bad_stateful_responder_return(
          :fake,
          operation,
          :erlang.fun_info(fallback_fn)[:arity],
          other
        )
    end
  rescue
    # NOTE: Same limitation as invoke_fn_fallback — see "Known limitations"
    # in the DoubleDown.Double moduledoc.
    FunctionClauseError ->
      msg = unexpected_call_message(state.contract, state, operation, args)
      {%DoubleDown.Contract.Dispatch.Defer{fun: fn -> reraise msg, __STACKTRACE__ end}, state}
  end

  # Module fallback: defer the apply to the calling process via %Defer{}.
  # This is critical — the canonical_handler runs inside NimbleOwnership's
  # get_and_update (GenServer process). Real implementation modules do I/O
  # (e.g. Ecto queries) that require the calling process's context (sandbox
  # checkout, process dictionary, etc.). %Defer{} moves the apply outside
  # the lock, same mechanism transact uses.
  defp invoke_module_fallback(module, state, operation, args) do
    {%DoubleDown.Contract.Dispatch.Defer{fun: fn -> apply(module, operation, args) end}, state}
  end

  # -- Error messages --

  defp raise_bad_stateful_responder_return(kind, operation, arity, got) do
    raise ArgumentError, """
    Stateful #{kind} responder for :#{operation} must return {result, new_state}.

    Got: #{inspect(got)}

    #{arity}-arity #{kind} responders must return a {result, new_fallback_state} tuple. \
    Use a 1-arity fn [args] -> result end for stateless #{kind}s that return bare results.
    """
  end

  defp unexpected_call_message(
         contract,
         %CanonicalHandlerState{expects: expects},
         operation,
         args
       ) do
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
end
