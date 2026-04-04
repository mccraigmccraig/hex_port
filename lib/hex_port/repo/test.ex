# Stateless test handler for HexPort.Repo.Contract.
#
# Provides a function handler for use with set_fn_handler. Write operations
# apply changeset changes and return {:ok, struct}. Read operations go
# through a user-supplied fallback function, or raise.
#
# ## Usage
#
#     HexPort.Testing.set_fn_handler(HexPort.Repo.Contract, HexPort.Repo.Test.new())
#
#     # With fallback for reads:
#     HexPort.Testing.set_fn_handler(
#       HexPort.Repo,
#       HexPort.Repo.Test.new(
#         fallback_fn: fn
#           :all, [User] -> [%User{id: 1, name: "Alice"}]
#           :get, [User, 1] -> %User{id: 1, name: "Alice"}
#         end
#       )
#     )
#
if Code.ensure_loaded?(Ecto) do
  defmodule HexPort.Repo.Test do
    @moduledoc """
    Stateless test handler for `HexPort.Repo.Contract`.

    Provides a function handler via `new/1` for use with
    `HexPort.Testing.set_fn_handler/2`. Write operations (`insert`, `update`,
    `delete`) apply changeset changes and return `{:ok, struct}`. All read
    operations go through an optional fallback function, or raise a clear
    error.

    This applies the same "fail when consistency cannot be proven" approach
    as `HexPort.Repo.InMemory` — reads never silently return `nil` or `[]`
    because the adapter has no basis for claiming a record does or doesn't
    exist.

    ## Usage

        # Writes only — reads will raise:
        HexPort.Testing.set_fn_handler(HexPort.Repo.Contract, HexPort.Repo.Test.new())

        # With fallback for reads:
        HexPort.Testing.set_fn_handler(
          HexPort.Repo.Contract,
          HexPort.Repo.Test.new(
            fallback_fn: fn
              :get, [User, 1] -> %User{id: 1, name: "Alice"}
              :all, [User] -> [%User{id: 1, name: "Alice"}]
            end
          )
        )

        # With logging:
        HexPort.Testing.set_fn_handler(HexPort.Repo, HexPort.Repo.Test.new())
        HexPort.Testing.enable_log(HexPort.Repo.Contract)

    ## Differences from Repo.InMemory

    `Repo.Test` is stateless — writes apply changesets and return `{:ok, struct}`
    but nothing is stored. There is no read-after-write consistency.

    `Repo.InMemory` is stateful — writes store records and PK-based reads can
    find them. Use `Repo.InMemory` when your test needs read-after-write
    consistency. Use `Repo.Test` when you only need fire-and-forget writes.
    """

    @doc """
    Create a new Test handler function.

    Returns a 2-arity function `(operation, args) -> result` suitable for
    use with `HexPort.Testing.set_fn_handler/2`.

    ## Options

      * `:fallback_fn` - a 2-arity function `(operation, args) -> result` that
        handles read operations. If the function raises `FunctionClauseError`
        (no matching clause), dispatch falls through to an error. If omitted,
        all reads raise immediately.

    ## Examples

        # Writes only
        HexPort.Repo.Test.new()

        # With fallback for specific reads
        HexPort.Repo.Test.new(
          fallback_fn: fn
            :get, [User, 1] -> %User{id: 1, name: "Alice"}
            :all, [User] -> [%User{id: 1, name: "Alice"}]
            :exists?, [User] -> true
          end
        )
    """
    @spec new(keyword()) :: (atom(), [term()] -> term())
    def new(opts \\ []) do
      fallback_fn = Keyword.get(opts, :fallback_fn, nil)

      fn operation, args ->
        dispatch(operation, args, fallback_fn)
      end
    end

    # -----------------------------------------------------------------
    # Write Operations — always authoritative
    # -----------------------------------------------------------------

    defp dispatch(:insert, [%Ecto.Changeset{valid?: false} = changeset], _fallback_fn) do
      {:error, changeset}
    end

    defp dispatch(:insert, [changeset], _fallback_fn) do
      {:ok, safe_apply_changes(changeset, :insert)}
    end

    defp dispatch(:update, [%Ecto.Changeset{valid?: false} = changeset], _fallback_fn) do
      {:error, changeset}
    end

    defp dispatch(:update, [changeset], _fallback_fn) do
      {:ok, safe_apply_changes(changeset, :update)}
    end

    defp dispatch(:delete, [record], _fallback_fn) do
      {:ok, record}
    end

    # -----------------------------------------------------------------
    # Read and bulk operations — fallback or error
    # -----------------------------------------------------------------

    defp dispatch(operation, args, fallback_fn)
         when operation in [
                :get,
                :get!,
                :get_by,
                :get_by!,
                :one,
                :one!,
                :all,
                :exists?,
                :aggregate,
                :update_all,
                :delete_all
              ] do
      try_fallback(fallback_fn, operation, args)
    end

    # -----------------------------------------------------------------
    # Transaction Operations
    # -----------------------------------------------------------------

    defp dispatch(:transact, [fun, _opts], _fallback_fn) when is_function(fun, 0) do
      fun.()
    end

    defp dispatch(:transact, [fun, opts], _fallback_fn) when is_function(fun, 1) do
      repo_facade = Keyword.get(opts, HexPort.Repo.Facade)
      fun.(repo_facade)
    end

    defp dispatch(:transact, [%Ecto.Multi{} = multi, opts], _fallback_fn) do
      repo_facade = Keyword.get(opts, HexPort.Repo.Facade)
      HexPort.Repo.MultiStepper.run(multi, repo_facade)
    end

    # -----------------------------------------------------------------
    # Fallback dispatch
    # -----------------------------------------------------------------

    defp try_fallback(nil, operation, args) do
      raise_no_fallback(operation, args)
    end

    defp try_fallback(fallback_fn, operation, args) when is_function(fallback_fn, 2) do
      fallback_fn.(operation, args)
    rescue
      FunctionClauseError -> raise_no_fallback(operation, args)
    end

    defp raise_no_fallback(operation, args) do
      raise ArgumentError, """
      HexPort.Repo.Test cannot service :#{operation} with args #{inspect(args)}.

      The Test adapter can only answer authoritatively for:
        - Write operations (insert, update, delete)

      For all other operations, register a fallback function:

          HexPort.Repo.Test.new(
            fallback_fn: fn
              :#{operation}, #{inspect(args)} -> # your result here
            end
          )
      """
    end

    # -----------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------

    defp safe_apply_changes(%Ecto.Changeset{} = changeset, action) do
      changeset
      |> Ecto.Changeset.apply_changes()
      |> apply_autogenerate(action)
    end

    defp apply_autogenerate(record, action) do
      schema = record.__struct__

      if function_exported?(schema, :__schema__, 1) do
        autogen_fields =
          case action do
            :insert -> schema.__schema__(:autogenerate)
            :update -> schema.__schema__(:autoupdate)
          end

        Enum.reduce(autogen_fields, record, fn {fields, {mod, fun, args}}, acc ->
          generated_value = apply(mod, fun, args)

          Enum.reduce(fields, acc, fn field, rec ->
            if Map.get(rec, field) == nil do
              Map.put(rec, field, generated_value)
            else
              rec
            end
          end)
        end)
      else
        record
      end
    end
  end
end
