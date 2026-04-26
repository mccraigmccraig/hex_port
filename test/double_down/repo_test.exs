defmodule DoubleDown.RepoTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Repo
  alias DoubleDown.Test.Repo, as: TestRepo

  # -------------------------------------------------------------------
  # Test Schemas
  # -------------------------------------------------------------------

  defmodule User do
    use Ecto.Schema

    schema "users" do
      field(:name, :string)
      field(:email, :string)
      field(:age, :integer)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name, :email, :age])
    end
  end

  defmodule Post do
    use Ecto.Schema

    schema "posts" do
      field(:title, :string)
      field(:body, :string)
    end

    def changeset(post \\ %__MODULE__{}, attrs) do
      post
      |> Ecto.Changeset.cast(attrs, [:title, :body])
    end
  end

  # -------------------------------------------------------------------
  # Contract Tests
  # -------------------------------------------------------------------

  describe "DoubleDown.Repo" do
    test "generates Behaviour module with all callbacks" do
      {:module, _} = Code.ensure_loaded(Repo)
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(Repo)
      callback_names = Enum.map(callbacks, fn {name_arity, _} -> elem(name_arity, 0) end)

      assert :insert in callback_names
      assert :update in callback_names
      assert :delete in callback_names
      assert :update_all in callback_names
      assert :delete_all in callback_names
      assert :get in callback_names
      assert :get! in callback_names
      assert :get_by in callback_names
      assert :get_by! in callback_names
      assert :one in callback_names
      assert :one! in callback_names
      assert :all in callback_names
      assert :exists? in callback_names
      assert :aggregate in callback_names
      assert :transact in callback_names
    end

    test "Facade (defined via use DoubleDown.ContractFacade) has all operations" do
      {:module, _} = Code.ensure_loaded(TestRepo)

      # Base arities
      assert function_exported?(TestRepo, :insert, 1)
      assert function_exported?(TestRepo, :update, 1)
      assert function_exported?(TestRepo, :delete, 1)
      assert function_exported?(TestRepo, :get, 2)
      assert function_exported?(TestRepo, :get!, 2)
      assert function_exported?(TestRepo, :get_by, 2)
      assert function_exported?(TestRepo, :get_by!, 2)
      assert function_exported?(TestRepo, :one, 1)
      assert function_exported?(TestRepo, :one!, 1)
      assert function_exported?(TestRepo, :all, 1)
      assert function_exported?(TestRepo, :exists?, 1)
      assert function_exported?(TestRepo, :aggregate, 3)
      assert function_exported?(TestRepo, :transact, 2)
      assert function_exported?(TestRepo, :rollback, 1)

      # Opts-accepting arities
      assert function_exported?(TestRepo, :insert, 2)
      assert function_exported?(TestRepo, :update, 2)
      assert function_exported?(TestRepo, :delete, 2)
      assert function_exported?(TestRepo, :get, 3)
      assert function_exported?(TestRepo, :get!, 3)
      assert function_exported?(TestRepo, :get_by, 3)
      assert function_exported?(TestRepo, :get_by!, 3)
      assert function_exported?(TestRepo, :one, 2)
      assert function_exported?(TestRepo, :one!, 2)
      assert function_exported?(TestRepo, :all, 2)
      assert function_exported?(TestRepo, :exists?, 2)
      assert function_exported?(TestRepo, :aggregate, 4)
    end

    test "raise-on-not-found read operations are regular contract operations" do
      ops = Repo.__callbacks__() |> Enum.map(& &1.name)

      assert :get! in ops
      assert :get_by! in ops
      assert :one! in ops
    end

    test "__callbacks__ covers all expected operation names" do
      ops = Repo.__callbacks__()
      op_names = Enum.map(ops, & &1.name) |> Enum.uniq() |> Enum.sort()

      assert op_names == [
               :aggregate,
               :all,
               :all_by,
               :delete,
               :delete!,
               :delete_all,
               :exists?,
               :get,
               :get!,
               :get_by,
               :get_by!,
               :in_transaction?,
               :insert,
               :insert!,
               :insert_all,
               :insert_or_update,
               :insert_or_update!,
               :load,
               :one,
               :one!,
               :preload,
               :query,
               :query!,
               :reload,
               :reload!,
               :rollback,
               :stream,
               :transact,
               :transaction,
               :update,
               :update!,
               :update_all
             ]
    end
  end

  # -------------------------------------------------------------------
  # MockRepo for Ecto delegation tests
  # -------------------------------------------------------------------

  defmodule MockRepo do
    def insert(cs, _opts \\ []), do: {:ok, Ecto.Changeset.apply_changes(cs)}
    def update(cs, _opts \\ []), do: {:ok, Ecto.Changeset.apply_changes(cs)}
    def delete(record, _opts \\ []), do: {:ok, record}
    def insert_all(_s, entries, _o), do: {length(entries), nil}
    def update_all(_q, _u, _o), do: {3, nil}
    def delete_all(_q, _o), do: {5, nil}
    def get(_q, id, _opts \\ []), do: %User{id: id, name: "found"}
    def get!(_q, id, _opts \\ []), do: %User{id: id, name: "found!"}
    def get_by(_q, clauses, _opts \\ []), do: %User{id: 1, name: clauses[:name]}
    def get_by!(_q, clauses, _opts \\ []), do: %User{id: 1, name: clauses[:name]}
    def one(_q, _opts \\ []), do: %User{id: 1, name: "one"}
    def one!(_q, _opts \\ []), do: %User{id: 1, name: "one!"}
    def all(_q, _opts \\ []), do: [%User{id: 1}, %User{id: 2}]
    def exists?(_q, _opts \\ []), do: true
    def aggregate(_q, _agg, _f, _opts \\ []), do: 42

    # The facade's pre_dispatch wraps 1-arity fns into 0-arity thunks,
    # so implementations always receive a 0-arity fn or an Ecto.Multi.
    def transact(fun, _opts) when is_function(fun, 0), do: fun.()

    def transact(%Ecto.Multi{} = multi, _opts) do
      # Simulate what a real Ecto Repo does: step through the Multi
      # using this module as the repo for :run callbacks
      DoubleDown.Repo.Impl.MultiStepper.run(multi, __MODULE__)
    end

    def transaction(fun, _opts) when is_function(fun, 0), do: fun.()

    def transaction(%Ecto.Multi{} = multi, _opts) do
      DoubleDown.Repo.Impl.MultiStepper.run(multi, __MODULE__)
    end
  end

  # -------------------------------------------------------------------
  # Ecto Repo delegation tests (using MockRepo directly as impl)
  # -------------------------------------------------------------------

  describe "Ecto Repo delegation" do
    setup do
      DoubleDown.Testing.set_module_handler(Repo, MockRepo)
      :ok
    end

    test "insert delegates to mock Repo" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice"}} = TestRepo.insert(cs)
    end

    test "update delegates to mock Repo" do
      cs = User.changeset(%User{id: 1, name: "old"}, %{name: "new"})
      assert {:ok, %User{name: "new"}} = TestRepo.update(cs)
    end

    test "delete delegates to mock Repo" do
      record = %User{id: 1, name: "Alice"}
      assert {:ok, ^record} = TestRepo.delete(record)
    end

    test "get delegates to mock Repo" do
      assert %User{id: 42, name: "found"} = TestRepo.get(User, 42)
    end

    test "get! delegates to mock Repo" do
      assert %User{id: 42, name: "found!"} = TestRepo.get!(User, 42)
    end

    test "get_by delegates to mock Repo" do
      assert %User{name: "Alice"} = TestRepo.get_by(User, name: "Alice")
    end

    test "get_by! delegates to mock Repo" do
      assert %User{name: "Alice"} = TestRepo.get_by!(User, name: "Alice")
    end

    test "one delegates to mock Repo" do
      assert %User{name: "one"} = TestRepo.one(User)
    end

    test "one! delegates to mock Repo" do
      assert %User{name: "one!"} = TestRepo.one!(User)
    end

    test "all delegates to mock Repo" do
      assert [%User{id: 1}, %User{id: 2}] = TestRepo.all(User)
    end

    test "exists? delegates to mock Repo" do
      assert TestRepo.exists?(User) == true
    end

    test "aggregate delegates to mock Repo" do
      assert 42 = TestRepo.aggregate(User, :count, :id)
    end

    test "insert_all delegates to mock Repo" do
      assert {2, nil} = TestRepo.insert_all(User, [%{name: "a"}, %{name: "b"}], [])
    end

    test "update_all delegates to mock Repo" do
      assert {3, nil} = TestRepo.update_all(User, [set: [name: "bulk"]], [])
    end

    test "delete_all delegates to mock Repo" do
      assert {5, nil} = TestRepo.delete_all(User, [])
    end

    test "transact with 0-arity fun delegates to mock Repo" do
      result = TestRepo.transact(fn -> {:ok, :committed} end, [])
      assert {:ok, :committed} = result
    end

    test "transact with 1-arity fun delegates to mock Repo (receives facade module)" do
      result = TestRepo.transact(fn repo -> {:ok, repo} end, [])
      # 1-arity fns are wrapped into 0-arity thunks by the facade's pre_dispatch,
      # so the fn receives the facade module (TestRepo), not the impl (MockRepo).
      assert {:ok, TestRepo} = result
    end

    test "transact with Ecto.Multi delegates to mock Repo" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))

      assert {:ok, %{user: %User{name: "Alice"}}} = TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi and :run receives the Ecto Repo (MockRepo)" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:check, fn repo, _changes ->
          {:ok, repo}
        end)

      # In the Ecto adapter, :run callbacks receive the underlying Ecto Repo module,
      # not the Port facade. This mirrors real Ecto.Repo.transact/2 behaviour.
      assert {:ok, %{check: MockRepo}} = TestRepo.transact(multi, [])
    end

    test "transaction with 0-arity fun delegates to mock Repo" do
      result = TestRepo.transaction(fn -> {:ok, :committed} end, [])
      assert {:ok, :committed} = result
    end

    test "transaction with 1-arity fun delegates to mock Repo (receives facade module)" do
      result = TestRepo.transaction(fn repo -> {:ok, repo} end, [])
      assert {:ok, TestRepo} = result
    end

    test "transaction with Ecto.Multi delegates to mock Repo" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))

      assert {:ok, %{user: %User{name: "Alice"}}} = TestRepo.transaction(multi, [])
    end

    test "transaction with Ecto.Multi and :run receives the Ecto Repo (MockRepo)" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:check, fn repo, _changes ->
          {:ok, repo}
        end)

      assert {:ok, %{check: MockRepo}} = TestRepo.transaction(multi, [])
    end
  end
end
