defmodule DoubleDown.Double.CanonicalHandlerState do
  @moduledoc """
  State for `DoubleDown.Double.canonical_handler/5`.

  Stored inline in `HandlerMeta.Stateful.state` when `Double` installs
  its canonical stateful handler. Tracks queued expectations,
  per-operation stubs, per-operation fakes, and the fallback handler
  (function, stateful fake, or module) with its associated state.

  ## Fields

  * `contract` — the contract module this state belongs to (never nil)
  * `expects` — `%{operation => [fun | :passthrough]}` queued expectations
  * `op_fakes` — `%{operation => fun}` per-operation stateful fake overrides
  * `stubs` — `%{operation => fun}` per-operation stateless stub functions
  * `fallback` — the fallback handler, one of:
    - `nil` — no fallback configured
    - `{:fun, fun}` — stateless 3-arity function fallback
    - `{:stateful, fun}` — 4/5-arity stateful fake function
    - `{:module, module}` — module implementing the contract behaviour
  * `fallback_state` — domain state for stateful fakes (only meaningful
    when `fallback` is `{:stateful, _}`)
  """

  @enforce_keys [:contract]
  defstruct [
    :contract,
    expects: %{},
    op_fakes: %{},
    stubs: %{},
    fallback: nil,
    fallback_state: nil
  ]

  @type fallback ::
          nil
          | {:fun, (module(), atom(), [term()] -> term())}
          | {:stateful, (... -> {term(), term()})}
          | {:module, module()}

  @type t :: %__MODULE__{
          contract: module(),
          expects: %{atom() => [function() | :passthrough]},
          op_fakes: %{atom() => function()},
          stubs: %{atom() => function()},
          fallback: fallback(),
          fallback_state: term()
        }

  @doc """
  Create a new canonical handler state for the given contract.
  """
  @spec new(module()) :: t()
  def new(contract) when is_atom(contract) do
    %__MODULE__{contract: contract}
  end
end
