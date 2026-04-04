# Stateful in-memory Repo implementation for tests.
#
# Provides read-after-write consistency for PK-based lookups. Non-PK reads
# (get_by, all, one, exists?, aggregate, etc.) go through an optional
# fallback function, or raise if no fallback is registered.
#
# ## Usage
#
#     HexPort.Testing.set_stateful_handler(
#       HexPort.Repo.Contract,
#       &HexPort.Repo.InMemory.dispatch/3,
#       HexPort.Repo.InMemory.new()
#     )
#
#     # With seeded data and a fallback function
#     initial = HexPort.Repo.InMemory.new(
#       seed: [%User{id: 1, name: "Alice"}],
#       fallback_fn: fn
#         :all, [User] -> [%User{id: 1, name: "Alice"}]
#       end
#     )
#     HexPort.Testing.set_stateful_handler(
#       HexPort.Repo.Contract,
#       &HexPort.Repo.InMemory.dispatch/3,
#       initial
#     )
#
if Code.ensure_loaded?(Ecto) do
  defmodule HexPort.Repo.InMemory do
    @moduledoc """
    Stateful in-memory Repo implementation for tests.

    Provides a stateful handler function for `HexPort.Repo.Contract` operations.
    State is a nested map keyed by `schema_module => %{primary_key => struct}`,
    giving read-after-write consistency for PK-based lookups within a test.

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

    For all other reads (`get_by`, `one`, `all`, `exists?`, `aggregate`, etc.)
    the state is never authoritative — these always go through the fallback
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
        HexPort.Testing.set_stateful_handler(
          HexPort.Repo.Contract,
          &HexPort.Repo.InMemory.dispatch/3,
          HexPort.Repo.InMemory.new()
        )

        # With seed data and fallback:
        state = HexPort.Repo.InMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn
            :all, [User], state ->
              Map.get(state, User, %{}) |> Map.values()
            :get_by, [User, [email: "alice@example.com"]], _state ->
              %User{id: 1}
          end
        )
        HexPort.Testing.set_stateful_handler(
          HexPort.Repo.Contract,
          &HexPort.Repo.InMemory.dispatch/3,
          state
        )

    ## Seeding Initial State

    Use `new/1` with the `:seed` option, or `seed/1` to convert a list of
    structs into the nested state map:

        HexPort.Repo.InMemory.new(seed: [
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"}
        ])

    ## Differences from Repo.Test

    `Repo.Test` is stateless — writes apply changesets and return `{:ok, struct}`
    but nothing is stored. Reads always return defaults (`nil`, `[]`, `false`).

    `Repo.InMemory` is stateful — writes store records in state, and subsequent
    PK-based reads can find them. Non-PK reads require a fallback function.
    Use `Repo.InMemory` when your test needs read-after-write consistency.
    Use `Repo.Test` when you only need fire-and-forget writes.

    ## Auto-incrementing IDs

    When inserting a changeset for a record with a `nil` id, `Repo.InMemory`
    assigns a positive integer id based on the count of existing records of
    that schema type. This mirrors Ecto's auto-increment behaviour.

    ## Supported Operations

    - **Writes (authoritative):** `insert`, `update`, `delete` — always handled
      by the state
    - **PK reads (3-stage):** `get`, `get!` — check state first, then fallback,
      then error
    - **Non-PK reads (2-stage):** `get_by`, `get_by!`, `one`, `one!`, `all`,
      `exists?`, `aggregate` — fallback or error
    - **Bulk (2-stage):** `update_all`, `delete_all` — fallback or error
    - **Transactions:** `transact` — delegates to sub-operations
    """

    @type store :: %{optional(module()) => %{optional(term()) => struct()}}

    @fallback_fn_key :__fallback_fn__

    @doc """
    Create a new InMemory state map.

    ## Options

      * `:seed` - a list of structs to pre-populate the store
      * `:fallback_fn` - a 3-arity function `(operation, args, state) -> result`
        that handles operations the state cannot answer authoritatively. The
        `state` argument is the clean store map (without internal keys like
        `:__fallback_fn__`), so the fallback can compose canned data with
        records inserted during the test. If the function raises
        `FunctionClauseError`, dispatch falls through to an error.

    ## Examples

        # Empty state, no fallback
        HexPort.Repo.InMemory.new()

        # Seeded with fallback that uses state
        HexPort.Repo.InMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn
            :all, [User], state ->
              Map.get(state, User, %{}) |> Map.values()
          end
        )
    """
    @spec new(keyword()) :: store()
    def new(opts \\ []) do
      seed_records = Keyword.get(opts, :seed, [])
      fallback_fn = Keyword.get(opts, :fallback_fn, nil)

      store = seed(seed_records)

      if fallback_fn do
        Map.put(store, @fallback_fn_key, fallback_fn)
      else
        store
      end
    end

    @doc """
    Convert a list of structs into the nested state map for seeding.

    ## Example

        HexPort.Repo.InMemory.seed([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"}
        ])
        #=> %{User => %{1 => %User{id: 1, name: "Alice"},
        #               2 => %User{id: 2, name: "Bob"}}}
    """
    @spec seed(list(struct())) :: store()
    def seed(records) when is_list(records) do
      Enum.reduce(records, %{}, fn record, store ->
        schema = record.__struct__
        id = HexPort.Repo.Autogenerate.get_primary_key(record)
        put_record(store, schema, id, record)
      end)
    end

    @doc """
    Stateful handler function for use with `HexPort.Testing.set_stateful_handler/3`.

    Handles all `HexPort.Repo.Contract` operations. The function signature is
    `(operation, args, store) -> {result, new_store}`.

    Write operations are handled directly by the state. PK-based reads check
    the state first, then fall through to the fallback function. All other
    reads go directly to the fallback function. If no fallback is registered
    or the fallback doesn't handle the operation, an error is raised.
    """
    @spec dispatch(atom(), list(), store()) :: {term(), store()}

    # -----------------------------------------------------------------
    # Write operations — always authoritative
    # -----------------------------------------------------------------

    def dispatch(:insert, [%Ecto.Changeset{valid?: false} = changeset], store) do
      {{:error, changeset}, store}
    end

    def dispatch(:insert, [changeset], store) do
      alias HexPort.Repo.Autogenerate

      record = Autogenerate.apply_changes(changeset, :insert)
      schema = record.__struct__

      case Autogenerate.maybe_autogenerate_id(record, schema, fn s ->
             store
             |> records_for_schema(s)
             |> Enum.map(&Autogenerate.get_primary_key/1)
             |> Enum.filter(&is_integer/1)
           end) do
        {:error, {:no_autogenerate, message}} ->
          {{:defer, fn -> raise ArgumentError, message end}, store}

        {id, record} ->
          {{:ok, record}, put_record(store, schema, id, record)}
      end
    end

    def dispatch(:update, [%Ecto.Changeset{valid?: false} = changeset], store) do
      {{:error, changeset}, store}
    end

    def dispatch(:update, [changeset], store) do
      record = HexPort.Repo.Autogenerate.apply_changes(changeset, :update)
      schema = record.__struct__
      id = HexPort.Repo.Autogenerate.get_primary_key(record)
      {{:ok, record}, put_record(store, schema, id, record)}
    end

    def dispatch(:delete, [record], store) do
      schema = record.__struct__
      id = HexPort.Repo.Autogenerate.get_primary_key(record)
      {{:ok, record}, delete_record(store, schema, id)}
    end

    # -----------------------------------------------------------------
    # PK reads — 3-stage: state -> fallback -> error
    # -----------------------------------------------------------------

    def dispatch(:get, [queryable, id] = args, store) do
      schema = extract_schema(queryable)

      case get_record(store, schema, id) do
        nil -> try_fallback(store, :get, args)
        record -> {record, store}
      end
    end

    def dispatch(:get!, [queryable, id] = args, store) do
      schema = extract_schema(queryable)

      case get_record(store, schema, id) do
        nil -> try_fallback(store, :get!, args)
        record -> {record, store}
      end
    end

    # -----------------------------------------------------------------
    # Non-PK reads — 2-stage: fallback -> error
    # -----------------------------------------------------------------

    def dispatch(:get_by, args, store),
      do: dispatch_via_fallback(:get_by, args, store)

    def dispatch(:get_by!, args, store),
      do: dispatch_via_fallback(:get_by!, args, store)

    def dispatch(:one, args, store),
      do: dispatch_via_fallback(:one, args, store)

    def dispatch(:one!, args, store),
      do: dispatch_via_fallback(:one!, args, store)

    def dispatch(:all, args, store),
      do: dispatch_via_fallback(:all, args, store)

    def dispatch(:exists?, args, store),
      do: dispatch_via_fallback(:exists?, args, store)

    def dispatch(:aggregate, args, store),
      do: dispatch_via_fallback(:aggregate, args, store)

    # -----------------------------------------------------------------
    # Bulk operations — 2-stage: fallback -> error
    # -----------------------------------------------------------------

    def dispatch(:insert_all, args, store),
      do: dispatch_via_fallback(:insert_all, args, store)

    def dispatch(:update_all, args, store),
      do: dispatch_via_fallback(:update_all, args, store)

    def dispatch(:delete_all, args, store),
      do: dispatch_via_fallback(:delete_all, args, store)

    # -----------------------------------------------------------------
    # Transaction Operations
    # -----------------------------------------------------------------

    # transact uses {:defer, deferred_fn} to run the user's function
    # outside the NimbleOwnership lock. Sub-operations (insert, get, etc.)
    # each acquire the lock individually. This avoids GenServer reentrancy
    # deadlock at the cost of not providing true transaction isolation —
    # acceptable for a test-only in-memory adapter.
    def dispatch(:transact, [fun, _opts], _store) when is_function(fun, 0) do
      {:defer, fun}
    end

    def dispatch(:transact, [fun, opts], _store) when is_function(fun, 1) do
      repo_facade = Keyword.get(opts, HexPort.Repo.Facade)
      {:defer, fn -> fun.(repo_facade) end}
    end

    def dispatch(:transact, [%Ecto.Multi{} = multi, opts], _store) do
      repo_facade = Keyword.get(opts, HexPort.Repo.Facade)

      {:defer, fn -> HexPort.Repo.MultiStepper.run(multi, repo_facade) end}
    end

    # -----------------------------------------------------------------
    # Fallback dispatch
    #
    # Because dispatch/3 runs inside NimbleOwnership.get_and_update
    # (a GenServer call), we must not raise here — that would crash
    # the ownership server. Instead, we use {:defer, fn -> raise ... end}
    # to move the raise outside the lock.
    # -----------------------------------------------------------------

    defp dispatch_via_fallback(operation, args, store) do
      try_fallback(store, operation, args)
    end

    defp try_fallback(store, operation, args) do
      case Map.get(store, @fallback_fn_key) do
        nil ->
          defer_raise_no_fallback(operation, args, store)

        fallback_fn when is_function(fallback_fn, 3) ->
          clean_state = Map.delete(store, @fallback_fn_key)

          try do
            {fallback_fn.(operation, args, clean_state), store}
          rescue
            FunctionClauseError -> defer_raise_no_fallback(operation, args, store)
          end
      end
    end

    defp defer_raise_no_fallback(operation, args, store) do
      {{:defer,
        fn ->
          raise ArgumentError, """
          HexPort.Repo.InMemory cannot service :#{operation} with args #{inspect(args)}.

          The InMemory adapter can only answer authoritatively for:
            - Write operations (insert, update, delete)
            - PK-based reads (get, get!) when the record exists in state

          For all other operations, register a fallback function:

          HexPort.Repo.InMemory.new(
            fallback_fn: fn
              :#{operation}, #{inspect(args)}, _state -> # your result here
            end
          )
          """
        end}, store}
    end

    # -----------------------------------------------------------------
    # State access helpers
    # -----------------------------------------------------------------

    defp get_record(store, schema, id) do
      store
      |> Map.get(schema, %{})
      |> Map.get(id)
    end

    defp put_record(store, schema, id, record) do
      schema_map = Map.get(store, schema, %{})
      Map.put(store, schema, Map.put(schema_map, id, record))
    end

    defp delete_record(store, schema, id) do
      case Map.get(store, schema) do
        nil -> store
        schema_map -> Map.put(store, schema, Map.delete(schema_map, id))
      end
    end

    defp records_for_schema(store, schema) do
      store
      |> Map.get(schema, %{})
      |> Map.values()
    end

    defp extract_schema(queryable) when is_atom(queryable), do: queryable

    defp extract_schema(%Ecto.Query{from: %Ecto.Query.FromExpr{source: {_table, schema}}})
         when is_atom(schema) and not is_nil(schema) do
      schema
    end

    defp extract_schema(queryable), do: queryable
  end
end
