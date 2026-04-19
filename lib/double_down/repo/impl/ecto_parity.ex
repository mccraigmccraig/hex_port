if Code.ensure_loaded?(Ecto) do
  defmodule DoubleDown.Repo.Impl.EctoParity do
    @moduledoc false

    # Functions that make the in-memory Repo fakes behave more like
    # real Ecto.Repo by inspecting Ecto schema metadata.
    #
    # Kept separate from InMemoryShared (which handles store mechanics)
    # so schema-introspection concerns are isolated and reusable.

    # -------------------------------------------------------------------
    # FK backfill
    # -------------------------------------------------------------------

    @doc false
    @spec backfill_foreign_keys(struct(), term(), (struct(), atom(), term() -> term())) ::
            {struct(), term()}
    def backfill_foreign_keys(%{__struct__: schema} = record, store, insert_fn) do
      if function_exported?(schema, :__schema__, 1) do
        schema.__schema__(:associations)
        |> Enum.reduce({record, store}, fn assoc_name, {acc, st} ->
          case schema.__schema__(:association, assoc_name) do
            %Ecto.Association.BelongsTo{
              field: field,
              owner_key: fk_field,
              related_key: pk_field
            } ->
              backfill_belongs_to(acc, st, field, fk_field, pk_field, insert_fn)

            _other ->
              {acc, st}
          end
        end)
      else
        {record, store}
      end
    end

    defp backfill_belongs_to(record, store, assoc_field, fk_field, pk_field, insert_fn) do
      assoc_value = Map.get(record, assoc_field)
      fk_value = Map.get(record, fk_field)

      case {assoc_value, fk_value} do
        {%Ecto.Association.NotLoaded{}, _} ->
          # Association not loaded — leave as-is
          {record, store}

        {%{__struct__: _} = parent, nil} ->
          pk_value = Map.get(parent, pk_field)

          if pk_value do
            # Parent already has a PK — just copy it
            {Map.put(record, fk_field, pk_value), store}
          else
            # Parent PK is nil — insert it to trigger autogeneration,
            # then use the generated PK (matching Ecto's behaviour of
            # recursively inserting belongs_to parents)
            case insert_fn.(parent, :insert, store) do
              {{:ok, inserted_parent}, new_store} ->
                record =
                  record
                  |> Map.put(fk_field, Map.get(inserted_parent, pk_field))
                  |> Map.put(assoc_field, inserted_parent)

                {record, new_store}

              _error ->
                # Parent insert failed — leave as-is
                {record, store}
            end
          end

        _ ->
          # FK already set, or no association value — leave as-is
          {record, store}
      end
    end

    # -------------------------------------------------------------------
    # Association reset
    # -------------------------------------------------------------------

    @doc false
    @spec reset_associations(struct()) :: struct()
    def reset_associations(%{__struct__: schema} = record) do
      if function_exported?(schema, :__schema__, 1) do
        schema.__schema__(:associations)
        |> Enum.reduce(record, fn assoc_name, acc ->
          assoc = schema.__schema__(:association, assoc_name)

          Map.put(acc, assoc.field, %Ecto.Association.NotLoaded{
            __field__: assoc.field,
            __owner__: schema,
            __cardinality__: assoc.cardinality
          })
        end)
      else
        record
      end
    end
  end
end
