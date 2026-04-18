# Steps through an Ecto.Multi without a real database.
#
# Shared logic for Test and InMemory adapters. Iterates
# through Multi operations using Ecto.Multi.to_list/1 and
# dispatches each operation to the given `repo_facade` module
# (typically the Repo.Port facade so that :run callbacks can
# call repo.insert/1, repo.get/2, etc.).
#
if Code.ensure_loaded?(Ecto) do
  defmodule DoubleDown.Repo.Impl.MultiStepper do
    @moduledoc """
    Steps through an `Ecto.Multi` without a real database transaction.

    Used by `DoubleDown.Repo.Stub` and `DoubleDown.Repo.OpenInMemory` to execute
    Multi operations in order, accumulating a changes map.

    The `repo_facade` argument is passed to `:run` callbacks as the
    first argument (the "repo"), mirroring how Ecto passes the Repo
    module to `Ecto.Multi.run/3` callbacks.

    ## Return values

      * `{:ok, changes}` — all operations succeeded
      * `{:error, name, value, changes_so_far}` — an operation failed
    """

    @type changes :: %{optional(any()) => any()}

    @doc """
    Execute all operations in the given `Ecto.Multi`.

    `repo_facade` is the module passed to `:run` callbacks as the repo
    argument — typically the `Repo.Port` module so callbacks can call
    `repo.insert/1`, `repo.get/2`, etc.
    """
    @spec run(Ecto.Multi.t(), module()) ::
            {:ok, changes()}
            | {:error, any(), any(), changes()}
    def run(%Ecto.Multi{} = multi, repo_facade) do
      operations = Ecto.Multi.to_list(multi)

      # Pre-check: reject invalid changesets and explicit errors before stepping
      case find_pre_check_error(operations) do
        {:error, name, value} ->
          {:error, name, value, %{}}

        :ok ->
          step(operations, %{}, repo_facade)
      end
    end

    # -- Pre-check --

    defp find_pre_check_error(operations) do
      Enum.find_value(operations, :ok, fn
        {name, {action, %Ecto.Changeset{valid?: false} = changeset, _opts}}
        when action in [:insert, :update, :delete] ->
          {:error, name, changeset}

        {name, {:error, value}} ->
          {:error, name, value}

        _ ->
          nil
      end)
    end

    # -- Stepping --

    defp step([], changes, _repo_facade), do: {:ok, changes}

    defp step([{name, operation} | rest], changes, repo_facade) do
      case apply_operation(name, operation, changes, repo_facade) do
        {:ok, value, _op_changes} ->
          step(rest, Map.put(changes, name, value), repo_facade)

        {:ok_merge, merged_changes} ->
          step(rest, merged_changes, repo_facade)

        {:ok_inspect} ->
          step(rest, changes, repo_facade)

        {:error, value} ->
          {:error, name, value, changes}

        {:error, failed_name, failed_value, changes_so_far} ->
          {:error, failed_name, failed_value, changes_so_far}
      end
    end

    # -- Operation dispatch --

    # Changeset operations (insert, update, delete)
    defp apply_operation(_name, {:insert, changeset, _opts}, _changes, repo_facade) do
      apply_changeset_op(repo_facade, :insert, changeset)
    end

    defp apply_operation(_name, {:update, changeset, _opts}, _changes, repo_facade) do
      apply_changeset_op(repo_facade, :update, changeset)
    end

    defp apply_operation(_name, {:delete, changeset_or_struct, _opts}, _changes, repo_facade) do
      apply_changeset_op(repo_facade, :delete, changeset_or_struct)
    end

    # Run operations (arbitrary functions)
    defp apply_operation(_name, {:run, fun}, changes, repo_facade)
         when is_function(fun, 2) do
      case fun.(repo_facade, changes) do
        {:ok, value} -> {:ok, value, changes}
        {:error, value} -> {:error, value}
      end
    end

    defp apply_operation(_name, {:run, {mod, fun, args}}, changes, repo_facade) do
      case apply(mod, fun, [repo_facade, changes | args]) do
        {:ok, value} -> {:ok, value, changes}
        {:error, value} -> {:error, value}
      end
    end

    # Put (static value)
    defp apply_operation(_name, {:put, value}, changes, _repo_facade) do
      {:ok, value, changes}
    end

    # Error (explicit failure — should be caught by pre-check, but handle anyway)
    defp apply_operation(_name, {:error, value}, _changes, _repo_facade) do
      {:error, value}
    end

    # Inspect (debug logging) — mirrors Ecto.Multi.inspect/2 behaviour
    # credo:disable-for-next-line Credo.Check.Warning.IoInspect
    defp apply_operation(_name, {:inspect, opts}, changes, _repo_facade) do
      if opts[:only] do
        # credo:disable-for-next-line Credo.Check.Warning.IoInspect
        changes |> Map.take(List.wrap(opts[:only])) |> IO.inspect(opts)
      else
        # credo:disable-for-next-line Credo.Check.Warning.IoInspect
        IO.inspect(changes, opts)
      end

      {:ok_inspect}
    end

    # Merge (dynamic Multi composition)
    defp apply_operation(_name, {:merge, merge_fn}, changes, repo_facade)
         when is_function(merge_fn, 1) do
      sub_multi = merge_fn.(changes)
      apply_merge(sub_multi, changes, repo_facade)
    end

    defp apply_operation(_name, {:merge, {mod, fun, args}}, changes, repo_facade) do
      sub_multi = apply(mod, fun, [changes | args])
      apply_merge(sub_multi, changes, repo_facade)
    end

    # Bulk operations — insert_all, update_all, delete_all
    # Test/InMemory adapters don't support real bulk ops; return {0, nil}
    defp apply_operation(_name, {:insert_all, _source, _entries, _opts}, changes, _repo_facade) do
      {:ok, {0, nil}, changes}
    end

    defp apply_operation(_name, {:update_all, _query, _updates, _opts}, changes, _repo_facade) do
      {:ok, {0, nil}, changes}
    end

    defp apply_operation(_name, {:delete_all, _query, _opts}, changes, _repo_facade) do
      {:ok, {0, nil}, changes}
    end

    # -- Helpers --

    defp apply_changeset_op(repo_facade, action, %Ecto.Changeset{} = changeset) do
      case apply(repo_facade, action, [changeset]) do
        {:ok, value} -> {:ok, value, %{}}
        {:error, value} -> {:error, value}
      end
    end

    defp apply_changeset_op(repo_facade, :delete, struct) do
      case apply(repo_facade, :delete, [struct]) do
        {:ok, value} -> {:ok, value, %{}}
        {:error, value} -> {:error, value}
      end
    end

    defp apply_merge(sub_multi, changes, repo_facade) do
      case run(sub_multi, repo_facade) do
        {:ok, sub_changes} ->
          {:ok_merge, Map.merge(changes, sub_changes)}

        {:error, name, value, sub_changes} ->
          {:error, name, value, Map.merge(changes, sub_changes)}
      end
    end
  end
end
