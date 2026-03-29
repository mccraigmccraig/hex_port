# Stateless test implementation of HexPort.Repo.
#
# Provides default return values for all operations. Write operations
# apply changeset changes and return {:ok, struct}. Read operations
# return sensible defaults (nil, [], false).
#
# ## Usage
#
#     HexPort.Testing.set_handler(HexPort.Repo, HexPort.Repo.Test)
#
if Code.ensure_loaded?(Ecto) do
  defmodule HexPort.Repo.Test do
    @moduledoc """
    Stateless test implementation of `HexPort.Repo.Behaviour`.

    Write operations (`insert`, `update`, `delete`) apply changeset changes
    to produce a struct and return `{:ok, struct}`. Read operations return
    sensible empty defaults (`nil`, `[]`, `false`). Bulk operations return
    `{0, nil}`.

    Use this when you only need fire-and-forget writes and don't need
    read-after-write consistency. For stateful behaviour, see
    `HexPort.Repo.InMemory`.

    ## Usage

        # In test setup:
        HexPort.Testing.set_handler(HexPort.Repo, HexPort.Repo.Test)

        # With logging:
        HexPort.Testing.set_handler(HexPort.Repo, HexPort.Repo.Test)
        HexPort.Testing.enable_log(HexPort.Repo)
    """

    @behaviour HexPort.Repo.Behaviour

    # -----------------------------------------------------------------
    # Write Operations
    # -----------------------------------------------------------------

    @impl true
    def insert(changeset), do: {:ok, safe_apply_changes(changeset)}

    @impl true
    def update(changeset), do: {:ok, safe_apply_changes(changeset)}

    @impl true
    def delete(record), do: {:ok, record}

    # -----------------------------------------------------------------
    # Bulk Operations
    # -----------------------------------------------------------------

    @impl true
    def update_all(_queryable, _updates, _opts), do: {0, nil}

    @impl true
    def delete_all(_queryable, _opts), do: {0, nil}

    # -----------------------------------------------------------------
    # Read Operations
    # -----------------------------------------------------------------

    @impl true
    def get(_queryable, _id), do: nil

    @impl true
    def get!(_queryable, _id), do: nil

    @impl true
    def get_by(_queryable, _clauses), do: nil

    @impl true
    def get_by!(_queryable, _clauses), do: nil

    @impl true
    def one(_queryable), do: nil

    @impl true
    def one!(_queryable), do: nil

    @impl true
    def all(_queryable), do: []

    @impl true
    def exists?(_queryable), do: false

    @impl true
    def aggregate(_queryable, _aggregate_fn, _field), do: nil

    # -----------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------

    defp safe_apply_changes(%Ecto.Changeset{} = changeset) do
      Ecto.Changeset.apply_changes(changeset)
    end
  end
end
