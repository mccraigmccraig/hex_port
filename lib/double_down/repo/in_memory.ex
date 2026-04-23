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
            _contract, :all, [%Ecto.Query{}], _state -> []
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
    @spec dispatch(module(), atom(), list(), store()) :: {term(), store()}

    # -----------------------------------------------------------------
    # Write operations — delegate to Shared
    # -----------------------------------------------------------------

    def dispatch(_contract, :insert, [changeset], store),
      do: InMemoryShared.dispatch_insert([changeset], store)

    def dispatch(_contract, :insert, [cs, _opts], store),
      do: InMemoryShared.dispatch_insert([cs], store)

    def dispatch(_contract, :update, [changeset], store),
      do: InMemoryShared.dispatch_update([changeset], store)

    def dispatch(_contract, :update, [cs, _opts], store),
      do: InMemoryShared.dispatch_update([cs], store)

    def dispatch(_contract, :delete, [record], store),
      do: InMemoryShared.dispatch_delete([record], store)

    def dispatch(_contract, :delete, [record, _opts], store),
      do: InMemoryShared.dispatch_delete([record], store)

    def dispatch(_contract, :insert_or_update, [changeset], store),
      do: InMemoryShared.dispatch_insert_or_update([changeset], store)

    def dispatch(_contract, :insert_or_update, [cs, _opts], store),
      do: InMemoryShared.dispatch_insert_or_update([cs], store)

    def dispatch(_contract, :insert_or_update!, [changeset], store),
      do: InMemoryShared.dispatch_insert_or_update!([changeset], store)

    def dispatch(_contract, :insert_or_update!, [cs, _opts], store),
      do: InMemoryShared.dispatch_insert_or_update!([cs], store)

    def dispatch(_contract, :insert!, [changeset], store),
      do: InMemoryShared.dispatch_insert!([changeset], store)

    def dispatch(_contract, :insert!, [cs, _opts], store),
      do: InMemoryShared.dispatch_insert!([cs], store)

    def dispatch(_contract, :update!, [changeset], store),
      do: InMemoryShared.dispatch_update!([changeset], store)

    def dispatch(_contract, :update!, [cs, _opts], store),
      do: InMemoryShared.dispatch_update!([cs], store)

    def dispatch(_contract, :delete!, [record], store),
      do: InMemoryShared.dispatch_delete!([record], store)

    def dispatch(_contract, :delete!, [record, _opts], store),
      do: InMemoryShared.dispatch_delete!([record], store)

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
    # Reload — closed-world
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
    # PK reads — closed-world: nil/raise on miss
    # -----------------------------------------------------------------

    def dispatch(_contract, :get, [queryable, id], store) do
      schema = InMemoryShared.extract_schema(queryable)
      {InMemoryShared.get_record(store, schema, id), store}
    end

    def dispatch(contract, :get, [queryable, id, _opts], store),
      do: dispatch(contract, :get, [queryable, id], store)

    def dispatch(_contract, :get!, [queryable, id], store) do
      schema = InMemoryShared.extract_schema(queryable)

      case InMemoryShared.get_record(store, schema, id) do
        nil ->
          InMemoryShared.defer_raise_no_results(queryable, store)

        record ->
          {record, store}
      end
    end

    def dispatch(contract, :get!, [queryable, id, _opts], store),
      do: dispatch(contract, :get!, [queryable, id], store)

    # -----------------------------------------------------------------
    # get_by / get_by! — scan and filter (closed-world, bare schema)
    # -----------------------------------------------------------------

    def dispatch(_contract, :get_by, [queryable, clauses], store)
        when is_atom(queryable) and not is_nil(queryable) do
      clauses_kw = InMemoryShared.normalize_clauses(clauses)
      records = InMemoryShared.records_for_schema(store, queryable)
      matching = Enum.filter(records, &InMemoryShared.fields_match?(&1, clauses_kw))
      {List.first(matching), store}
    end

    def dispatch(contract, :get_by, [queryable, clauses], store),
      do: dispatch_via_fallback(contract, :get_by, [queryable, clauses], store)

    def dispatch(contract, :get_by, [queryable, clauses, _opts], store),
      do: dispatch(contract, :get_by, [queryable, clauses], store)

    def dispatch(_contract, :get_by!, [queryable, clauses], store)
        when is_atom(queryable) and not is_nil(queryable) do
      clauses_kw = InMemoryShared.normalize_clauses(clauses)
      records = InMemoryShared.records_for_schema(store, queryable)
      matching = Enum.filter(records, &InMemoryShared.fields_match?(&1, clauses_kw))

      case matching do
        [record] ->
          {record, store}

        [] ->
          InMemoryShared.defer_raise_no_results(queryable, store)

        _multiple ->
          InMemoryShared.defer_raise_multiple_results(queryable, length(matching), store)
      end
    end

    def dispatch(contract, :get_by!, [queryable, clauses], store),
      do: dispatch_via_fallback(contract, :get_by!, [queryable, clauses], store)

    def dispatch(contract, :get_by!, [queryable, clauses, _opts], store),
      do: dispatch(contract, :get_by!, [queryable, clauses], store)

    # -----------------------------------------------------------------
    # all_by — scan and filter, return all matches (closed-world)
    # -----------------------------------------------------------------

    def dispatch(_contract, :all_by, [queryable, clauses], store)
        when is_atom(queryable) and not is_nil(queryable) do
      clauses_kw = InMemoryShared.normalize_clauses(clauses)
      records = InMemoryShared.records_for_schema(store, queryable)
      matching = Enum.filter(records, &InMemoryShared.fields_match?(&1, clauses_kw))
      {matching, store}
    end

    def dispatch(contract, :all_by, [queryable, clauses], store),
      do: dispatch_via_fallback(contract, :all_by, [queryable, clauses], store)

    def dispatch(contract, :all_by, [queryable, clauses, _opts], store),
      do: dispatch(contract, :all_by, [queryable, clauses], store)

    # -----------------------------------------------------------------
    # Collection reads — scan (closed-world, bare schema)
    # -----------------------------------------------------------------

    def dispatch(_contract, :all, [queryable], store)
        when is_atom(queryable) and not is_nil(queryable) do
      {InMemoryShared.records_for_schema(store, queryable), store}
    end

    def dispatch(contract, :all, [queryable], store),
      do: dispatch_via_fallback(contract, :all, [queryable], store)

    def dispatch(contract, :all, [queryable, _opts], store),
      do: dispatch(contract, :all, [queryable], store)

    def dispatch(_contract, :one, [queryable], store)
        when is_atom(queryable) and not is_nil(queryable) do
      records = InMemoryShared.records_for_schema(store, queryable)

      case records do
        [] ->
          {nil, store}

        [record] ->
          {record, store}

        _multiple ->
          InMemoryShared.defer_raise_multiple_results(queryable, length(records), store)
      end
    end

    def dispatch(contract, :one, [queryable], store),
      do: dispatch_via_fallback(contract, :one, [queryable], store)

    def dispatch(contract, :one, [queryable, _opts], store),
      do: dispatch(contract, :one, [queryable], store)

    def dispatch(_contract, :one!, [queryable], store)
        when is_atom(queryable) and not is_nil(queryable) do
      records = InMemoryShared.records_for_schema(store, queryable)

      case records do
        [record] ->
          {record, store}

        [] ->
          InMemoryShared.defer_raise_no_results(queryable, store)

        _multiple ->
          InMemoryShared.defer_raise_multiple_results(queryable, length(records), store)
      end
    end

    def dispatch(contract, :one!, [queryable], store),
      do: dispatch_via_fallback(contract, :one!, [queryable], store)

    def dispatch(contract, :one!, [queryable, _opts], store),
      do: dispatch(contract, :one!, [queryable], store)

    def dispatch(_contract, :exists?, [queryable], store)
        when is_atom(queryable) and not is_nil(queryable) do
      {InMemoryShared.records_for_schema(store, queryable) != [], store}
    end

    def dispatch(contract, :exists?, [queryable], store),
      do: dispatch_via_fallback(contract, :exists?, [queryable], store)

    def dispatch(contract, :exists?, [queryable, _opts], store),
      do: dispatch(contract, :exists?, [queryable], store)

    # -----------------------------------------------------------------
    # Aggregates — compute from state (closed-world, bare schema)
    # -----------------------------------------------------------------

    def dispatch(_contract, :aggregate, [queryable, aggregate, field], store)
        when is_atom(queryable) and not is_nil(queryable) do
      records = InMemoryShared.records_for_schema(store, queryable)
      {compute_aggregate(records, aggregate, field), store}
    end

    def dispatch(contract, :aggregate, [queryable, aggregate, field], store),
      do: dispatch_via_fallback(contract, :aggregate, [queryable, aggregate, field], store)

    def dispatch(contract, :aggregate, [queryable, aggregate, field, _opts], store),
      do: dispatch(contract, :aggregate, [queryable, aggregate, field], store)

    # -----------------------------------------------------------------
    # Bulk writes (closed-world, bare schema)
    # -----------------------------------------------------------------

    def dispatch(_contract, :insert_all, [source, entries, opts], store)
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
            {:error, {:no_autogenerate, message}} ->
              raise ArgumentError, message

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

    def dispatch(contract, :insert_all, args, store),
      do: dispatch_via_fallback(contract, :insert_all, args, store)

    def dispatch(_contract, :delete_all, [queryable], store)
        when is_atom(queryable) and not is_nil(queryable) do
      records = InMemoryShared.records_for_schema(store, queryable)
      count = length(records)
      new_store = Map.delete(store, queryable)
      {{count, nil}, new_store}
    end

    def dispatch(contract, :delete_all, [queryable], store),
      do: dispatch_via_fallback(contract, :delete_all, [queryable], store)

    def dispatch(contract, :delete_all, [queryable, _opts], store),
      do: dispatch(contract, :delete_all, [queryable], store)

    def dispatch(_contract, :update_all, [queryable, [set: set_fields]], store)
        when is_atom(queryable) and not is_nil(queryable) do
      apply_set_fields = fn record ->
        Enum.reduce(set_fields, record, fn {field, value}, acc ->
          Map.put(acc, field, value)
        end)
      end

      case Map.get(store, queryable) do
        nil ->
          {{0, nil}, store}

        records when is_list(records) ->
          updated = Enum.map(records, apply_set_fields)
          {{length(records), nil}, Map.put(store, queryable, updated)}

        schema_map when is_map(schema_map) ->
          updated_map =
            Map.new(schema_map, fn {id, record} -> {id, apply_set_fields.(record)} end)

          {{map_size(schema_map), nil}, Map.put(store, queryable, updated_map)}
      end
    end

    def dispatch(contract, :update_all, [queryable, updates], store),
      do: dispatch_via_fallback(contract, :update_all, [queryable, updates], store)

    def dispatch(contract, :update_all, [queryable, updates, _opts], store),
      do: dispatch(contract, :update_all, [queryable, updates], store)

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
    # Fallback dispatch (closed-world error messages)
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
        DoubleDown.Repo.InMemory cannot service :#{operation} with args #{inspect(args)}.

        InMemory can handle bare schema queryables authoritatively, but
        Ecto.Query queryables require a fallback function.

        Register a fallback:

        DoubleDown.Repo.InMemory.new(
          fallback_fn: fn
            _contract, :#{operation}, #{inspect(args)}, _state -> # your result here
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
