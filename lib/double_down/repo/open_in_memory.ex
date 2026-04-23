# Open-world stateful in-memory Repo fake for tests.
# See Repo.InMemory for the recommended closed-world variant.
#
if Code.ensure_loaded?(Ecto) do
  defmodule DoubleDown.Repo.OpenInMemory do
    @behaviour DoubleDown.Contract.Dispatch.FakeHandler

    @moduledoc """
    Stateful in-memory Repo fake (open-world).

    Uses **open-world** semantics: the state may be incomplete. If a
    record is not found in state, the adapter falls through to the
    fallback function — it cannot assume the record doesn't exist.

    For most use cases, prefer `DoubleDown.Repo.InMemory` (closed-world)
    which is authoritative for all bare-schema reads without a
    fallback. Use `OpenInMemory` when the state is deliberately
    partial — e.g. you've inserted some records but expect the
    fallback to provide others.

    Implements `DoubleDown.Contract.Dispatch.FakeHandler`, so it can
    be used by module name with `Double.fake`:

    ## Usage with Double.fake

        # PK reads only — no fallback needed for records in state:
        DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.OpenInMemory)

        # With seed data and fallback for non-PK reads:
        DoubleDown.Double.fake(
          DoubleDown.Repo,
          DoubleDown.Repo.OpenInMemory,
          [%User{id: 1, name: "Alice"}],
          fallback_fn: fn
            _contract, :all, [User], state ->
              Map.get(state, User, %{}) |> Map.values()
            _contract, :get_by, [User, [email: "alice@example.com"]], _state ->
              %User{id: 1, name: "Alice"}
          end
        )

        # Layer expects for failure simulation:
        DoubleDown.Repo
        |> DoubleDown.Double.fake(DoubleDown.Repo.OpenInMemory)
        |> DoubleDown.Double.expect(:insert, fn [changeset] ->
          {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
        end)

    ## Operation dispatch (3-stage)

    | Category | Operations | Behaviour |
    |----------|-----------|-----------|
    | **Writes** | `insert`, `update`, `delete` | Always handled by state |
    | **PK reads** | `get`, `get!` | State first, then fallback |
    | **get_by** | `get_by`, `get_by!` | PK lookup when PK in clauses, then fallback |
    | **Other reads** | `one`, `all`, `exists?`, `aggregate` | Always fallback |
    | **Bulk** | `insert_all`, `update_all`, `delete_all` | Always fallback |
    | **Transactions** | `transact`, `rollback` | Delegate to sub-operations |

    For reads, the dispatch stages are:

    1. **State lookup** — if the record is in state, return it
    2. **Fallback function** — a 4-arity `(contract, operation, args, state)`
       function that handles operations the state can't answer
    3. **Raise** — clear error suggesting a fallback clause

    ## When to use which Repo fake

    | Fake | State | Best for |
    |------|-------|----------|
    | `Repo.Stub` | None | Fire-and-forget writes, canned reads |
    | `Repo.InMemory` | Complete store | All bare-schema reads; ExMachina factories |
    | **`Repo.OpenInMemory`** | **Partial store** | **PK reads in state, fallback for rest** |

    ## See also

    - `DoubleDown.Repo.InMemory` — closed-world variant (recommended).
      Authoritative for all bare-schema reads without a fallback.
    - `DoubleDown.Repo.Stub` — stateless stub for fire-and-forget writes.
    """

    alias DoubleDown.Repo.Impl.InMemoryShared

    @type store :: InMemoryShared.store()

    @doc """
    Create a new InMemory state map.

    ## Arguments

      * `seed` — seed data to pre-populate the store. Accepts:
        - a list of structs: `[%User{id: 1, name: "Alice"}]`
        - a pre-built store map: `%{User => %{1 => %User{id: 1}}}`
        - `%{}` or `[]` for empty (default)
      * `opts` — keyword options:
        - `:fallback_fn` — a 4-arity function `(contract, operation, args, state) -> result`
          that handles operations the state cannot answer authoritatively. The
          `state` argument is the clean store map (without internal keys like
          `:__fallback_fn__`), so the fallback can compose canned data with
          records inserted during the test. If the function raises
          `FunctionClauseError`, dispatch falls through to an error.

    ## Examples

        # Empty state, no fallback
        DoubleDown.Repo.OpenInMemory.new()

        # Seeded with a list of structs
        DoubleDown.Repo.OpenInMemory.new([%User{id: 1, name: "Alice"}])

        # Seeded with a map
        DoubleDown.Repo.OpenInMemory.new(%{User => %{1 => %User{id: 1, name: "Alice"}}})

        # Seeded with fallback
        DoubleDown.Repo.OpenInMemory.new(
          [%User{id: 1, name: "Alice"}],
          fallback_fn: fn
            _contract, :all, [User], state ->
              Map.get(state, User, %{}) |> Map.values()
          end
        )

    ## Legacy keyword-only form (still supported)

        DoubleDown.Repo.OpenInMemory.new(seed: [%User{id: 1}], fallback_fn: fn ...)
    """
    @impl DoubleDown.Contract.Dispatch.FakeHandler
    @spec new(term(), keyword()) :: store()
    defdelegate new(seed \\ %{}, opts \\ []), to: InMemoryShared

    @doc """
    Convert a list of structs into the nested state map for seeding.

    ## Example

        DoubleDown.Repo.OpenInMemory.seed([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"}
        ])
        #=> %{User => %{1 => %User{id: 1, name: "Alice"},
        #               2 => %User{id: 2, name: "Bob"}}}
    """
    @spec seed(list(struct())) :: store()
    defdelegate seed(records), to: InMemoryShared

    @doc """
    Stateful handler function for use with `DoubleDown.Testing.set_stateful_handler/3`
    or `DoubleDown.Double.fake/2..4`.

    Handles all `DoubleDown.Repo` operations. The function signature is
    `(contract, operation, args, store) -> {result, new_store}`.

    Write operations are handled directly by the state. PK-based reads check
    the state first, then fall through to the fallback function. All other
    reads go directly to the fallback function. If no fallback is registered
    or the fallback doesn't handle the operation, an error is raised.
    """
    @impl DoubleDown.Contract.Dispatch.FakeHandler
    @spec dispatch(module(), atom(), list(), store()) :: {term(), store()}

    # -----------------------------------------------------------------
    # Write operations — delegate to Shared
    # -----------------------------------------------------------------

    def dispatch(_contract, :insert, [changeset], store),
      do: InMemoryShared.dispatch_insert([changeset], store)

    def dispatch(_contract, :update, [changeset], store),
      do: InMemoryShared.dispatch_update([changeset], store)

    def dispatch(_contract, :delete, [record], store),
      do: InMemoryShared.dispatch_delete([record], store)

    def dispatch(_contract, :insert_or_update, [changeset], store),
      do: InMemoryShared.dispatch_insert_or_update([changeset], store)

    def dispatch(_contract, :insert_or_update!, [changeset], store),
      do: InMemoryShared.dispatch_insert_or_update!([changeset], store)

    def dispatch(_contract, :insert!, [changeset], store),
      do: InMemoryShared.dispatch_insert!([changeset], store)

    def dispatch(_contract, :update!, [changeset], store),
      do: InMemoryShared.dispatch_update!([changeset], store)

    def dispatch(_contract, :delete!, [record], store),
      do: InMemoryShared.dispatch_delete!([record], store)

    # -----------------------------------------------------------------
    # PK reads — 3-stage: state -> fallback -> error
    # -----------------------------------------------------------------

    def dispatch(contract, :get, [queryable, id] = args, store) do
      schema = InMemoryShared.extract_schema(queryable)

      case InMemoryShared.get_record(store, schema, id) do
        nil -> dispatch_via_fallback(contract, :get, args, store)
        record -> {record, store}
      end
    end

    def dispatch(contract, :get!, [queryable, id] = args, store) do
      schema = InMemoryShared.extract_schema(queryable)

      case InMemoryShared.get_record(store, schema, id) do
        nil -> dispatch_via_fallback(contract, :get!, args, store)
        record -> {record, store}
      end
    end

    # -----------------------------------------------------------------
    # Preload — resolve associations from state
    # -----------------------------------------------------------------

    def dispatch(contract, :preload, [struct_or_structs, preloads, _opts], store),
      do: dispatch(contract, :preload, [struct_or_structs, preloads], store)

    def dispatch(_contract, :preload, [struct_or_structs, preloads], store) do
      {DoubleDown.Repo.Impl.Preloader.preload(struct_or_structs, preloads, store), store}
    end

    # -----------------------------------------------------------------
    # Load — stateless
    # -----------------------------------------------------------------

    def dispatch(_contract, :load, args, store),
      do: InMemoryShared.dispatch_load(args, store)

    # -----------------------------------------------------------------
    # Reload — PK-based, authoritative from state
    # -----------------------------------------------------------------

    def dispatch(_contract, :reload, [struct_or_structs, _opts], store),
      do: InMemoryShared.dispatch_reload([struct_or_structs], store)

    def dispatch(_contract, :reload, [struct_or_structs], store),
      do: InMemoryShared.dispatch_reload([struct_or_structs], store)

    def dispatch(_contract, :reload!, [struct_or_structs, _opts], store),
      do: InMemoryShared.dispatch_reload!([struct_or_structs], store)

    def dispatch(_contract, :reload!, [struct_or_structs], store),
      do: InMemoryShared.dispatch_reload!([struct_or_structs], store)

    # -----------------------------------------------------------------
    # Opts-accepting variants — strip opts, delegate to base arity.
    # -----------------------------------------------------------------

    def dispatch(contract, :insert, [changeset, _opts], store),
      do: dispatch(contract, :insert, [changeset], store)

    def dispatch(contract, :update, [changeset, _opts], store),
      do: dispatch(contract, :update, [changeset], store)

    def dispatch(contract, :delete, [record, _opts], store),
      do: dispatch(contract, :delete, [record], store)

    def dispatch(contract, :insert_or_update, [changeset, _opts], store),
      do: dispatch(contract, :insert_or_update, [changeset], store)

    def dispatch(contract, :insert_or_update!, [changeset, _opts], store),
      do: dispatch(contract, :insert_or_update!, [changeset], store)

    def dispatch(contract, :insert!, [changeset, _opts], store),
      do: dispatch(contract, :insert!, [changeset], store)

    def dispatch(contract, :update!, [changeset, _opts], store),
      do: dispatch(contract, :update!, [changeset], store)

    def dispatch(contract, :delete!, [record, _opts], store),
      do: dispatch(contract, :delete!, [record], store)

    def dispatch(contract, :get, [queryable, id, _opts], store),
      do: dispatch(contract, :get, [queryable, id], store)

    def dispatch(contract, :get!, [queryable, id, _opts], store),
      do: dispatch(contract, :get!, [queryable, id], store)

    def dispatch(contract, :get_by, [queryable, clauses, _opts], store),
      do: dispatch(contract, :get_by, [queryable, clauses], store)

    def dispatch(contract, :get_by!, [queryable, clauses, _opts], store),
      do: dispatch(contract, :get_by!, [queryable, clauses], store)

    def dispatch(contract, :one, [queryable, _opts], store),
      do: dispatch(contract, :one, [queryable], store)

    def dispatch(contract, :one!, [queryable, _opts], store),
      do: dispatch(contract, :one!, [queryable], store)

    def dispatch(contract, :all, [queryable, _opts], store),
      do: dispatch(contract, :all, [queryable], store)

    def dispatch(contract, :exists?, [queryable, _opts], store),
      do: dispatch(contract, :exists?, [queryable], store)

    def dispatch(contract, :aggregate, [queryable, aggregate, field, _opts], store),
      do: dispatch(contract, :aggregate, [queryable, aggregate, field], store)

    # -----------------------------------------------------------------
    # get_by / get_by! — 3-stage when clauses include PK, else fallback
    # -----------------------------------------------------------------

    def dispatch(contract, :get_by, [queryable, clauses] = args, store) do
      dispatch_get_by(contract, :get_by, queryable, clauses, args, store)
    end

    def dispatch(contract, :get_by!, [queryable, clauses] = args, store) do
      dispatch_get_by(contract, :get_by!, queryable, clauses, args, store)
    end

    # -----------------------------------------------------------------
    # Non-PK reads — always fallback (open-world)
    # -----------------------------------------------------------------

    def dispatch(contract, :one, args, store),
      do: dispatch_via_fallback(contract, :one, args, store)

    def dispatch(contract, :one!, args, store),
      do: dispatch_via_fallback(contract, :one!, args, store)

    def dispatch(contract, :all, args, store),
      do: dispatch_via_fallback(contract, :all, args, store)

    def dispatch(contract, :all_by, [queryable, clauses, _opts], store),
      do: dispatch(contract, :all_by, [queryable, clauses], store)

    def dispatch(contract, :all_by, args, store),
      do: dispatch_via_fallback(contract, :all_by, args, store)

    def dispatch(contract, :exists?, args, store),
      do: dispatch_via_fallback(contract, :exists?, args, store)

    def dispatch(contract, :aggregate, args, store),
      do: dispatch_via_fallback(contract, :aggregate, args, store)

    # -----------------------------------------------------------------
    # Bulk operations — always fallback (open-world)
    # -----------------------------------------------------------------

    def dispatch(contract, :insert_all, args, store),
      do: dispatch_via_fallback(contract, :insert_all, args, store)

    def dispatch(contract, :update_all, args, store),
      do: dispatch_via_fallback(contract, :update_all, args, store)

    def dispatch(contract, :delete_all, args, store),
      do: dispatch_via_fallback(contract, :delete_all, args, store)

    # -----------------------------------------------------------------
    # Raw SQL operations — always fallback
    # -----------------------------------------------------------------

    def dispatch(contract, :query, args, store),
      do: dispatch_via_fallback(contract, :query, args, store)

    def dispatch(contract, :query!, args, store),
      do: dispatch_via_fallback(contract, :query!, args, store)

    # -----------------------------------------------------------------
    # Transaction operations — delegate to Shared
    # -----------------------------------------------------------------

    def dispatch(contract, :transact, args, store),
      do: InMemoryShared.dispatch_transact(args, store, contract)

    def dispatch(_contract, :rollback, args, store),
      do: InMemoryShared.dispatch_rollback(args, store)

    def dispatch(_contract, :in_transaction?, [], store),
      do: InMemoryShared.dispatch_in_transaction?(store)

    # -----------------------------------------------------------------
    # Catch-all — delegate unrecognised operations to fallback
    # -----------------------------------------------------------------

    def dispatch(contract, operation, args, store),
      do: dispatch_via_fallback(contract, operation, args, store)

    # -----------------------------------------------------------------
    # get_by PK-inclusive dispatch (open-world)
    # -----------------------------------------------------------------

    defp dispatch_get_by(contract, operation, queryable, clauses, args, store)
         when is_atom(queryable) and not is_nil(queryable) do
      clauses_kw = InMemoryShared.normalize_clauses(clauses)

      case InMemoryShared.extract_pk_from_clauses(queryable, clauses_kw) do
        {:ok, pk_value, remaining_clauses} ->
          case InMemoryShared.get_record(store, queryable, pk_value) do
            nil ->
              # Not in state — absence is not authoritative, delegate to fallback
              dispatch_via_fallback(contract, operation, args, store)

            record ->
              if InMemoryShared.fields_match?(record, remaining_clauses) do
                {record, store}
              else
                if operation == :get_by! do
                  InMemoryShared.defer_raise_no_results(queryable, store)
                else
                  {nil, store}
                end
              end
          end

        :not_pk_inclusive ->
          dispatch_via_fallback(contract, operation, args, store)
      end
    end

    defp dispatch_get_by(contract, operation, _queryable, _clauses, args, store) do
      # Ecto.Query or other non-atom queryable — delegate to fallback
      dispatch_via_fallback(contract, operation, args, store)
    end

    # -----------------------------------------------------------------
    # Fallback dispatch (open-world error messages)
    # -----------------------------------------------------------------

    defp dispatch_via_fallback(contract, operation, args, store) do
      case InMemoryShared.try_fallback(store, contract, operation, args) do
        {:no_fallback, ^operation, ^args} ->
          defer_raise_no_fallback(operation, args, store)

        result ->
          result
      end
    end

    defp defer_raise_no_fallback(operation, args, store) do
      InMemoryShared.defer_raise(
        """
        DoubleDown.Repo.OpenInMemory cannot service :#{operation} with args #{inspect(args)}.

        The InMemory adapter can only answer authoritatively for:
          - Write operations (insert, update, delete)
          - PK-based reads (get, get!) when the record exists in state

        For all other operations, register a fallback function:

        DoubleDown.Repo.OpenInMemory.new(
          fallback_fn: fn
            _contract, :#{operation}, #{inspect(args)}, _state -> # your result here
          end
        )
        """,
        store
      )
    end
  end
end
