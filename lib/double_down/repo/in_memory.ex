if Code.ensure_loaded?(Ecto) do
  defmodule DoubleDown.Repo.InMemory do
    @behaviour DoubleDown.Contract.Dispatch.FakeHandler

    @moduledoc """
    Stateful in-memory Repo fake (closed-world). **Recommended default.**

    The state is the complete truth — if a record isn't in the store,
    it doesn't exist. This makes the adapter authoritative for all
    bare schema operations without needing a fallback function.

    Implements `DoubleDown.Contract.Dispatch.FakeHandler`, so it can
    be used by module name with `Double.fake`:

    ## Usage with Double.fake

        # Basic — all bare-schema reads work without fallback:
        DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory)

        # With seed data:
        DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory,
          [%User{id: 1, name: "Alice"}, %Post{id: 1, title: "Hello"}])

        # Layer expects for failure simulation:
        DoubleDown.Repo
        |> DoubleDown.Double.fake(DoubleDown.Repo.InMemory)
        |> DoubleDown.Double.expect(:insert, fn [changeset] ->
          {:error, Ecto.Changeset.add_error(changeset, :email, "taken")}
        end)

    ## ExMachina integration

        setup do
          DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory)
          insert(:user, name: "Alice", email: "alice@example.com")
          insert(:user, name: "Bob", email: "bob@example.com")
          :ok
        end

        test "lists all users" do
          assert [_, _] = MyApp.Repo.all(User)
        end

        test "finds user by email" do
          assert %User{name: "Alice"} =
            MyApp.Repo.get_by(User, email: "alice@example.com")
        end

        test "count users" do
          assert 2 = MyApp.Repo.aggregate(User, :count, :id)
        end

    ## Authoritative operations (bare schema queryables)

    | Category | Operations | Behaviour |
    |----------|-----------|-----------|
    | **Writes** | `insert`, `update`, `delete` | Store in state |
    | **PK reads** | `get`, `get!` | `nil`/raise on miss (no fallback) |
    | **Clause reads** | `get_by`, `get_by!` | Scan and filter |
    | **Collection** | `all`, `one`/`one!`, `exists?` | Scan state |
    | **Aggregates** | `aggregate` | Compute from state |
    | **Bulk writes** | `insert_all`, `delete_all`, `update_all` (`set:`) | Modify state |
    | **Transactions** | `transact`, `rollback` | Delegate to sub-operations |

    ## Ecto.Query fallback

    Operations with `Ecto.Query` queryables (containing `where`,
    `join`, `select` etc.) cannot be evaluated in-memory. These fall
    through to the fallback function, or raise with a clear error:

        DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.InMemory, [],
          fallback_fn: fn
            :all, [%Ecto.Query{}], _state -> []
          end
        )

    ## When to use which Repo fake

    | Fake | State | Best for |
    |------|-------|----------|
    | `Repo.Stub` | None | Fire-and-forget writes, canned reads |
    | **`Repo.InMemory`** | **Complete store** | **All bare-schema reads; ExMachina factories** |
    | `Repo.OpenInMemory` | Partial store | PK reads in state, fallback for rest |

    ## See also

    - `DoubleDown.Repo.OpenInMemory` — open-world variant where absence
      is inconclusive, requiring a fallback for most reads.
    - `DoubleDown.Repo.Stub` — stateless stub for fire-and-forget writes.
    """

    alias DoubleDown.Repo.Impl.InMemoryShared

    @type store :: InMemoryShared.store()

    @doc """
    Create a new InMemory state map. Same API as `Repo.OpenInMemory.new/2`.
    """
    @impl DoubleDown.Contract.Dispatch.FakeHandler
    @spec new(term(), keyword()) :: store()
    defdelegate new(seed \\ %{}, opts \\ []), to: InMemoryShared

    @doc """
    Convert a list of structs into the nested state map for seeding.
    """
    @spec seed(list(struct())) :: store()
    defdelegate seed(records), to: InMemoryShared

    @doc """
    Stateful handler function with closed-world semantics.

    Bare schema reads are authoritative — the state is the full truth.
    `Ecto.Query` reads fall through to the fallback function.
    """
    @impl DoubleDown.Contract.Dispatch.FakeHandler
    @spec dispatch(atom(), list(), store()) :: {term(), store()}

    # -----------------------------------------------------------------
    # Write operations — delegate to Shared
    # -----------------------------------------------------------------

    def dispatch(:insert, [changeset], store),
      do: InMemoryShared.dispatch_insert([changeset], store)

    def dispatch(:insert, [cs, _opts], store), do: InMemoryShared.dispatch_insert([cs], store)

    def dispatch(:update, [changeset], store),
      do: InMemoryShared.dispatch_update([changeset], store)

    def dispatch(:update, [cs, _opts], store), do: InMemoryShared.dispatch_update([cs], store)

    def dispatch(:delete, [record], store), do: InMemoryShared.dispatch_delete([record], store)

    def dispatch(:delete, [record, _opts], store),
      do: InMemoryShared.dispatch_delete([record], store)

    def dispatch(:insert!, [changeset], store),
      do: InMemoryShared.dispatch_insert!([changeset], store)

    def dispatch(:insert!, [cs, _opts], store),
      do: InMemoryShared.dispatch_insert!([cs], store)

    def dispatch(:update!, [changeset], store),
      do: InMemoryShared.dispatch_update!([changeset], store)

    def dispatch(:update!, [cs, _opts], store),
      do: InMemoryShared.dispatch_update!([cs], store)

    def dispatch(:delete!, [record], store),
      do: InMemoryShared.dispatch_delete!([record], store)

    def dispatch(:delete!, [record, _opts], store),
      do: InMemoryShared.dispatch_delete!([record], store)

    # -----------------------------------------------------------------
    # PK reads — closed-world: nil/raise on miss
    # -----------------------------------------------------------------

    def dispatch(:get, [queryable, id], store) do
      schema = InMemoryShared.extract_schema(queryable)
      {InMemoryShared.get_record(store, schema, id), store}
    end

    def dispatch(:get, [queryable, id, _opts], store),
      do: dispatch(:get, [queryable, id], store)

    def dispatch(:get!, [queryable, id], store) do
      schema = InMemoryShared.extract_schema(queryable)

      case InMemoryShared.get_record(store, schema, id) do
        nil ->
          InMemoryShared.defer_raise(
            "expected #{inspect(schema)} with id #{inspect(id)} to exist in " <>
              "InMemory store, but it was not found",
            store
          )

        record ->
          {record, store}
      end
    end

    def dispatch(:get!, [queryable, id, _opts], store),
      do: dispatch(:get!, [queryable, id], store)

    # -----------------------------------------------------------------
    # get_by / get_by! — scan and filter (closed-world, bare schema)
    # -----------------------------------------------------------------

    def dispatch(:get_by, [queryable, clauses], store)
        when is_atom(queryable) and not is_nil(queryable) do
      clauses_kw = InMemoryShared.normalize_clauses(clauses)
      records = InMemoryShared.records_for_schema(store, queryable)
      matching = Enum.filter(records, &InMemoryShared.fields_match?(&1, clauses_kw))
      {List.first(matching), store}
    end

    def dispatch(:get_by, [queryable, clauses], store),
      do: dispatch_via_fallback(:get_by, [queryable, clauses], store)

    def dispatch(:get_by, [queryable, clauses, _opts], store),
      do: dispatch(:get_by, [queryable, clauses], store)

    def dispatch(:get_by!, [queryable, clauses], store)
        when is_atom(queryable) and not is_nil(queryable) do
      clauses_kw = InMemoryShared.normalize_clauses(clauses)
      records = InMemoryShared.records_for_schema(store, queryable)
      matching = Enum.filter(records, &InMemoryShared.fields_match?(&1, clauses_kw))

      case matching do
        [record] ->
          {record, store}

        [] ->
          InMemoryShared.defer_raise(
            "expected #{inspect(queryable)} matching #{inspect(clauses)} to exist in " <>
              "InMemory store, but no matching record was found",
            store
          )

        _multiple ->
          InMemoryShared.defer_raise(
            "expected at most one #{inspect(queryable)} matching #{inspect(clauses)}, " <>
              "but found #{length(matching)} records in InMemory store",
            store
          )
      end
    end

    def dispatch(:get_by!, [queryable, clauses], store),
      do: dispatch_via_fallback(:get_by!, [queryable, clauses], store)

    def dispatch(:get_by!, [queryable, clauses, _opts], store),
      do: dispatch(:get_by!, [queryable, clauses], store)

    # -----------------------------------------------------------------
    # Collection reads — scan (closed-world, bare schema)
    # -----------------------------------------------------------------

    def dispatch(:all, [queryable], store)
        when is_atom(queryable) and not is_nil(queryable) do
      {InMemoryShared.records_for_schema(store, queryable), store}
    end

    def dispatch(:all, [queryable], store),
      do: dispatch_via_fallback(:all, [queryable], store)

    def dispatch(:all, [queryable, _opts], store),
      do: dispatch(:all, [queryable], store)

    def dispatch(:one, [queryable], store)
        when is_atom(queryable) and not is_nil(queryable) do
      records = InMemoryShared.records_for_schema(store, queryable)

      case records do
        [] ->
          {nil, store}

        [record] ->
          {record, store}

        _multiple ->
          InMemoryShared.defer_raise(
            "expected at most one #{inspect(queryable)} in InMemory store, " <>
              "but found #{length(records)}",
            store
          )
      end
    end

    def dispatch(:one, [queryable], store),
      do: dispatch_via_fallback(:one, [queryable], store)

    def dispatch(:one, [queryable, _opts], store),
      do: dispatch(:one, [queryable], store)

    def dispatch(:one!, [queryable], store)
        when is_atom(queryable) and not is_nil(queryable) do
      records = InMemoryShared.records_for_schema(store, queryable)

      case records do
        [record] ->
          {record, store}

        [] ->
          InMemoryShared.defer_raise(
            "expected exactly one #{inspect(queryable)} in InMemory store, " <>
              "but found none",
            store
          )

        _multiple ->
          InMemoryShared.defer_raise(
            "expected exactly one #{inspect(queryable)} in InMemory store, " <>
              "but found #{length(records)}",
            store
          )
      end
    end

    def dispatch(:one!, [queryable], store),
      do: dispatch_via_fallback(:one!, [queryable], store)

    def dispatch(:one!, [queryable, _opts], store),
      do: dispatch(:one!, [queryable], store)

    def dispatch(:exists?, [queryable], store)
        when is_atom(queryable) and not is_nil(queryable) do
      {InMemoryShared.records_for_schema(store, queryable) != [], store}
    end

    def dispatch(:exists?, [queryable], store),
      do: dispatch_via_fallback(:exists?, [queryable], store)

    def dispatch(:exists?, [queryable, _opts], store),
      do: dispatch(:exists?, [queryable], store)

    # -----------------------------------------------------------------
    # Aggregates — compute from state (closed-world, bare schema)
    # -----------------------------------------------------------------

    def dispatch(:aggregate, [queryable, aggregate, field], store)
        when is_atom(queryable) and not is_nil(queryable) do
      records = InMemoryShared.records_for_schema(store, queryable)
      {compute_aggregate(records, aggregate, field), store}
    end

    def dispatch(:aggregate, [queryable, aggregate, field], store),
      do: dispatch_via_fallback(:aggregate, [queryable, aggregate, field], store)

    def dispatch(:aggregate, [queryable, aggregate, field, _opts], store),
      do: dispatch(:aggregate, [queryable, aggregate, field], store)

    # -----------------------------------------------------------------
    # Bulk writes (closed-world, bare schema)
    # -----------------------------------------------------------------

    def dispatch(:insert_all, [source, entries, opts], store)
        when is_atom(source) and not is_nil(source) do
      {count, records, new_store} =
        Enum.reduce(entries, {0, [], store}, fn entry, {count, acc, st} ->
          record = struct(source, entry_to_keyword(entry))
          schema = record.__struct__

          case DoubleDown.Repo.Impl.Autogenerate.maybe_autogenerate_id(record, schema, fn s ->
                 st
                 |> InMemoryShared.records_for_schema(s)
                 |> Enum.map(&DoubleDown.Repo.Impl.Autogenerate.get_primary_key/1)
                 |> Enum.filter(&is_integer/1)
               end) do
            {:error, {:no_autogenerate, _message}} ->
              id = DoubleDown.Repo.Impl.Autogenerate.get_primary_key(record)
              {count + 1, [record | acc], InMemoryShared.put_record(st, schema, id, record)}

            {id, record} ->
              {count + 1, [record | acc], InMemoryShared.put_record(st, schema, id, record)}
          end
        end)

      returning? = Keyword.get(opts, :returning, false)

      result =
        if returning? do
          {count, Enum.reverse(records)}
        else
          {count, nil}
        end

      {result, new_store}
    end

    def dispatch(:insert_all, args, store),
      do: dispatch_via_fallback(:insert_all, args, store)

    def dispatch(:delete_all, [queryable], store)
        when is_atom(queryable) and not is_nil(queryable) do
      records = InMemoryShared.records_for_schema(store, queryable)
      count = length(records)
      new_store = Map.delete(store, queryable)
      {{count, nil}, new_store}
    end

    def dispatch(:delete_all, [queryable], store),
      do: dispatch_via_fallback(:delete_all, [queryable], store)

    def dispatch(:delete_all, [queryable, _opts], store),
      do: dispatch(:delete_all, [queryable], store)

    def dispatch(:update_all, [queryable, [set: set_fields]], store)
        when is_atom(queryable) and not is_nil(queryable) do
      schema_map = Map.get(store, queryable, %{})
      count = map_size(schema_map)

      updated_map =
        Map.new(schema_map, fn {id, record} ->
          updated =
            Enum.reduce(set_fields, record, fn {field, value}, acc ->
              Map.put(acc, field, value)
            end)

          {id, updated}
        end)

      new_store = Map.put(store, queryable, updated_map)
      {{count, nil}, new_store}
    end

    def dispatch(:update_all, [queryable, updates], store),
      do: dispatch_via_fallback(:update_all, [queryable, updates], store)

    def dispatch(:update_all, [queryable, updates, _opts], store),
      do: dispatch(:update_all, [queryable, updates], store)

    # -----------------------------------------------------------------
    # Transaction operations — delegate to Shared
    # -----------------------------------------------------------------

    def dispatch(:transact, args, store), do: InMemoryShared.dispatch_transact(args, store)
    def dispatch(:rollback, args, store), do: InMemoryShared.dispatch_rollback(args, store)

    # -----------------------------------------------------------------
    # Fallback dispatch (closed-world error messages)
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
        DoubleDown.Repo.InMemory cannot service :#{operation} with args #{inspect(args)}.

        InMemory can handle bare schema queryables authoritatively, but
        Ecto.Query queryables require a fallback function.

        Register a fallback:

        DoubleDown.Repo.InMemory.new(
          fallback_fn: fn
            :#{operation}, #{inspect(args)}, _state -> # your result here
          end
        )
        """,
        store
      )
    end

    # -----------------------------------------------------------------
    # Aggregate computation
    # -----------------------------------------------------------------

    defp compute_aggregate(records, :count, _field) do
      length(records)
    end

    defp compute_aggregate(records, aggregate, field)
         when aggregate in [:sum, :avg, :min, :max] do
      values =
        records
        |> Enum.map(&Map.get(&1, field))
        |> Enum.reject(&is_nil/1)

      case values do
        [] ->
          nil

        values ->
          case aggregate do
            :sum -> Enum.sum(values)
            :avg -> Enum.sum(values) / length(values)
            :min -> Enum.min(values)
            :max -> Enum.max(values)
          end
      end
    end

    # -----------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------

    defp entry_to_keyword(entry) when is_map(entry), do: Map.to_list(entry)
    defp entry_to_keyword(entry) when is_list(entry), do: entry
  end
end
