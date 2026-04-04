# Repo contract for common Ecto Repo operations.
#
# Provides a built-in set of defport declarations so that every domain
# using HexPort for DB operations doesn't need to redeclare insert/update/
# delete/get/all etc. with identical boilerplate.
#
# ## Usage
#
#     # Define a facade in your app:
#     defmodule MyApp.Repo do
#       use HexPort.Facade, contract: HexPort.Repo.Contract, otp_app: :my_app
#     end
#
#     MyApp.Repo.insert!(changeset)
#
# ## Configuration
#
#     config :my_app, HexPort.Repo.Contract, impl: MyApp.EctoRepo
#
if Code.ensure_loaded?(Ecto) do
  defmodule HexPort.Repo.Contract do
    @moduledoc """
    Repo contract for common Ecto Repo operations.

    Provides `defport` declarations for the standard write and read operations
    from `Ecto.Repo`, so that code using `HexPort` for database access doesn't
    need to redeclare these with identical boilerplate.

    ## Usage

        # Define a facade in your app:
        defmodule MyApp.Repo do
          use HexPort.Facade, contract: HexPort.Repo.Contract, otp_app: :my_app
        end

        changeset = User.changeset(%User{}, attrs)
        {:ok, user} = MyApp.Repo.insert(changeset)
        user = MyApp.Repo.get!(User, user_id)

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

    @doc "Insert all entries into a schema or source at once."
    defport insert_all(
              source :: Ecto.Queryable.t() | binary(),
              entries :: [map() | keyword()],
              opts :: keyword()
            ) :: {non_neg_integer(), nil | list()}

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
    Run a function or `Ecto.Multi` inside a database transaction.

    Mirrors `Ecto.Repo.transact/2`. Accepts either a function or an
    `Ecto.Multi` struct as the first argument.

    ## Use with function

    The function may be 0-arity or 1-arity:

    - **0-arity:** `fn -> {:ok, result} | {:error, reason} end`
    - **1-arity:** `fn repo -> {:ok, result} | {:error, reason} end` — where
      `repo` is the underlying Ecto Repo module (in the Ecto adapter) or the
      facade module in test/in-memory adapters.

    The function **must** return `{:ok, result}` or `{:error, reason}`.
    On `{:ok, result}`, the transaction is committed and `{:ok, result}` is returned.
    On `{:error, reason}`, the transaction is rolled back and `{:error, reason}` is returned.

    ## Use with Ecto.Multi

    When given an `Ecto.Multi`, all operations are executed in order.
    On success, returns `{:ok, changes}` where `changes` is a map of
    operation names to their results. On failure, returns
    `{:error, failed_operation, failed_value, changes_so_far}`.
    """
    defport transact(fun_or_multi :: term(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()},
            bang: false
  end
end
