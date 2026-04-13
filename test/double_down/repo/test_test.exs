defmodule DoubleDown.Repo.TestTest do
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
      DoubleDown.Testing.set_fn_handler(Repo, Repo.Test.new())
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

    test "insert returns {:error, changeset} for invalid changeset" do
      cs =
        %User{}
        |> Ecto.Changeset.cast(%{name: "Alice"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {:error, %Ecto.Changeset{valid?: false}} = Repo.Port.insert(cs)
    end

    test "update returns {:error, changeset} for invalid changeset" do
      cs =
        %User{id: 1, name: "old"}
        |> Ecto.Changeset.cast(%{name: "new"}, [:name])
        |> Ecto.Changeset.add_error(:name, "is invalid")

      assert {:error, %Ecto.Changeset{valid?: false}} = Repo.Port.update(cs)
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

      # Ensure some time passes so updated_at can differ
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

    test "schemas without timestamps are unaffected by autogeneration" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice"}} = Repo.Port.insert(cs)
    end

    test "integer :id PK is auto-assigned" do
      cs = User.changeset(%{name: "Alice"})
      assert {:ok, %User{name: "Alice", id: id}} = Repo.Port.insert(cs)
      assert is_integer(id)
      assert id > 0
    end

    test ":binary_id PK is auto-generated as UUID" do
      cs = BinaryIdUser.changeset(%{name: "Alice"})
      assert {:ok, user} = Repo.Port.insert(cs)
      assert is_binary(user.id)
      assert user.id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    end

    test "Ecto.UUID PK is auto-generated" do
      cs = UuidUser.changeset(%{name: "Alice"})
      assert {:ok, user} = Repo.Port.insert(cs)
      assert is_binary(user.uuid)
      assert user.uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    end

    test "no autogenerate configured raises on nil PK" do
      cs = NoAutoIdUser.changeset(%{name: "Alice"})

      assert_raise ArgumentError, ~r/Cannot autogenerate primary key/, fn ->
        Repo.Port.insert(cs)
      end
    end

    test "no autogenerate works with explicit PK" do
      explicit_id = Ecto.UUID.generate()
      cs = NoAutoIdUser.changeset(%NoAutoIdUser{id: explicit_id}, %{name: "Alice"})
      assert {:ok, %NoAutoIdUser{id: ^explicit_id}} = Repo.Port.insert(cs)
    end

    test "@primary_key false schema inserts without error" do
      cs = NoPkEvent.changeset(%{name: "thing_happened"})
      assert {:ok, %NoPkEvent{name: "thing_happened"}} = Repo.Port.insert(cs)
    end
  end

  # -------------------------------------------------------------------
  # Read operations raise without fallback
  # -------------------------------------------------------------------

  describe "read operations raise without fallback" do
    setup do
      DoubleDown.Testing.set_fn_handler(Repo, Repo.Test.new())
      :ok
    end

    test "get raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :get/, fn ->
        Repo.Port.get(User, 1)
      end
    end

    test "get! raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :get!/, fn ->
        Repo.Port.get!(User, 1)
      end
    end

    test "get_by raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :get_by/, fn ->
        Repo.Port.get_by(User, name: "Alice")
      end
    end

    test "get_by! raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :get_by!/, fn ->
        Repo.Port.get_by!(User, name: "Alice")
      end
    end

    test "one raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :one/, fn ->
        Repo.Port.one(User)
      end
    end

    test "one! raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :one!/, fn ->
        Repo.Port.one!(User)
      end
    end

    test "all raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :all/, fn ->
        Repo.Port.all(User)
      end
    end

    test "exists? raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :exists\?/, fn ->
        Repo.Port.exists?(User)
      end
    end

    test "aggregate raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :aggregate/, fn ->
        Repo.Port.aggregate(User, :count, :id)
      end
    end

    test "insert_all raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :insert_all/, fn ->
        Repo.Port.insert_all(User, [%{name: "a"}], [])
      end
    end

    test "update_all raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :update_all/, fn ->
        Repo.Port.update_all(User, [set: [name: "bulk"]], [])
      end
    end

    test "delete_all raises without fallback" do
      assert_raise ArgumentError, ~r/Repo.Test cannot service :delete_all/, fn ->
        Repo.Port.delete_all(User, [])
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
        Repo.Test.new(
          fallback_fn: fn
            :get, [User, 1] -> alice
            :get, [User, _] -> nil
          end
        )

      DoubleDown.Testing.set_fn_handler(Repo, handler)

      assert ^alice = Repo.Port.get(User, 1)
      assert nil == Repo.Port.get(User, 999)
    end

    test "get! dispatches to fallback" do
      alice = %User{id: 1, name: "Alice"}

      handler =
        Repo.Test.new(fallback_fn: fn :get!, [User, 1] -> alice end)

      DoubleDown.Testing.set_fn_handler(Repo, handler)
      assert ^alice = Repo.Port.get!(User, 1)
    end

    test "get_by dispatches to fallback" do
      alice = %User{id: 1, name: "Alice"}

      handler =
        Repo.Test.new(fallback_fn: fn :get_by, [User, [name: "Alice"]] -> alice end)

      DoubleDown.Testing.set_fn_handler(Repo, handler)
      assert ^alice = Repo.Port.get_by(User, name: "Alice")
    end

    test "all dispatches to fallback" do
      users = [%User{id: 1, name: "Alice"}, %User{id: 2, name: "Bob"}]

      handler =
        Repo.Test.new(fallback_fn: fn :all, [User] -> users end)

      DoubleDown.Testing.set_fn_handler(Repo, handler)
      assert ^users = Repo.Port.all(User)
    end

    test "exists? dispatches to fallback" do
      handler =
        Repo.Test.new(fallback_fn: fn :exists?, [User] -> true end)

      DoubleDown.Testing.set_fn_handler(Repo, handler)
      assert Repo.Port.exists?(User) == true
    end

    test "aggregate dispatches to fallback" do
      handler =
        Repo.Test.new(fallback_fn: fn :aggregate, [User, :count, :id] -> 42 end)

      DoubleDown.Testing.set_fn_handler(Repo, handler)
      assert 42 = Repo.Port.aggregate(User, :count, :id)
    end

    test "fallback raises on unmatched clause" do
      handler =
        Repo.Test.new(fallback_fn: fn :get, [User, 1] -> nil end)

      DoubleDown.Testing.set_fn_handler(Repo, handler)

      assert_raise ArgumentError, ~r/Repo.Test cannot service :get/, fn ->
        Repo.Port.get(User, 999)
      end
    end
  end

  # -------------------------------------------------------------------
  # Transactions
  # -------------------------------------------------------------------

  describe "transact" do
    setup do
      DoubleDown.Testing.set_fn_handler(Repo, Repo.Test.new())
      :ok
    end

    test "transact with 0-arity fun calls the function" do
      assert {:ok, :done} = Repo.Port.transact(fn -> {:ok, :done} end, [])
    end

    test "transact with 1-arity fun receives facade module" do
      assert {:ok, Repo.Port} = Repo.Port.transact(fn repo -> {:ok, repo} end, [])
    end

    test "transact with 1-arity fun can call back into facade" do
      result =
        Repo.Port.transact(
          fn repo ->
            {:ok, user} = repo.insert(User.changeset(%{name: "Alice"}))
            {:ok, user}
          end,
          []
        )

      assert {:ok, %User{name: "Alice"}} = result
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
  end

  # -------------------------------------------------------------------
  # Dispatch logging
  # -------------------------------------------------------------------

  describe "dispatch logging" do
    test "logs write operations" do
      DoubleDown.Testing.set_fn_handler(Repo, Repo.Test.new())
      DoubleDown.Testing.enable_log(Repo)
      cs = User.changeset(%{name: "Alice"})

      Repo.Port.insert(cs)

      log = DoubleDown.Testing.get_log(Repo)
      assert length(log) == 1
      assert [{Repo, :insert, [^cs], {:ok, %User{name: "Alice"}}}] = log
    end

    test "logs fallback-dispatched operations" do
      alice = %User{id: 1, name: "Alice"}

      DoubleDown.Testing.set_fn_handler(
        Repo,
        Repo.Test.new(fallback_fn: fn :get, [User, 1] -> alice end)
      )

      DoubleDown.Testing.enable_log(Repo)

      Repo.Port.get(User, 1)

      log = DoubleDown.Testing.get_log(Repo)
      assert length(log) == 1
      assert [{Repo, :get, [User, 1], ^alice}] = log
    end

    test "1-arity transact logs inner facade calls made from the transaction function" do
      DoubleDown.Testing.set_fn_handler(Repo, Repo.Test.new())
      DoubleDown.Testing.enable_log(Repo)

      cs = User.changeset(%{name: "Alice"})

      Repo.Port.transact(
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
  # Repo.Test via Double.stub (transact deadlock regression)
  # -------------------------------------------------------------------

  describe "Repo.Test via Double.stub" do
    test "transact with 0-arity fun works via Double.stub (no deadlock)" do
      DoubleDown.Double.stub(Repo, Repo.Test.new())

      assert {:ok, :done} = Repo.Port.transact(fn -> {:ok, :done} end, [])
    end

    test "transact with nested Repo calls works via Double.stub" do
      DoubleDown.Double.stub(Repo, Repo.Test.new())

      result =
        Repo.Port.transact(
          fn repo ->
            {:ok, user} = repo.insert(User.changeset(%{name: "Alice"}))
            {:ok, user}
          end,
          []
        )

      assert {:ok, %User{name: "Alice"}} = result
    end

    test "transact with Ecto.Multi works via Double.stub" do
      DoubleDown.Double.stub(Repo, Repo.Test.new())

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))

      assert {:ok, %{user: %User{name: "Alice"}}} = Repo.Port.transact(multi, [])
    end
  end

  # -------------------------------------------------------------------
  # Nested transact
  # -------------------------------------------------------------------

  describe "nested transact" do
    setup do
      DoubleDown.Testing.set_fn_handler(Repo, Repo.Test.new())
      :ok
    end

    test "nested transact with inner Multi" do
      result =
        Repo.Port.transact(
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
        Repo.Port.transact(
          fn repo ->
            repo.transact(fn -> {:ok, :inner_done} end, [])
          end,
          []
        )

      assert {:ok, :inner_done} = result
    end

    test "nested transact with insert in outer and inner" do
      result =
        Repo.Port.transact(
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

  describe "nested transact via Double.stub" do
    test "nested transact works via Double.stub (no deadlock)" do
      DoubleDown.Double.stub(Repo, Repo.Test.new())

      result =
        Repo.Port.transact(
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
      DoubleDown.Testing.set_fn_handler(Repo, Repo.Test.new())
      :ok
    end

    test "rollback inside transact returns {:error, value}" do
      result =
        Repo.Port.transact(
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
        Repo.Port.transact(
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
        Repo.Port.transact(
          fn repo ->
            repo.rollback(%{reason: :conflict, details: "duplicate key"})
          end,
          []
        )

      assert {:error, %{reason: :conflict, details: "duplicate key"}} = result
    end
  end

  describe "rollback via Double.stub" do
    test "rollback works via Double.stub" do
      DoubleDown.Double.stub(Repo, Repo.Test.new())

      result =
        Repo.Port.transact(
          fn repo ->
            repo.rollback(:stub_rollback)
          end,
          []
        )

      assert {:error, :stub_rollback} = result
    end
  end
end
