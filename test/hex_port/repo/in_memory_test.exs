defmodule HexPort.Repo.InMemoryTest do
  use ExUnit.Case, async: true

  alias HexPort.Repo

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

  defmodule TimestampUser do
    use Ecto.Schema

    schema "timestamp_users" do
      field(:name, :string)
      timestamps()
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  # -------------------------------------------------------------------
  # Direct dispatch/3 unit tests
  # -------------------------------------------------------------------

  describe "dispatch/3: insert with invalid changeset" do
    test "returns {:error, changeset} and leaves store unchanged" do
      store = Repo.InMemory.new()

      cs =
        %User{}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {{:error, %Ecto.Changeset{valid?: false}}, ^store} =
               Repo.InMemory.dispatch(:insert, [cs], store)
    end

    test "does not auto-assign id" do
      store = Repo.InMemory.new()

      cs =
        %User{}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      {{:error, changeset}, _store} = Repo.InMemory.dispatch(:insert, [cs], store)
      assert changeset.changes == %{name: "Alice"}
      # No id was assigned — the changeset data still has nil id
      assert changeset.data.id == nil
    end
  end

  describe "dispatch/3: update with invalid changeset" do
    test "returns {:error, changeset} and leaves store unchanged" do
      alice = %User{id: 1, name: "Alice"}
      store = Repo.InMemory.new(seed: [alice])

      cs =
        alice
        |> Ecto.Changeset.cast(%{name: "Bad"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {{:error, %Ecto.Changeset{valid?: false}}, new_store} =
               Repo.InMemory.dispatch(:update, [cs], store)

      # Store unchanged — original record still present
      assert new_store == store
    end
  end

  describe "dispatch/3: insert with valid changeset" do
    test "returns {:ok, record} and updates store" do
      store = Repo.InMemory.new()
      cs = User.changeset(%{name: "Alice"})

      assert {{:ok, %User{name: "Alice", id: 1}}, new_store} =
               Repo.InMemory.dispatch(:insert, [cs], store)

      assert %{User => %{1 => %User{name: "Alice"}}} = new_store
    end
  end

  describe "dispatch/3: update with valid changeset" do
    test "returns {:ok, record} and updates store" do
      alice = %User{id: 1, name: "Alice"}
      store = Repo.InMemory.new(seed: [alice])
      cs = User.changeset(alice, %{name: "Alicia"})

      assert {{:ok, %User{id: 1, name: "Alicia"}}, new_store} =
               Repo.InMemory.dispatch(:update, [cs], store)

      assert %{User => %{1 => %User{name: "Alicia"}}} = new_store
    end
  end

  # -------------------------------------------------------------------
  # seed/1 and new/1
  # -------------------------------------------------------------------

  describe "seed/1" do
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

  describe "new/1" do
    test "returns empty state with no options" do
      assert %{} = Repo.InMemory.new()
    end

    test "seeds records via :seed option" do
      alice = %User{id: 1, name: "Alice"}
      state = Repo.InMemory.new(seed: [alice])
      assert %{User => %{1 => ^alice}} = state
    end

    test "stores fallback_fn via :fallback_fn option" do
      fallback = fn :all, [User], _state -> [] end
      state = Repo.InMemory.new(fallback_fn: fallback)
      assert %{__fallback_fn__: ^fallback} = state
    end

    test "combines seed and fallback_fn" do
      alice = %User{id: 1, name: "Alice"}
      fallback = fn :all, [User], _state -> [alice] end
      state = Repo.InMemory.new(seed: [alice], fallback_fn: fallback)
      assert %{User => %{1 => ^alice}, __fallback_fn__: ^fallback} = state
    end
  end

  # -------------------------------------------------------------------
  # Write operations (via Port facade)
  # -------------------------------------------------------------------

  describe "write operations" do
    setup do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
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
        Repo.Contract,
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

    test "delete removes record from store and get raises for missing PK" do
      {:ok, alice} = Repo.Port.insert(User.changeset(%User{id: 1}, %{name: "Alice"}))
      assert {:ok, ^alice} = Repo.Port.delete(alice)

      assert_raise ArgumentError, ~r/InMemory cannot service :get/, fn ->
        Repo.Port.get(User, 1)
      end
    end

    test "insert returns {:error, changeset} for invalid changeset and leaves store unchanged" do
      cs =
        %User{}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {:error, %Ecto.Changeset{valid?: false}} = Repo.Port.insert(cs)

      # Store is unchanged — no record was inserted
      assert_raise ArgumentError, ~r/InMemory cannot service :get/, fn ->
        Repo.Port.get(User, 1)
      end
    end

    test "update returns {:error, changeset} for invalid changeset and leaves store unchanged" do
      {:ok, _alice} =
        Repo.Port.insert(User.changeset(%User{id: 1}, %{name: "Alice"}))

      cs =
        %User{id: 1, name: "Alice"}
        |> Ecto.Changeset.cast(%{name: "Bad"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {:error, %Ecto.Changeset{valid?: false}} = Repo.Port.update(cs)

      # Store is unchanged — original record preserved
      assert %User{id: 1, name: "Alice"} = Repo.Port.get(User, 1)
    end

    test "insert! raises for invalid changeset" do
      cs =
        %User{}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert_raise RuntimeError, fn ->
        Repo.Port.insert!(cs)
      end
    end

    test "insert populates inserted_at and updated_at for schemas with timestamps" do
      cs = TimestampUser.changeset(%{name: "Alice"})
      assert {:ok, user} = Repo.Port.insert(cs)

      assert %NaiveDateTime{} = user.inserted_at
      assert %NaiveDateTime{} = user.updated_at
    end

    test "update populates updated_at for schemas with timestamps" do
      cs = TimestampUser.changeset(%{name: "Alice"})
      {:ok, user} = Repo.Port.insert(cs)

      update_cs = TimestampUser.changeset(user, %{name: "Alicia"})
      {:ok, updated} = Repo.Port.update(update_cs)

      assert %NaiveDateTime{} = updated.updated_at
      assert updated.inserted_at == user.inserted_at
    end

    test "insert does not overwrite explicitly set timestamps" do
      explicit_time = ~N[2020-01-01 00:00:00]

      cs =
        %TimestampUser{inserted_at: explicit_time, updated_at: explicit_time}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])

      assert {:ok, user} = Repo.Port.insert(cs)
      assert user.inserted_at == explicit_time
      assert user.updated_at == explicit_time
    end

    test "timestamps are persisted in store and available via get" do
      cs = TimestampUser.changeset(%{name: "Alice"})
      {:ok, user} = Repo.Port.insert(cs)

      found = Repo.Port.get(TimestampUser, user.id)
      assert found.inserted_at == user.inserted_at
      assert found.updated_at == user.updated_at
    end

    test "schemas without timestamps are unaffected by autogeneration" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice"}} = Repo.Port.insert(cs)
    end
  end

  # -------------------------------------------------------------------
  # PK read operations (3-stage)
  # -------------------------------------------------------------------

  describe "PK read operations (3-stage)" do
    setup do
      initial =
        Repo.InMemory.new(
          seed: [
            %User{id: 1, name: "Alice", email: "alice@example.com"},
            %User{id: 2, name: "Bob", email: "bob@example.com"}
          ]
        )

      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
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
          fallback_fn: fn :get, [User, 99], _state -> bob end
        )

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)

      # Found in state
      assert %User{id: 1, name: "Alice"} = Repo.Port.get(User, 1)
      # Falls through to fallback
      assert ^bob = Repo.Port.get(User, 99)
    end

    test "get raises when fallback doesn't match" do
      state =
        Repo.InMemory.new(fallback_fn: fn :get, [User, 42], _state -> nil end)

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)

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
          fallback_fn: fn :get!, [User, 99], _state -> bob end
        )

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)

      assert %User{id: 1, name: "Alice"} = Repo.Port.get!(User, 1)
      assert ^bob = Repo.Port.get!(User, 99)
    end
  end

  # -------------------------------------------------------------------
  # Non-PK read operations (2-stage)
  # -------------------------------------------------------------------

  describe "non-PK read operations (2-stage)" do
    test "get_by requires fallback" do
      alice = %User{id: 1, name: "Alice", email: "alice@example.com"}

      state =
        Repo.InMemory.new(
          seed: [alice],
          fallback_fn: fn
            :get_by, [User, [name: "Alice"]], _state -> alice
            :get_by, [User, [name: "Alice", email: "alice@example.com"]], _state -> alice
            :get_by, [User, %{name: "Alice"}], _state -> alice
            :get_by, [User, [name: "Nobody"]], _state -> nil
          end
        )

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)

      assert %User{name: "Alice"} = Repo.Port.get_by(User, name: "Alice")

      assert %User{name: "Alice"} =
               Repo.Port.get_by(User, name: "Alice", email: "alice@example.com")

      assert %User{name: "Alice"} = Repo.Port.get_by(User, %{name: "Alice"})
      assert nil == Repo.Port.get_by(User, name: "Nobody")
    end

    test "get_by raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
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
        Repo.InMemory.new(fallback_fn: fn :get_by!, [User, [name: "Bob"]], _state -> bob end)

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)
      assert %User{name: "Bob"} = Repo.Port.get_by!(User, name: "Bob")
    end

    test "one requires fallback" do
      alice = %User{id: 1, name: "Alice"}

      state =
        Repo.InMemory.new(fallback_fn: fn :one, [User], _state -> alice end)

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)
      assert %User{name: "Alice"} = Repo.Port.one(User)
    end

    test "one raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
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
        Repo.InMemory.new(fallback_fn: fn :one!, [User], _state -> alice end)

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)
      assert %User{name: "Alice"} = Repo.Port.one!(User)
    end

    test "all requires fallback" do
      users = [%User{id: 1, name: "Alice"}, %User{id: 2, name: "Bob"}]

      state =
        Repo.InMemory.new(fallback_fn: fn :all, [User], _state -> users end)

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)

      result = Repo.Port.all(User)
      assert length(result) == 2
      assert Enum.all?(result, &match?(%User{}, &1))
    end

    test "all raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
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
            :exists?, [User], _state -> true
          end
        )

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)
      assert Repo.Port.exists?(User) == true
    end

    test "exists? raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :exists\?/, fn ->
        Repo.Port.exists?(User)
      end
    end
  end

  # -------------------------------------------------------------------
  # Aggregate (requires fallback)
  # -------------------------------------------------------------------

  describe "aggregate (requires fallback)" do
    test "aggregate dispatches to fallback" do
      state =
        Repo.InMemory.new(
          fallback_fn: fn
            :aggregate, [User, :count, :id], _state -> 3
            :aggregate, [User, :sum, :age], _state -> 55
            :aggregate, [User, :min, :age], _state -> 25
            :aggregate, [User, :max, :age], _state -> 30
          end
        )

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)

      assert 3 = Repo.Port.aggregate(User, :count, :id)
      assert 55 = Repo.Port.aggregate(User, :sum, :age)
      assert 25 = Repo.Port.aggregate(User, :min, :age)
      assert 30 = Repo.Port.aggregate(User, :max, :age)
    end

    test "aggregate raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :aggregate/, fn ->
        Repo.Port.aggregate(User, :count, :id)
      end
    end
  end

  # -------------------------------------------------------------------
  # Bulk operations (require fallback)
  # -------------------------------------------------------------------

  describe "bulk operations (require fallback)" do
    test "insert_all dispatches to fallback" do
      entries = [%{name: "a"}, %{name: "b"}]

      state =
        Repo.InMemory.new(
          fallback_fn: fn :insert_all, [User, ^entries, []], _state -> {2, nil} end
        )

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)
      assert {2, nil} = Repo.Port.insert_all(User, entries, [])
    end

    test "insert_all raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :insert_all/, fn ->
        Repo.Port.insert_all(User, [%{name: "a"}], [])
      end
    end

    test "delete_all dispatches to fallback" do
      state =
        Repo.InMemory.new(fallback_fn: fn :delete_all, [User, []], _state -> {2, nil} end)

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)
      assert {2, nil} = Repo.Port.delete_all(User, [])
    end

    test "delete_all raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
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
          fallback_fn: fn :update_all, [User, [set: [name: "bulk"]], []], _state -> {3, nil} end
        )

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)
      assert {3, nil} = Repo.Port.update_all(User, [set: [name: "bulk"]], [])
    end

    test "update_all raises without fallback" do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :update_all/, fn ->
        Repo.Port.update_all(User, [set: [name: "bulk"]], [])
      end
    end
  end

  # -------------------------------------------------------------------
  # Transactions
  # -------------------------------------------------------------------

  describe "transact" do
    setup do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      :ok
    end

    test "transact with 0-arity fun calls function and returns result" do
      assert {:ok, :committed} = Repo.Port.transact(fn -> {:ok, :committed} end, [])
    end

    test "transact with 1-arity fun receives facade module" do
      assert {:ok, Repo.Port} = Repo.Port.transact(fn repo -> {:ok, repo} end, [])
    end

    test "transact with 1-arity fun can call back into facade" do
      result =
        Repo.Port.transact(
          fn repo ->
            {:ok, user} = repo.insert(User.changeset(%{name: "Alice"}))
            found = repo.get(User, user.id)
            {:ok, {user, found}}
          end,
          []
        )

      assert {:ok, {%User{name: "Alice"} = user, %User{name: "Alice"} = found}} = result
      assert user == found
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

  # -------------------------------------------------------------------
  # Read-after-write consistency (PK reads)
  # -------------------------------------------------------------------

  describe "read-after-write consistency (PK reads)" do
    setup do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
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

  # -------------------------------------------------------------------
  # Multiple schema types
  # -------------------------------------------------------------------

  describe "multiple schema types" do
    test "different schemas are stored independently (PK reads)" do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      {:ok, user} = Repo.Port.insert(User.changeset(%{name: "Alice"}))
      {:ok, post} = Repo.Port.insert(Post.changeset(%{title: "Hello"}))

      assert ^user = Repo.Port.get(User, user.id)
      assert ^post = Repo.Port.get(Post, post.id)
    end
  end

  # -------------------------------------------------------------------
  # Seeded state
  # -------------------------------------------------------------------

  describe "seeded state" do
    test "seeded records are available via PK read" do
      alice = %User{id: 1, name: "Alice"}
      bob = %User{id: 2, name: "Bob"}
      state = Repo.InMemory.new(seed: [alice, bob])

      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)

      assert ^alice = Repo.Port.get(User, 1)
      assert ^bob = Repo.Port.get(User, 2)
    end

    test "can add to seeded state and read back by PK" do
      state = Repo.InMemory.new(seed: [%User{id: 1, name: "Alice"}])
      HexPort.Testing.set_stateful_handler(Repo.Contract, &Repo.InMemory.dispatch/3, state)

      {:ok, bob} = Repo.Port.insert(User.changeset(%{name: "Bob"}))
      assert ^bob = Repo.Port.get(User, bob.id)
      assert %User{name: "Alice"} = Repo.Port.get(User, 1)
    end
  end

  # -------------------------------------------------------------------
  # Dispatch logging
  # -------------------------------------------------------------------

  describe "dispatch logging" do
    test "logs write and PK read operations" do
      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new()
      )

      HexPort.Testing.enable_log(Repo.Contract)

      cs = User.changeset(%{name: "Alice"})
      {:ok, user} = Repo.Port.insert(cs)
      Repo.Port.get(User, user.id)

      log = HexPort.Testing.get_log(Repo.Contract)
      assert length(log) == 2

      assert [
               {Repo.Contract, :insert, [^cs], {:ok, %User{}}},
               {Repo.Contract, :get, [User, _], %User{}}
             ] = log
    end

    test "logs fallback-dispatched operations" do
      users = [%User{id: 1, name: "Alice"}]

      HexPort.Testing.set_stateful_handler(
        Repo.Contract,
        &Repo.InMemory.dispatch/3,
        Repo.InMemory.new(fallback_fn: fn :all, [User], _state -> users end)
      )

      HexPort.Testing.enable_log(Repo.Contract)

      Repo.Port.all(User)

      log = HexPort.Testing.get_log(Repo.Contract)
      assert length(log) == 1
      assert [{Repo.Contract, :all, [User], [%User{id: 1, name: "Alice"}]}] = log
    end
  end
end
