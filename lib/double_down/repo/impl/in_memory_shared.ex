if Code.ensure_loaded?(Ecto) do
  defmodule DoubleDown.Repo.Impl.InMemoryShared do
    @moduledoc false

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

    defp do_insert(record, action, store) do
      alias DoubleDown.Repo.Impl.Autogenerate

      record = Autogenerate.apply_timestamps(record, action)
      schema = record.__struct__

      case Autogenerate.maybe_autogenerate_id(record, schema, fn s ->
             store
             |> records_for_schema(s)
             |> Enum.map(&Autogenerate.get_primary_key/1)
             |> Enum.filter(&is_integer/1)
           end) do
        {:error, {:no_autogenerate, message}} ->
          {%DoubleDown.Contract.Dispatch.Defer{fn: fn -> raise ArgumentError, message end}, store}

        {id, record} ->
          {{:ok, record}, put_record(store, schema, id, record)}
      end
    end

    @doc false
    def dispatch_update([%Ecto.Changeset{valid?: false} = changeset], store) do
      {{:error, changeset}, store}
    end

    def dispatch_update([changeset], store) do
      record = DoubleDown.Repo.Impl.Autogenerate.apply_changes(changeset, :update)
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
      id = DoubleDown.Repo.Impl.Autogenerate.get_primary_key(record)
      {{:ok, record}, delete_record(store, schema, id)}
    end

    def dispatch_delete([record], store) do
      schema = record.__struct__
      id = DoubleDown.Repo.Impl.Autogenerate.get_primary_key(record)
      {{:ok, record}, delete_record(store, schema, id)}
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
      {{:ok, record}, new_store} = dispatch_delete(args, store)
      {record, new_store}
    end

    defp bang_raise(action, %Ecto.Changeset{} = changeset, store) do
      {%DoubleDown.Contract.Dispatch.Defer{
         fn: fn ->
           raise Ecto.InvalidChangesetError, action: action, changeset: changeset
         end
       }, store}
    end

    # -------------------------------------------------------------------
    # Transaction operations
    # -------------------------------------------------------------------

    @doc false
    def dispatch_transact([fun, _opts], store, contract) when is_function(fun, 0) do
      snapshot = store

      {%DoubleDown.Contract.Dispatch.Defer{
         fn: fn -> run_in_transaction(fun, contract, snapshot) end
       }, store}
    end

    def dispatch_transact([%Ecto.Multi{} = multi, opts], store, contract) do
      repo_facade = Keyword.get(opts, DoubleDown.Repo.Facade)
      snapshot = store

      {%DoubleDown.Contract.Dispatch.Defer{
         fn: fn ->
           run_in_transaction(
             fn -> DoubleDown.Repo.Impl.MultiStepper.run(multi, repo_facade) end,
             contract,
             snapshot
           )
         end
       }, store}
    end

    @doc false
    def dispatch_rollback([value], store) do
      {%DoubleDown.Contract.Dispatch.Defer{fn: fn -> throw({:rollback, value}) end}, store}
    end

    defp run_in_transaction(fun, contract, snapshot) do
      fun.()
    catch
      {:rollback, value} ->
        DoubleDown.Contract.Dispatch.restore_state(contract, snapshot)
        {:error, value}
    end

    # -------------------------------------------------------------------
    # Fallback dispatch
    #
    # Because dispatch/3 runs inside NimbleOwnership.get_and_update
    # (a GenServer call), we must not raise here — that would crash
    # the ownership server. Instead, we use %DoubleDown.Contract.Dispatch.Defer{}
    # to move the raise outside the lock.
    # -------------------------------------------------------------------

    @doc false
    def try_fallback(store, operation, args) do
      case Map.get(store, @fallback_fn_key) do
        nil ->
          {:no_fallback, operation, args}

        fallback_fn when is_function(fallback_fn, 3) ->
          clean_state = Map.delete(store, @fallback_fn_key)

          try do
            {fallback_fn.(operation, args, clean_state), store}
          rescue
            # FunctionClauseError means no matching clause — treat as missing fallback.
            FunctionClauseError ->
              {:no_fallback, operation, args}

            # Any other exception from user-supplied fallback code must not crash
            # the NimbleOwnership GenServer. Capture the exception and stacktrace,
            # then defer the reraise to the calling test process.
            exception ->
              stacktrace = __STACKTRACE__

              {%DoubleDown.Contract.Dispatch.Defer{fn: fn -> reraise exception, stacktrace end},
               store}
          end
      end
    end

    @doc false
    def defer_raise(message, store) do
      {%DoubleDown.Contract.Dispatch.Defer{fn: fn -> raise ArgumentError, message end}, store}
    end

    @doc false
    def defer_raise_no_results(queryable, store) do
      {%DoubleDown.Contract.Dispatch.Defer{
         fn: fn -> raise Ecto.NoResultsError, queryable: queryable end
       }, store}
    end

    @doc false
    def defer_raise_multiple_results(queryable, count, store) do
      {%DoubleDown.Contract.Dispatch.Defer{
         fn: fn -> raise Ecto.MultipleResultsError, queryable: queryable, count: count end
       }, store}
    end

    # -------------------------------------------------------------------
    # State access helpers
    # -------------------------------------------------------------------

    @doc false
    def get_record(store, schema, id) do
      store
      |> Map.get(schema, %{})
      |> Map.get(id)
    end

    @doc false
    def put_record(store, schema, id, record) do
      schema_map = Map.get(store, schema, %{})
      Map.put(store, schema, Map.put(schema_map, id, record))
    end

    @doc false
    def delete_record(store, schema, id) do
      case Map.get(store, schema) do
        nil -> store
        schema_map -> Map.put(store, schema, Map.delete(schema_map, id))
      end
    end

    @doc false
    def records_for_schema(store, schema) do
      store
      |> Map.get(schema, %{})
      |> Map.values()
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
