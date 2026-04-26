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
  end

  defmodule Stateless do
    @moduledoc "Handler meta for a stateless 3-arity function handler `(contract, operation, args)`."
    @enforce_keys [:fun]
    defstruct [:fun]

    @type t :: %__MODULE__{
            fun: DoubleDown.Contract.Dispatch.Types.stateless_fun()
          }
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
  end
end
