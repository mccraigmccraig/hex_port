# Stateful in-memory Repo implementation for tests.
#
# Provides read-after-write consistency for PK-based lookups. get_by/get_by!
# also use PK lookup when clauses include all PK fields. Other non-PK reads
# (all, one, exists?, aggregate, etc.) go through an optional fallback
# function, or raise if no fallback is registered.
#
# ## Usage
#
#     DoubleDown.Testing.set_stateful_handler(
#       DoubleDown.Repo,
#       &DoubleDown.Repo.OpenInMemory.dispatch/3,
#       DoubleDown.Repo.OpenInMemory.new()
#     )
#
#     # With seeded data and a fallback function
#     initial = DoubleDown.Repo.OpenInMemory.new(
#       seed: [%User{id: 1, name: "Alice"}],
#       fallback_fn: fn
#         :all, [User] -> [%User{id: 1, name: "Alice"}]
#       end
#     )
#     DoubleDown.Testing.set_stateful_handler(
#       DoubleDown.Repo,
#       &DoubleDown.Repo.OpenInMemory.dispatch/3,
#       initial
#     )
#
if Code.ensure_loaded?(Ecto) do
  defmodule DoubleDown.Repo.OpenInMemory do
    @behaviour DoubleDown.Contract.Dispatch.FakeHandler

    @moduledoc """
    Stateful in-memory Repo implementation for tests (open-world).

    Provides a stateful handler function for `DoubleDown.Repo` operations.
    State is a nested map keyed by `schema_module => %{primary_key => struct}`,
    giving read-after-write consistency for PK-based lookups within a test.

    ## Open-world semantics

    This adapter uses **open-world** semantics: the state may be
    incomplete. If a record is not found in state, the adapter cannot
    know whether it exists in the _logical_ store — it falls through to
    the fallback function. For **closed-world** semantics (absence
    means "doesn't exist"), see `DoubleDown.Repo.InMemory`.

    ## State Shape

        %{
          MyApp.User => %{
            1 => %MyApp.User{id: 1, name: "Alice"},
            2 => %MyApp.User{id: 2, name: "Bob"}
          },
          MyApp.Post => %{
            1 => %MyApp.Post{id: 1, title: "Hello"}
          }
        }

    ## 3-Stage Read Dispatch

    The InMemory adapter can only answer authoritatively for operations where
    the state definitively contains the answer. For PK-based reads (`get`,
    `get!`), if a record is found in state it is returned. If not found, the
    adapter cannot know whether the record exists in the _logical_ store —
    it falls through to the fallback function, or raises.

    `get_by` and `get_by!` use 3-stage dispatch when the queryable is a bare
    schema module (atom) and the clauses include all primary key fields. The
    PK is used for a direct map lookup in state. If found, any additional
    non-PK clauses are verified against the record (returning `nil` on
    mismatch). If not found in state, the adapter falls through to the
    fallback function. When the clauses do not include the PK, or the
    queryable is an `Ecto.Query`, `get_by`/`get_by!` delegate directly to
    the fallback function as before.

    For all other reads (`one`, `all`, `exists?`, `aggregate`, etc.) the
    state is never authoritative — these always go through the fallback
    function, or raise.

    The dispatch stages are:

    1. **State lookup** (PK reads only) — if the record is in state, return it
    2. **Fallback function** — an optional user-supplied function that handles
       operations the state cannot answer. Receives `(operation, args, state)`
       where `state` is the clean store map (without internal keys), and
       returns the result. If it raises `FunctionClauseError` (no matching
       clause), falls through to stage 3.
    3. **Raise** — a clear error explaining that InMemory cannot service the
       operation, suggesting the fallback function as the escape hatch.

    ## Usage

        # Basic — PK reads only, no fallback:
        DoubleDown.Testing.set_stateful_handler(
          DoubleDown.Repo,
          &DoubleDown.Repo.OpenInMemory.dispatch/3,
          DoubleDown.Repo.OpenInMemory.new()
        )

        # With seed data and fallback:
        state = DoubleDown.Repo.OpenInMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn
            :all, [User], state ->
              Map.get(state, User, %{}) |> Map.values()
            :get_by, [User, [email: "alice@example.com"]], _state ->
              %User{id: 1}
          end
        )
        DoubleDown.Testing.set_stateful_handler(
          DoubleDown.Repo,
          &DoubleDown.Repo.OpenInMemory.dispatch/3,
          state
        )

    ## Seeding Initial State

    Use `new/1` with the `:seed` option, or `seed/1` to convert a list of
    structs into the nested state map:

        DoubleDown.Repo.OpenInMemory.new(seed: [
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"}
        ])

    ## Differences from Repo.Stub

    `Repo.Stub` is stateless — writes apply changesets and return `{:ok, struct}`
    but nothing is stored. Reads always return defaults (`nil`, `[]`, `false`).

    `Repo.OpenInMemory` is stateful — writes store records in state, and subsequent
    PK-based reads can find them. Non-PK reads require a fallback function.
    Use `Repo.OpenInMemory` when your test needs read-after-write consistency.
    Use `Repo.Stub` when you only need fire-and-forget writes.

    ## Primary Key Autogeneration

    When inserting a changeset with a `nil` primary key, the adapter
    autogenerates the PK based on Ecto schema metadata:

    - **`:id` type** (default `schema`) — auto-incremented integer
      based on existing records of that schema type
    - **`:binary_id`** — generates a UUID string via `Ecto.UUID`
    - **Parameterized types** (`Ecto.UUID`, `Uniq.UUID`, etc.) —
      calls the type's `autogenerate` callback
    - **`@primary_key false`** — no PK handling needed
    - **`autogenerate: false`** — raises `ArgumentError` if no PK
      value is provided

    Explicitly set PK values are always preserved.

    ## Supported Operations

    - **Writes (authoritative):** `insert`, `update`, `delete` — always handled
      by the state
    - **PK reads (3-stage):** `get`, `get!` — check state first, then fallback,
      then error
    - **get_by / get_by! (3-stage when PK in clauses):** when the queryable is
      a bare schema and clauses include all PK fields, uses PK lookup in state
      then verifies remaining clauses. Falls through to fallback when PK not in
      state. Delegates directly to fallback when clauses don't include PK or
      queryable is an `Ecto.Query`.
    - **Non-PK reads (2-stage):** `one`, `one!`, `all`,
      `exists?`, `aggregate` — fallback or error
    - **Bulk (2-stage):** `update_all`, `delete_all` — fallback or error
    - **Transactions:** `transact` — delegates to sub-operations

    ## See also

    - `DoubleDown.Repo.InMemory` — closed-world variant where absence
      means "doesn't exist", enabling authoritative reads without a fallback.
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

    def dispatch(:insert, [changeset], store), do: InMemoryShared.dispatch_insert([changeset], store)
    def dispatch(:update, [changeset], store), do: InMemoryShared.dispatch_update([changeset], store)
    def dispatch(:delete, [record], store), do: InMemoryShared.dispatch_delete([record], store)

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

    def dispatch(:transact, args, store), do: InMemoryShared.dispatch_transact(args, store)
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
