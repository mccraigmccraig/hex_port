defmodule DoubleDown.Contract.Dispatch.Types do
  @moduledoc """
  Shared type definitions for DoubleDown dispatch.

  Used by `HandlerMeta`, `CanonicalHandlerState`, and other dispatch
  modules to avoid duplicating function type signatures.
  """

  @typedoc """
  A stateless handler function: `fn contract, operation, args -> result end`.
  """
  @type stateless_fun :: (module(), atom(), [term()] -> term())

  @typedoc """
  A stateful handler function — either 4-arity (own state) or 5-arity
  (own state + cross-contract state snapshot).

  * 4-arity: `fn contract, operation, args, state -> {result, new_state} end`
  * 5-arity: `fn contract, operation, args, state, all_states -> {result, new_state} end`
  """
  @type stateful_fun ::
          (module(), atom(), [term()], term() -> {term(), term()})
          | (module(), atom(), [term()], term(), map() -> {term(), term()})
end
