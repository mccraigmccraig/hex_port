defmodule DoubleDown.Contract.Dispatch.Defer do
  @moduledoc """
  A deferred execution marker.

  When a handler or test double returns `%DoubleDown.Contract.Dispatch.Defer{fun: fun}`,
  the dispatch system releases the NimbleOwnership lock before calling
  `fun.()`. This avoids deadlocks when the deferred function makes
  further dispatched calls (e.g. `transact` calling `insert` inside
  its body).

  Used internally by `Repo.Stub`, `Repo.OpenInMemory`, and
  `DoubleDown.Double`'s canonical handler.
  """

  @enforce_keys [:fun]
  defstruct [:fun]

  @type t :: %__MODULE__{fun: (-> term())}
end
