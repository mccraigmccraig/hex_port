if Code.ensure_loaded?(Ecto) do
  defmodule DoubleDown.Repo.Impl.InMemoryShared do
    @moduledoc false

    alias DoubleDown.Contract.Dispatch.Defer

    # Shared helpers for stateful in-memory Repo fakes.
    #
    # Used by both `Repo.OpenInMemory` (open-world: absence is inconclusive)
    # and `Repo.InMemory` (closed-world: absence means not found).
    #
    # Provides:
    # - State construction (new, seed, build_store)
    # - State access (get_record, put_record, delete_record, records_for_schema)
    # - Write operations (insert, update, delete)
    # - Transaction operations (transact, rollback)
    # - Opts-stripping dispatch
    # - Fallback dispatch (try_fallback, defer_raise)
    # - Query helpers (extract_schema, normalize_clauses, fields_match?,
    #   extract_pk_from_clauses)

    @type store :: %{optional(module()) => %{optional(term()) => struct()}}

    @fallback_fn_key :__fallback_fn__

    # -------------------------------------------------------------------
    # Store construction
    # -------------------------------------------------------------------

    @doc false
    def fallback_fn_key, do: @fallback_fn_key

    @doc false
    @spec new(term(), keyword()) :: store()
    def new(seed \\ %{}, opts \\ [])

    # Legacy keyword-only form: new(seed: [...], fallback_fn: fn ...)
    #
    # Disambiguation: when called with one non-empty list arg and no second
    # arg (opts defaults to []), we check if the list is a keyword list.
    # - Keyword list → legacy form: extract :seed and :fallback_fn keys
    # - Non-keyword list → positional form: treat as a list of seed structs
    #
    # This is unambiguous because seed structs are never {atom, value} tuples.
    def new(opts, []) when is_list(opts) and opts != [] do
      case Keyword.keyword?(opts) do
        true ->
          seed_records = Keyword.get(opts, :seed, [])
          fallback_fn = Keyword.get(opts, :fallback_fn, nil)
          build_store(seed_records, fallback_fn)

        false ->
          # It's a plain list of structs as seed
          build_store(opts, nil)
      end
    end

    # new(seed_list, opts)
    def new(seed, opts) when is_list(seed) do
      fallback_fn = Keyword.get(opts, :fallback_fn, nil)
      build_store(seed, fallback_fn)
    end

    # new(seed_map, opts)
    def new(seed, opts) when is_map(seed) do
      fallback_fn = Keyword.get(opts, :fallback_fn, nil)

      if fallback_fn do
        Map.put(seed, @fallback_fn_key, fallback_fn)
      else
        seed
      end
    end

    defp build_store(seed_records, fallback_fn) do
      store = seed(seed_records)

      if fallback_fn do
        Map.put(store, @fallback_fn_key, fallback_fn)
      else
        store
      end
    end

    @doc false
    @spec seed(list(struct())) :: store()
    def seed(records) when is_list(records) do
      Enum.reduce(records, %{}, fn record, store ->
        schema = record.__struct__
        id = DoubleDown.Repo.Impl.Autogenerate.get_primary_key(record)
        put_record(store, schema, id, record)
      end)
    end

    # -------------------------------------------------------------------
    # Write operations
    # -------------------------------------------------------------------

    @doc false
    def dispatch_insert([%Ecto.Changeset{valid?: false} = changeset], store) do
      {{:error, changeset}, store}
    end

    def dispatch_insert([%Ecto.Changeset{} = changeset], store) do
      do_insert(Ecto.Changeset.apply_changes(changeset), :insert, store)
    end

    def dispatch_insert([%{__struct__: _} = struct], store) do
      do_insert(struct, :insert, store)
    end

    # Public so it can be passed as a function reference to
    # EctoParity.backfill_foreign_keys for recursive parent insertion.
    @doc false
    def do_insert(record, action, store) do
      alias DoubleDown.Repo.Impl.Autogenerate
      alias DoubleDown.Repo.Impl.EctoParity

      {record, store} =
        EctoParity.backfill_foreign_keys(record, store, &do_insert/3)

      record =
        record
        |> EctoParity.reset_associations()
        |> Autogenerate.apply_timestamps(action)

      schema = record.__struct__

      case Autogenerate.maybe_autogenerate_id(record, schema, fn s ->
             store
             |> records_for_schema(s)
             |> Enum.map(&Autogenerate.get_primary_key/1)
             |> Enum.filter(&is_integer/1)
           end) do
        {:error, {:no_autogenerate, message}} ->
          {Defer.new(fn -> raise ArgumentError, message end), store}

        {id, record} ->
          record = Ecto.put_meta(record, state: :loaded)
          {{:ok, record}, put_record(store, schema, id, record)}
      end
    end

    @doc false
    def dispatch_update([%Ecto.Changeset{valid?: false} = changeset], store) do
      {{:error, changeset}, store}
    end

    def dispatch_update([changeset], store) do
      record = DoubleDown.Repo.Impl.Autogenerate.apply_changes(changeset, :update)
      record = Ecto.put_meta(record, state: :loaded)
      schema = record.__struct__
      id = DoubleDown.Repo.Impl.Autogenerate.get_primary_key(record)
      {{:ok, record}, put_record(store, schema, id, record)}
    end

    @doc false
    def dispatch_delete([%Ecto.Changeset{valid?: false} = changeset], store) do
      {{:error, changeset}, store}
    end

    def dispatch_delete([%Ecto.Changeset{} = changeset], store) do
      record = Ecto.Changeset.apply_changes(changeset)
      schema = record.__struct__

      key =
        if no_primary_key?(schema),
          do: record,
          else: DoubleDown.Repo.Impl.Autogenerate.get_primary_key(record)

      {{:ok, record}, delete_record(store, schema, key)}
    end

    def dispatch_delete([record], store) do
      schema = record.__struct__

      key =
        if no_primary_key?(schema),
          do: record,
          else: DoubleDown.Repo.Impl.Autogenerate.get_primary_key(record)

      {{:ok, record}, delete_record(store, schema, key)}
    end

    # -------------------------------------------------------------------
    # Bang write operations
    # -------------------------------------------------------------------

    @doc false
    def dispatch_insert!(args, store) do
      case dispatch_insert(args, store) do
        {{:ok, record}, new_store} -> {record, new_store}
        {{:error, changeset}, store} -> bang_raise(:insert!, changeset, store)
      end
    end

    @doc false
    def dispatch_update!(args, store) do
      case dispatch_update(args, store) do
        {{:ok, record}, new_store} -> {record, new_store}
        {{:error, changeset}, store} -> bang_raise(:update!, changeset, store)
      end
    end

    @doc false
    def dispatch_delete!(args, store) do
      case dispatch_delete(args, store) do
        {{:ok, record}, new_store} -> {record, new_store}
        {{:error, changeset}, store} -> bang_raise(:delete!, changeset, store)
      end
    end

    # -------------------------------------------------------------------
    # Insert-or-update operations
    # -------------------------------------------------------------------

    @doc false
    def dispatch_insert_or_update([%Ecto.Changeset{} = changeset], store) do
      if Ecto.get_meta(changeset.data, :state) == :loaded do
        dispatch_update([changeset], store)
      else
        dispatch_insert([changeset], store)
      end
    end

    @doc false
    def dispatch_insert_or_update!(args, store) do
      case dispatch_insert_or_update(args, store) do
        {{:ok, record}, new_store} -> {record, new_store}
        {{:error, changeset}, store} -> bang_raise(:insert_or_update!, changeset, store)
      end
    end

    # -------------------------------------------------------------------
    # Reload operations
    # -------------------------------------------------------------------

    @doc false
    def dispatch_reload([structs], store) when is_list(structs) do
      results =
        Enum.map(structs, fn struct ->
          schema = struct.__struct__
          id = DoubleDown.Repo.Impl.Autogenerate.get_primary_key(struct)
          get_record(store, schema, id)
        end)

      {results, store}
    end

    def dispatch_reload([struct], store) do
      schema = struct.__struct__
      id = DoubleDown.Repo.Impl.Autogenerate.get_primary_key(struct)
      {get_record(store, schema, id), store}
    end

    @doc false
    def dispatch_reload!([structs], store) when is_list(structs) do
      results =
        Enum.map(structs, fn struct ->
          schema = struct.__struct__
          id = DoubleDown.Repo.Impl.Autogenerate.get_primary_key(struct)

          case get_record(store, schema, id) do
            nil -> :reload_failed
            record -> record
          end
        end)

      case Enum.find(results, &(&1 == :reload_failed)) do
        nil ->
          {results, store}

        _ ->
          failed_index = Enum.find_index(results, &(&1 == :reload_failed))
          failed_struct = Enum.at(structs, failed_index)

          {Defer.new(fn ->
             raise RuntimeError,
                   "could not reload #{inspect(failed_struct)}, maybe it doesn't exist or was deleted"
           end), store}
      end
    end

    def dispatch_reload!([struct], store) do
      schema = struct.__struct__
      id = DoubleDown.Repo.Impl.Autogenerate.get_primary_key(struct)

      case get_record(store, schema, id) do
        nil ->
          {Defer.new(fn ->
             raise RuntimeError,
                   "could not reload #{inspect(struct)}, maybe it doesn't exist or was deleted"
           end), store}

        record ->
          {record, store}
      end
    end

    # -------------------------------------------------------------------
    # Load operation (stateless)
    # -------------------------------------------------------------------

    @doc false
    def dispatch_load([schema_or_map, data], store) do
      loader = fn _type, value -> {:ok, value} end

      loaded =
        case data do
          data when is_list(data) ->
            do_load(schema_or_map, Map.new(data), loader)

          {fields, values} when is_list(fields) and is_list(values) ->
            do_load(schema_or_map, Map.new(Enum.zip(fields, values)), loader)

          data when is_map(data) ->
            do_load(schema_or_map, data, loader)
        end

      {loaded, store}
    end

    defp do_load(schema, data, loader) when is_atom(schema) do
      Ecto.Schema.Loader.unsafe_load(schema, data, loader)
    end

    defp do_load(types, data, loader) when is_map(types) do
      Ecto.Schema.Loader.unsafe_load(%{}, types, data, loader)
    end

    defp bang_raise(action, %Ecto.Changeset{} = changeset, store) do
      {Defer.new(fn ->
         raise Ecto.InvalidChangesetError, action: action, changeset: changeset
       end), store}
    end

    # -------------------------------------------------------------------
    # Transaction operations
    # -------------------------------------------------------------------

    @doc false
    def dispatch_transact(args, store, contract) do
      do_dispatch_transact(normalise_transact_args(args, contract), store, contract)
    end

    defp do_dispatch_transact([fun, _opts], store, contract) when is_function(fun, 0) do
      snapshot = store

      {Defer.new(fn -> run_in_transaction(fun, contract, snapshot) end), store}
    end

    defp do_dispatch_transact([%Ecto.Multi{} = multi, opts], store, contract) do
      repo_facade = Keyword.get(opts, DoubleDown.Repo.Facade)
      snapshot = store

      {Defer.new(fn ->
         run_in_transaction(
           fn -> DoubleDown.Repo.Impl.MultiStepper.run(multi, repo_facade) end,
           contract,
           snapshot
         )
       end), store}
    end

    # Normalise transaction args for DynamicFacade compatibility.
    # ContractFacade's pre_dispatch handles these transforms, but
    # DynamicFacade bypasses pre_dispatch entirely.
    defp normalise_transact_args([fun], contract) when is_function(fun, 1) do
      [fn -> fun.(contract) end, []]
    end

    defp normalise_transact_args([fun], _contract) when is_function(fun, 0) do
      [fun, []]
    end

    defp normalise_transact_args([%Ecto.Multi{} = multi], _contract) do
      [multi, []]
    end

    defp normalise_transact_args([fun, opts], contract)
         when is_function(fun, 1) and is_list(opts) do
      [fn -> fun.(contract) end, opts]
    end

    defp normalise_transact_args([fun, opts], _contract)
         when is_function(fun, 0) and is_list(opts) do
      [fun, opts]
    end

    defp normalise_transact_args([%Ecto.Multi{} = multi, opts], _contract) when is_list(opts) do
      [multi, opts]
    end

    @transaction_key DoubleDown.Repo.InTransaction

    @doc false
    def dispatch_in_transaction?(store) do
      {Defer.new(fn -> Process.get(@transaction_key, false) end), store}
    end

    @doc false
    def dispatch_rollback([value], store) do
      {Defer.new(fn ->
         if Process.get(@transaction_key, false) do
           throw({:rollback, value})
         else
           raise RuntimeError,
                 "cannot call rollback outside of transaction"
         end
       end), store}
    end

    defp run_in_transaction(fun, contract, snapshot) do
      prev = Process.get(@transaction_key, false)
      Process.put(@transaction_key, true)

      try do
        result = fun.()

        case result do
          {:ok, _} ->
            result

          {:error, _} ->
            do_restore_state(contract, snapshot)
            result

          {:error, _name, _value, _changes} ->
            do_restore_state(contract, snapshot)
            result

          _other ->
            # Non-standard return (e.g. bare value) — treat as success,
            # matching Ecto.Repo.transaction/2 which returns {:ok, result}
            # for non-tagged returns.
            {:ok, result}
        end
      rescue
        exception ->
          do_restore_state(contract, snapshot)
          reraise exception, __STACKTRACE__
      catch
        {:rollback, value} ->
          do_restore_state(contract, snapshot)
          {:error, value}
      after
        Process.put(@transaction_key, prev)
      end
    end

    defp do_restore_state(contract, snapshot) do
      {:ok, owner_pid, _handler} =
        DoubleDown.Contract.Dispatch.resolve_test_handler(contract)

      DoubleDown.Contract.Dispatch.restore_state(contract, owner_pid, snapshot)
    end

    # -------------------------------------------------------------------
    # Fallback dispatch
    #
    # Because dispatch/4 runs inside NimbleOwnership.get_and_update
    # (a GenServer call), we must not raise here — that would crash
    # the ownership server. Instead, we use %DoubleDown.Contract.Dispatch.Defer{}
    # to move the raise outside the lock.
    # -------------------------------------------------------------------

    @doc false
    def try_fallback(store, contract, operation, args) do
      case Map.get(store, @fallback_fn_key) do
        nil ->
          {:no_fallback, operation, args}

        fallback_fn when is_function(fallback_fn, 4) ->
          clean_state = Map.delete(store, @fallback_fn_key)

          try do
            {fallback_fn.(contract, operation, args, clean_state), store}
          rescue
            # FunctionClauseError means no matching clause — treat as missing fallback.
            FunctionClauseError ->
              {:no_fallback, operation, args}

            # Any other exception from user-supplied fallback code must not crash
            # the NimbleOwnership GenServer. Capture the exception and stacktrace,
            # then defer the reraise to the calling test process.
            exception ->
              stacktrace = __STACKTRACE__

              {Defer.new(fn -> reraise exception, stacktrace end), store}
          end
      end
    end

    @doc false
    def defer_raise(message, store) do
      {Defer.new(fn -> raise ArgumentError, message end), store}
    end

    @doc false
    def defer_raise_no_results(queryable, store) do
      {Defer.new(fn -> raise Ecto.NoResultsError, queryable: queryable end), store}
    end

    @doc false
    def defer_raise_multiple_results(queryable, count, store) do
      {Defer.new(fn -> raise Ecto.MultipleResultsError, queryable: queryable, count: count end),
       store}
    end

    # -------------------------------------------------------------------
    # State access helpers
    #
    # Schemas with a primary key are stored as %{pk => record} maps.
    # Schemas with @primary_key false are stored as [record] lists
    # (reverse insertion order — newest first).
    # -------------------------------------------------------------------

    @doc false
    def no_primary_key?(schema) do
      function_exported?(schema, :__schema__, 1) and
        schema.__schema__(:primary_key) == []
    end

    @doc false
    def get_record(store, schema, id) do
      case Map.get(store, schema) do
        nil -> nil
        records when is_list(records) -> nil
        schema_map when is_map(schema_map) -> Map.get(schema_map, id)
      end
    end

    @doc false
    def put_record(store, schema, id, record) do
      if no_primary_key?(schema) do
        records = Map.get(store, schema, [])
        Map.put(store, schema, [record | records])
      else
        schema_map = Map.get(store, schema, %{})
        Map.put(store, schema, Map.put(schema_map, id, record))
      end
    end

    @doc false
    def delete_record(store, schema, record_or_id) do
      case Map.get(store, schema) do
        nil ->
          store

        records when is_list(records) ->
          Map.put(store, schema, List.delete(records, record_or_id))

        schema_map when is_map(schema_map) ->
          Map.put(store, schema, Map.delete(schema_map, record_or_id))
      end
    end

    @doc false
    def records_for_schema(store, schema) do
      case Map.get(store, schema) do
        nil -> []
        records when is_list(records) -> records
        schema_map when is_map(schema_map) -> Map.values(schema_map)
      end
    end

    # -------------------------------------------------------------------
    # Query helpers
    # -------------------------------------------------------------------

    @doc false
    def extract_schema(queryable) when is_atom(queryable), do: queryable

    def extract_schema(%Ecto.Query{from: %Ecto.Query.FromExpr{source: {_table, schema}}})
        when is_atom(schema) and not is_nil(schema) do
      schema
    end

    def extract_schema(queryable), do: queryable

    @doc false
    def normalize_clauses(clauses) when is_map(clauses), do: Enum.to_list(clauses)
    def normalize_clauses(clauses) when is_list(clauses), do: clauses

    @doc false
    def fields_match?(_record, []), do: true

    def fields_match?(record, clauses) do
      Enum.all?(clauses, fn {field, value} ->
        Map.get(record, field) == value
      end)
    end

    @doc false
    def extract_pk_from_clauses(schema, clauses_kw) do
      if function_exported?(schema, :__schema__, 1) do
        case schema.__schema__(:primary_key) do
          [] ->
            :not_pk_inclusive

          [pk_field] ->
            case Keyword.fetch(clauses_kw, pk_field) do
              {:ok, pk_value} ->
                remaining = Keyword.delete(clauses_kw, pk_field)
                {:ok, pk_value, remaining}

              :error ->
                :not_pk_inclusive
            end

          pk_fields when is_list(pk_fields) ->
            pk_values = Enum.map(pk_fields, &Keyword.fetch(clauses_kw, &1))

            if Enum.all?(pk_values, &match?({:ok, _}, &1)) do
              pk_value = pk_values |> Enum.map(fn {:ok, v} -> v end) |> List.to_tuple()
              remaining = Enum.reject(clauses_kw, fn {k, _v} -> k in pk_fields end)
              {:ok, pk_value, remaining}
            else
              :not_pk_inclusive
            end
        end
      else
        :not_pk_inclusive
      end
    end
  end
end
