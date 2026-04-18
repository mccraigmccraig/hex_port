defmodule DoubleDown.Contract.Dispatch.StubHandler do
  @moduledoc """
  Behaviour for stateless stub handler modules.

  Implement this behaviour to make a stateless stub usable by module
  name in `DoubleDown.Double.stub/2..4`:

      # Instead of:
      Double.stub(Repo, Repo.Stub.new())

      # Write:
      Double.stub(Repo, Repo.Stub)

      # With a fallback function:
      Double.stub(Repo, Repo.Stub, fn :all, [User] -> [] end)

  ## Callbacks

    * `new/2` — build a 2-arity dispatch function from a fallback
      function and options. The returned function has the signature
      `fn operation, args -> result end`.

  ## Example

      defmodule MyApp.TestStore do
        @behaviour DoubleDown.Contract.Dispatch.StubHandler

        @impl true
        def new(fallback_fn, _opts) do
          fn operation, args ->
            case {operation, args} do
              {:get, [id]} -> %{id: id}
              _ when is_function(fallback_fn) -> fallback_fn.(operation, args)
              _ -> raise "unhandled"
            end
          end
        end
      end
  """

  @doc """
  Build a 2-arity dispatch function from a fallback function and options.

    * `fallback_fn` — an optional 2-arity function `(operation, args) -> result`
      for operations the stub doesn't handle directly. `nil` if not provided.
    * `opts` — additional options for configuring the stub.

  Returns a 2-arity function `fn operation, args -> result end` suitable
  for use as a `Double.stub` function fallback.
  """
  @callback new(
              fallback_fn :: (atom(), [term()] -> term()) | nil,
              opts :: keyword()
            ) :: (atom(), [term()] -> term())
end
