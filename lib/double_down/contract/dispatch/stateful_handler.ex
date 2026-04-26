defmodule DoubleDown.Contract.Dispatch.StatefulHandler do
  @moduledoc """
  Behaviour for stateful fake handler modules.

  Implement this behaviour to make a stateful fake usable by module
  name in `DoubleDown.Double.fallback/2..4`:

      # Instead of:
      Double.fallback(Repo, &Repo.OpenInMemory.dispatch/4, Repo.OpenInMemory.new())

      # Write:
      Double.fallback(Repo, Repo.OpenInMemory)

  ## Callbacks

    * `new/2` — build initial state from seed data and options
    * `dispatch/4` — stateful handler `(contract, operation, args, state) -> {result, new_state}`
    * `dispatch/5` — stateful handler with cross-contract state access

  Implement either `dispatch/4` or `dispatch/5` (or both). When both
  are implemented, `dispatch/5` takes priority.

  ## Example

      defmodule MyApp.InMemoryStore do
        @behaviour DoubleDown.Contract.Dispatch.StatefulHandler

        @impl true
        def new(seed, _opts), do: seed

        @impl true
        def dispatch(_contract, :get, [id], state), do: {Map.get(state, id), state}
        def dispatch(_contract, :put, [id, val], state), do: {:ok, Map.put(state, id, val)}
      end
  """

  @doc """
  Build initial state from seed data and options.

  Called by `Double.fallback/2..4` to construct the initial state for the
  stateful handler.

    * `seed` — seed data (e.g. `%{User => %{1 => %User{}}}` for Repo.OpenInMemory)
    * `opts` — additional options (e.g. `fallback_fn: fn ... end`)
  """
  @callback new(seed :: term(), opts :: keyword()) :: term()

  @doc """
  Stateful dispatch handler.

  Receives the contract module, operation name, argument list, and
  current state. Returns `{result, new_state}`.
  """
  @callback dispatch(
              contract :: module(),
              operation :: atom(),
              args :: [term()],
              state :: term()
            ) ::
              {term(), term()}

  @doc """
  Stateful dispatch handler with cross-contract state access.

  Same as `dispatch/4` but receives a read-only snapshot of all
  contract states as the 5th argument.
  """
  @callback dispatch(
              contract :: module(),
              operation :: atom(),
              args :: [term()],
              state :: term(),
              all_states :: map()
            ) ::
              {term(), term()}

  @optional_callbacks [dispatch: 4, dispatch: 5]
end
