# Repo contract for common Ecto Repo operations.
#
# Provides a built-in set of defcallback declarations so that every domain
# using DoubleDown for DB operations doesn't need to redeclare insert/update/
# delete/get/all etc. with identical boilerplate.
#
# ## Usage
#
#     # Define a facade in your app:
#     defmodule MyApp.Repo do
#       use DoubleDown.ContractFacade, contract: DoubleDown.Repo, otp_app: :my_app
#     end
#
#     {:ok, user} = MyApp.Repo.insert(changeset)
#
# ## Configuration
#
#     config :my_app, DoubleDown.Repo, impl: MyApp.EctoRepo
#
if Code.ensure_loaded?(Ecto) do
  defmodule DoubleDown.Repo do
    @moduledoc """
    Repo contract for common Ecto Repo operations.

    Provides `defcallback` declarations for the standard write and read operations
    from `Ecto.Repo`, so that code using `DoubleDown` for database access doesn't
    need to redeclare these with identical boilerplate.

    ## Usage

        # Define a facade in your app:
        defmodule MyApp.Repo do
          use DoubleDown.ContractFacade, contract: DoubleDown.Repo, otp_app: :my_app
        end

        changeset = User.changeset(%User{}, attrs)
        {:ok, user} = MyApp.Repo.insert(changeset)
        user = MyApp.Repo.get!(User, user_id)

    ## Write Operations

    Write operations return `{:ok, struct()} | {:error, Ecto.Changeset.t()}`.

    ## Bulk Operations

    `update_all/3` and `delete_all/2` follow Ecto's return convention of
    `{count, nil | list}`.

    ## Read Operations

    Read operations follow Ecto's conventions: `get/2`, `get_by/2`, `one/1`
    return `nil` on not-found; `all/1` returns a list; `exists?/1` returns
    a boolean; `aggregate/3` returns a term.

    Raise-on-not-found variants (`get!/2`, `get_by!/2`, `one!/1`) mirror
    Ecto's semantics.
    """

    use DoubleDown.Contract

    # -----------------------------------------------------------------
    # Write Operations
    # -----------------------------------------------------------------

    @doc "Insert a new record from a changeset or struct."
    defcallback insert(struct_or_changeset :: Ecto.Changeset.t() | struct()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Insert a new record from a changeset or struct with options."
    defcallback insert(struct_or_changeset :: Ecto.Changeset.t() | struct(), opts :: keyword()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Update an existing record from a changeset."
    defcallback update(changeset :: Ecto.Changeset.t()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Update an existing record from a changeset with options."
    defcallback update(changeset :: Ecto.Changeset.t(), opts :: keyword()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Delete a record or changeset."
    defcallback delete(struct_or_changeset :: struct() | Ecto.Changeset.t()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Delete a record or changeset with options."
    defcallback delete(struct_or_changeset :: struct() | Ecto.Changeset.t(), opts :: keyword()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    # -----------------------------------------------------------------
    # Bang Write Operations
    # -----------------------------------------------------------------

    @doc "Insert a new record, raising on failure. Mirrors `Ecto.Repo.insert!/2`."
    defcallback insert!(struct_or_changeset :: Ecto.Changeset.t() | struct()) :: struct()

    @doc "Insert a new record with options, raising on failure."
    defcallback insert!(struct_or_changeset :: Ecto.Changeset.t() | struct(), opts :: keyword()) ::
                  struct()

    @doc "Update an existing record, raising on failure. Mirrors `Ecto.Repo.update!/2`."
    defcallback update!(changeset :: Ecto.Changeset.t()) :: struct()

    @doc "Update an existing record with options, raising on failure."
    defcallback update!(changeset :: Ecto.Changeset.t(), opts :: keyword()) :: struct()

    @doc "Delete a record or changeset, raising on failure. Mirrors `Ecto.Repo.delete!/2`."
    defcallback delete!(struct_or_changeset :: struct() | Ecto.Changeset.t()) :: struct()

    @doc "Delete a record or changeset with options, raising on failure."
    defcallback delete!(struct_or_changeset :: struct() | Ecto.Changeset.t(), opts :: keyword()) ::
                  struct()

    # -----------------------------------------------------------------
    # Upsert Operations
    # -----------------------------------------------------------------

    @doc """
    Insert or update a record depending on whether it has been loaded.

    If the changeset's data has `:loaded` state, delegates to `update`;
    otherwise delegates to `insert`. Mirrors `Ecto.Repo.insert_or_update/2`.
    """
    defcallback insert_or_update(changeset :: Ecto.Changeset.t()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc "Insert or update a record with options."
    defcallback insert_or_update(changeset :: Ecto.Changeset.t(), opts :: keyword()) ::
                  {:ok, struct()} | {:error, Ecto.Changeset.t()}

    @doc """
    Insert or update a record, raising on failure.

    Mirrors `Ecto.Repo.insert_or_update!/2`.
    """
    defcallback insert_or_update!(changeset :: Ecto.Changeset.t()) :: struct()

    @doc "Insert or update a record with options, raising on failure."
    defcallback insert_or_update!(changeset :: Ecto.Changeset.t(), opts :: keyword()) :: struct()

    # -----------------------------------------------------------------
    # Raw SQL Operations
    # -----------------------------------------------------------------

    @doc "Execute a raw SQL query. Returns `{:ok, result} | {:error, term()}`."
    defcallback query(sql :: String.t()) :: {:ok, term()} | {:error, term()}

    @doc "Execute a raw SQL query with parameters."
    defcallback query(sql :: String.t(), params :: list()) :: {:ok, term()} | {:error, term()}

    @doc "Execute a raw SQL query with parameters and options."
    defcallback query(sql :: String.t(), params :: list(), opts :: keyword()) ::
                  {:ok, term()} | {:error, term()}

    @doc "Execute a raw SQL query, raising on error."
    defcallback query!(sql :: String.t()) :: term()

    @doc "Execute a raw SQL query with parameters, raising on error."
    defcallback query!(sql :: String.t(), params :: list()) :: term()

    @doc "Execute a raw SQL query with parameters and options, raising on error."
    defcallback query!(sql :: String.t(), params :: list(), opts :: keyword()) :: term()

    # -----------------------------------------------------------------
    # Bulk Operations
    # -----------------------------------------------------------------

    @doc "Insert all entries into a schema or source at once."
    defcallback insert_all(
                  source :: Ecto.Queryable.t() | binary(),
                  entries :: [map() | keyword()],
                  opts :: keyword()
                ) :: {non_neg_integer(), nil | list()}

    @doc "Update all records matching a queryable."
    defcallback update_all(
                  queryable :: Ecto.Queryable.t(),
                  updates :: keyword(),
                  opts :: keyword()
                ) :: {non_neg_integer(), nil | list()}

    @doc "Delete all records matching a queryable."
    defcallback delete_all(queryable :: Ecto.Queryable.t(), opts :: keyword()) ::
                  {non_neg_integer(), nil | list()}

    # -----------------------------------------------------------------
    # Read Operations
    # -----------------------------------------------------------------

    @doc "Fetch a single record by primary key. Returns `nil` if not found."
    defcallback get(queryable :: Ecto.Queryable.t(), id :: term()) :: struct() | nil

    @doc "Fetch a single record by primary key with options."
    defcallback get(queryable :: Ecto.Queryable.t(), id :: term(), opts :: keyword()) ::
                  struct() | nil

    @doc """
    Fetch a single record by primary key, or raise if not found.

    Mirrors `Ecto.Repo.get!/2`.
    """
    defcallback get!(queryable :: Ecto.Queryable.t(), id :: term()) :: struct()

    @doc "Fetch a single record by primary key with options, or raise if not found."
    defcallback get!(queryable :: Ecto.Queryable.t(), id :: term(), opts :: keyword()) :: struct()

    @doc "Fetch a single record by the given clauses. Returns `nil` if not found."
    defcallback get_by(queryable :: Ecto.Queryable.t(), clauses :: keyword() | map()) ::
                  struct() | nil

    @doc "Fetch a single record by the given clauses with options."
    defcallback get_by(
                  queryable :: Ecto.Queryable.t(),
                  clauses :: keyword() | map(),
                  opts :: keyword()
                ) :: struct() | nil

    @doc """
    Fetch a single record by the given clauses, or raise if not found.

    Mirrors `Ecto.Repo.get_by!/2`.
    """
    defcallback get_by!(queryable :: Ecto.Queryable.t(), clauses :: keyword() | map()) :: struct()

    @doc "Fetch a single record by the given clauses with options, or raise if not found."
    defcallback get_by!(
                  queryable :: Ecto.Queryable.t(),
                  clauses :: keyword() | map(),
                  opts :: keyword()
                ) :: struct()

    @doc "Fetch a single result from a query. Returns `nil` if no result."
    defcallback one(queryable :: Ecto.Queryable.t()) :: struct() | nil

    @doc "Fetch a single result from a query with options."
    defcallback one(queryable :: Ecto.Queryable.t(), opts :: keyword()) :: struct() | nil

    @doc """
    Fetch a single result from a query, or raise if no result.

    Mirrors `Ecto.Repo.one!/1`.
    """
    defcallback one!(queryable :: Ecto.Queryable.t()) :: struct()

    @doc "Fetch a single result from a query with options, or raise if not found."
    defcallback one!(queryable :: Ecto.Queryable.t(), opts :: keyword()) :: struct()

    @doc "Fetch all records matching a queryable."
    defcallback all(queryable :: Ecto.Queryable.t()) :: list(struct())

    @doc "Fetch all records matching a queryable with options."
    defcallback all(queryable :: Ecto.Queryable.t(), opts :: keyword()) :: list(struct())

    @doc "Check whether any record matching the queryable exists."
    defcallback exists?(queryable :: Ecto.Queryable.t()) :: boolean()

    @doc "Check whether any record matching the queryable exists, with options."
    defcallback exists?(queryable :: Ecto.Queryable.t(), opts :: keyword()) :: boolean()

    @doc "Calculate an aggregate over the given field."
    defcallback aggregate(queryable :: Ecto.Queryable.t(), aggregate :: atom(), field :: atom()) ::
                  term()

    @doc "Calculate an aggregate over the given field with options."
    defcallback aggregate(
                  queryable :: Ecto.Queryable.t(),
                  aggregate :: atom(),
                  field :: atom(),
                  opts :: keyword()
                ) :: term()

    @doc """
    Fetch all records matching the given clauses.

    Similar to `get_by`, but returns all matching records as a list
    instead of just the first. New in Ecto 3.13. Mirrors `Ecto.Repo.all_by/3`.
    """
    defcallback all_by(queryable :: Ecto.Queryable.t(), clauses :: keyword() | map()) ::
                  list(struct())

    @doc "Fetch all records matching the given clauses with options."
    defcallback all_by(
                  queryable :: Ecto.Queryable.t(),
                  clauses :: keyword() | map(),
                  opts :: keyword()
                ) :: list(struct())

    # -----------------------------------------------------------------
    # Reload Operations
    # -----------------------------------------------------------------

    @doc """
    Reload a struct or list of structs from the data store.

    Re-fetches the record by primary key. Returns `nil` if not found
    (for a single struct) or `nil` in the corresponding list position
    (for a list). Mirrors `Ecto.Repo.reload/2`.
    """
    defcallback reload(struct_or_structs :: struct() | list(struct())) ::
                  struct() | nil | list(struct() | nil)

    @doc "Reload a struct or list of structs with options."
    defcallback reload(struct_or_structs :: struct() | list(struct()), opts :: keyword()) ::
                  struct() | nil | list(struct() | nil)

    @doc """
    Reload a struct or list of structs, raising if any are not found.

    Mirrors `Ecto.Repo.reload!/2`.
    """
    defcallback reload!(struct_or_structs :: struct() | list(struct())) ::
                  struct() | list(struct())

    @doc "Reload a struct or list of structs with options, raising if not found."
    defcallback reload!(struct_or_structs :: struct() | list(struct()), opts :: keyword()) ::
                  struct() | list(struct())

    # -----------------------------------------------------------------
    # Preload Operations
    # -----------------------------------------------------------------

    @doc """
    Preload associations on a struct, list of structs, or nil.

    Uses schema reflection to resolve associations from the in-memory
    store (when using InMemory fakes) or delegates to the real Repo.
    Mirrors `Ecto.Repo.preload/3`.
    """
    defcallback preload(
                  structs_or_struct_or_nil :: list(struct()) | struct() | nil,
                  preloads :: term()
                ) :: list(struct()) | struct() | nil

    @doc "Preload associations with options."
    defcallback preload(
                  structs_or_struct_or_nil :: list(struct()) | struct() | nil,
                  preloads :: term(),
                  opts :: keyword()
                ) :: list(struct()) | struct() | nil

    # -----------------------------------------------------------------
    # Load Operations
    # -----------------------------------------------------------------

    @doc """
    Load a schema struct or map from raw data.

    Coerces raw data (map, keyword list, or `{columns, values}` tuple)
    into a schema struct using Ecto's type system. Stateless — does not
    touch the data store. Mirrors `Ecto.Repo.load/2`.
    """
    defcallback load(
                  schema_or_map :: module() | map(),
                  data :: map() | keyword() | {list(), list()}
                ) :: struct() | map()

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
      `repo` is the facade module. Calls to `repo.insert/1`, `repo.get/2`,
      etc. go through the facade dispatch chain, ensuring logging, telemetry,
      and other facade-level concerns are applied.

    The function **must** return `{:ok, result}` or `{:error, reason}`.
    On `{:ok, result}`, the transaction is committed and `{:ok, result}` is returned.
    On `{:error, reason}`, the transaction is rolled back and `{:error, reason}` is returned.

    1-arity functions are wrapped into 0-arity thunks at the facade boundary,
    binding the facade module. Implementations always receive a 0-arity function.

    ## Use with Ecto.Multi

    When given an `Ecto.Multi`, all operations are executed in order.
    On success, returns `{:ok, changes}` where `changes` is a map of
    operation names to their results. On failure, returns
    `{:error, failed_operation, failed_value, changes_so_far}`.

    The facade module is injected into opts under the `DoubleDown.Repo.Facade`
    key so that test adapters can pass it to `DoubleDown.Repo.Impl.MultiStepper`
    for `:run` callbacks.
    """
    defcallback transact(fun_or_multi :: term(), opts :: keyword()) ::
                  {:ok, term()} | {:error, term()} | {:error, term(), term(), term()},
                pre_dispatch: fn args, facade_mod ->
                  case args do
                    [fun, opts] when is_function(fun, 1) ->
                      # Wrap 1-arity fn into 0-arity thunk closing over facade.
                      # Calls inside the fn go through the facade dispatch chain.
                      [fn -> fun.(facade_mod) end, opts]

                    [%Ecto.Multi{} = _multi, opts] ->
                      # Multi stays as-is. Inject facade into opts so test adapters
                      # can extract it for MultiStepper.
                      [Enum.at(args, 0), Keyword.put(opts, DoubleDown.Repo.Facade, facade_mod)]

                    [fun, _opts] when is_function(fun, 0) ->
                      # 0-arity fn: pass through unchanged
                      args
                  end
                end

    @doc """
    Roll back the current transaction.

    Throws `{:rollback, value}`, which is caught by `transact` and
    returned as `{:error, value}`. Mirrors `Ecto.Repo.rollback/1`.

    Must be called from within a `transact` callback. Calling outside
    a transaction raises.
    """
    defcallback rollback(value :: term()) :: no_return()

    @doc """
    Check whether the current process is inside a transaction.

    Returns `true` if called from within a `transact` callback,
    `false` otherwise. Mirrors `Ecto.Repo.in_transaction?/0`.
    """
    defcallback in_transaction?() :: boolean()
  end
end
