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
            :all, [User], state ->
              Map.get(state, User, %{}) |> Map.values()
            :get_by, [User, [email: "alice@example.com"]], _state ->
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
    2. **Fallback function** — a 3-arity `(operation, args, state)`
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
        - `:fallback_fn` — a 3-arity function `(operation, args, state) -> result`
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
            :all, [User], state ->
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
    `(operation, args, store) -> {result, new_store}`.

    Write operations are handled directly by the state. PK-based reads check
    the state first, then fall through to the fallback function. All other
    reads go directly to the fallback function. If no fallback is registered
    or the fallback doesn't handle the operation, an error is raised.
    """
    @impl DoubleDown.Contract.Dispatch.FakeHandler
    @spec dispatch(atom(), list(), store()) :: {term(), store()}

    # -----------------------------------------------------------------
    # Write operations — delegate to Shared
    # -----------------------------------------------------------------

    def dispatch(:insert, [changeset], store),
      do: InMemoryShared.dispatch_insert([changeset], store)

    def dispatch(:update, [changeset], store),
      do: InMemoryShared.dispatch_update([changeset], store)

    def dispatch(:delete, [record], store), do: InMemoryShared.dispatch_delete([record], store)

    def dispatch(:insert!, [changeset], store),
      do: InMemoryShared.dispatch_insert!([changeset], store)

    def dispatch(:update!, [changeset], store),
      do: InMemoryShared.dispatch_update!([changeset], store)

    def dispatch(:delete!, [record], store),
      do: InMemoryShared.dispatch_delete!([record], store)

    # -----------------------------------------------------------------
    # PK reads — 3-stage: state -> fallback -> error
    # -----------------------------------------------------------------

    def dispatch(:get, [queryable, id] = args, store) do
      schema = InMemoryShared.extract_schema(queryable)

      case InMemoryShared.get_record(store, schema, id) do
        nil -> dispatch_via_fallback(:get, args, store)
        record -> {record, store}
      end
    end

    def dispatch(:get!, [queryable, id] = args, store) do
      schema = InMemoryShared.extract_schema(queryable)

      case InMemoryShared.get_record(store, schema, id) do
        nil -> dispatch_via_fallback(:get!, args, store)
        record -> {record, store}
      end
    end

    # -----------------------------------------------------------------
    # Opts-accepting variants — strip opts, delegate to base arity.
    # -----------------------------------------------------------------

    def dispatch(:insert, [changeset, _opts], store),
      do: dispatch(:insert, [changeset], store)

    def dispatch(:update, [changeset, _opts], store),
      do: dispatch(:update, [changeset], store)

    def dispatch(:delete, [record, _opts], store),
      do: dispatch(:delete, [record], store)

    def dispatch(:insert!, [changeset, _opts], store),
      do: dispatch(:insert!, [changeset], store)

    def dispatch(:update!, [changeset, _opts], store),
      do: dispatch(:update!, [changeset], store)

    def dispatch(:delete!, [record, _opts], store),
      do: dispatch(:delete!, [record], store)

    def dispatch(:get, [queryable, id, _opts], store),
      do: dispatch(:get, [queryable, id], store)

    def dispatch(:get!, [queryable, id, _opts], store),
      do: dispatch(:get!, [queryable, id], store)

    def dispatch(:get_by, [queryable, clauses, _opts], store),
      do: dispatch(:get_by, [queryable, clauses], store)

    def dispatch(:get_by!, [queryable, clauses, _opts], store),
      do: dispatch(:get_by!, [queryable, clauses], store)

    def dispatch(:one, [queryable, _opts], store),
      do: dispatch(:one, [queryable], store)

    def dispatch(:one!, [queryable, _opts], store),
      do: dispatch(:one!, [queryable], store)

    def dispatch(:all, [queryable, _opts], store),
      do: dispatch(:all, [queryable], store)

    def dispatch(:exists?, [queryable, _opts], store),
      do: dispatch(:exists?, [queryable], store)

    def dispatch(:aggregate, [queryable, aggregate, field, _opts], store),
      do: dispatch(:aggregate, [queryable, aggregate, field], store)

    # -----------------------------------------------------------------
    # get_by / get_by! — 3-stage when clauses include PK, else fallback
    # -----------------------------------------------------------------

    def dispatch(:get_by, [queryable, clauses] = args, store) do
      dispatch_get_by(:get_by, queryable, clauses, args, store)
    end

    def dispatch(:get_by!, [queryable, clauses] = args, store) do
      dispatch_get_by(:get_by!, queryable, clauses, args, store)
    end

    # -----------------------------------------------------------------
    # Non-PK reads — always fallback (open-world)
    # -----------------------------------------------------------------

    def dispatch(:one, args, store), do: dispatch_via_fallback(:one, args, store)
    def dispatch(:one!, args, store), do: dispatch_via_fallback(:one!, args, store)
    def dispatch(:all, args, store), do: dispatch_via_fallback(:all, args, store)
    def dispatch(:exists?, args, store), do: dispatch_via_fallback(:exists?, args, store)
    def dispatch(:aggregate, args, store), do: dispatch_via_fallback(:aggregate, args, store)

    # -----------------------------------------------------------------
    # Bulk operations — always fallback (open-world)
    # -----------------------------------------------------------------

    def dispatch(:insert_all, args, store), do: dispatch_via_fallback(:insert_all, args, store)
    def dispatch(:update_all, args, store), do: dispatch_via_fallback(:update_all, args, store)
    def dispatch(:delete_all, args, store), do: dispatch_via_fallback(:delete_all, args, store)

    # -----------------------------------------------------------------
    # Transaction operations — delegate to Shared
    # -----------------------------------------------------------------

    def dispatch(:transact, args, store),
      do: InMemoryShared.dispatch_transact(args, store, DoubleDown.Repo)

    def dispatch(:rollback, args, store), do: InMemoryShared.dispatch_rollback(args, store)

    # -----------------------------------------------------------------
    # get_by PK-inclusive dispatch (open-world)
    # -----------------------------------------------------------------

    defp dispatch_get_by(operation, queryable, clauses, args, store)
         when is_atom(queryable) and not is_nil(queryable) do
      clauses_kw = InMemoryShared.normalize_clauses(clauses)

      case InMemoryShared.extract_pk_from_clauses(queryable, clauses_kw) do
        {:ok, pk_value, remaining_clauses} ->
          case InMemoryShared.get_record(store, queryable, pk_value) do
            nil ->
              # Not in state — absence is not authoritative, delegate to fallback
              dispatch_via_fallback(operation, args, store)

            record ->
              if InMemoryShared.fields_match?(record, remaining_clauses) do
                {record, store}
              else
                {nil, store}
              end
          end

        :not_pk_inclusive ->
          dispatch_via_fallback(operation, args, store)
      end
    end

    defp dispatch_get_by(operation, _queryable, _clauses, args, store) do
      # Ecto.Query or other non-atom queryable — delegate to fallback
      dispatch_via_fallback(operation, args, store)
    end

    # -----------------------------------------------------------------
    # Fallback dispatch (open-world error messages)
    # -----------------------------------------------------------------

    defp dispatch_via_fallback(operation, args, store) do
      case InMemoryShared.try_fallback(store, operation, args) do
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
            :#{operation}, #{inspect(args)}, _state -> # your result here
          end
        )
        """,
        store
      )
    end
  end
end
