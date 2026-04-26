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
  * `fakes` — `%{operation => fun}` per-operation stateful fake overrides
  * `stubs` — `%{operation => fun}` per-operation stateless stub functions
  * `fallback` — the fallback handler, one of:
    - `nil` — no fallback configured
    - `{:stateless, fun}` — stateless 3-arity function fallback
    - `{:stateful, fun}` — 4/5-arity stateful fake function
    - `{:module, module}` — module implementing the contract behaviour
  * `fallback_state` — domain state for stateful fakes (only meaningful
    when `fallback` is `{:stateful, _}`)
  """

  @enforce_keys [:contract]
  defstruct [
    :contract,
    expects: %{},
    fakes: %{},
    stubs: %{},
    fallback: nil,
    fallback_state: nil
  ]

  @type fallback ::
          nil
          | {:stateless, DoubleDown.Contract.Dispatch.Types.stateless_fun()}
          | {:stateful, DoubleDown.Contract.Dispatch.Types.stateful_fun()}
          | {:module, module()}

  @type t :: %__MODULE__{
          contract: module(),
          expects: %{atom() => [DoubleDown.Double.Types.expect_fun() | :passthrough]},
          fakes: %{atom() => DoubleDown.Double.Types.fake_fun()},
          stubs: %{atom() => DoubleDown.Double.Types.stub_fun()},
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

  # -- Mutation functions --

  @doc "Add a single expect entry for an operation."
  @spec add_expect(t(), atom(), DoubleDown.Double.Types.expect_fun() | :passthrough) :: t()
  def add_expect(%__MODULE__{} = state, operation, entry)
      when is_atom(operation) and (is_function(entry) or entry == :passthrough) do
    add_expects(state, operation, [entry])
  end

  @doc "Add multiple expect entries for an operation (e.g. from `times: n`)."
  @spec add_expects(t(), atom(), [DoubleDown.Double.Types.expect_fun() | :passthrough]) :: t()
  def add_expects(%__MODULE__{expects: expects} = state, operation, entries)
      when is_atom(operation) and is_list(entries) do
    existing = Map.get(expects, operation, [])
    %{state | expects: Map.put(expects, operation, existing ++ entries)}
  end

  @doc "Set a per-operation stub."
  @spec put_stub(t(), atom(), DoubleDown.Double.Types.stub_fun()) :: t()
  def put_stub(%__MODULE__{} = state, operation, fun)
      when is_atom(operation) and is_function(fun, 1) do
    %{state | stubs: Map.put(state.stubs, operation, fun)}
  end

  @doc "Set a per-operation fake."
  @spec put_fake(t(), atom(), DoubleDown.Double.Types.fake_fun()) :: t()
  def put_fake(%__MODULE__{} = state, operation, fun)
      when is_atom(operation) and (is_function(fun, 2) or is_function(fun, 3)) do
    %{state | fakes: Map.put(state.fakes, operation, fun)}
  end

  @doc "Set a stateless function fallback."
  @spec set_stateless_fallback(t(), DoubleDown.Contract.Dispatch.Types.stateless_fun()) :: t()
  def set_stateless_fallback(%__MODULE__{} = state, fun) when is_function(fun, 3) do
    %{state | fallback: {:stateless, fun}}
  end

  @doc "Set a stateful function fallback with initial state."
  @spec set_stateful_fallback(t(), DoubleDown.Contract.Dispatch.Types.stateful_fun(), term()) ::
          t()
  def set_stateful_fallback(%__MODULE__{} = state, fun, init_state)
      when is_function(fun, 4) or is_function(fun, 5) do
    %{state | fallback: {:stateful, fun}, fallback_state: init_state}
  end

  @doc "Set a module fallback."
  @spec set_module_fallback(t(), module()) :: t()
  def set_module_fallback(%__MODULE__{} = state, module) when is_atom(module) do
    %{state | fallback: {:module, module}}
  end

  @doc "Update the fallback_state (used during dispatch)."
  @spec put_fallback_state(t(), term()) :: t()
  def put_fallback_state(%__MODULE__{} = state, new_fallback_state) do
    %{state | fallback_state: new_fallback_state}
  end

  @doc "Pop the next expect entry for an operation."
  @spec pop_expect(t(), atom()) ::
          {:ok, DoubleDown.Double.Types.expect_fun() | :passthrough, t()} | :none
  def pop_expect(%__MODULE__{expects: expects} = state, operation) do
    case Map.get(expects, operation, []) do
      [entry | rest] ->
        {:ok, entry, %{state | expects: Map.put(expects, operation, rest)}}

      [] ->
        :none
    end
  end

  @doc "Check if a stateful fallback is configured."
  @spec stateful_fallback?(t()) :: boolean()
  def stateful_fallback?(%__MODULE__{fallback: {:stateful, _}}), do: true
  def stateful_fallback?(%__MODULE__{}), do: false
end
