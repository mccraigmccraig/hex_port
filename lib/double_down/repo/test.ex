# Stateless test handler for DoubleDown.Repo.
#
# Provides a function handler for use with set_fn_handler. Write operations
# apply changeset changes and return {:ok, struct}. Read operations go
# through a user-supplied fallback function, or raise.
#
# ## Usage
#
#     DoubleDown.Testing.set_fn_handler(DoubleDown.Repo, DoubleDown.Repo.Test.new())
#
#     # With fallback for reads:
#     DoubleDown.Testing.set_fn_handler(
#       DoubleDown.Repo,
#       DoubleDown.Repo.Test.new(
#         fallback_fn: fn
#           :all, [User] -> [%User{id: 1, name: "Alice"}]
#           :get, [User, 1] -> %User{id: 1, name: "Alice"}
#         end
#       )
#     )
#
if Code.ensure_loaded?(Ecto) do
  defmodule DoubleDown.Repo.Test do
    @behaviour DoubleDown.Dispatch.StubHandler

    @moduledoc """
    Stateless test handler for `DoubleDown.Repo`.

    Provides a function handler via `new/1` for use with
    `DoubleDown.Testing.set_fn_handler/2`. Write operations (`insert`, `update`,
    `delete`) apply changeset changes and return `{:ok, struct}`. All read
    operations go through an optional fallback function, or raise a clear
    error.

    This applies the same "fail when consistency cannot be proven" approach
    as `DoubleDown.Repo.InMemory` — reads never silently return `nil` or `[]`
    because the adapter has no basis for claiming a record does or doesn't
    exist.

    ## Usage

        # Writes only — reads will raise:
        DoubleDown.Testing.set_fn_handler(DoubleDown.Repo, DoubleDown.Repo.Test.new())

        # With fallback for reads:
        DoubleDown.Testing.set_fn_handler(
          DoubleDown.Repo,
          DoubleDown.Repo.Test.new(
            fallback_fn: fn
              :get, [User, 1] -> %User{id: 1, name: "Alice"}
              :all, [User] -> [%User{id: 1, name: "Alice"}]
            end
          )
        )

        # With logging:
        DoubleDown.Testing.set_fn_handler(DoubleDown.Repo, DoubleDown.Repo.Test.new())
        DoubleDown.Testing.enable_log(DoubleDown.Repo)

    ## Differences from Repo.InMemory

    `Repo.Test` is stateless — writes apply changesets and return `{:ok, struct}`
    but nothing is stored. There is no read-after-write consistency.

    `Repo.InMemory` is stateful — writes store records and PK-based reads can
    find them. Use `Repo.InMemory` when your test needs read-after-write
    consistency. Use `Repo.Test` when you only need fire-and-forget writes.
    """

    @doc """
    Create a new Test handler function.

    Returns a 2-arity function `(operation, args) -> result` suitable for
    use with `DoubleDown.Double.stub/2` or `DoubleDown.Testing.set_fn_handler/2`.

    ## Arguments

      * `fallback_fn` — an optional 2-arity function `(operation, args) -> result`
        that handles read operations. If the function raises `FunctionClauseError`
        (no matching clause), dispatch falls through to an error. If omitted or
        `nil`, all reads raise immediately.
      * `opts` — keyword options (reserved for future use).

    ## Examples

        # Writes only — via module name (StubHandler)
        DoubleDown.Double.stub(DoubleDown.Repo, DoubleDown.Repo.Test)

        # With fallback for specific reads
        DoubleDown.Double.stub(DoubleDown.Repo, DoubleDown.Repo.Test,
          fn
            :get, [User, 1] -> %User{id: 1, name: "Alice"}
            :all, [User] -> [%User{id: 1, name: "Alice"}]
            :exists?, [User] -> true
          end
        )

    ## Legacy keyword-only form (still supported)

        DoubleDown.Repo.Test.new(fallback_fn: fn :get, [User, 1] -> %User{} end)
    """
    @impl DoubleDown.Dispatch.StubHandler
    @spec new((atom(), [term()] -> term()) | nil, keyword()) :: (atom(), [term()] -> term())
    def new(fallback_fn \\ nil, opts \\ [])

    # Legacy keyword-only form: new(fallback_fn: fn ...)
    def new(opts, []) when is_list(opts) and opts != [] do
      if Keyword.keyword?(opts) do
        fallback_fn = Keyword.get(opts, :fallback_fn, nil)
        build_handler(fallback_fn)
      else
        # Not a keyword list — shouldn't happen, but handle gracefully
        build_handler(nil)
      end
    end

    def new(fallback_fn, _opts) do
      build_handler(fallback_fn)
    end

    defp build_handler(fallback_fn) do
      fn operation, args ->
        dispatch(operation, args, fallback_fn)
      end
    end

    # -----------------------------------------------------------------
    # Write Operations — always authoritative
    # -----------------------------------------------------------------

    defp dispatch(:insert, [%Ecto.Changeset{valid?: false} = changeset], _fallback_fn) do
      {:error, changeset}
    end

    defp dispatch(:insert, [changeset], _fallback_fn) do
      alias DoubleDown.Repo.Autogenerate

      record = Autogenerate.apply_changes(changeset, :insert)
      schema = record.__struct__

      case Autogenerate.maybe_autogenerate_id(record, schema, fn _schema ->
             # Repo.Test is stateless — use a monotonic counter for unique integer IDs
             [System.unique_integer([:positive, :monotonic])]
           end) do
        {:error, {:no_autogenerate, message}} ->
          raise ArgumentError, message

        {_id, record} ->
          {:ok, record}
      end
    end

    defp dispatch(:update, [%Ecto.Changeset{valid?: false} = changeset], _fallback_fn) do
      {:error, changeset}
    end

    defp dispatch(:update, [changeset], _fallback_fn) do
      {:ok, DoubleDown.Repo.Autogenerate.apply_changes(changeset, :update)}
    end

    defp dispatch(:delete, [record], _fallback_fn) do
      {:ok, record}
    end

    # Opts-accepting variants — strip opts, delegate to base arity.
    # Ecto.Repo operations all accept an optional opts keyword list as
    # the last argument. These are called by Ecto.Multi's internal :run
    # callbacks and by user code passing opts through the facade.
    defp dispatch(:insert, [changeset, _opts], fallback_fn),
      do: dispatch(:insert, [changeset], fallback_fn)

    defp dispatch(:update, [changeset, _opts], fallback_fn),
      do: dispatch(:update, [changeset], fallback_fn)

    defp dispatch(:delete, [record, _opts], fallback_fn),
      do: dispatch(:delete, [record], fallback_fn)

    defp dispatch(:get, [queryable, id, _opts], fallback_fn),
      do: dispatch(:get, [queryable, id], fallback_fn)

    defp dispatch(:get!, [queryable, id, _opts], fallback_fn),
      do: dispatch(:get!, [queryable, id], fallback_fn)

    defp dispatch(:get_by, [queryable, clauses, _opts], fallback_fn),
      do: dispatch(:get_by, [queryable, clauses], fallback_fn)

    defp dispatch(:get_by!, [queryable, clauses, _opts], fallback_fn),
      do: dispatch(:get_by!, [queryable, clauses], fallback_fn)

    defp dispatch(:one, [queryable, _opts], fallback_fn),
      do: dispatch(:one, [queryable], fallback_fn)

    defp dispatch(:one!, [queryable, _opts], fallback_fn),
      do: dispatch(:one!, [queryable], fallback_fn)

    defp dispatch(:all, [queryable, _opts], fallback_fn),
      do: dispatch(:all, [queryable], fallback_fn)

    defp dispatch(:exists?, [queryable, _opts], fallback_fn),
      do: dispatch(:exists?, [queryable], fallback_fn)

    defp dispatch(:aggregate, [queryable, aggregate, field, _opts], fallback_fn),
      do: dispatch(:aggregate, [queryable, aggregate, field], fallback_fn)

    # -----------------------------------------------------------------
    # Read and bulk operations — fallback or error
    # -----------------------------------------------------------------

    defp dispatch(operation, args, fallback_fn)
         when operation in [
                :get,
                :get!,
                :get_by,
                :get_by!,
                :one,
                :one!,
                :all,
                :exists?,
                :aggregate,
                :insert_all,
                :update_all,
                :delete_all
              ] do
      try_fallback(fallback_fn, operation, args)
    end

    # -----------------------------------------------------------------
    # Transaction Operations
    #
    # The facade's pre_dispatch wraps 1-arity fns into 0-arity thunks,
    # so implementations always receive a 0-arity fn or an Ecto.Multi.
    # -----------------------------------------------------------------

    defp dispatch(:transact, [fun, _opts], _fallback_fn) when is_function(fun, 0) do
      %DoubleDown.Dispatch.Defer{fn: fn -> run_in_transaction(fun) end}
    end

    defp dispatch(:transact, [%Ecto.Multi{} = multi, opts], _fallback_fn) do
      repo_facade = Keyword.get(opts, DoubleDown.Repo.Facade)

      %DoubleDown.Dispatch.Defer{
        fn: fn ->
          run_in_transaction(fn -> DoubleDown.Repo.MultiStepper.run(multi, repo_facade) end)
        end
      }
    end

    defp dispatch(:rollback, [value], _fallback_fn) do
      %DoubleDown.Dispatch.Defer{fn: fn -> throw({:rollback, value}) end}
    end

    defp run_in_transaction(fun) do
      fun.()
    catch
      {:rollback, value} -> {:error, value}
    end

    # -----------------------------------------------------------------
    # Fallback dispatch
    # -----------------------------------------------------------------

    defp try_fallback(nil, operation, args) do
      raise_no_fallback(operation, args)
    end

    defp try_fallback(fallback_fn, operation, args) when is_function(fallback_fn, 2) do
      fallback_fn.(operation, args)
    rescue
      FunctionClauseError -> raise_no_fallback(operation, args)
    end

    defp raise_no_fallback(operation, args) do
      raise ArgumentError, """
      DoubleDown.Repo.Test cannot service :#{operation} with args #{inspect(args)}.

      The Test adapter can only answer authoritatively for:
        - Write operations (insert, update, delete)

      For all other operations, register a fallback function:

          DoubleDown.Repo.Test.new(
            fallback_fn: fn
              :#{operation}, #{inspect(args)} -> # your result here
            end
          )
      """
    end
  end
end
