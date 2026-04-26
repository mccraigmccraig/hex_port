defmodule DoubleDown.Repo.StubTest do
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

  # -------------------------------------------------------------------
  # Write operations
  # -------------------------------------------------------------------

  describe "write operations" do
    setup do
      DoubleDown.Testing.set_stateless_handler(Repo, Repo.Stub.new())
      :ok
    end

    test "insert applies changeset and returns {:ok, struct}" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice"}} = TestRepo.insert(cs)
    end

    test "update applies changeset and returns {:ok, struct}" do
      cs = User.changeset(%User{id: 1, name: "old"}, %{name: "new"})
      assert {:ok, %User{id: 1, name: "new"}} = TestRepo.update(cs)
    end

    test "delete returns {:ok, record}" do
      record = %User{id: 1, name: "Alice"}
      assert {:ok, ^record} = TestRepo.delete(record)
    end

    test "insert returns {:error, changeset} for invalid changeset" do
      cs =
        %User{}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {:error, %Ecto.Changeset{valid?: false}} = TestRepo.insert(cs)
    end

    test "update returns {:error, changeset} for invalid changeset" do
      cs =
        %User{id: 1, name: "old"}
        |> Ecto.Changeset.cast(%{name: "new"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {:error, %Ecto.Changeset{valid?: false}} = TestRepo.update(cs)
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

      # Ensure some time passes so updated_at can differ
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

    test "schemas without timestamps are unaffected by autogeneration" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice"}} = TestRepo.insert(cs)
    end

    test "integer :id PK is auto-assigned" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice", id: id}} = TestRepo.insert(cs)
      assert is_integer(id)
      assert id > 0
    end

    test ":binary_id PK is auto-generated as UUID" do
      cs = BinaryIdUser.changeset(%{name: "Alice"})
      assert {:ok, user} = TestRepo.insert(cs)
      assert is_binary(user.id)
      assert user.id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    end

    test "Ecto.UUID PK is auto-generated" do
      cs = UuidUser.changeset(%{name: "Alice"})
      assert {:ok, user} = TestRepo.insert(cs)
      assert is_binary(user.uuid)
      assert user.uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
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
  end

  # -------------------------------------------------------------------
  # Read operations raise without fallback
  # -------------------------------------------------------------------

  describe "read operations raise without fallback" do
    setup do
      DoubleDown.Testing.set_stateless_handler(Repo, Repo.Stub.new())
      :ok
    end

    test "get raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :get/, fn ->
        TestRepo.get(User, 1)
      end
    end

    test "get! raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :get!/, fn ->
        TestRepo.get!(User, 1)
      end
    end

    test "get_by raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :get_by/, fn ->
        TestRepo.get_by(User, name: "Alice")
      end
    end

    test "get_by! raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :get_by!/, fn ->
        TestRepo.get_by!(User, name: "Alice")
      end
    end

    test "one raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :one/, fn ->
        TestRepo.one(User)
      end
    end

    test "one! raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :one!/, fn ->
        TestRepo.one!(User)
      end
    end

    test "all raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :all/, fn ->
        TestRepo.all(User)
      end
    end

    test "exists? raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :exists\?/, fn ->
        TestRepo.exists?(User)
      end
    end

    test "aggregate raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :aggregate/, fn ->
        TestRepo.aggregate(User, :count, :id)
      end
    end

    test "insert_all raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :insert_all/, fn ->
        TestRepo.insert_all(User, [%{name: "a"}], [])
      end
    end

    test "update_all raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :update_all/, fn ->
        TestRepo.update_all(User, [set: [name: "bulk"]], [])
      end
    end

    test "delete_all raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Stub cannot service :delete_all/, fn ->
        TestRepo.delete_all(User, [])
      end
    end
  end

  # -------------------------------------------------------------------
  # Read operations with fallback
  # -------------------------------------------------------------------

  describe "read operations with fallback" do
    test "get dispatches to fallback" do
      alice = %User{id: 1, name: "Alice"}

      handler =
        Repo.Stub.new(
          fallback_fn: fn _contract, operation, args ->
            case {operation, args} do
              {:get, [User, 1]} -> alice
              {:get, [User, _]} -> nil
            end
          end
        )

      DoubleDown.Testing.set_stateless_handler(Repo, handler)

      assert ^alice = TestRepo.get(User, 1)
      assert nil == TestRepo.get(User, 999)
    end

    test "get! dispatches to fallback" do
      alice = %User{id: 1, name: "Alice"}

      handler =
        Repo.Stub.new(fallback_fn: fn _contract, :get!, [User, 1] -> alice end)

      DoubleDown.Testing.set_stateless_handler(Repo, handler)
      assert ^alice = TestRepo.get!(User, 1)
    end

    test "get_by dispatches to fallback" do
      alice = %User{id: 1, name: "Alice"}

      handler =
        Repo.Stub.new(fallback_fn: fn _contract, :get_by, [User, [name: "Alice"]] -> alice end)

      DoubleDown.Testing.set_stateless_handler(Repo, handler)
      assert ^alice = TestRepo.get_by(User, name: "Alice")
    end

    test "all dispatches to fallback" do
      users = [%User{id: 1, name: "Alice"}, %User{id: 2, name: "Bob"}]

      handler =
        Repo.Stub.new(fallback_fn: fn _contract, :all, [User] -> users end)

      DoubleDown.Testing.set_stateless_handler(Repo, handler)
      assert ^users = TestRepo.all(User)
    end

    test "exists? dispatches to fallback" do
      handler =
        Repo.Stub.new(fallback_fn: fn _contract, :exists?, [User] -> true end)

      DoubleDown.Testing.set_stateless_handler(Repo, handler)
      assert TestRepo.exists?(User) == true
    end

    test "aggregate dispatches to fallback" do
      handler =
        Repo.Stub.new(fallback_fn: fn _contract, :aggregate, [User, :count, :id] -> 42 end)

      DoubleDown.Testing.set_stateless_handler(Repo, handler)
      assert 42 = TestRepo.aggregate(User, :count, :id)
    end

    test "fallback raises on unmatched clause" do
      handler =
        Repo.Stub.new(fallback_fn: fn _contract, :get, [User, 1] -> nil end)

      DoubleDown.Testing.set_stateless_handler(Repo, handler)

      assert_raise ArgumentError, ~r/Repo.Stub cannot service :get/, fn ->
        TestRepo.get(User, 999)
      end
    end
  end

  # -------------------------------------------------------------------
  # Transactions
  # -------------------------------------------------------------------

  describe "transact" do
    setup do
      DoubleDown.Testing.set_stateless_handler(Repo, Repo.Stub.new())
      :ok
    end

    test "transact with 0-arity fun calls the function" do
      assert {:ok, :done} = TestRepo.transact(fn -> {:ok, :done} end, [])
    end

    test "transact with 1-arity fun receives facade module" do
      assert {:ok, TestRepo} = TestRepo.transact(fn repo -> {:ok, repo} end, [])
    end

    test "transact with 1-arity fun can call back into facade" do
      result =
        TestRepo.transact(
          fn repo ->
            {:ok, user} = repo.insert(User.changeset(%{name: "Alice"}))
            {:ok, user}
          end,
          []
        )

      assert {:ok, %User{name: "Alice"}} = result
    end

    test "transact propagates error tuples" do
      assert {:error, :rollback} = TestRepo.transact(fn -> {:error, :rollback} end, [])
    end

    test "transact with Ecto.Multi executes insert operations" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.insert(:post, Post.changeset(%{title: "Hello"}))

      assert {:ok, %{user: %User{name: "Alice"}, post: %Post{title: "Hello"}}} =
               TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi rejects invalid changesets" do
      invalid = %Ecto.Changeset{valid?: false, action: :insert, errors: [name: {"required", []}]}

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, invalid)

      assert {:error, :user, %Ecto.Changeset{valid?: false}, %{}} =
               TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi handles :run operations" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:value, fn _repo, _changes -> {:ok, 42} end)

      assert {:ok, %{value: 42}} = TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi :run receives repo facade" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:repo_check, fn repo, _changes -> {:ok, repo} end)

      assert {:ok, %{repo_check: TestRepo}} = TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi :run failure returns 4-tuple error" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.run(:fail, fn _repo, _changes -> {:error, :boom} end)

      assert {:error, :fail, :boom, %{user: %User{name: "Alice"}}} =
               TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi :put adds static values" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.put(:greeting, "hello")

      assert {:ok, %{greeting: "hello"}} = TestRepo.transact(multi, [])
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

    test "transact with Ecto.Multi :error causes immediate failure" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.error(:fail, :forced_error)
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))

      assert {:error, :fail, :forced_error, %{}} = TestRepo.transact(multi, [])
    end

    test "transact with Ecto.Multi passes changes to dependent :run operations" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))
        |> Ecto.Multi.run(:greeting, fn _repo, %{user: user} ->
          {:ok, "Hello, #{user.name}!"}
        end)

      assert {:ok, %{user: %User{name: "Alice"}, greeting: "Hello, Alice!"}} =
               TestRepo.transact(multi, [])
    end
  end

  # -------------------------------------------------------------------
  # Dispatch logging
  # -------------------------------------------------------------------

  describe "dispatch logging" do
    test "logs write operations" do
      DoubleDown.Testing.set_stateless_handler(Repo, Repo.Stub.new())
      DoubleDown.Testing.enable_log(Repo)
      cs = User.changeset(%{name: "Alice"})

      TestRepo.insert(cs)

      log = DoubleDown.Testing.get_log(Repo)
      assert length(log) == 1
      assert [{Repo, :insert, [^cs], {:ok, %User{name: "Alice"}}}] = log
    end

    test "logs fallback-dispatched operations" do
      alice = %User{id: 1, name: "Alice"}

      DoubleDown.Testing.set_stateless_handler(
        Repo,
        Repo.Stub.new(fallback_fn: fn _contract, :get, [User, 1] -> alice end)
      )

      DoubleDown.Testing.enable_log(Repo)

      TestRepo.get(User, 1)

      log = DoubleDown.Testing.get_log(Repo)
      assert length(log) == 1
      assert [{Repo, :get, [User, 1], ^alice}] = log
    end

    test "1-arity transact logs inner facade calls made from the transaction function" do
      DoubleDown.Testing.set_stateless_handler(Repo, Repo.Stub.new())
      DoubleDown.Testing.enable_log(Repo)

      cs = User.changeset(%{name: "Alice"})

      TestRepo.transact(
        fn repo ->
          {:ok, _user} = repo.insert(cs)
          {:ok, :done}
        end,
        []
      )

      log = DoubleDown.Testing.get_log(Repo)

      # Inner calls are logged first (during fn execution), then the outer
      # transact call is logged when it completes.
      assert length(log) == 2

      assert [
               {Repo, :insert, [^cs], {:ok, %User{name: "Alice"}}},
               {Repo, :transact, _, {:ok, :done}}
             ] = log
    end
  end

  # -------------------------------------------------------------------
  # Repo.Stub via Double.stub (transact deadlock regression)
  # -------------------------------------------------------------------

  describe "Repo.Stub via Double.fallback" do
    test "transact with 0-arity fun works via Double.fallback (no deadlock)" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      assert {:ok, :done} = TestRepo.transact(fn -> {:ok, :done} end, [])
    end

    test "transact with nested Repo calls works via Double.fallback" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      result =
        TestRepo.transact(
          fn repo ->
            {:ok, user} = repo.insert(User.changeset(%{name: "Alice"}))
            {:ok, user}
          end,
          []
        )

      assert {:ok, %User{name: "Alice"}} = result
    end

    test "transact with Ecto.Multi works via Double.fallback" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))

      assert {:ok, %{user: %User{name: "Alice"}}} = TestRepo.transact(multi, [])
    end
  end

  # -------------------------------------------------------------------
  # Nested transact
  # -------------------------------------------------------------------

  describe "nested transact" do
    setup do
      DoubleDown.Testing.set_stateless_handler(Repo, Repo.Stub.new())
      :ok
    end

    test "nested transact with inner Multi" do
      result =
        TestRepo.transact(
          fn repo ->
            multi =
              Ecto.Multi.new()
              |> Ecto.Multi.put(:val, 42)

            repo.transact(multi, [])
          end,
          []
        )

      assert {:ok, %{val: 42}} = result
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

    test "nested transact with insert in outer and inner" do
      result =
        TestRepo.transact(
          fn repo ->
            {:ok, user} = repo.insert(User.changeset(%{name: "Alice"}))

            {:ok, inner} =
              repo.transact(
                fn ->
                  {:ok, post} = repo.insert(Post.changeset(%{title: "Hello"}))
                  {:ok, {user, post}}
                end,
                []
              )

            {:ok, inner}
          end,
          []
        )

      assert {:ok, {%User{name: "Alice"}, %Post{title: "Hello"}}} = result
    end
  end

  describe "nested transact via Double.fallback" do
    test "nested transact works via Double.fallback (no deadlock)" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      result =
        TestRepo.transact(
          fn repo ->
            multi =
              Ecto.Multi.new()
              |> Ecto.Multi.put(:val, 42)

            repo.transact(multi, [])
          end,
          []
        )

      assert {:ok, %{val: 42}} = result
    end
  end

  # -------------------------------------------------------------------
  # Rollback
  # -------------------------------------------------------------------

  describe "rollback" do
    setup do
      DoubleDown.Testing.set_stateless_handler(Repo, Repo.Stub.new())
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

    test "rollback stops execution — code after rollback is not reached" do
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

    test "rollback with arbitrary value" do
      result =
        TestRepo.transact(
          fn repo ->
            repo.rollback(%{reason: :conflict, details: "duplicate key"})
          end,
          []
        )

      assert {:error, %{reason: :conflict, details: "duplicate key"}} = result
    end
  end

  describe "rollback via Double.fallback" do
    test "rollback works via Double.fallback" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      result =
        TestRepo.transact(
          fn repo ->
            repo.rollback(:stub_rollback)
          end,
          []
        )

      assert {:error, :stub_rollback} = result
    end
  end

  describe "rollback outside transaction" do
    test "raises RuntimeError" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      assert_raise RuntimeError, ~r/cannot call rollback outside of transaction/, fn ->
        TestRepo.rollback(:oops)
      end
    end
  end

  # -------------------------------------------------------------------
  # insert_or_update / insert_or_update!
  # -------------------------------------------------------------------

  describe "insert_or_update" do
    test "inserts when meta state is :built" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice"}} = TestRepo.insert_or_update(cs)
    end

    test "updates when meta state is :loaded" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      user = %User{id: 1, name: "Alice"} |> Ecto.put_meta(state: :loaded)
      cs = User.changeset(user, %{name: "Alicia"})
      assert {:ok, %User{name: "Alicia"}} = TestRepo.insert_or_update(cs)
    end

    test "returns error on invalid changeset" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      cs = User.changeset(%{}) |> Ecto.Changeset.add_error(:name, "required")
      cs = %{cs | valid?: false}
      assert {:error, %Ecto.Changeset{}} = TestRepo.insert_or_update(cs)
    end

    test "opts-stripping variant works" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice"}} = TestRepo.insert_or_update(cs, [])
    end
  end

  describe "insert_or_update!" do
    test "returns struct on success" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      cs = User.changeset(%{name: "Alice"})
      assert %User{name: "Alice"} = TestRepo.insert_or_update!(cs)
    end

    test "raises on invalid changeset" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      cs = User.changeset(%{}) |> Ecto.Changeset.add_error(:name, "required")
      cs = %{cs | valid?: false}

      assert_raise Ecto.InvalidChangesetError, fn ->
        TestRepo.insert_or_update!(cs)
      end
    end

    test "opts-stripping variant works" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      cs = User.changeset(%{name: "Alice"})
      assert %User{name: "Alice"} = TestRepo.insert_or_update!(cs, [])
    end
  end

  # -------------------------------------------------------------------
  # in_transaction?
  # -------------------------------------------------------------------

  describe "in_transaction?" do
    test "returns false outside transaction" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      refute TestRepo.in_transaction?()
    end

    test "returns true inside transaction" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      TestRepo.transact(
        fn _repo ->
          assert TestRepo.in_transaction?()
          {:ok, :done}
        end,
        []
      )
    end
  end

  # -------------------------------------------------------------------
  # :transaction (alias for :transact)
  # -------------------------------------------------------------------

  describe "transaction (alias for transact)" do
    setup do
      DoubleDown.Testing.set_stateless_handler(Repo, Repo.Stub.new())
      :ok
    end

    test "0-arity fun success" do
      assert {:ok, :done} = TestRepo.transaction(fn -> {:ok, :done} end, [])
    end

    test "1-arity fun receives facade module" do
      assert {:ok, TestRepo} = TestRepo.transaction(fn repo -> {:ok, repo} end, [])
    end

    test "1-arity fun can call back into facade" do
      result =
        TestRepo.transaction(
          fn repo ->
            {:ok, user} = repo.insert(User.changeset(%{name: "Alice"}))
            {:ok, user}
          end,
          []
        )

      assert {:ok, %User{name: "Alice"}} = result
    end

    test "Multi via transaction" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))

      assert {:ok, %{user: %User{name: "Alice"}}} = TestRepo.transaction(multi, [])
    end

    test "in_transaction? returns true inside transaction" do
      TestRepo.transaction(
        fn ->
          assert TestRepo.in_transaction?()
          {:ok, :done}
        end,
        []
      )
    end

    test "rollback inside transaction returns error" do
      result =
        TestRepo.transaction(
          fn ->
            TestRepo.rollback(:aborted)
          end,
          []
        )

      assert {:error, :aborted} = result
    end
  end

  # -------------------------------------------------------------------
  # load
  # -------------------------------------------------------------------

  describe "load" do
    test "loads a schema struct from keyword data" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      result = TestRepo.load(User, id: 1, name: "Alice")
      assert %User{id: 1, name: "Alice"} = result
    end

    test "loads a schema struct from map data" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      result = TestRepo.load(User, %{id: 1, name: "Alice"})
      assert %User{id: 1, name: "Alice"} = result
    end

    test "loads a schema struct from {fields, values} tuple" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      result = TestRepo.load(User, {[:id, :name], [1, "Alice"]})
      assert %User{id: 1, name: "Alice"} = result
    end
  end

  # -------------------------------------------------------------------
  # preload, reload, reload!, all_by — fallback operations
  # -------------------------------------------------------------------

  describe "preload" do
    test "delegates to fallback" do
      DoubleDown.Double.fallback(
        Repo,
        Repo.Stub.new(fn _contract, :preload, [struct, [:posts]] ->
          %{struct | name: "preloaded"}
        end)
      )

      user = %User{id: 1, name: "Alice"}
      assert %User{name: "preloaded"} = TestRepo.preload(user, [:posts])
    end

    test "raises without fallback" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      assert_raise ArgumentError, ~r/cannot service :preload/, fn ->
        TestRepo.preload(%User{id: 1}, [:posts])
      end
    end

    test "opts-stripping variant works" do
      DoubleDown.Double.fallback(
        Repo,
        Repo.Stub.new(fn _contract, :preload, [struct, [:posts]] ->
          %{struct | name: "preloaded"}
        end)
      )

      user = %User{id: 1, name: "Alice"}
      assert %User{name: "preloaded"} = TestRepo.preload(user, [:posts], [])
    end
  end

  describe "reload" do
    test "delegates to fallback" do
      DoubleDown.Double.fallback(
        Repo,
        Repo.Stub.new(fn _contract, :reload, [%User{id: 1}] ->
          %User{id: 1, name: "Reloaded"}
        end)
      )

      assert %User{name: "Reloaded"} = TestRepo.reload(%User{id: 1})
    end

    test "raises without fallback" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      assert_raise ArgumentError, ~r/cannot service :reload/, fn ->
        TestRepo.reload(%User{id: 1})
      end
    end

    test "opts-stripping variant works" do
      DoubleDown.Double.fallback(
        Repo,
        Repo.Stub.new(fn _contract, :reload, [%User{id: 1}] ->
          %User{id: 1, name: "Reloaded"}
        end)
      )

      assert %User{name: "Reloaded"} = TestRepo.reload(%User{id: 1}, [])
    end
  end

  describe "reload!" do
    test "delegates to fallback" do
      DoubleDown.Double.fallback(
        Repo,
        Repo.Stub.new(fn _contract, :reload!, [%User{id: 1}] ->
          %User{id: 1, name: "Reloaded"}
        end)
      )

      assert %User{name: "Reloaded"} = TestRepo.reload!(%User{id: 1})
    end

    test "raises without fallback" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      assert_raise ArgumentError, ~r/cannot service :reload!/, fn ->
        TestRepo.reload!(%User{id: 1})
      end
    end

    test "opts-stripping variant works" do
      DoubleDown.Double.fallback(
        Repo,
        Repo.Stub.new(fn _contract, :reload!, [%User{id: 1}] ->
          %User{id: 1, name: "Reloaded"}
        end)
      )

      assert %User{name: "Reloaded"} = TestRepo.reload!(%User{id: 1}, [])
    end
  end

  describe "all_by" do
    test "delegates to fallback" do
      DoubleDown.Double.fallback(
        Repo,
        Repo.Stub.new(fn _contract, :all_by, [User, [name: "Alice"]] ->
          [%User{id: 1, name: "Alice"}]
        end)
      )

      assert [%User{name: "Alice"}] = TestRepo.all_by(User, name: "Alice")
    end

    test "raises without fallback" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      assert_raise ArgumentError, ~r/cannot service :all_by/, fn ->
        TestRepo.all_by(User, name: "Alice")
      end
    end

    test "opts-stripping variant works" do
      DoubleDown.Double.fallback(
        Repo,
        Repo.Stub.new(fn _contract, :all_by, [User, [name: "Alice"]] ->
          [%User{id: 1, name: "Alice"}]
        end)
      )

      assert [%User{name: "Alice"}] = TestRepo.all_by(User, [name: "Alice"], [])
    end
  end

  # -------------------------------------------------------------------
  # stream
  # -------------------------------------------------------------------

  describe "stream" do
    test "delegates to fallback" do
      DoubleDown.Double.fallback(
        Repo,
        Repo.Stub.new(fn _contract, :stream, [User] ->
          Stream.map([%User{id: 1, name: "Alice"}], & &1)
        end)
      )

      stream = TestRepo.stream(User)
      assert [%User{name: "Alice"}] = Enum.to_list(stream)
    end

    test "raises without fallback" do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())

      assert_raise ArgumentError, ~r/cannot service :stream/, fn ->
        TestRepo.stream(User)
      end
    end

    test "opts-stripping variant works" do
      DoubleDown.Double.fallback(
        Repo,
        Repo.Stub.new(fn _contract, :stream, [User] ->
          Stream.map([%User{id: 1, name: "Alice"}], & &1)
        end)
      )

      stream = TestRepo.stream(User, [])
      assert [%User{name: "Alice"}] = Enum.to_list(stream)
    end
  end

  # -------------------------------------------------------------------
  # Transaction args normalisation (DynamicFacade compatibility)
  # -------------------------------------------------------------------

  describe "transaction args normalisation" do
    setup do
      DoubleDown.Double.fallback(Repo, Repo.Stub.new())
      :ok
    end

    test "0-arity fn without opts" do
      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          Repo,
          :transaction,
          [fn -> {:ok, :zero_arity} end]
        )

      assert {:ok, :zero_arity} = result
    end

    test "1-arity fn without opts" do
      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          Repo,
          :transaction,
          [fn _repo -> {:ok, :one_arity} end]
        )

      assert {:ok, :one_arity} = result
    end

    test "0-arity fn with opts" do
      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          Repo,
          :transaction,
          [fn -> {:ok, :with_opts} end, []]
        )

      assert {:ok, :with_opts} = result
    end

    test "transact also normalises" do
      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          Repo,
          :transact,
          [fn -> {:ok, :transact} end]
        )

      assert {:ok, :transact} = result
    end
  end
end
