defmodule DoubleDown.Repo.OpenInMemoryTest do
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

  defmodule BinaryIdUser do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "binary_id_users" do
      field(:name, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  defmodule UuidUser do
    use Ecto.Schema

    @primary_key {:uuid, Ecto.UUID, autogenerate: true}
    schema "uuid_users" do
      field(:name, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  defmodule NoAutoIdUser do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "no_auto_id_users" do
      field(:name, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user
      |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  defmodule NoPkEvent do
    use Ecto.Schema

    @primary_key false
    schema "events" do
      field(:name, :string)
    end

    def changeset(event \\ %__MODULE__{}, attrs) do
      event
      |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  defmodule CompositePkMembership do
    use Ecto.Schema

    @primary_key false
    schema "memberships" do
      field(:user_id, :integer, primary_key: true)
      field(:org_id, :integer, primary_key: true)
      field(:role, :string)
    end

    def changeset(membership \\ %__MODULE__{}, attrs) do
      membership
      |> Ecto.Changeset.cast(attrs, [:user_id, :org_id, :role])
    end
  end

  # -------------------------------------------------------------------
  # Direct dispatch/4 unit tests
  # -------------------------------------------------------------------

  describe "dispatch/4: insert with invalid changeset" do
    test "returns {:error, changeset} and leaves store unchanged" do
      store = Repo.OpenInMemory.new()

      cs =
        %User{}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {{:error, %Ecto.Changeset{valid?: false}}, ^store} =
               Repo.OpenInMemory.dispatch(DoubleDown.Repo, :insert, [cs], store)
    end

    test "does not auto-assign id" do
      store = Repo.OpenInMemory.new()

      cs =
        %User{}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      {{:error, changeset}, _store} =
        Repo.OpenInMemory.dispatch(DoubleDown.Repo, :insert, [cs], store)

      assert changeset.changes == %{name: "Alice"}
      # No id was assigned — the changeset data still has nil id
      assert changeset.data.id == nil
    end
  end

  describe "dispatch/4: update with invalid changeset" do
    test "returns {:error, changeset} and leaves store unchanged" do
      alice = %User{id: 1, name: "Alice"}
      store = Repo.OpenInMemory.new(seed: [alice])

      cs =
        alice
        |> Ecto.Changeset.cast(%{name: "Bad"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {{:error, %Ecto.Changeset{valid?: false}}, new_store} =
               Repo.OpenInMemory.dispatch(DoubleDown.Repo, :update, [cs], store)

      # Store unchanged — original record still present
      assert new_store == store
    end
  end

  describe "dispatch/4: insert with valid changeset" do
    test "returns {:ok, record} and updates store" do
      store = Repo.OpenInMemory.new()
      cs = User.changeset(%{name: "Alice"})

      assert {{:ok, %User{name: "Alice", id: 1}}, new_store} =
               Repo.OpenInMemory.dispatch(DoubleDown.Repo, :insert, [cs], store)

      assert %{User => %{1 => %User{name: "Alice"}}} = new_store
    end
  end

  describe "dispatch/4: update with valid changeset" do
    test "returns {:ok, record} and updates store" do
      alice = %User{id: 1, name: "Alice"}
      store = Repo.OpenInMemory.new(seed: [alice])
      cs = User.changeset(alice, %{name: "Alicia"})

      assert {{:ok, %User{id: 1, name: "Alicia"}}, new_store} =
               Repo.OpenInMemory.dispatch(DoubleDown.Repo, :update, [cs], store)

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
      store = Repo.OpenInMemory.seed([alice, bob])

      assert %{User => %{1 => ^alice, 2 => ^bob}} = store
    end

    test "handles multiple schema types" do
      user = %User{id: 1, name: "Alice"}
      post = %Post{id: 1, title: "Hello"}
      store = Repo.OpenInMemory.seed([user, post])

      assert %{User => %{1 => ^user}, Post => %{1 => ^post}} = store
    end

    test "empty list returns empty map" do
      assert %{} = Repo.OpenInMemory.seed([])
    end
  end

  describe "new/1" do
    test "returns empty state with no options" do
      assert %{} = Repo.OpenInMemory.new()
    end

    test "seeds records via :seed option" do
      alice = %User{id: 1, name: "Alice"}
      state = Repo.OpenInMemory.new(seed: [alice])
      assert %{User => %{1 => ^alice}} = state
    end

    test "stores fallback_fn via :fallback_fn option" do
      fallback = fn _contract, :all, [User], _state -> [] end
      state = Repo.OpenInMemory.new(fallback_fn: fallback)
      assert %{__fallback_fn__: ^fallback} = state
    end

    test "combines seed and fallback_fn" do
      alice = %User{id: 1, name: "Alice"}
      fallback = fn _contract, :all, [User], _state -> [alice] end
      state = Repo.OpenInMemory.new(seed: [alice], fallback_fn: fallback)
      assert %{User => %{1 => ^alice}, __fallback_fn__: ^fallback} = state
    end
  end

  # -------------------------------------------------------------------
  # Write operations (via Port facade)
  # -------------------------------------------------------------------

  describe "write operations" do
    setup do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      :ok
    end

    test "insert stores a record and returns {:ok, struct}" do
      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})
      assert {:ok, %User{name: "Alice", email: "alice@example.com"}} = TestRepo.insert(cs)
    end

    test "insert auto-assigns id when nil" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{id: 1, name: "Alice"}} = TestRepo.insert(cs)
    end

    test "insert preserves explicit id" do
      cs = User.changeset(%User{id: 42}, %{name: "Alice"})
      assert {:ok, %User{id: 42, name: "Alice"}} = TestRepo.insert(cs)
    end

    test "insert auto-id increments based on existing records" do
      initial = Repo.OpenInMemory.new(seed: [%User{id: 5, name: "Existing"}])

      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        initial
      )

      assert {:ok, %User{id: 6, name: "New"}} = TestRepo.insert(User.changeset(%{name: "New"}))
    end

    test "update updates an existing record in store" do
      TestRepo.insert(User.changeset(%User{id: 1}, %{name: "Alice", email: "old@example.com"}))
      cs = User.changeset(%User{id: 1, name: "Alice"}, %{email: "new@example.com"})
      assert {:ok, %User{id: 1, email: "new@example.com"}} = TestRepo.update(cs)
    end

    test "delete removes record from store and get raises for missing PK" do
      {:ok, alice} = TestRepo.insert(User.changeset(%User{id: 1}, %{name: "Alice"}))
      assert {:ok, ^alice} = TestRepo.delete(alice)

      assert_raise ArgumentError, ~r/InMemory cannot service :get/, fn ->
        TestRepo.get(User, 1)
      end
    end

    test "insert returns {:error, changeset} for invalid changeset and leaves store unchanged" do
      cs =
        %User{}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {:error, %Ecto.Changeset{valid?: false}} = TestRepo.insert(cs)

      # Store is unchanged — no record was inserted
      assert_raise ArgumentError, ~r/InMemory cannot service :get/, fn ->
        TestRepo.get(User, 1)
      end
    end

    test "update returns {:error, changeset} for invalid changeset and leaves store unchanged" do
      {:ok, _alice} =
        TestRepo.insert(User.changeset(%User{id: 1}, %{name: "Alice"}))

      cs =
        %User{id: 1, name: "Alice"}
        |> Ecto.Changeset.cast(%{name: "Bad"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {:error, %Ecto.Changeset{valid?: false}} = TestRepo.update(cs)

      # Store is unchanged — original record preserved
      assert %User{id: 1, name: "Alice"} = TestRepo.get(User, 1)
    end

    test "insert populates inserted_at and updated_at for schemas with timestamps" do
      cs = TimestampUser.changeset(%{name: "Alice"})
      assert {:ok, user} = TestRepo.insert(cs)

      assert %NaiveDateTime{} = user.inserted_at
      assert %NaiveDateTime{} = user.updated_at
    end

    test "update populates updated_at for schemas with timestamps" do
      cs = TimestampUser.changeset(%{name: "Alice"})
      {:ok, user} = TestRepo.insert(cs)

      update_cs = TimestampUser.changeset(user, %{name: "Alicia"})
      {:ok, updated} = TestRepo.update(update_cs)

      assert %NaiveDateTime{} = updated.updated_at
      assert updated.inserted_at == user.inserted_at
    end

    test "insert does not overwrite explicitly set timestamps" do
      explicit_time = ~N[2020-01-01 00:00:00]

      cs =
        %TimestampUser{inserted_at: explicit_time, updated_at: explicit_time}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])

      assert {:ok, user} = TestRepo.insert(cs)
      assert user.inserted_at == explicit_time
      assert user.updated_at == explicit_time
    end

    test "timestamps are persisted in store and available via get" do
      cs = TimestampUser.changeset(%{name: "Alice"})
      {:ok, user} = TestRepo.insert(cs)

      found = TestRepo.get(TimestampUser, user.id)
      assert found.inserted_at == user.inserted_at
      assert found.updated_at == user.updated_at
    end

    test "schemas without timestamps are unaffected by autogeneration" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice"}} = TestRepo.insert(cs)
    end
  end

  # -------------------------------------------------------------------
  # insert_or_update / insert_or_update!
  # -------------------------------------------------------------------

  describe "insert_or_update" do
    setup do
      DoubleDown.Double.fake(DoubleDown.Repo, Repo.OpenInMemory)
      :ok
    end

    test "inserts when changeset data is :built (new struct)" do
      cs = User.changeset(%{name: "Alice"})
      assert Ecto.get_meta(cs.data, :state) == :built

      {:ok, user} = TestRepo.insert_or_update(cs)
      assert user.name == "Alice"
      assert user.id != nil
    end

    test "updates when changeset data is :loaded (existing struct)" do
      {:ok, user} = TestRepo.insert(User.changeset(%{name: "Alice"}))
      assert Ecto.get_meta(user, :state) == :loaded

      cs = User.changeset(user, %{name: "Alice Updated"})
      {:ok, updated} = TestRepo.insert_or_update(cs)
      assert updated.name == "Alice Updated"
      assert updated.id == user.id
    end

    test "returns error for invalid changeset" do
      cs =
        User.changeset(%{name: "Alice"})
        |> Ecto.Changeset.add_error(:name, "is bad")

      assert {:error, %Ecto.Changeset{}} = TestRepo.insert_or_update(cs)
    end

    test "accepts opts" do
      cs = User.changeset(%{name: "Alice"})
      {:ok, user} = TestRepo.insert_or_update(cs, returning: true)
      assert user.name == "Alice"
    end
  end

  describe "insert_or_update!" do
    setup do
      DoubleDown.Double.fake(DoubleDown.Repo, Repo.OpenInMemory)
      :ok
    end

    test "inserts new struct and returns record" do
      cs = User.changeset(%{name: "Bob"})
      user = TestRepo.insert_or_update!(cs)
      assert user.name == "Bob"
    end

    test "updates loaded struct and returns record" do
      {:ok, user} = TestRepo.insert(User.changeset(%{name: "Bob"}))
      cs = User.changeset(user, %{name: "Bob Updated"})
      updated = TestRepo.insert_or_update!(cs)
      assert updated.name == "Bob Updated"
    end

    test "raises on invalid changeset" do
      cs =
        User.changeset(%{name: "Bob"})
        |> Ecto.Changeset.add_error(:name, "is bad")

      assert_raise Ecto.InvalidChangesetError, fn ->
        TestRepo.insert_or_update!(cs)
      end
    end
  end

  # -------------------------------------------------------------------
  # Primary key autogeneration variants
  # -------------------------------------------------------------------

  describe "PK autogeneration" do
    setup do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      :ok
    end

    test "integer :id PK is auto-incremented" do
      assert {:ok, %User{id: 1}} = TestRepo.insert(User.changeset(%{name: "Alice"}))
      assert {:ok, %User{id: 2}} = TestRepo.insert(User.changeset(%{name: "Bob"}))
    end

    test "integer :id PK preserves explicit value" do
      cs = User.changeset(%User{id: 42}, %{name: "Alice"})
      assert {:ok, %User{id: 42}} = TestRepo.insert(cs)
    end

    test ":binary_id PK is auto-generated as UUID" do
      cs = BinaryIdUser.changeset(%{name: "Alice"})
      assert {:ok, user} = TestRepo.insert(cs)
      assert is_binary(user.id)
      # Verify it's a valid UUID format (8-4-4-4-12 hex)
      assert user.id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    end

    test ":binary_id PK preserves explicit value" do
      explicit_id = Ecto.UUID.generate()
      cs = BinaryIdUser.changeset(%BinaryIdUser{id: explicit_id}, %{name: "Alice"})
      assert {:ok, %BinaryIdUser{id: ^explicit_id}} = TestRepo.insert(cs)
    end

    test ":binary_id PK is retrievable via get after insert" do
      {:ok, user} = TestRepo.insert(BinaryIdUser.changeset(%{name: "Alice"}))
      assert user == TestRepo.get(BinaryIdUser, user.id)
    end

    test "Ecto.UUID PK is auto-generated via autogenerate metadata" do
      cs = UuidUser.changeset(%{name: "Alice"})
      assert {:ok, user} = TestRepo.insert(cs)
      assert is_binary(user.uuid)
      assert user.uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    end

    test "Ecto.UUID PK preserves explicit value" do
      explicit_uuid = Ecto.UUID.generate()
      cs = UuidUser.changeset(%UuidUser{uuid: explicit_uuid}, %{name: "Alice"})
      assert {:ok, %UuidUser{uuid: ^explicit_uuid}} = TestRepo.insert(cs)
    end

    test "Ecto.UUID PK is retrievable via get after insert" do
      {:ok, user} = TestRepo.insert(UuidUser.changeset(%{name: "Alice"}))
      assert user == TestRepo.get(UuidUser, user.uuid)
    end

    test "no autogenerate configured raises on nil PK" do
      cs = NoAutoIdUser.changeset(%{name: "Alice"})

      assert_raise ArgumentError, ~r/Cannot autogenerate primary key/, fn ->
        TestRepo.insert(cs)
      end
    end

    test "no autogenerate works with explicit PK" do
      explicit_id = Ecto.UUID.generate()
      cs = NoAutoIdUser.changeset(%NoAutoIdUser{id: explicit_id}, %{name: "Alice"})
      assert {:ok, %NoAutoIdUser{id: ^explicit_id}} = TestRepo.insert(cs)
    end

    test "@primary_key false schema inserts without error" do
      cs = NoPkEvent.changeset(%{name: "thing_happened"})
      assert {:ok, %NoPkEvent{name: "thing_happened"}} = TestRepo.insert(cs)
    end

    test "@primary_key false schema preserves multiple inserts" do
      {:ok, _} = TestRepo.insert(NoPkEvent.changeset(%{name: "a"}))
      {:ok, _} = TestRepo.insert(NoPkEvent.changeset(%{name: "b"}))
      {:ok, _} = TestRepo.insert(NoPkEvent.changeset(%{name: "c"}))

      # OpenInMemory is open-world so all/1 requires a fallback;
      # verify via the store directly.
      store = DoubleDown.Contract.Dispatch.get_state(Repo)
      events = DoubleDown.Repo.Impl.InMemoryShared.records_for_schema(store, NoPkEvent)
      assert length(events) == 3
      names = Enum.map(events, & &1.name) |> Enum.sort()
      assert names == ["a", "b", "c"]
    end
  end

  # -------------------------------------------------------------------
  # PK read operations (3-stage)
  # -------------------------------------------------------------------

  describe "PK read operations (3-stage)" do
    setup do
      initial =
        Repo.OpenInMemory.new(
          seed: [
            %User{id: 1, name: "Alice", email: "alice@example.com"},
            %User{id: 2, name: "Bob", email: "bob@example.com"}
          ]
        )

      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        initial
      )

      :ok
    end

    test "get returns record from state when found" do
      assert %User{id: 1, name: "Alice"} = TestRepo.get(User, 1)
    end

    test "get raises when not found in state and no fallback" do
      assert_raise ArgumentError, ~r/InMemory cannot service :get/, fn ->
        TestRepo.get(User, 999)
      end
    end

    test "get falls through to fallback when not found in state" do
      bob = %User{id: 99, name: "Fallback Bob"}

      state =
        Repo.OpenInMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn _contract, :get, [User, 99], _state -> bob end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      # Found in state
      assert %User{id: 1, name: "Alice"} = TestRepo.get(User, 1)
      # Falls through to fallback
      assert ^bob = TestRepo.get(User, 99)
    end

    test "get raises when fallback doesn't match" do
      state =
        Repo.OpenInMemory.new(fallback_fn: fn _contract, :get, [User, 42], _state -> nil end)

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert_raise ArgumentError, ~r/InMemory cannot service :get/, fn ->
        TestRepo.get(User, 999)
      end
    end

    test "get! returns record from state when found" do
      assert %User{id: 1, name: "Alice"} = TestRepo.get!(User, 1)
    end

    test "get! raises when not found in state and no fallback" do
      assert_raise ArgumentError, ~r/InMemory cannot service :get!/, fn ->
        TestRepo.get!(User, 999)
      end
    end

    test "get! falls through to fallback when not found in state" do
      bob = %User{id: 99, name: "Fallback Bob"}

      state =
        Repo.OpenInMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn _contract, :get!, [User, 99], _state -> bob end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert %User{id: 1, name: "Alice"} = TestRepo.get!(User, 1)
      assert ^bob = TestRepo.get!(User, 99)
    end
  end

  # -------------------------------------------------------------------
  # get_by / get_by! with PK-inclusive clauses (3-stage)
  # -------------------------------------------------------------------

  describe "get_by with PK-inclusive clauses (3-stage)" do
    test "get_by returns record from state when PK is in clauses" do
      alice = %User{id: 1, name: "Alice", email: "alice@example.com"}
      state = Repo.OpenInMemory.new(seed: [alice])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert %User{id: 1, name: "Alice"} = TestRepo.get_by(User, id: 1)
    end

    test "get_by with PK and extra fields matching returns record" do
      alice = %User{id: 1, name: "Alice", email: "alice@example.com"}
      state = Repo.OpenInMemory.new(seed: [alice])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert %User{id: 1, name: "Alice"} = TestRepo.get_by(User, id: 1, name: "Alice")
    end

    test "get_by with PK and extra fields not matching returns nil" do
      alice = %User{id: 1, name: "Alice", email: "alice@example.com"}
      state = Repo.OpenInMemory.new(seed: [alice])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert nil == TestRepo.get_by(User, id: 1, name: "NotAlice")
    end

    test "get_by with PK falls through to fallback when not in state" do
      bob = %User{id: 99, name: "Fallback Bob"}

      state =
        Repo.OpenInMemory.new(
          seed: [%User{id: 1, name: "Alice"}],
          fallback_fn: fn _contract, :get_by, [User, [id: 99]], _state -> bob end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      # Found in state
      assert %User{id: 1, name: "Alice"} = TestRepo.get_by(User, id: 1)
      # Falls through to fallback
      assert ^bob = TestRepo.get_by(User, id: 99)
    end

    test "get_by with PK raises when not in state and no fallback" do
      state = Repo.OpenInMemory.new(seed: [%User{id: 1, name: "Alice"}])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert_raise ArgumentError, ~r/InMemory cannot service :get_by/, fn ->
        TestRepo.get_by(User, id: 999)
      end
    end

    test "get_by with PK works with map clauses" do
      alice = %User{id: 1, name: "Alice", email: "alice@example.com"}
      state = Repo.OpenInMemory.new(seed: [alice])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert %User{id: 1, name: "Alice"} = TestRepo.get_by(User, %{id: 1})
      assert %User{id: 1, name: "Alice"} = TestRepo.get_by(User, %{id: 1, name: "Alice"})
      assert nil == TestRepo.get_by(User, %{id: 1, name: "NotAlice"})
    end

    test "get_by with binary_id PK returns record from state" do
      uuid = Ecto.UUID.generate()
      user = %BinaryIdUser{id: uuid, name: "Alice"}
      state = Repo.OpenInMemory.new(seed: [user])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert %BinaryIdUser{name: "Alice"} = TestRepo.get_by(BinaryIdUser, id: uuid)
    end

    test "get_by without PK in clauses delegates to fallback" do
      alice = %User{id: 1, name: "Alice", email: "alice@example.com"}

      state =
        Repo.OpenInMemory.new(
          seed: [alice],
          fallback_fn: fn _contract, :get_by, [User, [name: "Alice"]], _state -> alice end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert %User{name: "Alice"} = TestRepo.get_by(User, name: "Alice")
    end

    test "get_by with Ecto.Query delegates to fallback" do
      alice = %User{id: 1, name: "Alice"}
      query = Ecto.Queryable.to_query(User)

      state =
        Repo.OpenInMemory.new(
          fallback_fn: fn _contract, :get_by, [^query, [name: "Alice"]], _state -> alice end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert %User{name: "Alice"} = TestRepo.get_by(query, name: "Alice")
    end

    test "get_by with composite PK returns record when all PK fields present" do
      membership = %CompositePkMembership{user_id: 1, org_id: 10, role: "admin"}
      state = Repo.OpenInMemory.new(seed: [membership])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert %CompositePkMembership{role: "admin"} =
               TestRepo.get_by(CompositePkMembership, user_id: 1, org_id: 10)
    end

    test "get_by with composite PK and extra fields matching" do
      membership = %CompositePkMembership{user_id: 1, org_id: 10, role: "admin"}
      state = Repo.OpenInMemory.new(seed: [membership])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert %CompositePkMembership{role: "admin"} =
               TestRepo.get_by(CompositePkMembership, user_id: 1, org_id: 10, role: "admin")
    end

    test "get_by with composite PK and extra fields not matching returns nil" do
      membership = %CompositePkMembership{user_id: 1, org_id: 10, role: "admin"}
      state = Repo.OpenInMemory.new(seed: [membership])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert nil ==
               TestRepo.get_by(CompositePkMembership, user_id: 1, org_id: 10, role: "member")
    end

    test "get_by with partial composite PK delegates to fallback" do
      membership = %CompositePkMembership{user_id: 1, org_id: 10, role: "admin"}

      state =
        Repo.OpenInMemory.new(
          seed: [membership],
          fallback_fn: fn
            _contract, :get_by, [CompositePkMembership, [user_id: 1]], _state -> membership
          end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      # Only one PK field — must delegate to fallback
      assert %CompositePkMembership{role: "admin"} =
               TestRepo.get_by(CompositePkMembership, user_id: 1)
    end
  end

  describe "get_by! with PK-inclusive clauses (3-stage)" do
    test "get_by! returns record from state when PK is in clauses" do
      alice = %User{id: 1, name: "Alice"}
      state = Repo.OpenInMemory.new(seed: [alice])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert %User{id: 1, name: "Alice"} = TestRepo.get_by!(User, id: 1)
    end

    test "get_by! with PK falls through to fallback when not in state" do
      bob = %User{id: 99, name: "Fallback Bob"}

      state =
        Repo.OpenInMemory.new(
          fallback_fn: fn _contract, :get_by!, [User, [id: 99]], _state -> bob end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert ^bob = TestRepo.get_by!(User, id: 99)
    end

    test "get_by! with PK raises when not in state and no fallback" do
      state = Repo.OpenInMemory.new()
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert_raise ArgumentError, ~r/InMemory cannot service :get_by!/, fn ->
        TestRepo.get_by!(User, id: 999)
      end
    end

    test "get_by! with PK and extra fields not matching raises Ecto.NoResultsError" do
      alice = %User{id: 1, name: "Alice"}
      state = Repo.OpenInMemory.new(seed: [alice])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      # get_by! raises when PK found but extra fields don't match,
      # matching real Ecto.Repo.get_by!/2 behaviour
      assert_raise Ecto.NoResultsError, fn ->
        TestRepo.get_by!(User, id: 1, name: "NotAlice")
      end
    end
  end

  # -------------------------------------------------------------------
  # reload / reload! (PK-based, authoritative from state)
  # -------------------------------------------------------------------

  describe "reload (open-world)" do
    setup do
      DoubleDown.Double.fake(DoubleDown.Repo, Repo.OpenInMemory)
      :ok
    end

    test "reloads existing record from state" do
      {:ok, user} = TestRepo.insert(User.changeset(%{name: "Alice"}))
      reloaded = TestRepo.reload(user)
      assert reloaded.name == "Alice"
    end

    test "returns nil for missing record" do
      missing = %User{id: 999, name: "Ghost"}
      assert TestRepo.reload(missing) == nil
    end

    test "reflects updated values" do
      {:ok, user} = TestRepo.insert(User.changeset(%{name: "Alice"}))
      {:ok, _} = TestRepo.update(User.changeset(user, %{name: "Updated"}))
      reloaded = TestRepo.reload(user)
      assert reloaded.name == "Updated"
    end
  end

  describe "reload! (open-world)" do
    setup do
      DoubleDown.Double.fake(DoubleDown.Repo, Repo.OpenInMemory)
      :ok
    end

    test "reloads existing record" do
      {:ok, user} = TestRepo.insert(User.changeset(%{name: "Alice"}))
      reloaded = TestRepo.reload!(user)
      assert reloaded.name == "Alice"
    end

    test "raises for missing record" do
      missing = %User{id: 999, name: "Ghost"}

      assert_raise RuntimeError, ~r/could not reload/, fn ->
        TestRepo.reload!(missing)
      end
    end
  end

  # -------------------------------------------------------------------
  # all_by (open-world — always fallback)
  # -------------------------------------------------------------------

  describe "all_by (requires fallback)" do
    test "delegates to fallback" do
      alice = %User{id: 1, name: "Alice", age: 30}
      bob = %User{id: 2, name: "Bob", age: 30}

      state =
        Repo.OpenInMemory.new(
          seed: [alice, bob],
          fallback_fn: fn
            _contract, :all_by, [User, [age: 30]], state ->
              state |> Map.get(User, %{}) |> Map.values()
              |> Enum.filter(&(&1.age == 30))
          end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)
      users = TestRepo.all_by(User, age: 30)
      assert length(users) == 2
    end

    test "raises without fallback" do
      state = Repo.OpenInMemory.new()
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert_raise ArgumentError, ~r/cannot service :all_by/, fn ->
        TestRepo.all_by(User, age: 30)
      end
    end
  end

  # -------------------------------------------------------------------
  # Non-PK read operations (2-stage)
  # -------------------------------------------------------------------

  describe "non-PK read operations (2-stage)" do
    test "get_by requires fallback" do
      alice = %User{id: 1, name: "Alice", email: "alice@example.com"}

      state =
        Repo.OpenInMemory.new(
          seed: [alice],
          fallback_fn: fn
            _contract, :get_by, [User, [name: "Alice"]], _state ->
              alice

            _contract, :get_by, [User, [name: "Alice", email: "alice@example.com"]], _state ->
              alice

            _contract, :get_by, [User, %{name: "Alice"}], _state ->
              alice

            _contract, :get_by, [User, [name: "Nobody"]], _state ->
              nil
          end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert %User{name: "Alice"} = TestRepo.get_by(User, name: "Alice")

      assert %User{name: "Alice"} =
               TestRepo.get_by(User, name: "Alice", email: "alice@example.com")

      assert %User{name: "Alice"} = TestRepo.get_by(User, %{name: "Alice"})
      assert nil == TestRepo.get_by(User, name: "Nobody")
    end

    test "get_by raises without fallback" do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :get_by/, fn ->
        TestRepo.get_by(User, name: "Alice")
      end
    end

    test "get_by! requires fallback" do
      bob = %User{id: 2, name: "Bob"}

      state =
        Repo.OpenInMemory.new(
          fallback_fn: fn _contract, :get_by!, [User, [name: "Bob"]], _state -> bob end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)
      assert %User{name: "Bob"} = TestRepo.get_by!(User, name: "Bob")
    end

    test "one requires fallback" do
      alice = %User{id: 1, name: "Alice"}

      state =
        Repo.OpenInMemory.new(fallback_fn: fn _contract, :one, [User], _state -> alice end)

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)
      assert %User{name: "Alice"} = TestRepo.one(User)
    end

    test "one raises without fallback" do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :one/, fn ->
        TestRepo.one(User)
      end
    end

    test "one! requires fallback" do
      alice = %User{id: 1, name: "Alice"}

      state =
        Repo.OpenInMemory.new(fallback_fn: fn _contract, :one!, [User], _state -> alice end)

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)
      assert %User{name: "Alice"} = TestRepo.one!(User)
    end

    test "all requires fallback" do
      users = [%User{id: 1, name: "Alice"}, %User{id: 2, name: "Bob"}]

      state =
        Repo.OpenInMemory.new(fallback_fn: fn _contract, :all, [User], _state -> users end)

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      result = TestRepo.all(User)
      assert length(result) == 2
      assert Enum.all?(result, &match?(%User{}, &1))
    end

    test "all raises without fallback" do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :all/, fn ->
        TestRepo.all(User)
      end
    end

    test "exists? requires fallback" do
      state =
        Repo.OpenInMemory.new(
          fallback_fn: fn
            _contract, :exists?, [User], _state -> true
          end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)
      assert TestRepo.exists?(User) == true
    end

    test "exists? raises without fallback" do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :exists\?/, fn ->
        TestRepo.exists?(User)
      end
    end
  end

  # -------------------------------------------------------------------
  # Aggregate (requires fallback)
  # -------------------------------------------------------------------

  describe "aggregate (requires fallback)" do
    test "aggregate dispatches to fallback" do
      state =
        Repo.OpenInMemory.new(
          fallback_fn: fn
            _contract, :aggregate, [User, :count, :id], _state -> 3
            _contract, :aggregate, [User, :sum, :age], _state -> 55
            _contract, :aggregate, [User, :min, :age], _state -> 25
            _contract, :aggregate, [User, :max, :age], _state -> 30
          end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert 3 = TestRepo.aggregate(User, :count, :id)
      assert 55 = TestRepo.aggregate(User, :sum, :age)
      assert 25 = TestRepo.aggregate(User, :min, :age)
      assert 30 = TestRepo.aggregate(User, :max, :age)
    end

    test "aggregate raises without fallback" do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :aggregate/, fn ->
        TestRepo.aggregate(User, :count, :id)
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
        Repo.OpenInMemory.new(
          fallback_fn: fn _contract, :insert_all, [User, ^entries, []], _state -> {2, nil} end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)
      assert {2, nil} = TestRepo.insert_all(User, entries, [])
    end

    test "insert_all raises without fallback" do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :insert_all/, fn ->
        TestRepo.insert_all(User, [%{name: "a"}], [])
      end
    end

    test "delete_all dispatches to fallback" do
      state =
        Repo.OpenInMemory.new(
          fallback_fn: fn _contract, :delete_all, [User, []], _state -> {2, nil} end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)
      assert {2, nil} = TestRepo.delete_all(User, [])
    end

    test "delete_all raises without fallback" do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :delete_all/, fn ->
        TestRepo.delete_all(User, [])
      end
    end

    test "update_all dispatches to fallback" do
      state =
        Repo.OpenInMemory.new(
          fallback_fn: fn _contract, :update_all, [User, [set: [name: "bulk"]], []], _state ->
            {3, nil}
          end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)
      assert {3, nil} = TestRepo.update_all(User, [set: [name: "bulk"]], [])
    end

    test "update_all raises without fallback" do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      assert_raise ArgumentError, ~r/InMemory cannot service :update_all/, fn ->
        TestRepo.update_all(User, [set: [name: "bulk"]], [])
      end
    end
  end

  # -------------------------------------------------------------------
  # Transactions
  # -------------------------------------------------------------------

  describe "transact" do
    setup do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      :ok
    end

    test "transact with 0-arity fun calls function and returns result" do
      assert {:ok, :committed} = TestRepo.transact(fn -> {:ok, :committed} end, [])
    end

    test "transact with 1-arity fun receives facade module" do
      assert {:ok, TestRepo} = TestRepo.transact(fn repo -> {:ok, repo} end, [])
    end

    test "transact with 1-arity fun can call back into facade" do
      result =
        TestRepo.transact(
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
      assert {:error, :rollback} = TestRepo.transact(fn -> {:error, :rollback} end, [])
    end

    test "transact with insert gives read-after-write within transaction" do
      result =
        TestRepo.transact(
          fn ->
            {:ok, user} = TestRepo.insert(User.changeset(%{name: "Alice"}))
            found = TestRepo.get(User, user.id)
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
               TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi gives read-after-write via :run" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.run(:found, fn repo, %{user: user} ->
          {:ok, repo.get(User, user.id)}
        end)

      assert {:ok, %{user: %User{name: "Alice"} = user, found: %User{name: "Alice"} = found}} =
               TestRepo.transact(multi, [])

      assert user == found
    end

    test "transact with Ecto.Multi rejects invalid changesets" do
      invalid = %Ecto.Changeset{valid?: false, action: :insert, errors: [name: {"required", []}]}

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, invalid)

      assert {:error, :user, %Ecto.Changeset{valid?: false}, %{}} =
               TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi :run failure returns 4-tuple error" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.run(:fail, fn _repo, _changes -> {:error, :boom} end)

      assert {:error, :fail, :boom, %{user: %User{name: "Alice"}}} =
               TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi :run receives TestRepo as facade" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:repo_check, fn repo, _changes -> {:ok, repo} end)

      assert {:ok, %{repo_check: TestRepo}} = TestRepo.transact(multi, [])
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
               TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi :put adds static values" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.put(:greeting, "hello")

      assert {:ok, %{greeting: "hello"}} = TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi persists insert to InMemory store" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))

      {:ok, %{user: user}} = TestRepo.transact(multi, [])

      # Verify the record is accessible via PK read outside the Multi
      assert user == TestRepo.get(User, user.id)
    end
  end

  # -------------------------------------------------------------------
  # Read-after-write consistency (PK reads)
  # -------------------------------------------------------------------

  describe "read-after-write consistency (PK reads)" do
    setup do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      :ok
    end

    test "insert then get returns the same record" do
      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})
      {:ok, user} = TestRepo.insert(cs)

      found = TestRepo.get(User, user.id)
      assert user == found
    end

    test "insert then delete then get raises (no fallback)" do
      cs = User.changeset(%{name: "Alice"})
      {:ok, user} = TestRepo.insert(cs)
      TestRepo.delete(user)

      assert_raise ArgumentError, ~r/InMemory cannot service :get/, fn ->
        TestRepo.get(User, user.id)
      end
    end

    test "insert, update, then get returns updated record" do
      {:ok, user} = TestRepo.insert(User.changeset(%{name: "Alice"}))
      {:ok, updated} = TestRepo.update(User.changeset(user, %{name: "Alicia"}))

      found = TestRepo.get(User, user.id)
      assert updated == found
      assert %User{name: "Alicia"} = found
    end
  end

  # -------------------------------------------------------------------
  # Multiple schema types
  # -------------------------------------------------------------------

  describe "multiple schema types" do
    test "different schemas are stored independently (PK reads)" do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      {:ok, user} = TestRepo.insert(User.changeset(%{name: "Alice"}))
      {:ok, post} = TestRepo.insert(Post.changeset(%{title: "Hello"}))

      assert ^user = TestRepo.get(User, user.id)
      assert ^post = TestRepo.get(Post, post.id)
    end
  end

  # -------------------------------------------------------------------
  # Seeded state
  # -------------------------------------------------------------------

  describe "seeded state" do
    test "seeded records are available via PK read" do
      alice = %User{id: 1, name: "Alice"}
      bob = %User{id: 2, name: "Bob"}
      state = Repo.OpenInMemory.new(seed: [alice, bob])

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert ^alice = TestRepo.get(User, 1)
      assert ^bob = TestRepo.get(User, 2)
    end

    test "can add to seeded state and read back by PK" do
      state = Repo.OpenInMemory.new(seed: [%User{id: 1, name: "Alice"}])
      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      {:ok, bob} = TestRepo.insert(User.changeset(%{name: "Bob"}))
      assert ^bob = TestRepo.get(User, bob.id)
      assert %User{name: "Alice"} = TestRepo.get(User, 1)
    end
  end

  # -------------------------------------------------------------------
  # Dispatch logging
  # -------------------------------------------------------------------

  describe "dispatch logging" do
    test "logs write and PK read operations" do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      DoubleDown.Testing.enable_log(Repo)

      cs = User.changeset(%{name: "Alice"})
      {:ok, user} = TestRepo.insert(cs)
      TestRepo.get(User, user.id)

      log = DoubleDown.Testing.get_log(Repo)
      assert length(log) == 2

      assert [
               {Repo, :insert, [^cs], {:ok, %User{}}},
               {Repo, :get, [User, _], %User{}}
             ] = log
    end

    test "logs fallback-dispatched operations" do
      users = [%User{id: 1, name: "Alice"}]

      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new(fallback_fn: fn _contract, :all, [User], _state -> users end)
      )

      DoubleDown.Testing.enable_log(Repo)

      TestRepo.all(User)

      log = DoubleDown.Testing.get_log(Repo)
      assert length(log) == 1
      assert [{Repo, :all, [User], [%User{id: 1, name: "Alice"}]}] = log
    end

    test "1-arity transact logs inner facade calls made from the transaction function" do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      DoubleDown.Testing.enable_log(Repo)

      cs = User.changeset(%{name: "Alice"})

      TestRepo.transact(
        fn repo ->
          {:ok, user} = repo.insert(cs)
          found = repo.get(User, user.id)
          {:ok, {user, found}}
        end,
        []
      )

      log = DoubleDown.Testing.get_log(Repo)

      # Inner calls are logged first (during deferred fn execution), then
      # the outer transact call is logged when it completes.
      assert length(log) == 3

      assert [
               {Repo, :insert, [^cs], {:ok, %User{name: "Alice"}}},
               {Repo, :get, [User, _], %User{name: "Alice"}},
               {Repo, :transact, _, {:ok, {%User{name: "Alice"}, %User{name: "Alice"}}}}
             ] = log
    end
  end

  # -------------------------------------------------------------------
  # Fallback error boundary
  # -------------------------------------------------------------------

  describe "fallback error boundary" do
    test "fallback raising RuntimeError does not crash the ownership server" do
      state =
        Repo.OpenInMemory.new(
          fallback_fn: fn _contract, :all, [User], _state ->
            raise RuntimeError, "boom from fallback"
          end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      # The RuntimeError is re-raised in the calling process, not in the GenServer
      assert_raise RuntimeError, ~r/boom from fallback/, fn ->
        TestRepo.all(User)
      end

      # The ownership server is still alive — subsequent operations work
      assert {:ok, %User{name: "Alice"}} = TestRepo.insert(User.changeset(%{name: "Alice"}))
    end

    test "fallback raising ArgumentError does not crash the ownership server" do
      state =
        Repo.OpenInMemory.new(
          fallback_fn: fn _contract, :get_by, [User, [name: "Alice"]], _state ->
            raise ArgumentError, "bad argument in fallback"
          end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      assert_raise ArgumentError, ~r/bad argument in fallback/, fn ->
        TestRepo.get_by(User, name: "Alice")
      end

      # Ownership server still works
      assert {:ok, %User{name: "Bob"}} = TestRepo.insert(User.changeset(%{name: "Bob"}))
    end

    test "FunctionClauseError from fallback still treated as missing clause" do
      state =
        Repo.OpenInMemory.new(
          fallback_fn: fn _contract, :all, [User], _state -> [%User{id: 1, name: "Alice"}] end
        )

      DoubleDown.Testing.set_stateful_handler(Repo, &Repo.OpenInMemory.dispatch/4, state)

      # Matching clause works
      assert [%User{name: "Alice"}] = TestRepo.all(User)

      # Non-matching clause raises the "cannot service" error, not FunctionClauseError
      assert_raise ArgumentError, ~r/InMemory cannot service :exists\?/, fn ->
        TestRepo.exists?(User)
      end
    end
  end

  # -------------------------------------------------------------------
  # Nested transact
  # -------------------------------------------------------------------

  describe "nested transact" do
    setup do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      :ok
    end

    test "nested transact with inner function" do
      result =
        TestRepo.transact(
          fn repo ->
            repo.transact(fn -> {:ok, :inner_done} end, [])
          end,
          []
        )

      assert {:ok, :inner_done} = result
    end

    test "nested transact with read-after-write across nesting" do
      result =
        TestRepo.transact(
          fn repo ->
            {:ok, user} = repo.insert(User.changeset(%User{}, %{name: "Alice"}))

            {:ok, found} =
              repo.transact(
                fn ->
                  found = repo.get(User, user.id)
                  {:ok, found}
                end,
                []
              )

            {:ok, {user, found}}
          end,
          []
        )

      assert {:ok, {%User{name: "Alice"}, %User{name: "Alice"}}} = result
    end

    test "nested transact with inner Multi" do
      result =
        TestRepo.transact(
          fn repo ->
            multi =
              Ecto.Multi.new()
              |> Ecto.Multi.insert(:user, User.changeset(%User{}, %{name: "Alice"}))

            repo.transact(multi, [])
          end,
          []
        )

      assert {:ok, %{user: %User{name: "Alice"}}} = result
    end
  end

  describe "nested transact via Double.fake" do
    test "nested transact works via Double.fake (no deadlock)" do
      DoubleDown.Double.fake(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      result =
        TestRepo.transact(
          fn repo ->
            {:ok, user} = repo.insert(User.changeset(%User{}, %{name: "Alice"}))

            {:ok, found} =
              repo.transact(
                fn ->
                  found = repo.get(User, user.id)
                  {:ok, found}
                end,
                []
              )

            {:ok, {user, found}}
          end,
          []
        )

      assert {:ok, {%User{name: "Alice"}, %User{name: "Alice"}}} = result
    end
  end

  # -------------------------------------------------------------------
  # Rollback
  # -------------------------------------------------------------------

  describe "rollback" do
    setup do
      DoubleDown.Testing.set_stateful_handler(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      :ok
    end

    test "rollback inside transact returns {:error, value}" do
      result =
        TestRepo.transact(
          fn repo ->
            repo.rollback(:something_went_wrong)
          end,
          []
        )

      assert {:error, :something_went_wrong} = result
    end

    test "rollback stops execution" do
      test_pid = self()

      result =
        TestRepo.transact(
          fn repo ->
            repo.rollback(:early_exit)
            send(test_pid, :should_not_reach)
            {:ok, :unreachable}
          end,
          []
        )

      assert {:error, :early_exit} = result
      refute_received :should_not_reach
    end

    test "rollback after insert — insert is NOT rolled back (documented limitation)" do
      result =
        TestRepo.transact(
          fn repo ->
            {:ok, _user} = repo.insert(User.changeset(%User{}, %{name: "Alice"}))
            repo.rollback(:oops)
          end,
          []
        )

      assert {:error, :oops} = result

      # The insert persists in InMemory state — no true rollback
      # This is a documented limitation of the test adapter
    end
  end

  describe "rollback via Double.fake" do
    test "rollback works via Double.fake" do
      DoubleDown.Double.fake(
        Repo,
        &Repo.OpenInMemory.dispatch/4,
        Repo.OpenInMemory.new()
      )

      result =
        TestRepo.transact(
          fn repo ->
            repo.rollback(:fake_rollback)
          end,
          []
        )

      assert {:error, :fake_rollback} = result
    end
  end

  # -------------------------------------------------------------------
  # in_transaction?
  # -------------------------------------------------------------------

  describe "in_transaction?" do
    setup do
      DoubleDown.Double.fake(DoubleDown.Repo, Repo.OpenInMemory)
      :ok
    end

    test "returns false outside a transaction" do
      refute TestRepo.in_transaction?()
    end

    test "returns true inside a transaction" do
      TestRepo.transact(
        fn ->
          assert TestRepo.in_transaction?()
          {:ok, :done}
        end,
        []
      )
    end
  end
end
