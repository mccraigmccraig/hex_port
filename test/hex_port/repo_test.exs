defmodule HexPort.RepoTest do
  use ExUnit.Case, async: true

  alias HexPort.Repo

  setup do
    on_exit(fn -> HexPort.Testing.reset() end)
    :ok
  end

  # -------------------------------------------------------------------
  # Test Schema
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

  describe "HexPort.Repo contract" do
    test "generates Behaviour module with all callbacks" do
      {:module, _} = Code.ensure_loaded(Repo.Behaviour)
      {:ok, callbacks} = Code.Typespec.fetch_callbacks(Repo.Behaviour)
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
    end

    test "generates Port facade module" do
      {:module, _} = Code.ensure_loaded(Repo.Port)

      assert function_exported?(Repo.Port, :insert, 1)
      assert function_exported?(Repo.Port, :update, 1)
      assert function_exported?(Repo.Port, :delete, 1)
      assert function_exported?(Repo.Port, :get, 2)
      assert function_exported?(Repo.Port, :all, 1)
    end

    test "generates bang variants for write operations" do
      {:module, _} = Code.ensure_loaded(Repo.Port)

      # Auto-generated bangs from {:ok, T} return types
      assert function_exported?(Repo.Port, :insert!, 1)
      assert function_exported?(Repo.Port, :update!, 1)
      assert function_exported?(Repo.Port, :delete!, 1)
    end

    test "read bang operations are separate ports (not auto-generated bangs)" do
      ops = Repo.__port_operations__() |> Enum.map(& &1.name)

      # These are declared as defport with bang: false
      assert :get! in ops
      assert :get_by! in ops
      assert :one! in ops
    end

    test "__port_operations__ lists all 14 operations" do
      ops = Repo.__port_operations__()

      assert length(ops) == 14

      op_names = Enum.map(ops, & &1.name) |> Enum.sort()

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
               :one,
               :one!,
               :update,
               :update_all
             ]
    end
  end

  # -------------------------------------------------------------------
  # MockRepo for Ecto delegation tests
  # -------------------------------------------------------------------

  defmodule MockRepo do
    def insert(cs), do: {:ok, Ecto.Changeset.apply_changes(cs)}
    def update(cs), do: {:ok, Ecto.Changeset.apply_changes(cs)}
    def delete(record), do: {:ok, record}
    def update_all(_q, _u, _o), do: {3, nil}
    def delete_all(_q, _o), do: {5, nil}
    def get(_q, id), do: %User{id: id, name: "found"}
    def get!(_q, id), do: %User{id: id, name: "found!"}
    def get_by(_q, clauses), do: %User{id: 1, name: clauses[:name]}
    def get_by!(_q, clauses), do: %User{id: 1, name: clauses[:name]}
    def one(_q), do: %User{id: 1, name: "one"}
    def one!(_q), do: %User{id: 1, name: "one!"}
    def all(_q), do: [%User{id: 1}, %User{id: 2}]
    def exists?(_q), do: true
    def aggregate(_q, _agg, _f), do: 42
  end

  defmodule TestRepoPort do
    use HexPort.Repo.Ecto, repo: MockRepo
  end

  # -------------------------------------------------------------------
  # Repo.Ecto Tests
  # -------------------------------------------------------------------

  describe "Repo.Ecto delegation" do
    setup do
      HexPort.Testing.set_handler(Repo, TestRepoPort)
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

    test "update_all delegates to mock Repo" do
      assert {3, nil} = Repo.Port.update_all(User, [set: [name: "bulk"]], [])
    end

    test "delete_all delegates to mock Repo" do
      assert {5, nil} = Repo.Port.delete_all(User, [])
    end

    test "bang variant unwraps {:ok, value}" do
      cs = User.changeset(%{name: "Alice"})
      assert %User{name: "Alice"} = Repo.Port.insert!(cs)
    end

    test "bang variant raises on {:error, reason}" do
      # Override with an fn handler that returns an error
      HexPort.Testing.set_fn_handler(Repo, fn
        :insert, [_cs] -> {:error, :validation_failed}
      end)

      assert_raise RuntimeError, ~r/insert failed/, fn ->
        Repo.Port.insert!(User.changeset(%{name: "bad"}))
      end
    end
  end

  # -------------------------------------------------------------------
  # Repo.Test Tests
  # -------------------------------------------------------------------

  describe "Repo.Test stateless impl" do
    setup do
      HexPort.Testing.set_handler(Repo, Repo.Test)
      :ok
    end

    test "insert applies changeset and returns {:ok, struct}" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice"}} = Repo.Port.insert(cs)
    end

    test "update applies changeset and returns {:ok, struct}" do
      cs = User.changeset(%User{id: 1, name: "old"}, %{name: "new"})
      assert {:ok, %User{id: 1, name: "new"}} = Repo.Port.update(cs)
    end

    test "delete returns {:ok, record}" do
      record = %User{id: 1, name: "Alice"}
      assert {:ok, ^record} = Repo.Port.delete(record)
    end

    test "read operations return sensible defaults" do
      assert Repo.Port.get(User, 1) == nil
      assert_raise Ecto.NoResultsError, fn -> Repo.Port.get!(User, 1) end
      assert Repo.Port.get_by(User, name: "Alice") == nil
      assert_raise Ecto.NoResultsError, fn -> Repo.Port.get_by!(User, name: "Alice") end
      assert Repo.Port.one(User) == nil
      assert_raise Ecto.NoResultsError, fn -> Repo.Port.one!(User) end
      assert Repo.Port.all(User) == []
      assert Repo.Port.exists?(User) == false
      assert Repo.Port.aggregate(User, :count, :id) == nil
    end

    test "bulk operations return {0, nil}" do
      assert {0, nil} = Repo.Port.update_all(User, [set: [name: "bulk"]], [])
      assert {0, nil} = Repo.Port.delete_all(User, [])
    end

    test "with logging enabled, all dispatches are recorded" do
      HexPort.Testing.enable_log(Repo)
      cs = User.changeset(%{name: "Alice"})

      Repo.Port.insert(cs)
      Repo.Port.get(User, 1)

      log = HexPort.Testing.get_log(Repo)
      assert length(log) == 2

      assert [{Repo, :insert, [^cs], {:ok, %User{name: "Alice"}}}, {Repo, :get, [User, 1], nil}] =
               log
    end
  end

  # -------------------------------------------------------------------
  # Repo.InMemory Tests
  # -------------------------------------------------------------------

  describe "InMemory: seed/1" do
    test "converts list of structs to state map" do
      alice = %User{id: 1, name: "Alice"}
      bob = %User{id: 2, name: "Bob"}
      store = Repo.InMemory.seed([alice, bob])

      assert %{{User, 1} => ^alice, {User, 2} => ^bob} = store
    end

    test "handles multiple schema types" do
      user = %User{id: 1, name: "Alice"}
      post = %Post{id: 1, title: "Hello"}
      store = Repo.InMemory.seed([user, post])

      assert %{{User, 1} => ^user, {Post, 1} => ^post} = store
    end

    test "empty list returns empty map" do
      assert %{} = Repo.InMemory.seed([])
    end
  end

  describe "InMemory: write operations" do
    setup do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        %{}
      )

      :ok
    end

    test "insert stores a record and returns {:ok, struct}" do
      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})
      assert {:ok, %User{name: "Alice", email: "alice@example.com"}} = Repo.Port.insert(cs)
    end

    test "insert auto-assigns id when nil" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{id: 1, name: "Alice"}} = Repo.Port.insert(cs)
    end

    test "insert preserves explicit id" do
      cs = User.changeset(%User{id: 42}, %{name: "Alice"})
      assert {:ok, %User{id: 42, name: "Alice"}} = Repo.Port.insert(cs)
    end

    test "insert auto-id increments based on existing records" do
      initial = Repo.InMemory.seed([%User{id: 5, name: "Existing"}])

      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        initial
      )

      assert {:ok, %User{id: 6, name: "New"}} = Repo.Port.insert(User.changeset(%{name: "New"}))
    end

    test "insert! unwraps the result" do
      cs = User.changeset(%{name: "Alice"})
      assert %User{name: "Alice"} = Repo.Port.insert!(cs)
    end

    test "update updates an existing record in store" do
      Repo.Port.insert(User.changeset(%User{id: 1}, %{name: "Alice", email: "old@example.com"}))
      cs = User.changeset(%User{id: 1, name: "Alice"}, %{email: "new@example.com"})
      assert {:ok, %User{id: 1, email: "new@example.com"}} = Repo.Port.update(cs)
    end

    test "delete removes record from store" do
      {:ok, alice} = Repo.Port.insert(User.changeset(%User{id: 1}, %{name: "Alice"}))
      assert {:ok, ^alice} = Repo.Port.delete(alice)
      assert Repo.Port.get(User, 1) == nil
    end
  end

  describe "InMemory: read operations" do
    setup do
      initial =
        Repo.InMemory.seed([
          %User{id: 1, name: "Alice", email: "alice@example.com"},
          %User{id: 2, name: "Bob", email: "bob@example.com"}
        ])

      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        initial
      )

      :ok
    end

    test "get returns record when found" do
      assert %User{id: 1, name: "Alice"} = Repo.Port.get(User, 1)
    end

    test "get returns nil when not found" do
      assert Repo.Port.get(User, 999) == nil
    end

    test "get! returns record when found" do
      assert %User{id: 1, name: "Alice"} = Repo.Port.get!(User, 1)
    end

    test "get! returns nil when not found" do
      assert Repo.Port.get!(User, 999) == nil
    end

    test "get_by finds record matching keyword clauses" do
      assert %User{name: "Bob"} = Repo.Port.get_by(User, name: "Bob")
    end

    test "get_by returns nil when no match" do
      assert Repo.Port.get_by(User, name: "Nobody") == nil
    end

    test "get_by matches multiple clauses" do
      assert %User{name: "Alice"} =
               Repo.Port.get_by(User, name: "Alice", email: "alice@example.com")
    end

    test "get_by accepts map clauses" do
      assert %User{name: "Alice"} = Repo.Port.get_by(User, %{name: "Alice"})
    end

    test "get_by! finds record matching clauses" do
      assert %User{name: "Bob"} = Repo.Port.get_by!(User, name: "Bob")
    end

    test "one returns a record when schema has records" do
      assert %User{} = Repo.Port.one(User)
    end

    test "one returns nil when no records" do
      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, %{})
      assert Repo.Port.one(User) == nil
    end

    test "one! returns a record when found" do
      assert %User{} = Repo.Port.one!(User)
    end

    test "all returns all records of a schema" do
      result = Repo.Port.all(User)
      assert length(result) == 2
      assert Enum.all?(result, &match?(%User{}, &1))
    end

    test "all returns empty list when no records" do
      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, %{})
      assert Repo.Port.all(User) == []
    end

    test "exists? returns true when records exist" do
      assert Repo.Port.exists?(User) == true
    end

    test "exists? returns false when no records" do
      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, %{})
      assert Repo.Port.exists?(User) == false
    end
  end

  describe "InMemory: aggregate" do
    test "count returns number of records" do
      initial =
        Repo.InMemory.seed([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"},
          %User{id: 3, name: "Charlie"}
        ])

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, initial)
      assert 3 = Repo.Port.aggregate(User, :count, :id)
    end

    test "count returns 0 for empty" do
      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, %{})
      assert 0 = Repo.Port.aggregate(User, :count, :id)
    end

    test "sum aggregates field values" do
      initial =
        Repo.InMemory.seed([
          %User{id: 1, name: "Alice", age: 30},
          %User{id: 2, name: "Bob", age: 25}
        ])

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, initial)
      assert 55 = Repo.Port.aggregate(User, :sum, :age)
    end

    test "min returns minimum value" do
      initial =
        Repo.InMemory.seed([
          %User{id: 1, name: "Alice", age: 30},
          %User{id: 2, name: "Bob", age: 25}
        ])

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, initial)
      assert 25 = Repo.Port.aggregate(User, :min, :age)
    end

    test "max returns maximum value" do
      initial =
        Repo.InMemory.seed([
          %User{id: 1, name: "Alice", age: 30},
          %User{id: 2, name: "Bob", age: 25}
        ])

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, initial)
      assert 30 = Repo.Port.aggregate(User, :max, :age)
    end
  end

  describe "InMemory: bulk operations" do
    test "delete_all removes all records of the given schema" do
      initial =
        Repo.InMemory.seed([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"},
          %Post{id: 1, title: "Hello"}
        ])

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, initial)

      assert {2, nil} = Repo.Port.delete_all(User, [])

      # Post remains, users deleted
      assert Repo.Port.all(Post) == [%Post{id: 1, title: "Hello"}]
      assert Repo.Port.all(User) == []
    end

    test "update_all returns {0, nil} (not supported)" do
      initial = Repo.InMemory.seed([%User{id: 1, name: "Alice"}])
      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, initial)

      assert {0, nil} = Repo.Port.update_all(User, [set: [name: "bulk"]], [])
    end
  end

  describe "InMemory: read-after-write consistency" do
    setup do
      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, %{})
      :ok
    end

    test "insert then get returns the same record" do
      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})
      {:ok, user} = Repo.Port.insert(cs)

      found = Repo.Port.get(User, user.id)
      assert user == found
    end

    test "insert then get_by returns the same record" do
      cs = User.changeset(%{name: "Alice"})
      {:ok, user} = Repo.Port.insert(cs)

      found = Repo.Port.get_by(User, name: "Alice")
      assert user == found
    end

    test "insert then all includes the record" do
      Repo.Port.insert(User.changeset(%{name: "Alice"}))
      Repo.Port.insert(User.changeset(%{name: "Bob"}))

      result = Repo.Port.all(User)
      assert length(result) == 2
      names = Enum.map(result, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob"]
    end

    test "insert then delete then get returns nil" do
      cs = User.changeset(%{name: "Alice"})
      {:ok, user} = Repo.Port.insert(cs)
      Repo.Port.delete(user)

      assert Repo.Port.get(User, user.id) == nil
    end

    test "insert, update, then get returns updated record" do
      {:ok, user} = Repo.Port.insert(User.changeset(%{name: "Alice"}))
      {:ok, updated} = Repo.Port.update(User.changeset(user, %{name: "Alicia"}))

      found = Repo.Port.get(User, user.id)
      assert updated == found
      assert %User{name: "Alicia"} = found
    end

    test "insert affects exists? and aggregate" do
      assert Repo.Port.exists?(User) == false
      assert 0 = Repo.Port.aggregate(User, :count, :id)

      Repo.Port.insert(User.changeset(%{name: "Alice"}))

      assert Repo.Port.exists?(User) == true
      assert 1 = Repo.Port.aggregate(User, :count, :id)
    end
  end

  describe "InMemory: multiple schema types" do
    setup do
      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, %{})
      :ok
    end

    test "different schemas are independent" do
      {:ok, _user} = Repo.Port.insert(User.changeset(%{name: "Alice"}))
      {:ok, _post} = Repo.Port.insert(Post.changeset(%{title: "Hello"}))

      users = Repo.Port.all(User)
      posts = Repo.Port.all(Post)

      assert length(users) == 1
      assert length(posts) == 1
      assert [%User{name: "Alice"}] = users
      assert [%Post{title: "Hello"}] = posts
    end

    test "delete_all only affects target schema" do
      initial =
        Repo.InMemory.seed([
          %User{id: 1, name: "Alice"},
          %Post{id: 1, title: "Hello"}
        ])

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, initial)

      assert {1, nil} = Repo.Port.delete_all(User, [])
      assert Repo.Port.all(Post) == [%Post{id: 1, title: "Hello"}]
    end
  end

  describe "InMemory: seeded state" do
    test "seeded records are available immediately" do
      alice = %User{id: 1, name: "Alice"}
      bob = %User{id: 2, name: "Bob"}
      initial = Repo.InMemory.seed([alice, bob])

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, initial)

      assert ^alice = Repo.Port.get(User, 1)
      assert ^bob = Repo.Port.get(User, 2)
    end

    test "can add to seeded state" do
      initial = Repo.InMemory.seed([%User{id: 1, name: "Alice"}])
      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, initial)

      Repo.Port.insert(User.changeset(%{name: "Bob"}))
      assert length(Repo.Port.all(User)) == 2
    end
  end

  describe "InMemory: dispatch logging" do
    test "logs all operations" do
      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, %{})
      HexPort.Testing.enable_log(Repo)

      cs = User.changeset(%{name: "Alice"})
      {:ok, user} = Repo.Port.insert(cs)
      Repo.Port.get(User, user.id)
      Repo.Port.all(User)

      log = HexPort.Testing.get_log(Repo)
      assert length(log) == 3

      assert [
               {Repo, :insert, [^cs], {:ok, %User{}}},
               {Repo, :get, [User, _], %User{}},
               {Repo, :all, [User], [%User{}]}
             ] = log
    end
  end
end
