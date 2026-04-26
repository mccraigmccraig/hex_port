# Stateless stub for DoubleDown.Repo.
#
# Write operations apply changeset changes and return {:ok, struct}.
# Read operations go through a user-supplied fallback function, or raise.
#
if Code.ensure_loaded?(Ecto) do
  defmodule DoubleDown.Repo.Stub do
    alias DoubleDown.Contract.Dispatch.Defer

    @behaviour DoubleDown.Contract.Dispatch.StatelessHandler

    @moduledoc """
    Stateless stub for `DoubleDown.Repo`.

    Write operations (`insert`, `update`, `delete`) apply changeset
    changes and return `{:ok, struct}` but store nothing. Read
    operations go through an optional fallback function, or raise a
    clear error.

    Implements `DoubleDown.Contract.Dispatch.StatelessHandler`, so it can
    be used by module name with `Double.fallback`:

    ## Usage with Double.fallback

        # Writes only — reads will raise with a helpful message:
        DoubleDown.Double.fallback(DoubleDown.Repo, DoubleDown.Repo.Stub)

        # With fallback for specific reads:
        DoubleDown.Double.fallback(DoubleDown.Repo, DoubleDown.Repo.Stub,
          fn _contract, operation, args ->
            case {operation, args} do
              {:get, [User, 1]} -> %User{id: 1, name: "Alice"}
              {:all, [User]} -> [%User{id: 1, name: "Alice"}]
              {:exists?, [User]} -> true
            end
          end
        )

        # Layer expects on top for failure simulation:
        DoubleDown.Repo
        |> DoubleDown.Double.fallback(DoubleDown.Repo.Stub)
        |> DoubleDown.Double.expect(:insert, fn [changeset] ->
          {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
        end)

    ## When to use Repo.Stub

    Use `Repo.Stub` when your test only needs fire-and-forget writes
    and a few canned read responses. It's the lightest-weight option —
    no state to reason about.

    For read-after-write consistency, use `Repo.InMemory` (closed-world,
    recommended) or `Repo.OpenInMemory` (open-world, fallback-based).

    | Fake | State | Reads |
    |------|-------|-------|
    | `Repo.Stub` | None | Fallback function or raise |
    | `Repo.InMemory` | Complete store | Authoritative for bare schemas |
    | `Repo.OpenInMemory` | Partial store | PK lookup in state, fallback for rest |
    """

    @doc """
    Create a new Test handler function.

    Returns a 3-arity function `(contract, operation, args) -> result` suitable for
    use with `DoubleDown.Double.fallback/2` or `DoubleDown.Testing.set_stateless_handler/2`.

    ## Arguments

      * `fallback_fn` — an optional 3-arity function `(contract, operation, args) -> result`
        that handles read operations. If the function raises `FunctionClauseError`
        (no matching clause), dispatch falls through to an error. If omitted or
        `nil`, all reads raise immediately.
      * `opts` — keyword options (reserved for future use).

    ## Examples

        # Writes only — via module name (StatelessHandler)
        DoubleDown.Double.fallback(DoubleDown.Repo, DoubleDown.Repo.Stub)

        # With fallback for specific reads
        DoubleDown.Double.fallback(DoubleDown.Repo, DoubleDown.Repo.Stub,
          fn _contract, operation, args ->
            case {operation, args} do
              {:get, [User, 1]} -> %User{id: 1, name: "Alice"}
              {:all, [User]} -> [%User{id: 1, name: "Alice"}]
              {:exists?, [User]} -> true
            end
          end
        )

    ## Legacy keyword-only form (still supported)

        DoubleDown.Repo.Stub.new(fallback_fn: fn _contract, :get, [User, 1] -> %User{} end)
    """
    @impl DoubleDown.Contract.Dispatch.StatelessHandler
    @spec new((module(), atom(), [term()] -> term()) | nil, keyword()) :: (module(),
                                                                           atom(),
                                                                           [term()] ->
                                                                             term())
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
      fn contract, operation, args ->
        dispatch(contract, operation, args, fallback_fn)
      end
    end

    # -----------------------------------------------------------------
    # Write Operations — always authoritative
    # -----------------------------------------------------------------

    defp dispatch(_contract, :insert, [%Ecto.Changeset{valid?: false} = changeset], _fallback_fn) do
      {:error, changeset}
    end

    defp dispatch(_contract, :insert, [%Ecto.Changeset{} = changeset], _fallback_fn) do
      do_insert(Ecto.Changeset.apply_changes(changeset))
    end

    defp dispatch(_contract, :insert, [%{__struct__: _} = struct], _fallback_fn) do
      do_insert(struct)
    end

    defp dispatch(_contract, :update, [%Ecto.Changeset{valid?: false} = changeset], _fallback_fn) do
      {:error, changeset}
    end

    defp dispatch(_contract, :update, [changeset], _fallback_fn) do
      {:ok, DoubleDown.Repo.Impl.Autogenerate.apply_changes(changeset, :update)}
    end

    defp dispatch(_contract, :delete, [%Ecto.Changeset{valid?: false} = changeset], _fallback_fn) do
      {:error, changeset}
    end

    defp dispatch(_contract, :delete, [%Ecto.Changeset{} = changeset], _fallback_fn) do
      {:ok, Ecto.Changeset.apply_changes(changeset)}
    end

    defp dispatch(_contract, :delete, [record], _fallback_fn) do
      {:ok, record}
    end

    # -----------------------------------------------------------------
    # Bang Write Operations
    # -----------------------------------------------------------------

    defp dispatch(contract, :insert!, [changeset], fallback_fn) do
      case dispatch(contract, :insert, [changeset], fallback_fn) do
        {:ok, record} ->
          record

        {:error, changeset} ->
          raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
      end
    end

    defp dispatch(contract, :update!, [changeset], fallback_fn) do
      case dispatch(contract, :update, [changeset], fallback_fn) do
        {:ok, record} ->
          record

        {:error, changeset} ->
          raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
      end
    end

    defp dispatch(contract, :delete!, [record], fallback_fn) do
      case dispatch(contract, :delete, [record], fallback_fn) do
        {:ok, record} ->
          record

        {:error, changeset} ->
          raise Ecto.InvalidChangesetError, action: :delete, changeset: changeset
      end
    end

    # -----------------------------------------------------------------
    # Insert-or-update — delegate to insert/update based on meta state
    # -----------------------------------------------------------------

    defp dispatch(contract, :insert_or_update, [%Ecto.Changeset{} = changeset], fallback_fn) do
      if Ecto.get_meta(changeset.data, :state) == :loaded do
        dispatch(contract, :update, [changeset], fallback_fn)
      else
        dispatch(contract, :insert, [changeset], fallback_fn)
      end
    end

    defp dispatch(contract, :insert_or_update!, [changeset], fallback_fn) do
      case dispatch(contract, :insert_or_update, [changeset], fallback_fn) do
        {:ok, record} ->
          record

        {:error, changeset} ->
          raise Ecto.InvalidChangesetError, action: :insert_or_update, changeset: changeset
      end
    end

    # -----------------------------------------------------------------
    # Load — stateless struct loading
    # -----------------------------------------------------------------

    defp dispatch(_contract, :load, [schema_or_map, data], _fallback_fn) do
      loader = fn _type, value -> {:ok, value} end

      case data do
        data when is_list(data) ->
          do_load(schema_or_map, Map.new(data), loader)

        {fields, values} when is_list(fields) and is_list(values) ->
          do_load(schema_or_map, Map.new(Enum.zip(fields, values)), loader)

        data when is_map(data) ->
          do_load(schema_or_map, data, loader)
      end
    end

    # Opts-accepting variants — strip opts, delegate to base arity.
    # Ecto.Repo operations all accept an optional opts keyword list as
    # the last argument. These are called by Ecto.Multi's internal :run
    # callbacks and by user code passing opts through the facade.
    defp dispatch(contract, :insert, [changeset, _opts], fallback_fn),
      do: dispatch(contract, :insert, [changeset], fallback_fn)

    defp dispatch(contract, :update, [changeset, _opts], fallback_fn),
      do: dispatch(contract, :update, [changeset], fallback_fn)

    defp dispatch(contract, :delete, [record, _opts], fallback_fn),
      do: dispatch(contract, :delete, [record], fallback_fn)

    defp dispatch(contract, :insert!, [changeset, _opts], fallback_fn),
      do: dispatch(contract, :insert!, [changeset], fallback_fn)

    defp dispatch(contract, :update!, [changeset, _opts], fallback_fn),
      do: dispatch(contract, :update!, [changeset], fallback_fn)

    defp dispatch(contract, :delete!, [record, _opts], fallback_fn),
      do: dispatch(contract, :delete!, [record], fallback_fn)

    defp dispatch(contract, :get, [queryable, id, _opts], fallback_fn),
      do: dispatch(contract, :get, [queryable, id], fallback_fn)

    defp dispatch(contract, :get!, [queryable, id, _opts], fallback_fn),
      do: dispatch(contract, :get!, [queryable, id], fallback_fn)

    defp dispatch(contract, :get_by, [queryable, clauses, _opts], fallback_fn),
      do: dispatch(contract, :get_by, [queryable, clauses], fallback_fn)

    defp dispatch(contract, :get_by!, [queryable, clauses, _opts], fallback_fn),
      do: dispatch(contract, :get_by!, [queryable, clauses], fallback_fn)

    defp dispatch(contract, :one, [queryable, _opts], fallback_fn),
      do: dispatch(contract, :one, [queryable], fallback_fn)

    defp dispatch(contract, :one!, [queryable, _opts], fallback_fn),
      do: dispatch(contract, :one!, [queryable], fallback_fn)

    defp dispatch(contract, :all, [queryable, _opts], fallback_fn),
      do: dispatch(contract, :all, [queryable], fallback_fn)

    defp dispatch(contract, :exists?, [queryable, _opts], fallback_fn),
      do: dispatch(contract, :exists?, [queryable], fallback_fn)

    defp dispatch(contract, :aggregate, [queryable, aggregate, field, _opts], fallback_fn),
      do: dispatch(contract, :aggregate, [queryable, aggregate, field], fallback_fn)

    defp dispatch(contract, :insert_or_update, [changeset, _opts], fallback_fn),
      do: dispatch(contract, :insert_or_update, [changeset], fallback_fn)

    defp dispatch(contract, :insert_or_update!, [changeset, _opts], fallback_fn),
      do: dispatch(contract, :insert_or_update!, [changeset], fallback_fn)

    defp dispatch(contract, :all_by, [queryable, clauses, _opts], fallback_fn),
      do: dispatch(contract, :all_by, [queryable, clauses], fallback_fn)

    defp dispatch(contract, :preload, [struct_or_structs, preloads, _opts], fallback_fn),
      do: dispatch(contract, :preload, [struct_or_structs, preloads], fallback_fn)

    defp dispatch(contract, :reload, [struct_or_structs, _opts], fallback_fn),
      do: dispatch(contract, :reload, [struct_or_structs], fallback_fn)

    defp dispatch(contract, :reload!, [struct_or_structs, _opts], fallback_fn),
      do: dispatch(contract, :reload!, [struct_or_structs], fallback_fn)

    defp dispatch(contract, :stream, [queryable, _opts], fallback_fn),
      do: dispatch(contract, :stream, [queryable], fallback_fn)

    # -----------------------------------------------------------------
    # Read and bulk operations — fallback or error
    # -----------------------------------------------------------------

    defp dispatch(contract, operation, args, fallback_fn)
         when operation in [
                :get,
                :get!,
                :get_by,
                :get_by!,
                :one,
                :one!,
                :all,
                :all_by,
                :exists?,
                :aggregate,
                :preload,
                :reload,
                :reload!,
                :stream,
                :insert_all,
                :update_all,
                :delete_all
              ] do
      try_fallback(contract, fallback_fn, operation, args)
    end

    # -----------------------------------------------------------------
    # Transaction Operations
    #
    # Transaction operations.
    #
    # With ContractFacade, pre_dispatch wraps 1-arity fns into 0-arity
    # thunks and always provides opts. With DynamicFacade, raw args
    # arrive — may be [fun/1], [fun/0], [fun/0, opts], etc.
    # Normalise before dispatching.
    # -----------------------------------------------------------------

    defp dispatch(contract, :transact, args, fallback_fn),
      do: do_dispatch_transact(contract, normalise_transact_args(args, contract), fallback_fn)

    defp dispatch(contract, :transaction, args, fallback_fn),
      do: do_dispatch_transact(contract, normalise_transact_args(args, contract), fallback_fn)

    @transaction_key DoubleDown.Repo.InTransaction

    defp dispatch(_contract, :rollback, [value], _fallback_fn) do
      Defer.new(fn ->
        if Process.get(@transaction_key, false) do
          throw({:rollback, value})
        else
          raise RuntimeError,
                "cannot call rollback outside of transaction"
        end
      end)
    end

    defp dispatch(_contract, :in_transaction?, [], _fallback_fn) do
      Defer.new(fn -> Process.get(@transaction_key, false) end)
    end

    # -- Transaction helpers (after all dispatch clauses) --

    defp do_dispatch_transact(_contract, [fun, _opts], _fallback_fn) when is_function(fun, 0) do
      Defer.new(fn -> run_in_transaction(fun) end)
    end

    defp do_dispatch_transact(_contract, [%Ecto.Multi{} = multi, opts], _fallback_fn) do
      repo_facade = Keyword.get(opts, DoubleDown.Repo.Facade)

      Defer.new(fn ->
        run_in_transaction(fn -> DoubleDown.Repo.Impl.MultiStepper.run(multi, repo_facade) end)
      end)
    end

    defp normalise_transact_args([fun], contract) when is_function(fun, 1),
      do: [fn -> fun.(contract) end, []]

    defp normalise_transact_args([fun], _contract) when is_function(fun, 0),
      do: [fun, []]

    defp normalise_transact_args([%Ecto.Multi{} = multi], _contract),
      do: [multi, []]

    defp normalise_transact_args([fun, opts], contract) when is_function(fun, 1) and is_list(opts),
      do: [fn -> fun.(contract) end, opts]

    defp normalise_transact_args([fun, opts], _contract) when is_function(fun, 0) and is_list(opts),
      do: [fun, opts]

    defp normalise_transact_args([%Ecto.Multi{} = multi, opts], _contract) when is_list(opts),
      do: [multi, opts]

    defp run_in_transaction(fun) do
      prev = Process.get(@transaction_key, false)
      Process.put(@transaction_key, true)

      try do
        fun.()
      catch
        {:rollback, value} -> {:error, value}
      after
        Process.put(@transaction_key, prev)
      end
    end

    # -----------------------------------------------------------------
    # Helpers (after all dispatch clauses to avoid grouping warning)
    # -----------------------------------------------------------------

    defp do_load(schema, data, loader) when is_atom(schema) do
      Ecto.Schema.Loader.unsafe_load(schema, data, loader)
    end

    defp do_load(types, data, loader) when is_map(types) do
      Ecto.Schema.Loader.unsafe_load(%{}, types, data, loader)
    end

    defp do_insert(record) do
      alias DoubleDown.Repo.Impl.Autogenerate

      record = Autogenerate.apply_timestamps(record, :insert)
      schema = record.__struct__

      case Autogenerate.maybe_autogenerate_id(record, schema, fn _schema ->
             # Repo.Stub is stateless — use a monotonic counter for unique integer IDs
             [System.unique_integer([:positive, :monotonic])]
           end) do
        {:error, {:no_autogenerate, message}} ->
          raise ArgumentError, message

        {_id, record} ->
          {:ok, record}
      end
    end

    # -----------------------------------------------------------------
    # Fallback dispatch
    # -----------------------------------------------------------------

    defp try_fallback(_contract, nil, operation, args) do
      raise_no_fallback(operation, args)
    end

    defp try_fallback(contract, fallback_fn, operation, args) when is_function(fallback_fn, 3) do
      fallback_fn.(contract, operation, args)
    rescue
      FunctionClauseError -> raise_no_fallback(operation, args)
    end

    defp raise_no_fallback(operation, args) do
      raise ArgumentError, """
      DoubleDown.Repo.Stub cannot service :#{operation} with args #{inspect(args)}.

      Repo.Stub can only answer authoritatively for:
        - Write operations (insert, update, delete)

      For all other operations, register a fallback function:

          DoubleDown.Repo.Stub.new(
            fallback_fn: fn
              :#{operation}, #{inspect(args)} -> # your result here
            end
          )
      """
    end
  end
end
