# Compile-time macro for generating a Behaviour implementation of HexPort.Repo
# that delegates to a specific Ecto Repo module.
#
# ## Usage
#
#     defmodule MyApp.Repo.HexPort do
#       use HexPort.Repo.Ecto, repo: MyApp.Repo
#     end
#
#     # config/config.exs
#     config :my_app, HexPort.Repo, impl: MyApp.Repo.HexPort
#
if Code.ensure_loaded?(Ecto) do
  defmodule HexPort.Repo.Ecto do
    @moduledoc """
    Macro for generating a `HexPort.Repo.Behaviour` implementation that
    delegates to a specific Ecto Repo module.

    Each operation in the `HexPort.Repo` contract is implemented by calling
    the corresponding function on the configured Repo module with the
    same arguments.

    ## Usage

        defmodule MyApp.Repo.HexPort do
          use HexPort.Repo.Ecto, repo: MyApp.Repo
        end

    This generates a module satisfying `HexPort.Repo.Behaviour` with
    functions like:

        def insert(changeset), do: MyApp.Repo.insert(changeset)
        def update(changeset), do: MyApp.Repo.update(changeset)
        # ... etc.

    All generated functions are `defoverridable`, so you can selectively
    override operations that need custom behaviour.

    ## Configuration

        config :my_app, HexPort.Repo, impl: MyApp.Repo.HexPort
    """

    defmacro __using__(opts) do
      repo = Keyword.fetch!(opts, :repo)

      operations = HexPort.Repo.__port_operations__()

      delegations =
        Enum.map(operations, fn %{name: name, params: params, arity: arity} ->
          param_vars = Enum.map(params, fn p -> Macro.var(p, nil) end)

          quote do
            @impl true
            def unquote(name)(unquote_splicing(param_vars)) do
              unquote(repo).unquote(name)(unquote_splicing(param_vars))
            end

            defoverridable [{unquote(name), unquote(arity)}]
          end
        end)

      quote do
        @behaviour HexPort.Repo.Behaviour

        unquote_splicing(delegations)
      end
    end
  end
end
