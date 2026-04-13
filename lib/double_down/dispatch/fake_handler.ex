defmodule DoubleDown.Dispatch.FakeHandler do
  @moduledoc """
  Behaviour for stateful fake handler modules.

  Implement this behaviour to make a stateful fake usable by module
  name in `DoubleDown.Double.fake/2..4`:

      # Instead of:
      Double.fake(Repo, &Repo.InMemory.dispatch/3, Repo.InMemory.new())

      # Write:
      Double.fake(Repo, Repo.InMemory)

  ## Callbacks

    * `new/2` — build initial state from seed data and options
    * `dispatch/3` — stateful handler `(operation, args, state) -> {result, new_state}`
    * `dispatch/4` — stateful handler with cross-contract state access

  Implement either `dispatch/3` or `dispatch/4` (or both). When both
  are implemented, `dispatch/4` takes priority.

  ## Example

      defmodule MyApp.InMemoryStore do
        @behaviour DoubleDown.Dispatch.FakeHandler

        @impl true
        def new(seed, _opts), do: seed

        @impl true
        def dispatch(:get, [id], state), do: {Map.get(state, id), state}
        def dispatch(:put, [id, val], state), do: {:ok, Map.put(state, id, val)}
      end
  """

  @doc """
  Build initial state from seed data and options.

  Called by `Double.fake/2..4` to construct the initial state for the
  stateful handler.

    * `seed` — seed data (e.g. `%{User => %{1 => %User{}}}` for Repo.InMemory)
    * `opts` — additional options (e.g. `fallback_fn: fn ... end`)
  """
  @callback new(seed :: term(), opts :: keyword()) :: term()

  @doc """
  Stateful dispatch handler.

  Receives the operation name, argument list, and current state.
  Returns `{result, new_state}`.
  """
  @callback dispatch(operation :: atom(), args :: [term()], state :: term()) ::
              {term(), term()}

  @doc """
  Stateful dispatch handler with cross-contract state access.

  Same as `dispatch/3` but receives a read-only snapshot of all
  contract states as the 4th argument.
  """
  @callback dispatch(operation :: atom(), args :: [term()], state :: term(), all_states :: map()) ::
              {term(), term()}

  @optional_callbacks [dispatch: 3, dispatch: 4]
end
