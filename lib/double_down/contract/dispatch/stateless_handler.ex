defmodule DoubleDown.Contract.Dispatch.StatelessHandler do
  @moduledoc """
  Behaviour for stateless stub handler modules.

  Implement this behaviour to make a stateless stub usable by module
  name in `DoubleDown.Double.fallback/2..4`:

      # Instead of:
      Double.fallback(Repo, Repo.Stub.new())

      # Write:
      Double.fallback(Repo, Repo.Stub)

      # With a fallback function:
      Double.fallback(Repo, Repo.Stub, fn _contract, :all, [User] -> [] end)

  ## Callbacks

    * `new/2` — build a 3-arity dispatch function from a fallback
      function and options. The returned function has the signature
      `fn contract, operation, args -> result end`.

  ## Example

      defmodule MyApp.TestStore do
        @behaviour DoubleDown.Contract.Dispatch.StatelessHandler

        @impl true
        def new(fallback_fn, _opts) do
          fn contract, operation, args ->
            case {operation, args} do
              {:get, [id]} -> %{id: id}
              _ when is_function(fallback_fn) -> fallback_fn.(contract, operation, args)
              _ -> raise "unhandled"
            end
          end
        end
      end
  """

  @doc """
  Build a 3-arity dispatch function from a fallback function and options.

    * `fallback_fn` — an optional 3-arity function `(contract, operation, args) -> result`
      for operations the stub doesn't handle directly. `nil` if not provided.
    * `opts` — additional options for configuring the stub.

  Returns a 3-arity function `fn contract, operation, args -> result end` suitable
  for use as a `Double.fallback` function fallback.
  """
  @callback new(
              fallback_fn :: DoubleDown.Contract.Dispatch.Types.stateless_fun() | nil,
              opts :: keyword()
            ) :: DoubleDown.Contract.Dispatch.Types.stateless_fun()
end
