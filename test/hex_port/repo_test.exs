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
      assert :transact in callback_names
    end

    test "Port facade (defined via use HexPort.Port) has all operations" do
      {:module, _} = Code.ensure_loaded(Repo.Port)

      assert function_exported?(Repo.Port, :insert, 1)
      assert function_exported?(Repo.Port, :update, 1)
      assert function_exported?(Repo.Port, :delete, 1)
      assert function_exported?(Repo.Port, :get, 2)
      assert function_exported?(Repo.Port, :all, 1)
      assert function_exported?(Repo.Port, :transact, 2)
    end

    test "Port facade has bang variants for write operations" do
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

    test "__port_operations__ lists all 15 operations" do
      ops = Repo.__port_operations__()

      assert length(ops) == 15

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

    def transact(fun, _opts) when is_function(fun, 0), do: fun.()
    def transact(fun, _opts) when is_function(fun, 1), do: fun.(__MODULE__)

    def transact(%Ecto.Multi{} = multi, _opts) do
      # Simulate what a real Ecto Repo does: step through the Multi
      # using this module as the repo for :run callbacks
      HexPort.Repo.MultiStepper.run(multi, __MODULE__)
    end
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

    test "transact with 0-arity fun delegates to mock Repo" do
      result = Repo.Port.transact(fn -> {:ok, :committed} end, [])
      assert {:ok, :committed} = result
    end

    test "transact with 1-arity fun delegates to mock Repo (receives repo module)" do
      result = Repo.Port.transact(fn repo -> {:ok, repo} end, [])
      assert {:ok, MockRepo} = result
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

    test "transact with 0-arity fun calls the function" do
      assert {:ok, :done} = Repo.Port.transact(fn -> {:ok, :done} end, [])
    end

    test "transact with 1-arity fun passes nil" do
      assert {:ok, nil} = Repo.Port.transact(fn repo -> {:ok, repo} end, [])
    end

    test "transact propagates error tuples" do
      assert {:error, :rollback} = Repo.Port.transact(fn -> {:error, :rollback} end, [])
    end

    test "transact with Ecto.Multi executes insert operations" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.insert(:post, Post.changeset(%{title: "Hello"}))

      assert {:ok, %{user: %User{name: "Alice"}, post: %Post{title: "Hello"}}} =
               Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi rejects invalid changesets" do
      invalid = %Ecto.Changeset{valid?: false, action: :insert, errors: [name: {"required", []}]}

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, invalid)

      assert {:error, :user, %Ecto.Changeset{valid?: false}, %{}} =
               Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi handles :run operations" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:value, fn _repo, _changes -> {:ok, 42} end)

      assert {:ok, %{value: 42}} = Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi :run receives repo facade" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:repo_check, fn repo, _changes -> {:ok, repo} end)

      assert {:ok, %{repo_check: Repo.Port}} = Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi :run failure returns 4-tuple error" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.run(:fail, fn _repo, _changes -> {:error, :boom} end)

      assert {:error, :fail, :boom, %{user: %User{name: "Alice"}}} =
               Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi :put adds static values" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.put(:greeting, "hello")

      assert {:ok, %{greeting: "hello"}} = Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi :merge composes sub-Multis" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.merge(fn %{user: user} ->
          Ecto.Multi.new()
          |> Ecto.Multi.insert(:post, Post.changeset(%{title: "by #{user.name}"}))
        end)

      assert {:ok, %{user: %User{name: "Alice"}, post: %Post{title: "by Alice"}}} =
               Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi :error causes immediate failure" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.error(:fail, :forced_error)
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))

      assert {:error, :fail, :forced_error, %{}} = Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi passes changes to dependent :run operations" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.run(:greeting, fn _repo, %{user: user} ->
          {:ok, "Hello, #{user.name}!"}
        end)

      assert {:ok, %{user: %User{name: "Alice"}, greeting: "Hello, Alice!"}} =
               Repo.Port.transact(multi, [])
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
    test "converts list of structs to nested state map" do
      alice = %User{id: 1, name: "Alice"}
      bob = %User{id: 2, name: "Bob"}
      store = Repo.InMemory.seed([alice, bob])

      assert %{User => %{1 => ^alice, 2 => ^bob}} = store
    end

    test "handles multiple schema types" do
      user = %User{id: 1, name: "Alice"}
      post = %Post{id: 1, title: "Hello"}
      store = Repo.InMemory.seed([user, post])

      assert %{User => %{1 => ^user}, Post => %{1 => ^post}} = store
    end

    test "empty list returns empty map" do
      assert %{} = Repo.InMemory.seed([])
    end
  end

  describe "InMemory: new/1" do
    test "returns empty state with no options" do
      assert %{} = Repo.InMemory.new()
    end

    test "seeds records via :seed option" do
      alice = %User{id: 1, name: "Alice"}
      state = Repo.InMemory.new(seed: [alice])
      assert %{User => %{1 => ^alice}} = state
    end

    test "stores fallback_fn via :fallback_fn option" do
      fallback = fn :all, [User] -> [] end
      state = Repo.InMemory.new(fallback_fn: fallback)
      assert %{__fallback_fn__: ^fallback} = state
    end

    test "combines seed and fallback_fn" do
      alice = %User{id: 1, name: "Alice"}
      fallback = fn :all, [User] -> [alice] end
      state = Repo.InMemory.new(seed: [alice], fallback_fn: fallback)
      assert %{User => %{1 => ^alice}, __fallback_fn__: ^fallback} = state
    end
  end

  describe "InMemory: write operations" do
    setup do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
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
      initial = Repo.InMemory.new(seed: [%User{id: 5, name: "Existing"}])

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

    test "delete removes record from store and get returns nil for missing PK" do
      {:ok, alice} = Repo.Port.insert(User.changeset(%User{id: 1}, %{name: "Alice"}))
      assert {:ok, ^alice} = Repo.Port.delete(alice)
      # get with missing PK and no fallback raises
      assert_raise ArgumentError, ~r/InMemory cannot service :get/, fn ->
        Repo.Port.get(User, 1)
      end
    end
  end

  describe "InMemory: PK read operations (3-stage)" do
    setup do
      initial =
        Repo.InMemory.new(
          seed: [
            %User{id: 1, name: "Alice", email: "alice@example.com"},
            %User{id: 2, name: "Bob", email: "bob@example.com"}
          ]
        )

      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        initial
      )

      :ok
    end

    test "get returns record from state when found" do
      assert %User{id: 1, name: "Alice"} = Repo.Port.get(User, 1)
    end

    test "get raises when not found in state and no fallback" do
      assert_raise ArgumentError, ~r/InMemory cannot service :get/, fn ->
        Repo.Port.get(User, 999)
      end
    end

    test "get falls through to fallback when not found in state" do
      bob = %User{id: 99, name: "Fallback Bob"}

      state =
        Repo.InMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn :get, [User, 99] -> bob end
        )

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)

      # Found in state
      assert %User{id: 1, name: "Alice"} = Repo.Port.get(User, 1)
      # Falls through to fallback
      assert ^bob = Repo.Port.get(User, 99)
    end

    test "get raises when fallback doesn't match" do
      state =
        Repo.InMemory.new(fallback_fn: fn :get, [User, 42] -> nil end)

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)

      assert_raise ArgumentError, ~r/InMemory cannot service :get/, fn ->
        Repo.Port.get(User, 999)
      end
    end

    test "get! returns record from state when found" do
      assert %User{id: 1, name: "Alice"} = Repo.Port.get!(User, 1)
    end

    test "get! raises when not found in state and no fallback" do
      assert_raise ArgumentError, ~r/InMemory cannot service :get!/, fn ->
        Repo.Port.get!(User, 999)
      end
    end

    test "get! falls through to fallback when not found in state" do
      bob = %User{id: 99, name: "Fallback Bob"}

      state =
        Repo.InMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn :get!, [User, 99] -> bob end
        )

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)

      assert %User{id: 1, name: "Alice"} = Repo.Port.get!(User, 1)
      assert ^bob = Repo.Port.get!(User, 99)
    end
  end

  describe "InMemory: non-PK read operations (2-stage)" do
    test "get_by requires fallback" do
      alice = %User{id: 1, name: "Alice", email: "alice@example.com"}

      state =
        Repo.InMemory.new(
          seed: [alice],
          fallback_fn: fn
            :get_by, [User, [name: "Alice"]] -> alice
            :get_by, [User, [name: "Alice", email: "alice@example.com"]] -> alice
            :get_by, [User, %{name: "Alice"}] -> alice
            :get_by, [User, [name: "Nobody"]] -> nil
          end
        )

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)

      assert %User{name: "Alice"} = Repo.Port.get_by(User, name: "Alice")

      assert %User{name: "Alice"} =
               Repo.Port.get_by(User, name: "Alice", email: "alice@example.com")

      assert %User{name: "Alice"} = Repo.Port.get_by(User, %{name: "Alice"})
      assert nil == Repo.Port.get_by(User, name: "Nobody")
    end

    test "get_by raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :get_by/, fn ->
        Repo.Port.get_by(User, name: "Alice")
      end
    end

    test "get_by! requires fallback" do
      bob = %User{id: 2, name: "Bob"}

      state =
        Repo.InMemory.new(fallback_fn: fn :get_by!, [User, [name: "Bob"]] -> bob end)

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)
      assert %User{name: "Bob"} = Repo.Port.get_by!(User, name: "Bob")
    end

    test "one requires fallback" do
      alice = %User{id: 1, name: "Alice"}

      state =
        Repo.InMemory.new(fallback_fn: fn :one, [User] -> alice end)

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)
      assert %User{name: "Alice"} = Repo.Port.one(User)
    end

    test "one raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :one/, fn ->
        Repo.Port.one(User)
      end
    end

    test "one! requires fallback" do
      alice = %User{id: 1, name: "Alice"}

      state =
        Repo.InMemory.new(fallback_fn: fn :one!, [User] -> alice end)

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)
      assert %User{name: "Alice"} = Repo.Port.one!(User)
    end

    test "all requires fallback" do
      users = [%User{id: 1, name: "Alice"}, %User{id: 2, name: "Bob"}]

      state =
        Repo.InMemory.new(fallback_fn: fn :all, [User] -> users end)

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)

      result = Repo.Port.all(User)
      assert length(result) == 2
      assert Enum.all?(result, &match?(%User{}, &1))
    end

    test "all raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :all/, fn ->
        Repo.Port.all(User)
      end
    end

    test "exists? requires fallback" do
      state =
        Repo.InMemory.new(
          fallback_fn: fn
            :exists?, [User] -> true
          end
        )

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)
      assert Repo.Port.exists?(User) == true
    end

    test "exists? raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :exists\?/, fn ->
        Repo.Port.exists?(User)
      end
    end
  end

  describe "InMemory: aggregate (requires fallback)" do
    test "aggregate dispatches to fallback" do
      state =
        Repo.InMemory.new(
          fallback_fn: fn
            :aggregate, [User, :count, :id] -> 3
            :aggregate, [User, :sum, :age] -> 55
            :aggregate, [User, :min, :age] -> 25
            :aggregate, [User, :max, :age] -> 30
          end
        )

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)

      assert 3 = Repo.Port.aggregate(User, :count, :id)
      assert 55 = Repo.Port.aggregate(User, :sum, :age)
      assert 25 = Repo.Port.aggregate(User, :min, :age)
      assert 30 = Repo.Port.aggregate(User, :max, :age)
    end

    test "aggregate raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :aggregate/, fn ->
        Repo.Port.aggregate(User, :count, :id)
      end
    end
  end

  describe "InMemory: bulk operations (require fallback)" do
    test "delete_all dispatches to fallback" do
      state =
        Repo.InMemory.new(fallback_fn: fn :delete_all, [User, []] -> {2, nil} end)

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)
      assert {2, nil} = Repo.Port.delete_all(User, [])
    end

    test "delete_all raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :delete_all/, fn ->
        Repo.Port.delete_all(User, [])
      end
    end

    test "update_all dispatches to fallback" do
      state =
        Repo.InMemory.new(
          fallback_fn: fn :update_all, [User, [set: [name: "bulk"]], []] -> {3, nil} end
        )

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)
      assert {3, nil} = Repo.Port.update_all(User, [set: [name: "bulk"]], [])
    end

    test "update_all raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :update_all/, fn ->
        Repo.Port.update_all(User, [set: [name: "bulk"]], [])
      end
    end
  end

  describe "InMemory: transact" do
    setup do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      :ok
    end

    test "transact with 0-arity fun calls function and returns result" do
      assert {:ok, :committed} = Repo.Port.transact(fn -> {:ok, :committed} end, [])
    end

    test "transact with 1-arity fun passes nil and returns result" do
      assert {:ok, nil} = Repo.Port.transact(fn repo -> {:ok, repo} end, [])
    end

    test "transact propagates error tuples" do
      assert {:error, :rollback} = Repo.Port.transact(fn -> {:error, :rollback} end, [])
    end

    test "transact with insert gives read-after-write within transaction" do
      result =
        Repo.Port.transact(
          fn ->
            {:ok, user} = Repo.Port.insert(User.changeset(%{name: "Alice"}))
            found = Repo.Port.get(User, user.id)
            {:ok, {user, found}}
          end,
          []
        )

      assert {:ok, {%User{name: "Alice"} = user, %User{name: "Alice"} = found}} = result
      assert user == found
    end

    test "transact with Ecto.Multi executes insert operations" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.insert(:post, Post.changeset(%{title: "Hello"}))

      assert {:ok, %{user: %User{name: "Alice"}, post: %Post{title: "Hello"}}} =
               Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi gives read-after-write via :run" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.run(:found, fn repo, %{user: user} ->
          {:ok, repo.get(User, user.id)}
        end)

      assert {:ok, %{user: %User{name: "Alice"} = user, found: %User{name: "Alice"} = found}} =
               Repo.Port.transact(multi, [])

      assert user == found
    end

    test "transact with Ecto.Multi rejects invalid changesets" do
      invalid = %Ecto.Changeset{valid?: false, action: :insert, errors: [name: {"required", []}]}

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, invalid)

      assert {:error, :user, %Ecto.Changeset{valid?: false}, %{}} =
               Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi :run failure returns 4-tuple error" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.run(:fail, fn _repo, _changes -> {:error, :boom} end)

      assert {:error, :fail, :boom, %{user: %User{name: "Alice"}}} =
               Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi :run receives Repo.Port as facade" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:repo_check, fn repo, _changes -> {:ok, repo} end)

      assert {:ok, %{repo_check: Repo.Port}} = Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi :merge composes sub-Multis" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.merge(fn %{user: user} ->
          Ecto.Multi.new()
          |> Ecto.Multi.insert(:post, Post.changeset(%{title: "by #{user.name}"}))
        end)

      assert {:ok, %{user: %User{name: "Alice"}, post: %Post{title: "by Alice"}}} =
               Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi :put adds static values" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.put(:greeting, "hello")

      assert {:ok, %{greeting: "hello"}} = Repo.Port.transact(multi, [])
    end

    test "transact with Ecto.Multi persists insert to InMemory store" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))

      {:ok, %{user: user}} = Repo.Port.transact(multi, [])

      # Verify the record is accessible via PK read outside the Multi
      assert user == Repo.Port.get(User, user.id)
    end
  end

  describe "InMemory: read-after-write consistency (PK reads)" do
    setup do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      :ok
    end

    test "insert then get returns the same record" do
      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})
      {:ok, user} = Repo.Port.insert(cs)

      found = Repo.Port.get(User, user.id)
      assert user == found
    end

    test "insert then delete then get raises (no fallback)" do
      cs = User.changeset(%{name: "Alice"})
      {:ok, user} = Repo.Port.insert(cs)
      Repo.Port.delete(user)

      assert_raise ArgumentError, ~r/InMemory cannot service :get/, fn ->
        Repo.Port.get(User, user.id)
      end
    end

    test "insert, update, then get returns updated record" do
      {:ok, user} = Repo.Port.insert(User.changeset(%{name: "Alice"}))
      {:ok, updated} = Repo.Port.update(User.changeset(user, %{name: "Alicia"}))

      found = Repo.Port.get(User, user.id)
      assert updated == found
      assert %User{name: "Alicia"} = found
    end
  end

  describe "InMemory: multiple schema types" do
    test "different schemas are stored independently (PK reads)" do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      {:ok, user} = Repo.Port.insert(User.changeset(%{name: "Alice"}))
      {:ok, post} = Repo.Port.insert(Post.changeset(%{title: "Hello"}))

      assert ^user = Repo.Port.get(User, user.id)
      assert ^post = Repo.Port.get(Post, post.id)
    end
  end

  describe "InMemory: seeded state" do
    test "seeded records are available via PK read" do
      alice = %User{id: 1, name: "Alice"}
      bob = %User{id: 2, name: "Bob"}
      state = Repo.InMemory.new(seed: [alice, bob])

      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)

      assert ^alice = Repo.Port.get(User, 1)
      assert ^bob = Repo.Port.get(User, 2)
    end

    test "can add to seeded state and read back by PK" do
      state = Repo.InMemory.new(seed: [%User{id: 1, name: "Alice"}])
      HexPort.Testing.set_stateful_handler(Repo, &Repo.InMemory.dispatch/3, state)

      {:ok, bob} = Repo.Port.insert(User.changeset(%{name: "Bob"}))
      assert ^bob = Repo.Port.get(User, bob.id)
      assert %User{name: "Alice"} = Repo.Port.get(User, 1)
    end
  end

  describe "InMemory: dispatch logging" do
    test "logs write and PK read operations" do
      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      HexPort.Testing.enable_log(Repo)

      cs = User.changeset(%{name: "Alice"})
      {:ok, user} = Repo.Port.insert(cs)
      Repo.Port.get(User, user.id)

      log = HexPort.Testing.get_log(Repo)
      assert length(log) == 2

      assert [
               {Repo, :insert, [^cs], {:ok, %User{}}},
               {Repo, :get, [User, _], %User{}}
             ] = log
    end

    test "logs fallback-dispatched operations" do
      users = [%User{id: 1, name: "Alice"}]

      HexPort.Testing.set_stateful_handler(
        Repo,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new(fallback_fn: fn :all, [User] -> users end)
      )

      HexPort.Testing.enable_log(Repo)

      Repo.Port.all(User)

      log = HexPort.Testing.get_log(Repo)
      assert length(log) == 1
      assert [{Repo, :all, [User], [%User{id: 1, name: "Alice"}]}] = log
    end
  end
end
