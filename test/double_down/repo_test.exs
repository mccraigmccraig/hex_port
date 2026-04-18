defmodule DoubleDown.RepoTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Repo

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
      {:module, _} = Code.ensure_loaded(Repo.Port)

      # Base arities
      assert function_exported?(Repo.Port, :insert, 1)
      assert function_exported?(Repo.Port, :update, 1)
      assert function_exported?(Repo.Port, :delete, 1)
      assert function_exported?(Repo.Port, :get, 2)
      assert function_exported?(Repo.Port, :get!, 2)
      assert function_exported?(Repo.Port, :get_by, 2)
      assert function_exported?(Repo.Port, :get_by!, 2)
      assert function_exported?(Repo.Port, :one, 1)
      assert function_exported?(Repo.Port, :one!, 1)
      assert function_exported?(Repo.Port, :all, 1)
      assert function_exported?(Repo.Port, :exists?, 1)
      assert function_exported?(Repo.Port, :aggregate, 3)
      assert function_exported?(Repo.Port, :transact, 2)
      assert function_exported?(Repo.Port, :rollback, 1)

      # Opts-accepting arities
      assert function_exported?(Repo.Port, :insert, 2)
      assert function_exported?(Repo.Port, :update, 2)
      assert function_exported?(Repo.Port, :delete, 2)
      assert function_exported?(Repo.Port, :get, 3)
      assert function_exported?(Repo.Port, :get!, 3)
      assert function_exported?(Repo.Port, :get_by, 3)
      assert function_exported?(Repo.Port, :get_by!, 3)
      assert function_exported?(Repo.Port, :one, 2)
      assert function_exported?(Repo.Port, :one!, 2)
      assert function_exported?(Repo.Port, :all, 2)
      assert function_exported?(Repo.Port, :exists?, 2)
      assert function_exported?(Repo.Port, :aggregate, 4)
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
               :delete,
               :delete_all,
               :exists?,
               :get,
               :get!,
               :get_by,
               :get_by!,
               :insert,
               :insert_all,
               :one,
               :one!,
               :rollback,
               :transact,
               :update,
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
  end

  # -------------------------------------------------------------------
  # Ecto Repo delegation tests (using MockRepo directly as impl)
  # -------------------------------------------------------------------

  describe "Ecto Repo delegation" do
    setup do
      DoubleDown.Testing.set_handler(Repo, MockRepo)
      :ok
    end

    test "insert delegates to mock Repo" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice"}} = Repo.Port.insert(cs)
    end

    test "update delegates to mock Repo" do
      cs = User.changeset(%User{id: 1, name: "old"}, %{name: "new"})
      assert {:ok, %User{name: "new"}} = Repo.Port.update(cs)
    end

    test "delete delegates to mock Repo" do
      record = %User{id: 1, name: "Alice"}
      assert {:ok, ^record} = Repo.Port.delete(record)
    end

    test "get delegates to mock Repo" do
      assert %User{id: 42, name: "found"} = Repo.Port.get(User, 42)
    end

    test "get! delegates to mock Repo" do
      assert %User{id: 42, name: "found!"} = Repo.Port.get!(User, 42)
    end

    test "get_by delegates to mock Repo" do
      assert %User{name: "Alice"} = Repo.Port.get_by(User, name: "Alice")
    end

    test "get_by! delegates to mock Repo" do
      assert %User{name: "Alice"} = Repo.Port.get_by!(User, name: "Alice")
    end

    test "one delegates to mock Repo" do
      assert %User{name: "one"} = Repo.Port.one(User)
    end

    test "one! delegates to mock Repo" do
      assert %User{name: "one!"} = Repo.Port.one!(User)
    end

    test "all delegates to mock Repo" do
      assert [%User{id: 1}, %User{id: 2}] = Repo.Port.all(User)
    end

    test "exists? delegates to mock Repo" do
      assert Repo.Port.exists?(User) == true
    end

    test "aggregate delegates to mock Repo" do
      assert 42 = Repo.Port.aggregate(User, :count, :id)
    end

    test "insert_all delegates to mock Repo" do
      assert {2, nil} = Repo.Port.insert_all(User, [%{name: "a"}, %{name: "b"}], [])
    end

    test "update_all delegates to mock Repo" do
      assert {3, nil} = Repo.Port.update_all(User, [set: [name: "bulk"]], [])
    end

    test "delete_all delegates to mock Repo" do
      assert {5, nil} = Repo.Port.delete_all(User, [])
    end

    test "transact with 0-arity fun delegates to mock Repo" do
      result = Repo.Port.transact(fn -> {:ok, :committed} end, [])
      assert {:ok, :committed} = result
    end

    test "transact with 1-arity fun delegates to mock Repo (receives facade module)" do
      result = Repo.Port.transact(fn repo -> {:ok, repo} end, [])
      # 1-arity fns are wrapped into 0-arity thunks by the facade's pre_dispatch,
      # so the fn receives the facade module (Repo.Port), not the impl (MockRepo).
      assert {:ok, Repo.Port} = result
    end

    test "transact with Ecto.Multi delegates to mock Repo" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))

      assert {:ok, %{user: %User{name: "Alice"}}} = Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi and :run receives the Ecto Repo (MockRepo)" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:check, fn repo, _changes ->
          {:ok, repo}
        end)

      # In the Ecto adapter, :run callbacks receive the underlying Ecto Repo module,
      # not the Port facade. This mirrors real Ecto.Repo.transact/2 behaviour.
      assert {:ok, %{check: MockRepo}} = Repo.Port.transact(multi, [])
    end
  end
end
