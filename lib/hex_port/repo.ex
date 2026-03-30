# Port contract for common Ecto Repo operations.
#
# Provides a built-in set of defport declarations so that every domain
# using HexPort for DB operations doesn't need to redeclare insert/update/
# delete/get/all etc. with identical boilerplate.
#
# ## Usage
#
#     alias HexPort.Repo
#
#     Repo.Port.insert!(changeset)
#
# ## Configuration
#
#     # config/config.exs
#     config :my_app, HexPort.Repo, impl: MyApp.Repo.HexPort
#
# ## Handler Installation (test)
#
#     HexPort.Testing.set_handler(HexPort.Repo, HexPort.Repo.Test)
#
if Code.ensure_loaded?(Ecto) do
  defmodule HexPort.Repo do
    @moduledoc """
    Port contract for common Ecto Repo operations.

    Provides `defport` declarations for the standard write and read operations
    from `Ecto.Repo`, so that code using `HexPort` for database access doesn't
    need to redeclare these with identical boilerplate.

    ## Write Operations

    Write operations return `{:ok, struct()} | {:error, Ecto.Changeset.t()}`
    and auto-generate bang variants (`insert!`, `update!`, `delete!`) that
    unwrap the success value or raise on error.

    ## Bulk Operations

    `update_all/3` and `delete_all/2` follow Ecto's return convention of
    `{count, nil | list}`. No bang variants are generated for these.

    ## Read Operations

    Read operations follow Ecto's conventions: `get/2`, `get_by/2`, `one/1`
    return `nil` on not-found; `all/1` returns a list; `exists?/1` returns
    a boolean; `aggregate/3` returns a term.

    Bang read variants (`get!/2`, `get_by!/2`, `one!/1`) are provided as
    separate port operations that mirror Ecto's raise-on-not-found semantics.

    ## Example

        alias HexPort.Repo

        changeset = User.changeset(%User{}, attrs)
        {:ok, user} = Repo.Port.insert(changeset)

        user = Repo.Port.get!(User, user_id)
    """

    use HexPort.Contract

    # -----------------------------------------------------------------
    # Write Operations
    # -----------------------------------------------------------------

    @doc "Insert a new record from a changeset."
    defport insert(changeset :: Ecto.Changeset.t()) ::
              {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Update an existing record from a changeset."
    defport update(changeset :: Ecto.Changeset.t()) ::
              {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Delete a record."
    defport delete(record :: struct()) ::
              {:ok, struct()} | {:error, Ecto.Changeset.t()}

    # -----------------------------------------------------------------
    # Bulk Operations
    # -----------------------------------------------------------------

    @doc "Update all records matching a queryable."
    defport update_all(
              queryable :: Ecto.Queryable.t(),
              updates :: keyword(),
              opts :: keyword()
            ) :: {non_neg_integer(), nil | list()}

    @doc "Delete all records matching a queryable."
    defport delete_all(queryable :: Ecto.Queryable.t(), opts :: keyword()) ::
              {non_neg_integer(), nil | list()}

    # -----------------------------------------------------------------
    # Read Operations
    # -----------------------------------------------------------------

    @doc "Fetch a single record by primary key. Returns `nil` if not found."
    defport get(queryable :: Ecto.Queryable.t(), id :: term()) :: struct() | nil

    @doc """
    Fetch a single record by primary key, or raise if not found.

    Mirrors `Ecto.Repo.get!/2`.
    """
    defport get!(queryable :: Ecto.Queryable.t(), id :: term()) :: struct(), bang: false

    @doc "Fetch a single record by the given clauses. Returns `nil` if not found."
    defport get_by(queryable :: Ecto.Queryable.t(), clauses :: keyword() | map()) ::
              struct() | nil

    @doc """
    Fetch a single record by the given clauses, or raise if not found.

    Mirrors `Ecto.Repo.get_by!/2`.
    """
    defport get_by!(queryable :: Ecto.Queryable.t(), clauses :: keyword() | map()) :: struct(),
      bang: false

    @doc "Fetch a single result from a query. Returns `nil` if no result."
    defport one(queryable :: Ecto.Queryable.t()) :: struct() | nil

    @doc """
    Fetch a single result from a query, or raise if no result.

    Mirrors `Ecto.Repo.one!/1`.
    """
    defport one!(queryable :: Ecto.Queryable.t()) :: struct(), bang: false

    @doc "Fetch all records matching a queryable."
    defport all(queryable :: Ecto.Queryable.t()) :: list(struct())

    @doc "Check whether any record matching the queryable exists."
    defport exists?(queryable :: Ecto.Queryable.t()) :: boolean()

    @doc "Calculate an aggregate over the given field."
    defport aggregate(queryable :: Ecto.Queryable.t(), aggregate :: atom(), field :: atom()) ::
              term()

    # -----------------------------------------------------------------
    # Transaction Operations
    # -----------------------------------------------------------------

    @doc """
    Run a function inside a database transaction.

    Mirrors `Ecto.Repo.transact/2`. The function may be 0-arity or 1-arity:

    - **0-arity:** `fn -> {:ok, result} | {:error, reason} end`
    - **1-arity:** `fn repo -> {:ok, result} | {:error, reason} end` — where
      `repo` is the underlying Ecto Repo module (in the Ecto adapter) or a
      placeholder in test/in-memory adapters.

    The function **must** return `{:ok, result}` or `{:error, reason}`.
    On `{:ok, result}`, the transaction is committed and `{:ok, result}` is returned.
    On `{:error, reason}`, the transaction is rolled back and `{:error, reason}` is returned.

    ## Example

        Repo.Port.transact(fn ->
          {:ok, user} = Repo.Port.insert(user_changeset)
          {:ok, profile} = Repo.Port.insert(profile_changeset(user))
          {:ok, {user, profile}}
        end)
    """
    defport transact(fun :: (-> {:ok, term()} | {:error, term()}), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}
  end
end
