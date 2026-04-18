if Code.ensure_loaded?(Ecto) do
  defmodule DoubleDown.Repo.ClosedInMemory do
    @behaviour DoubleDown.Dispatch.FakeHandler

    @moduledoc """
    Stateful in-memory Repo implementation for tests (closed-world).

    Like `DoubleDown.Repo.InMemory`, provides a stateful handler for
    `DoubleDown.Repo` operations with state keyed by
    `schema_module => %{primary_key => struct}`. The difference is the
    **closed-world assumption**: the state is the complete truth. If a
    record is not in the state, it doesn't exist.

    This makes the adapter authoritative for a much larger subset of
    operations than `Repo.InMemory`:

    - **Writes:** `insert`, `update`, `delete` — same as InMemory
    - **PK reads:** `get`/`get!` — `nil`/raise on miss (no fallback)
    - **Clause-based reads:** `get_by`/`get_by!` — scan and filter
    - **Collection reads:** `all`, `one`/`one!`, `exists?` — scan
    - **Aggregates:** `aggregate(:count/:sum/:avg/:min/:max, field)`
    - **Bulk writes:** `insert_all`, `delete_all`, `update_all`
      (bare schema with `set:` updates)
    - **Transactions:** `transact`, `rollback`

    The **fallback function** is only needed for operations with
    `Ecto.Query` queryables (containing `where`, `join`, `select`
    etc.) that cannot be evaluated against in-memory data without a
    query engine. For bare schema queryables, the adapter handles
    everything.

    ## When to use ClosedInMemory vs InMemory

    | Scenario | Use |
    |----------|-----|
    | State is the full truth, reads should work without fallback | `ClosedInMemory` |
    | State is partial, reads for missing records should hit a fallback | `InMemory` |
    | ExMachina factories writing to an in-memory store | `ClosedInMemory` |
    | Only need PK-based read-after-write | `InMemory` |

    ## Usage

        # Basic — closed-world, no fallback needed for bare schemas
        DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.ClosedInMemory)

        # With seed data
        DoubleDown.Double.fake(
          DoubleDown.Repo,
          DoubleDown.Repo.ClosedInMemory,
          [%User{id: 1, name: "Alice"}, %Post{id: 1, title: "Hello"}]
        )

        # With fallback for Ecto.Query operations
        DoubleDown.Double.fake(
          DoubleDown.Repo,
          DoubleDown.Repo.ClosedInMemory,
          [],
          fallback_fn: fn
            :all, [%Ecto.Query{} = _query], _state -> []
          end
        )

    ## ExMachina integration

        setup do
          DoubleDown.Double.fake(DoubleDown.Repo, DoubleDown.Repo.ClosedInMemory)
          insert(:user, name: "Alice", email: "alice@example.com")
          insert(:user, name: "Bob", email: "bob@example.com")
          :ok
        end

        test "lists all users" do
          users = MyApp.Repo.all(User)
          assert length(users) == 2
        end

        test "finds user by email" do
          assert %User{name: "Alice"} =
            MyApp.Repo.get_by(User, email: "alice@example.com")
        end

    ## Ecto.Query limitation

    Operations with `Ecto.Query` queryables fall through to the
    fallback function, or raise with a clear error. The adapter
    cannot evaluate `where`, `join`, `preload`, `select`, or other
    query expressions against in-memory data.

    ## See also

    - `DoubleDown.Repo.InMemory` — open-world variant where absence is
      inconclusive, requiring a fallback for most reads.
    """

    alias DoubleDown.Repo.InMemory.Shared

    @type store :: Shared.store()

    @doc """
    Create a new ClosedInMemory state map. Same API as `Repo.InMemory.new/2`.
    """
    @impl DoubleDown.Dispatch.FakeHandler
    @spec new(term(), keyword()) :: store()
    defdelegate new(seed \\ %{}, opts \\ []), to: Shared

    @doc """
    Convert a list of structs into the nested state map for seeding.
    """
    @spec seed(list(struct())) :: store()
    defdelegate seed(records), to: Shared

    @doc """
    Stateful handler function with closed-world semantics.

    Bare schema reads are authoritative — the state is the full truth.
    `Ecto.Query` reads fall through to the fallback function.
    """
    @impl DoubleDown.Dispatch.FakeHandler
    @spec dispatch(atom(), list(), store()) :: {term(), store()}

    # -----------------------------------------------------------------
    # Write operations — delegate to Shared
    # -----------------------------------------------------------------

    def dispatch(:insert, [changeset], store), do: Shared.dispatch_insert([changeset], store)
    def dispatch(:insert, [cs, _opts], store), do: Shared.dispatch_insert([cs], store)

    def dispatch(:update, [changeset], store), do: Shared.dispatch_update([changeset], store)
    def dispatch(:update, [cs, _opts], store), do: Shared.dispatch_update([cs], store)

    def dispatch(:delete, [record], store), do: Shared.dispatch_delete([record], store)
    def dispatch(:delete, [record, _opts], store), do: Shared.dispatch_delete([record], store)

    # -----------------------------------------------------------------
    # PK reads — closed-world: nil/raise on miss
    # -----------------------------------------------------------------

    def dispatch(:get, [queryable, id], store) do
      schema = Shared.extract_schema(queryable)
      {Shared.get_record(store, schema, id), store}
    end

    def dispatch(:get, [queryable, id, _opts], store),
      do: dispatch(:get, [queryable, id], store)

    def dispatch(:get!, [queryable, id], store) do
      schema = Shared.extract_schema(queryable)

      case Shared.get_record(store, schema, id) do
        nil ->
          Shared.defer_raise(
            "expected #{inspect(schema)} with id #{inspect(id)} to exist in " <>
              "ClosedInMemory store, but it was not found",
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
      clauses_kw = Shared.normalize_clauses(clauses)
      records = Shared.records_for_schema(store, queryable)
      matching = Enum.filter(records, &Shared.fields_match?(&1, clauses_kw))
      {List.first(matching), store}
    end

    def dispatch(:get_by, [queryable, clauses], store),
      do: dispatch_via_fallback(:get_by, [queryable, clauses], store)

    def dispatch(:get_by, [queryable, clauses, _opts], store),
      do: dispatch(:get_by, [queryable, clauses], store)

    def dispatch(:get_by!, [queryable, clauses], store)
        when is_atom(queryable) and not is_nil(queryable) do
      clauses_kw = Shared.normalize_clauses(clauses)
      records = Shared.records_for_schema(store, queryable)
      matching = Enum.filter(records, &Shared.fields_match?(&1, clauses_kw))

      case matching do
        [record] ->
          {record, store}

        [] ->
          Shared.defer_raise(
            "expected #{inspect(queryable)} matching #{inspect(clauses)} to exist in " <>
              "ClosedInMemory store, but no matching record was found",
            store
          )

        _multiple ->
          Shared.defer_raise(
            "expected at most one #{inspect(queryable)} matching #{inspect(clauses)}, " <>
              "but found #{length(matching)} records in ClosedInMemory store",
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
      {Shared.records_for_schema(store, queryable), store}
    end

    def dispatch(:all, [queryable], store),
      do: dispatch_via_fallback(:all, [queryable], store)

    def dispatch(:all, [queryable, _opts], store),
      do: dispatch(:all, [queryable], store)

    def dispatch(:one, [queryable], store)
        when is_atom(queryable) and not is_nil(queryable) do
      records = Shared.records_for_schema(store, queryable)

      case records do
        [] ->
          {nil, store}

        [record] ->
          {record, store}

        _multiple ->
          Shared.defer_raise(
            "expected at most one #{inspect(queryable)} in ClosedInMemory store, " <>
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
      records = Shared.records_for_schema(store, queryable)

      case records do
        [record] ->
          {record, store}

        [] ->
          Shared.defer_raise(
            "expected exactly one #{inspect(queryable)} in ClosedInMemory store, " <>
              "but found none",
            store
          )

        _multiple ->
          Shared.defer_raise(
            "expected exactly one #{inspect(queryable)} in ClosedInMemory store, " <>
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
      {Shared.records_for_schema(store, queryable) != [], store}
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
      records = Shared.records_for_schema(store, queryable)
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

          case DoubleDown.Repo.Autogenerate.maybe_autogenerate_id(record, schema, fn s ->
                 st
                 |> Shared.records_for_schema(s)
                 |> Enum.map(&DoubleDown.Repo.Autogenerate.get_primary_key/1)
                 |> Enum.filter(&is_integer/1)
               end) do
            {:error, {:no_autogenerate, _message}} ->
              id = DoubleDown.Repo.Autogenerate.get_primary_key(record)
              {count + 1, [record | acc], Shared.put_record(st, schema, id, record)}

            {id, record} ->
              {count + 1, [record | acc], Shared.put_record(st, schema, id, record)}
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
      records = Shared.records_for_schema(store, queryable)
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

    def dispatch(:transact, args, store), do: Shared.dispatch_transact(args, store)
    def dispatch(:rollback, args, store), do: Shared.dispatch_rollback(args, store)

    # -----------------------------------------------------------------
    # Fallback dispatch (closed-world error messages)
    # -----------------------------------------------------------------

    defp dispatch_via_fallback(operation, args, store) do
      case Shared.try_fallback(store, operation, args) do
        {:no_fallback, ^operation, ^args} ->
          defer_raise_no_fallback(operation, args, store)

        result ->
          result
      end
    end

    defp defer_raise_no_fallback(operation, args, store) do
      Shared.defer_raise(
        """
        DoubleDown.Repo.ClosedInMemory cannot service :#{operation} with args #{inspect(args)}.

        ClosedInMemory can handle bare schema queryables authoritatively, but
        Ecto.Query queryables require a fallback function.

        Register a fallback:

        DoubleDown.Repo.ClosedInMemory.new(
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
