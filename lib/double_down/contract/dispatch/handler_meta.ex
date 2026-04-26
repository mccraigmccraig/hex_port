defmodule DoubleDown.Contract.Dispatch.HandlerMeta do
  @moduledoc """
  Structs describing the three handler types that can be installed for
  a contract via `DoubleDown.Testing`.

  Stored in `NimbleOwnership` under the contract module atom as key.
  `DoubleDown.Contract.Dispatch.invoke_handler/5` pattern-matches on
  the struct to select the dispatch strategy.

  ## Variants

  * `HandlerMeta.Module` — delegate to a module implementing the contract behaviour
  * `HandlerMeta.Stateless` — dispatch via a 3-arity `fn contract, operation, args -> result end`
  * `HandlerMeta.Stateful` — dispatch via a 4/5-arity stateful function with
    mutable state stored inline in the `:state` field
  """

  defmodule Module do
    @moduledoc "Handler meta for a module-based implementation."
    @enforce_keys [:impl]
    defstruct [:impl]

    @type t :: %__MODULE__{
            impl: module()
          }

    @doc "Create a new Module handler meta. Validates that `impl` is an atom."
    @spec new(module()) :: t()
    def new(impl) when is_atom(impl), do: %__MODULE__{impl: impl}
  end

  defmodule Stateless do
    @moduledoc "Handler meta for a stateless 3-arity function handler `(contract, operation, args)`."
    @enforce_keys [:fun]
    defstruct [:fun]

    @type t :: %__MODULE__{
            fun: DoubleDown.Contract.Dispatch.Types.stateless_fun()
          }

    @doc "Create a new Stateless handler meta. Validates that `fun` is a 3-arity function."
    @spec new(DoubleDown.Contract.Dispatch.Types.stateless_fun()) :: t()
    def new(fun) when is_function(fun, 3), do: %__MODULE__{fun: fun}
  end

  defmodule Stateful do
    @moduledoc """
    Handler meta for a stateful (4/5-arity) function handler.

    The `:state` field holds the mutable handler state directly —
    for raw `set_stateful_handler` this is user-provided state,
    for `Double`-managed handlers it is a `CanonicalHandlerState` struct.
    """
    @enforce_keys [:fun, :state]
    defstruct [:fun, :state]

    @type t :: %__MODULE__{
            fun: DoubleDown.Contract.Dispatch.Types.stateful_fun(),
            state: term()
          }

    @doc "Create a new Stateful handler meta. Validates that `fun` is a 4 or 5-arity function."
    @spec new(DoubleDown.Contract.Dispatch.Types.stateful_fun(), term()) :: t()
    def new(fun, state) when is_function(fun, 4) or is_function(fun, 5) do
      %__MODULE__{fun: fun, state: state}
    end

    @doc "Update the state within a Stateful handler meta."
    @spec update_state(t(), (term() -> term())) :: t()
    def update_state(%__MODULE__{state: state} = meta, update_fn)
        when is_function(update_fn, 1) do
      %{meta | state: update_fn.(state)}
    end
  end
end
