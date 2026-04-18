defmodule DoubleDown.Contract.Dispatch.Defer do
  @moduledoc """
  A deferred execution marker.

  When a handler or test double returns `%DoubleDown.Contract.Dispatch.Defer{fn: fun}`,
  the dispatch system releases the NimbleOwnership lock before calling
  `fun.()`. This avoids deadlocks when the deferred function makes
  further dispatched calls (e.g. `transact` calling `insert` inside
  its body).

  Used internally by `Repo.Stub`, `Repo.OpenInMemory`, and
  `DoubleDown.Double`'s canonical handler.
  """

  @enforce_keys [:fn]
  defstruct [:fn]

  @type t :: %__MODULE__{fn: (-> term())}
end
