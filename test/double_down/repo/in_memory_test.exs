defmodule DoubleDown.Repo.InMemoryTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Repo.InMemory
  alias DoubleDown.Repo.Impl.InMemoryShared
  require Ecto.Query

  # -- Test schemas --

  defmodule User do
    use Ecto.Schema

    schema "users" do
      field(:name, :string)
      field(:email, :string)
      field(:age, :integer)
    end

    def changeset(user \\ %__MODULE__{}, params) do
      Ecto.Changeset.cast(user, params, [:name, :email, :age])
    end
  end

  defmodule Post do
    use Ecto.Schema

    schema "posts" do
      field(:title, :string)
      field(:body, :string)
    end
  end

  defmodule Organisation do
    use Ecto.Schema

    schema "organisations" do
      field(:name, :string)
    end
  end

  defmodule TaskCategory do
    use Ecto.Schema

    schema "task_categories" do
      field(:name, :string)
      belongs_to(:organisation, Organisation)
    end
  end

  defmodule ManualPkRecord do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "manual_pk_records" do
      field(:name, :string)
    end
  end

  defmodule NoPkEvent do
    use Ecto.Schema

    @primary_key false
    schema "events" do
      field(:name, :string)
    end

    def changeset(event \\ %__MODULE__{}, attrs) do
      Ecto.Changeset.cast(event, attrs, [:name])
    end
  end

  # -------------------------------------------------------------------
  # Write operations
  # -------------------------------------------------------------------

  describe "insert" do
    test "inserts a valid changeset and stores the record" do
      store = InMemory.new()
      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})

      {{:ok, user}, store} = InMemory.dispatch(DoubleDown.Repo, :insert, [cs], store)
      assert user.name == "Alice"
      assert user.id != nil

      # Read back
      {found, _store} = InMemory.dispatch(DoubleDown.Repo, :get, [User, user.id], store)
      assert found.name == "Alice"
    end

    test "rejects invalid changeset" do
      store = InMemory.new()
      cs = %Ecto.Changeset{valid?: false, errors: [name: {"required", []}]}

      {{:error, ^cs}, ^store} = InMemory.dispatch(DoubleDown.Repo, :insert, [cs], store)
    end
  end

  describe "update" do
    test "updates a record in the store" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])

      cs =
        %User{id: 1, name: "Alice"}
        |> User.changeset(%{name: "Alicia"})

      {{:ok, updated}, store} = InMemory.dispatch(DoubleDown.Repo, :update, [cs], store)
      assert updated.name == "Alicia"

      {found, _} = InMemory.dispatch(DoubleDown.Repo, :get, [User, 1], store)
      assert found.name == "Alicia"
    end
  end

  describe "delete" do
    test "removes a record from the store" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])

      {{:ok, _}, store} = InMemory.dispatch(DoubleDown.Repo, :delete, [%User{id: 1}], store)

      {found, _} = InMemory.dispatch(DoubleDown.Repo, :get, [User, 1], store)
      assert found == nil
    end
  end

  # -------------------------------------------------------------------
  # FK backfill on insert
  # -------------------------------------------------------------------

  describe "FK backfill" do
    test "belongs_to FK is backfilled from loaded association struct" do
      store = InMemory.new()
      org = %Organisation{id: 42, name: "Acme"}

      # Insert with association struct but no FK set
      record = %TaskCategory{name: "Widgets", organisation: org, organisation_id: nil}
      {{:ok, inserted}, store} = InMemory.dispatch(DoubleDown.Repo, :insert, [record], store)

      # FK should have been backfilled from the association
      assert inserted.organisation_id == 42

      # Should be findable by FK
      {found, _} =
        InMemory.dispatch(DoubleDown.Repo, :get_by, [TaskCategory, [organisation_id: 42]], store)

      assert found.name == "Widgets"
    end

    test "explicit FK is preserved (not overwritten by association)" do
      store = InMemory.new()
      org = %Organisation{id: 42, name: "Acme"}

      # Insert with both FK and association set — FK takes precedence
      record = %TaskCategory{name: "Widgets", organisation: org, organisation_id: 99}
      {{:ok, inserted}, _store} = InMemory.dispatch(DoubleDown.Repo, :insert, [record], store)

      assert inserted.organisation_id == 99
    end

    test "no backfill when association is not loaded" do
      store = InMemory.new()

      # Insert with no association loaded
      record = %TaskCategory{name: "Widgets", organisation_id: nil}
      {{:ok, inserted}, _store} = InMemory.dispatch(DoubleDown.Repo, :insert, [record], store)

      assert inserted.organisation_id == nil
    end

    test "backfill works with changeset insert" do
      store = InMemory.new()
      org = %Organisation{id: 42, name: "Acme"}

      cs =
        %TaskCategory{organisation: org}
        |> Ecto.Changeset.cast(%{name: "Widgets"}, [:name])

      {{:ok, inserted}, _store} = InMemory.dispatch(DoubleDown.Repo, :insert, [cs], store)

      assert inserted.organisation_id == 42
    end

    test "backfill works with custom (non-:id) parent PK" do
      store = InMemory.new()
      # Organisation uses :id (default), but the FK reference works the same
      # for custom PK names — related_key from the association metadata
      # is used, not a hardcoded :id
      org = %Organisation{id: 42, name: "Acme"}
      {{:ok, org}, store} = InMemory.dispatch(DoubleDown.Repo, :insert, [org], store)

      child = %TaskCategory{name: "Widgets", organisation: org, organisation_id: nil}
      {{:ok, inserted}, _store} = InMemory.dispatch(DoubleDown.Repo, :insert, [child], store)

      assert inserted.organisation_id == org.id
    end

    test "backfill recursively inserts parent when parent PK is nil" do
      store = InMemory.new()

      # Parent has nil PK — simulates ExMachina's nested struct pattern
      org = %Organisation{id: nil, name: "Acme"}
      record = %TaskCategory{name: "Widgets", organisation: org, organisation_id: nil}
      {{:ok, inserted}, store} = InMemory.dispatch(DoubleDown.Repo, :insert, [record], store)

      # FK should be set to the auto-generated parent PK
      assert inserted.organisation_id != nil

      # Parent should have been inserted into the store
      {found_org, _} =
        InMemory.dispatch(DoubleDown.Repo, :get, [Organisation, inserted.organisation_id], store)

      assert found_org != nil
      assert found_org.name == "Acme"
    end

    test "backfill recursive insert works through insert! (bang)" do
      store = InMemory.new()

      org = %Organisation{id: nil, name: "Acme"}
      record = %TaskCategory{name: "Widgets", organisation: org, organisation_id: nil}
      {inserted, store} = InMemory.dispatch(DoubleDown.Repo, :insert!, [record], store)

      assert inserted.organisation_id != nil

      {found_org, _} =
        InMemory.dispatch(DoubleDown.Repo, :get, [Organisation, inserted.organisation_id], store)

      assert found_org != nil
    end

    test "backfill works with insert!" do
      store = InMemory.new()
      org = %Organisation{id: 42, name: "Acme"}

      record = %TaskCategory{name: "Widgets", organisation: org, organisation_id: nil}
      {inserted, _store} = InMemory.dispatch(DoubleDown.Repo, :insert!, [record], store)

      assert inserted.organisation_id == 42
    end
  end

  # -------------------------------------------------------------------
  # Association reset on insert
  # -------------------------------------------------------------------

  describe "association reset" do
    test "associations are reset to NotLoaded after insert" do
      store = InMemory.new()
      org = %Organisation{id: 42, name: "Acme"}

      record = %TaskCategory{name: "Widgets", organisation: org, organisation_id: nil}
      {{:ok, inserted}, _store} = InMemory.dispatch(DoubleDown.Repo, :insert, [record], store)

      # FK was backfilled
      assert inserted.organisation_id == 42

      # Association was reset to NotLoaded
      assert %Ecto.Association.NotLoaded{} = inserted.organisation
      assert inserted.organisation.__field__ == :organisation
      assert inserted.organisation.__owner__ == TaskCategory
      assert inserted.organisation.__cardinality__ == :one
    end

    test "stored record has NotLoaded associations" do
      store = InMemory.new()
      org = %Organisation{id: 42, name: "Acme"}

      record = %TaskCategory{name: "Widgets", organisation: org, organisation_id: nil}
      {{:ok, inserted}, store} = InMemory.dispatch(DoubleDown.Repo, :insert, [record], store)

      # Reading back from the store also has NotLoaded
      {found, _} = InMemory.dispatch(DoubleDown.Repo, :get, [TaskCategory, inserted.id], store)
      assert %Ecto.Association.NotLoaded{} = found.organisation
    end

    test "struct equality works after insert (matching Ecto behaviour)" do
      store = InMemory.new()
      org = %Organisation{id: 42, name: "Acme"}

      record = %TaskCategory{name: "Widgets", organisation: org, organisation_id: nil}
      {{:ok, inserted}, store} = InMemory.dispatch(DoubleDown.Repo, :insert, [record], store)

      {found, _} = InMemory.dispatch(DoubleDown.Repo, :get, [TaskCategory, inserted.id], store)

      # The inserted record and the read-back record should be equal
      assert inserted == found
    end
  end

  # -------------------------------------------------------------------
  # Bang write operations
  # -------------------------------------------------------------------

  describe "insert!" do
    test "returns the struct on success" do
      store = InMemory.new()
      cs = User.changeset(%{name: "Alice"})
      {user, _store} = InMemory.dispatch(DoubleDown.Repo, :insert!, [cs], store)
      assert user.name == "Alice"
      assert user.id != nil
    end

    test "raises on invalid changeset" do
      store = InMemory.new()
      cs = User.changeset(%{}) |> Ecto.Changeset.add_error(:name, "required")
      cs = %{cs | valid?: false}

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :insert!, [cs], store)

      assert_raise Ecto.InvalidChangesetError, fn -> raise_fn.() end
    end
  end

  describe "update!" do
    test "returns the struct on success" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])
      cs = User.changeset(%User{id: 1, name: "Alice"}, %{name: "Alicia"})
      {user, _store} = InMemory.dispatch(DoubleDown.Repo, :update!, [cs], store)
      assert user.name == "Alicia"
    end

    test "raises on invalid changeset" do
      store = InMemory.new()
      cs = User.changeset(%{}) |> Ecto.Changeset.add_error(:name, "required")
      cs = %{cs | valid?: false}

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :update!, [cs], store)

      assert_raise Ecto.InvalidChangesetError, fn -> raise_fn.() end
    end
  end

  describe "delete!" do
    test "returns the struct on success" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])
      {user, _store} = InMemory.dispatch(DoubleDown.Repo, :delete!, [%User{id: 1}], store)
      assert user.id == 1
    end

    test "raises on invalid changeset" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])

      cs =
        User.changeset(%User{id: 1, name: "Alice"}, %{})
        |> Ecto.Changeset.add_error(:name, "required")

      cs = %{cs | valid?: false}

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :delete!, [cs], store)

      assert_raise Ecto.InvalidChangesetError, fn -> raise_fn.() end
    end
  end

  # -------------------------------------------------------------------
  # insert_or_update / insert_or_update!
  # -------------------------------------------------------------------

  describe "insert_or_update" do
    setup do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)
      :ok
    end

    test "inserts when changeset data is :built (new struct)" do
      cs = User.changeset(%User{}, %{name: "Alice"})
      assert Ecto.get_meta(cs.data, :state) == :built

      {:ok, user} = DoubleDown.Test.Repo.insert_or_update(cs)
      assert user.name == "Alice"
      assert user.id != nil
    end

    test "updates when changeset data is :loaded (existing struct)" do
      {:ok, user} = DoubleDown.Test.Repo.insert(User.changeset(%User{}, %{name: "Alice"}))
      assert Ecto.get_meta(user, :state) == :loaded

      cs = User.changeset(user, %{name: "Alice Updated"})
      {:ok, updated} = DoubleDown.Test.Repo.insert_or_update(cs)
      assert updated.name == "Alice Updated"
      assert updated.id == user.id
    end

    test "returns error for invalid changeset" do
      cs =
        %User{}
        |> User.changeset(%{name: "Alice"})
        |> Ecto.Changeset.add_error(:name, "is bad")

      assert {:error, %Ecto.Changeset{}} = DoubleDown.Test.Repo.insert_or_update(cs)
    end

    test "accepts opts" do
      cs = User.changeset(%User{}, %{name: "Alice"})
      {:ok, user} = DoubleDown.Test.Repo.insert_or_update(cs, returning: true)
      assert user.name == "Alice"
    end
  end

  describe "insert_or_update!" do
    setup do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)
      :ok
    end

    test "inserts new struct and returns record" do
      cs = User.changeset(%User{}, %{name: "Bob"})
      user = DoubleDown.Test.Repo.insert_or_update!(cs)
      assert user.name == "Bob"
    end

    test "updates loaded struct and returns record" do
      {:ok, user} = DoubleDown.Test.Repo.insert(User.changeset(%User{}, %{name: "Bob"}))
      cs = User.changeset(user, %{name: "Bob Updated"})
      updated = DoubleDown.Test.Repo.insert_or_update!(cs)
      assert updated.name == "Bob Updated"
    end

    test "raises on invalid changeset" do
      cs =
        %User{}
        |> User.changeset(%{name: "Bob"})
        |> Ecto.Changeset.add_error(:name, "is bad")

      assert_raise Ecto.InvalidChangesetError, fn ->
        DoubleDown.Test.Repo.insert_or_update!(cs)
      end
    end

    test "accepts opts" do
      cs = User.changeset(%User{}, %{name: "Bob"})
      user = DoubleDown.Test.Repo.insert_or_update!(cs, returning: true)
      assert user.name == "Bob"
    end
  end

  # -------------------------------------------------------------------
  # PK reads — closed-world
  # -------------------------------------------------------------------

  describe "get (closed-world)" do
    test "returns record when present" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = InMemory.dispatch(DoubleDown.Repo, :get, [User, 1], store)
      assert user.name == "Alice"
    end

    test "returns nil when absent (no fallback)" do
      store = InMemory.new()
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :get, [User, 999], store)
      assert result == nil
    end

    test "does NOT call fallback on miss" do
      store =
        InMemory.new([],
          fallback_fn: fn _contract, _op, _args, _state ->
            raise "fallback should not be called for get miss"
          end
        )

      {result, _} = InMemory.dispatch(DoubleDown.Repo, :get, [User, 999], store)
      assert result == nil
    end
  end

  describe "get! (closed-world)" do
    test "returns record when present" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = InMemory.dispatch(DoubleDown.Repo, :get!, [User, 1], store)
      assert user.name == "Alice"
    end

    test "raises when absent" do
      store = InMemory.new()

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :get!, [User, 999], store)

      assert_raise Ecto.NoResultsError, fn -> raise_fn.() end
    end
  end

  # -------------------------------------------------------------------
  # get_by — scan and filter (closed-world)
  # -------------------------------------------------------------------

  describe "get_by (closed-world)" do
    test "finds record by field" do
      store =
        InMemory.new([
          %User{id: 1, name: "Alice", email: "alice@example.com"},
          %User{id: 2, name: "Bob", email: "bob@example.com"}
        ])

      {user, _} =
        InMemory.dispatch(DoubleDown.Repo, :get_by, [User, [email: "alice@example.com"]], store)

      assert user.name == "Alice"
    end

    test "returns nil when no match" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :get_by, [User, [name: "Nobody"]], store)
      assert result == nil
    end

    test "matches on multiple clauses" do
      store =
        InMemory.new([
          %User{id: 1, name: "Alice", email: "alice@example.com"},
          %User{id: 2, name: "Alice", email: "alice2@example.com"}
        ])

      {user, _} =
        InMemory.dispatch(
          DoubleDown.Repo,
          :get_by,
          [User, [name: "Alice", email: "alice2@example.com"]],
          store
        )

      assert user.id == 2
    end
  end

  describe "get_by! (closed-world)" do
    test "returns matching record" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = InMemory.dispatch(DoubleDown.Repo, :get_by!, [User, [name: "Alice"]], store)
      assert user.id == 1
    end

    test "raises when no match" do
      store = InMemory.new()

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :get_by!, [User, [name: "Nobody"]], store)

      assert_raise Ecto.NoResultsError, fn -> raise_fn.() end
    end

    test "raises when multiple matches" do
      store =
        InMemory.new([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Alice"}
        ])

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :get_by!, [User, [name: "Alice"]], store)

      assert_raise Ecto.MultipleResultsError, fn -> raise_fn.() end
    end
  end

  # -------------------------------------------------------------------
  # load — stateless
  # -------------------------------------------------------------------

  describe "load" do
    setup do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)
      :ok
    end

    test "loads a schema from a map" do
      user = DoubleDown.Test.Repo.load(User, %{id: 1, name: "Alice"})
      assert %User{id: 1, name: "Alice"} = user
    end

    test "loads a schema from a keyword list" do
      user = DoubleDown.Test.Repo.load(User, id: 1, name: "Bob")
      assert %User{id: 1, name: "Bob"} = user
    end

    test "loads from {columns, values} tuple" do
      user = DoubleDown.Test.Repo.load(User, {[:id, :name], [1, "Carol"]})
      assert %User{id: 1, name: "Carol"} = user
    end
  end

  # -------------------------------------------------------------------
  # reload / reload! — closed-world
  # -------------------------------------------------------------------

  describe "reload (closed-world)" do
    setup do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)
      :ok
    end

    test "reloads existing record" do
      {:ok, user} = DoubleDown.Test.Repo.insert(User.changeset(%User{}, %{name: "Alice"}))
      reloaded = DoubleDown.Test.Repo.reload(user)
      assert reloaded.name == "Alice"
      assert reloaded.id == user.id
    end

    test "returns nil for missing record" do
      missing = %User{id: 999, name: "Ghost"}
      assert DoubleDown.Test.Repo.reload(missing) == nil
    end

    test "reflects updated values" do
      {:ok, user} = DoubleDown.Test.Repo.insert(User.changeset(%User{}, %{name: "Alice"}))
      {:ok, _} = DoubleDown.Test.Repo.update(User.changeset(user, %{name: "Updated"}))
      reloaded = DoubleDown.Test.Repo.reload(user)
      assert reloaded.name == "Updated"
    end

    test "reloads a list of structs" do
      {:ok, alice} = DoubleDown.Test.Repo.insert(User.changeset(%User{}, %{name: "Alice"}))
      {:ok, bob} = DoubleDown.Test.Repo.insert(User.changeset(%User{}, %{name: "Bob"}))
      missing = %User{id: 999, name: "Ghost"}

      result = DoubleDown.Test.Repo.reload([alice, bob, missing])
      assert length(result) == 3
      assert Enum.at(result, 0).name == "Alice"
      assert Enum.at(result, 1).name == "Bob"
      assert Enum.at(result, 2) == nil
    end

    test "accepts opts" do
      {:ok, user} = DoubleDown.Test.Repo.insert(User.changeset(%User{}, %{name: "Alice"}))
      reloaded = DoubleDown.Test.Repo.reload(user, prefix: "public")
      assert reloaded.name == "Alice"
    end
  end

  describe "reload! (closed-world)" do
    setup do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)
      :ok
    end

    test "reloads existing record" do
      {:ok, user} = DoubleDown.Test.Repo.insert(User.changeset(%User{}, %{name: "Alice"}))
      reloaded = DoubleDown.Test.Repo.reload!(user)
      assert reloaded.name == "Alice"
    end

    test "raises for missing record" do
      missing = %User{id: 999, name: "Ghost"}

      assert_raise RuntimeError, ~r/could not reload/, fn ->
        DoubleDown.Test.Repo.reload!(missing)
      end
    end

    test "reloads list of structs" do
      {:ok, alice} = DoubleDown.Test.Repo.insert(User.changeset(%User{}, %{name: "Alice"}))
      {:ok, bob} = DoubleDown.Test.Repo.insert(User.changeset(%User{}, %{name: "Bob"}))

      result = DoubleDown.Test.Repo.reload!([alice, bob])
      assert length(result) == 2
    end

    test "raises for list with missing record" do
      {:ok, alice} = DoubleDown.Test.Repo.insert(User.changeset(%User{}, %{name: "Alice"}))
      missing = %User{id: 999, name: "Ghost"}

      assert_raise RuntimeError, ~r/could not reload/, fn ->
        DoubleDown.Test.Repo.reload!([alice, missing])
      end
    end
  end

  # -------------------------------------------------------------------
  # all_by — closed-world
  # -------------------------------------------------------------------

  describe "all_by (closed-world)" do
    test "returns all matching records" do
      store =
        InMemory.new([
          %User{id: 1, name: "Alice", age: 30},
          %User{id: 2, name: "Bob", age: 30},
          %User{id: 3, name: "Carol", age: 25}
        ])

      {users, _} = InMemory.dispatch(DoubleDown.Repo, :all_by, [User, [age: 30]], store)
      assert length(users) == 2
      assert Enum.map(users, & &1.name) |> Enum.sort() == ["Alice", "Bob"]
    end

    test "returns empty list when no matches" do
      store = InMemory.new([%User{id: 1, name: "Alice", age: 30}])
      {users, _} = InMemory.dispatch(DoubleDown.Repo, :all_by, [User, [age: 99]], store)
      assert users == []
    end

    test "returns single match in a list" do
      store = InMemory.new([%User{id: 1, name: "Alice", age: 30}])
      {users, _} = InMemory.dispatch(DoubleDown.Repo, :all_by, [User, [name: "Alice"]], store)
      assert length(users) == 1
      assert hd(users).name == "Alice"
    end

    test "strips opts" do
      store = InMemory.new([%User{id: 1, name: "Alice", age: 30}])

      {users, _} =
        InMemory.dispatch(
          DoubleDown.Repo,
          :all_by,
          [User, [name: "Alice"], [timeout: 5000]],
          store
        )

      assert length(users) == 1
    end
  end

  # -------------------------------------------------------------------
  # Collection reads — closed-world
  # -------------------------------------------------------------------

  describe "all (closed-world)" do
    test "returns all records of a schema" do
      store =
        InMemory.new([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"},
          %Post{id: 1, title: "Hello"}
        ])

      {users, _} = InMemory.dispatch(DoubleDown.Repo, :all, [User], store)
      assert length(users) == 2
      assert Enum.map(users, & &1.name) |> Enum.sort() == ["Alice", "Bob"]
    end

    test "returns empty list when no records" do
      store = InMemory.new()
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :all, [User], store)
      assert result == []
    end
  end

  describe "one (closed-world)" do
    test "returns the single record" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = InMemory.dispatch(DoubleDown.Repo, :one, [User], store)
      assert user.name == "Alice"
    end

    test "returns nil when no records" do
      store = InMemory.new()
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :one, [User], store)
      assert result == nil
    end

    test "raises when multiple records" do
      store = InMemory.new([%User{id: 1, name: "Alice"}, %User{id: 2, name: "Bob"}])

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :one, [User], store)

      assert_raise Ecto.MultipleResultsError, fn -> raise_fn.() end
    end
  end

  describe "one! (closed-world)" do
    test "returns the single record" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = InMemory.dispatch(DoubleDown.Repo, :one!, [User], store)
      assert user.name == "Alice"
    end

    test "raises when no records" do
      store = InMemory.new()

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :one!, [User], store)

      assert_raise Ecto.NoResultsError, fn -> raise_fn.() end
    end

    test "raises when multiple records" do
      store = InMemory.new([%User{id: 1, name: "Alice"}, %User{id: 2, name: "Bob"}])

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :one!, [User], store)

      assert_raise Ecto.MultipleResultsError, fn -> raise_fn.() end
    end
  end

  describe "exists? (closed-world)" do
    test "returns true when records exist" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :exists?, [User], store)
      assert result == true
    end

    test "returns false when no records" do
      store = InMemory.new()
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :exists?, [User], store)
      assert result == false
    end
  end

  # -------------------------------------------------------------------
  # Aggregates
  # -------------------------------------------------------------------

  describe "aggregate (closed-world)" do
    test "count returns number of records" do
      store = InMemory.new([%User{id: 1}, %User{id: 2}, %User{id: 3}])
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :aggregate, [User, :count, :id], store)
      assert result == 3
    end

    test "count returns 0 for empty schema" do
      store = InMemory.new()
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :aggregate, [User, :count, :id], store)
      assert result == 0
    end

    test "sum computes sum of field values" do
      store =
        InMemory.new([
          %User{id: 1, age: 25},
          %User{id: 2, age: 30},
          %User{id: 3, age: 35}
        ])

      {result, _} = InMemory.dispatch(DoubleDown.Repo, :aggregate, [User, :sum, :age], store)
      assert result == 90
    end

    test "avg computes average of field values" do
      store = InMemory.new([%User{id: 1, age: 20}, %User{id: 2, age: 30}])
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :aggregate, [User, :avg, :age], store)
      assert result == 25.0
    end

    test "min returns minimum field value" do
      store = InMemory.new([%User{id: 1, age: 25}, %User{id: 2, age: 18}])
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :aggregate, [User, :min, :age], store)
      assert result == 18
    end

    test "max returns maximum field value" do
      store = InMemory.new([%User{id: 1, age: 25}, %User{id: 2, age: 40}])
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :aggregate, [User, :max, :age], store)
      assert result == 40
    end

    test "returns nil for empty schema (non-count)" do
      store = InMemory.new()
      {result, _} = InMemory.dispatch(DoubleDown.Repo, :aggregate, [User, :sum, :age], store)
      assert result == nil
    end

    test "excludes nil field values" do
      store =
        InMemory.new([
          %User{id: 1, age: 25},
          %User{id: 2, age: nil},
          %User{id: 3, age: 35}
        ])

      {result, _} = InMemory.dispatch(DoubleDown.Repo, :aggregate, [User, :sum, :age], store)
      assert result == 60
    end
  end

  # -------------------------------------------------------------------
  # Bulk writes
  # -------------------------------------------------------------------

  describe "insert_all" do
    test "inserts multiple entries and returns count" do
      store = InMemory.new()

      entries = [%{name: "Alice", email: "a@b.com"}, %{name: "Bob", email: "b@b.com"}]

      {{count, nil}, store} =
        InMemory.dispatch(DoubleDown.Repo, :insert_all, [User, entries, []], store)

      assert count == 2

      {users, _} = InMemory.dispatch(DoubleDown.Repo, :all, [User], store)
      assert length(users) == 2
    end

    test "returns records with :returning option" do
      store = InMemory.new()

      entries = [%{name: "Alice"}]

      {{1, [user]}, _store} =
        InMemory.dispatch(DoubleDown.Repo, :insert_all, [User, entries, [returning: true]], store)

      assert user.name == "Alice"
    end

    test "raises ArgumentError for missing non-autogenerated PKs" do
      store = InMemory.new()
      entries = [%{name: "Alice"}, %{name: "Bob"}]

      assert_raise ArgumentError, fn ->
        InMemory.dispatch(DoubleDown.Repo, :insert_all, [ManualPkRecord, entries, []], store)
      end
    end

    test "returning: field list returns maps with only those fields" do
      store = InMemory.new()
      entries = [%{name: "Alice", email: "a@b.com"}, %{name: "Bob", email: "b@b.com"}]

      {{2, returned}, _store} =
        InMemory.dispatch(
          DoubleDown.Repo,
          :insert_all,
          [User, entries, [returning: [:id, :name]]],
          store
        )

      assert length(returned) == 2
      assert [%{name: "Alice"}, %{name: "Bob"}] = returned
      # Should not contain fields outside the returning list
      refute Map.has_key?(hd(returned), :email)
    end

    test "silently ignores on_conflict option" do
      store = InMemory.new()
      entries = [%{name: "Alice"}]

      {{1, nil}, _store} =
        InMemory.dispatch(
          DoubleDown.Repo,
          :insert_all,
          [User, entries, [on_conflict: :nothing, conflict_target: [:email]]],
          store
        )
    end

    test "raises descriptive error for binary table name source" do
      store = InMemory.new()
      entries = [%{name: "Alice"}]

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :insert_all, ["users", entries, []], store)

      assert_raise ArgumentError, ~r/does not support binary table name/, fn -> raise_fn.() end
    end
  end

  describe "delete_all" do
    test "deletes all records of a schema" do
      store = InMemory.new([%User{id: 1}, %User{id: 2}, %Post{id: 1, title: "Hi"}])

      {{count, nil}, store} = InMemory.dispatch(DoubleDown.Repo, :delete_all, [User], store)
      assert count == 2

      {users, _} = InMemory.dispatch(DoubleDown.Repo, :all, [User], store)
      assert users == []

      # Post is unaffected
      {posts, _} = InMemory.dispatch(DoubleDown.Repo, :all, [Post], store)
      assert length(posts) == 1
    end
  end

  describe "update_all" do
    test "applies set updates to all records" do
      store =
        InMemory.new([
          %User{id: 1, name: "Alice", age: 25},
          %User{id: 2, name: "Bob", age: 30}
        ])

      {{count, nil}, store} =
        InMemory.dispatch(DoubleDown.Repo, :update_all, [User, [set: [age: 99]]], store)

      assert count == 2

      {users, _} = InMemory.dispatch(DoubleDown.Repo, :all, [User], store)
      assert Enum.all?(users, &(&1.age == 99))
    end

    test "non-set updates fall to fallback" do
      store = InMemory.new()

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :update_all, [User, [inc: [age: 1]]], store)

      assert_raise ArgumentError, ~r/cannot service/, fn -> raise_fn.() end
    end
  end

  # -------------------------------------------------------------------
  # Ecto.Query fallback
  # -------------------------------------------------------------------

  describe "Ecto.Query fallback" do
    test "all with Ecto.Query falls to fallback" do
      query = Ecto.Query.from(u in User, where: u.age > 21)

      store =
        InMemory.new([],
          fallback_fn: fn _contract, :all, [_query], _state -> [%User{id: 1, name: "Alice"}] end
        )

      {result, _} = InMemory.dispatch(DoubleDown.Repo, :all, [query], store)
      assert [%User{name: "Alice"}] = result
    end

    test "all with Ecto.Query raises when no fallback" do
      query = Ecto.Query.from(u in User)
      store = InMemory.new()

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :all, [query], store)

      assert_raise ArgumentError, ~r/cannot service/, fn -> raise_fn.() end
    end
  end

  # -------------------------------------------------------------------
  # Integration with Double API
  # -------------------------------------------------------------------

  describe "Double.fallback integration" do
    test "works with Double.fallback/2" do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)

      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})
      assert {:ok, user} = DoubleDown.Test.Repo.insert(cs)
      assert user.name == "Alice"

      # Closed-world read
      assert [^user] = DoubleDown.Test.Repo.all(User)
    end

    test "works with Double.fallback/3 and seed data" do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory, [
        %User{id: 1, name: "Alice"},
        %User{id: 2, name: "Bob"}
      ])

      assert [_, _] = DoubleDown.Test.Repo.all(User)
      assert %User{name: "Alice"} = DoubleDown.Test.Repo.get(User, 1)
      assert nil == DoubleDown.Test.Repo.get(User, 999)
    end

    test "insert! bare struct through facade backfills FK" do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)

      org = DoubleDown.Test.Repo.insert!(%Organisation{name: "Acme"})

      child =
        DoubleDown.Test.Repo.insert!(%TaskCategory{
          name: "Widgets",
          organisation: org,
          organisation_id: nil
        })

      assert child.organisation_id == org.id
      assert child.organisation_id != nil
    end

    test "layering expects over InMemory" do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)

      # First insert succeeds
      DoubleDown.Double.expect(DoubleDown.Repo, :insert, :passthrough)

      # Second insert fails
      DoubleDown.Double.expect(DoubleDown.Repo, :insert, fn [cs] ->
        {:error, Ecto.Changeset.add_error(cs, :email, "taken")}
      end)

      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})
      assert {:ok, _} = DoubleDown.Test.Repo.insert(cs)
      assert {:error, _} = DoubleDown.Test.Repo.insert(cs)
    end
  end

  # -------------------------------------------------------------------
  # Opts-stripping
  # -------------------------------------------------------------------

  describe "opts-accepting variants" do
    test "get with opts" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = InMemory.dispatch(DoubleDown.Repo, :get, [User, 1, [prefix: "test"]], store)
      assert user.name == "Alice"
    end

    test "all with opts" do
      store = InMemory.new([%User{id: 1, name: "Alice"}])
      {users, _} = InMemory.dispatch(DoubleDown.Repo, :all, [User, [prefix: "test"]], store)
      assert length(users) == 1
    end
  end

  # -------------------------------------------------------------------
  # Transaction rollback — state restoration
  # -------------------------------------------------------------------

  describe "transaction rollback restores state" do
    setup do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)
      :ok
    end

    test "rollback undoes inserts" do
      result =
        DoubleDown.Test.Repo.transact(
          fn ->
            {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))
            DoubleDown.Test.Repo.rollback(:aborted)
          end,
          []
        )

      assert {:error, :aborted} = result

      # The insert should have been rolled back
      assert [] == DoubleDown.Test.Repo.all(User)
    end

    test "rollback preserves pre-transaction state" do
      # Insert before transaction
      {:ok, alice} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))

      result =
        DoubleDown.Test.Repo.transact(
          fn ->
            {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Bob"}))
            DoubleDown.Test.Repo.rollback(:aborted)
          end,
          []
        )

      assert {:error, :aborted} = result

      # Alice should still be there, Bob should not
      users = DoubleDown.Test.Repo.all(User)
      assert length(users) == 1
      assert hd(users).name == "Alice"
      assert ^alice = DoubleDown.Test.Repo.get(User, alice.id)
    end

    test "rollback undoes updates" do
      {:ok, alice} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))

      result =
        DoubleDown.Test.Repo.transact(
          fn ->
            cs = Ecto.Changeset.cast(alice, %{name: "CHANGED"}, [:name])
            {:ok, _} = DoubleDown.Test.Repo.update(cs)
            DoubleDown.Test.Repo.rollback(:aborted)
          end,
          []
        )

      assert {:error, :aborted} = result

      # Name should be restored to "Alice"
      found = DoubleDown.Test.Repo.get(User, alice.id)
      assert found.name == "Alice"
    end

    test "rollback undoes deletes" do
      {:ok, alice} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))

      result =
        DoubleDown.Test.Repo.transact(
          fn ->
            {:ok, _} = DoubleDown.Test.Repo.delete(alice)
            DoubleDown.Test.Repo.rollback(:aborted)
          end,
          []
        )

      assert {:error, :aborted} = result

      # Alice should still be there
      assert %User{name: "Alice"} = DoubleDown.Test.Repo.get(User, alice.id)
    end

    test "successful transaction commits normally" do
      result =
        DoubleDown.Test.Repo.transact(
          fn ->
            {:ok, user} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))
            {:ok, user}
          end,
          []
        )

      assert {:ok, %User{name: "Alice"}} = result

      # The insert should be committed
      assert [%User{name: "Alice"}] = DoubleDown.Test.Repo.all(User)
    end

    test "rollback in a Task restores state to the correct owner" do
      # Insert before transaction
      {:ok, _alice} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))

      # Run a transaction that inserts + rolls back inside a Task.
      # Task.async sets $callers, so resolve_test_handler finds the
      # test process as owner — restore_state must target that pid,
      # not the Task pid.
      task =
        Task.async(fn ->
          DoubleDown.Test.Repo.transact(
            fn ->
              {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Bob"}))
              DoubleDown.Test.Repo.rollback(:aborted)
            end,
            []
          )
        end)

      assert {:error, :aborted} = Task.await(task)

      # Alice survives, Bob was rolled back
      users = DoubleDown.Test.Repo.all(User)
      assert length(users) == 1
      assert hd(users).name == "Alice"
    end

    test "cross-contract isolation — rollback only affects Repo state" do
      # Set up a second contract with its own state
      DoubleDown.Double.fallback(
        DoubleDown.Test.Greeter,
        fn
          _contract, _op, _args, state -> {"hello", state}
        end,
        %{counter: 0}
      )

      # Run a Repo transaction that rolls back
      DoubleDown.Test.Repo.transact(
        fn ->
          {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))
          DoubleDown.Test.Repo.rollback(:aborted)
        end,
        []
      )

      # Repo state is restored (no Alice)
      assert [] == DoubleDown.Test.Repo.all(User)

      # Greeter state is unaffected
      greeter_state = DoubleDown.Contract.Dispatch.get_state(DoubleDown.Test.Greeter)
      assert greeter_state == %{counter: 0}
    end

    test "{:error, _} return from callback restores state" do
      {:ok, _alice} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))

      result =
        DoubleDown.Test.Repo.transact(
          fn ->
            {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Bob"}))
            {:error, :something_went_wrong}
          end,
          []
        )

      assert {:error, :something_went_wrong} = result

      # Bob was rolled back, Alice survives
      users = DoubleDown.Test.Repo.all(User)
      assert length(users) == 1
      assert hd(users).name == "Alice"
    end

    test "raised exception restores state and re-raises" do
      {:ok, _alice} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))

      assert_raise RuntimeError, "boom", fn ->
        DoubleDown.Test.Repo.transact(
          fn ->
            {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Bob"}))
            raise "boom"
          end,
          []
        )
      end

      # Bob was rolled back, Alice survives
      users = DoubleDown.Test.Repo.all(User)
      assert length(users) == 1
      assert hd(users).name == "Alice"
    end

    test "failed Ecto.Multi step restores state" do
      {:ok, _alice} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))

      # Build a Multi with a valid insert followed by an explicit error
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:bob, User.changeset(%{name: "Bob"}))
        |> Ecto.Multi.run(:fail, fn _repo, _changes ->
          {:error, :intentional_failure}
        end)

      result = DoubleDown.Test.Repo.transact(multi, [])

      assert {:error, :fail, :intentional_failure, %{bob: %User{name: "Bob"}}} = result

      # Bob was rolled back despite the successful insert step, Alice survives
      users = DoubleDown.Test.Repo.all(User)
      assert length(users) == 1
      assert hd(users).name == "Alice"
    end

    test "rollback outside transaction raises RuntimeError" do
      assert_raise RuntimeError, ~r/cannot call rollback outside of transaction/, fn ->
        DoubleDown.Test.Repo.rollback(:oops)
      end
    end
  end

  # -------------------------------------------------------------------
  # Transaction args normalisation (DynamicFacade compatibility)
  #
  # When dispatched via DynamicFacade (not ContractFacade), transaction
  # args bypass pre_dispatch — 1-arity fns aren't wrapped and opts may
  # be missing. These tests verify the normalisation handles all variants.
  # -------------------------------------------------------------------

  describe "transaction args normalisation" do
    setup do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)
      :ok
    end

    test "0-arity fn without opts" do
      # Simulates DynamicFacade: Repo.transaction(fn -> :ok end)
      # dispatched as :transaction with args [fn/0]
      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          DoubleDown.Repo,
          :transaction,
          [fn -> {:ok, :zero_arity} end]
        )

      assert {:ok, :zero_arity} = result
    end

    test "1-arity fn without opts" do
      # Simulates DynamicFacade: Repo.transaction(fn repo -> repo.insert(...) end)
      # dispatched as :transaction with args [fn/1].
      # The 1-arity fn receives the contract module — in DynamicFacade
      # scenarios, the contract IS the facade module (e.g. Backend.Repo).
      # Here we use DoubleDown.Test.Repo since that's the facade.
      alias DoubleDown.Test.Repo, as: TestRepo

      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          DoubleDown.Repo,
          :transaction,
          [
            fn _repo ->
              {:ok, _} = TestRepo.insert(User.changeset(%{name: "Alice"}))
              {:ok, :inserted}
            end
          ]
        )

      assert {:ok, :inserted} = result
      assert [%User{name: "Alice"}] = TestRepo.all(User)
    end

    test "1-arity fn with opts" do
      alias DoubleDown.Test.Repo, as: TestRepo

      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          DoubleDown.Repo,
          :transaction,
          [
            fn _repo ->
              {:ok, _} = TestRepo.insert(User.changeset(%{name: "Bob"}))
              {:ok, :inserted_with_opts}
            end,
            [timeout: 5000]
          ]
        )

      assert {:ok, :inserted_with_opts} = result
    end

    test "0-arity fn with opts (normal ContractFacade path)" do
      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          DoubleDown.Repo,
          :transaction,
          [fn -> {:ok, :with_opts} end, []]
        )

      assert {:ok, :with_opts} = result
    end

    test "transact operation also normalises" do
      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          DoubleDown.Repo,
          :transact,
          [fn -> {:ok, :transact_zero} end]
        )

      assert {:ok, :transact_zero} = result
    end

    test "bare return value wrapped in {:ok, result}" do
      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          DoubleDown.Repo,
          :transaction,
          [fn -> :hello end]
        )

      assert {:ok, :hello} = result
    end

    test "{:ok, value} returned as-is (not double-wrapped)" do
      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          DoubleDown.Repo,
          :transaction,
          [fn -> {:ok, :already_tagged} end]
        )

      assert {:ok, :already_tagged} = result
    end

    test "{:error, value} returned as-is and state rolled back" do
      alias DoubleDown.Test.Repo, as: TestRepo

      {:ok, _} = TestRepo.insert(User.changeset(%{name: "Before"}))

      result =
        DoubleDown.Contract.Dispatch.call(
          :double_down,
          DoubleDown.Repo,
          :transaction,
          [
            fn ->
              {:ok, _} = TestRepo.insert(User.changeset(%{name: "Inside"}))
              {:error, :aborted}
            end,
            []
          ]
        )

      assert {:error, :aborted} = result
      # Only the pre-transaction record should remain
      assert [%User{name: "Before"}] = TestRepo.all(User)
    end
  end

  # -------------------------------------------------------------------
  # in_transaction?
  # -------------------------------------------------------------------

  describe "in_transaction?" do
    setup do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)
      :ok
    end

    test "returns false outside a transaction" do
      refute DoubleDown.Test.Repo.in_transaction?()
    end

    test "returns true inside a transaction" do
      DoubleDown.Test.Repo.transact(
        fn ->
          assert DoubleDown.Test.Repo.in_transaction?()
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
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)
      :ok
    end

    test "0-arity fun success" do
      assert {:ok, :done} =
               DoubleDown.Test.Repo.transaction(fn -> {:ok, :done} end, [])
    end

    test "rollback undoes inserts and restores state" do
      {:ok, alice} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))

      result =
        DoubleDown.Test.Repo.transaction(
          fn ->
            {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Bob"}))
            DoubleDown.Test.Repo.rollback(:aborted)
          end,
          []
        )

      assert {:error, :aborted} = result
      assert [^alice] = DoubleDown.Test.Repo.all(User)
    end

    test "Multi via transaction" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%{name: "Alice"}))

      assert {:ok, %{user: %User{name: "Alice"}}} =
               DoubleDown.Test.Repo.transaction(multi, [])
    end

    test "in_transaction? returns true inside transaction" do
      DoubleDown.Test.Repo.transaction(
        fn ->
          assert DoubleDown.Test.Repo.in_transaction?()
          {:ok, :done}
        end,
        []
      )
    end
  end

  # -------------------------------------------------------------------
  # Ecto.Multi bulk operations
  # -------------------------------------------------------------------

  describe "Ecto.Multi bulk operations" do
    setup do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)
      :ok
    end

    test "Multi.insert_all mutates fake state" do
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.insert_all(:users, User, [%{name: "Alice"}, %{name: "Bob"}])

      assert {:ok, %{users: {2, nil}}} = DoubleDown.Test.Repo.transact(multi, [])

      users = DoubleDown.Test.Repo.all(User)
      assert length(users) == 2
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob"]
    end

    test "Multi.delete_all via :run callback mutates fake state" do
      {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))
      {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Bob"}))

      # Ecto.Multi.delete_all wraps the schema in an Ecto.Query, which
      # InMemory can't evaluate. Use a :run callback with the bare schema.
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:purge, fn repo, _changes ->
          {count, nil} = repo.delete_all(User, [])
          {:ok, {count, nil}}
        end)

      assert {:ok, %{purge: {2, nil}}} = DoubleDown.Test.Repo.transact(multi, [])
      assert [] == DoubleDown.Test.Repo.all(User)
    end

    test "Multi.update_all via :run callback mutates fake state" do
      {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))
      {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Bob"}))

      # Same as delete_all — use :run callback to pass bare schema.
      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:rename, fn repo, _changes ->
          {count, nil} = repo.update_all(User, [set: [name: "Updated"]], [])
          {:ok, {count, nil}}
        end)

      assert {:ok, %{rename: {2, nil}}} = DoubleDown.Test.Repo.transact(multi, [])

      users = DoubleDown.Test.Repo.all(User)
      assert Enum.all?(users, &(&1.name == "Updated"))
    end
  end

  # -------------------------------------------------------------------
  # @primary_key false schema support
  # -------------------------------------------------------------------

  describe "@primary_key false schemas" do
    setup do
      DoubleDown.Double.fallback(DoubleDown.Repo, InMemory)
      :ok
    end

    test "multiple inserts are all preserved" do
      {:ok, _a} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "a"}))
      {:ok, _b} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "b"}))
      {:ok, _c} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "c"}))

      events = DoubleDown.Test.Repo.all(NoPkEvent)
      assert length(events) == 3
      names = Enum.map(events, & &1.name) |> Enum.sort()
      assert names == ["a", "b", "c"]
    end

    test "seeding multiple rows preserves all of them" do
      store =
        InMemory.new([
          %NoPkEvent{name: "x"},
          %NoPkEvent{name: "y"}
        ])

      records = InMemoryShared.records_for_schema(store, NoPkEvent)
      assert length(records) == 2
      names = Enum.map(records, & &1.name) |> Enum.sort()
      assert names == ["x", "y"]
    end

    test "delete removes the specific record" do
      {:ok, a} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "a"}))
      {:ok, _b} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "b"}))

      {:ok, _} = DoubleDown.Test.Repo.delete(a)

      events = DoubleDown.Test.Repo.all(NoPkEvent)
      assert length(events) == 1
      assert hd(events).name == "b"
    end

    test "delete_all removes all records" do
      {:ok, _} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "a"}))
      {:ok, _} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "b"}))

      {count, nil} = DoubleDown.Test.Repo.delete_all(NoPkEvent, [])
      assert count == 2
      assert [] == DoubleDown.Test.Repo.all(NoPkEvent)
    end

    test "update_all applies updates to all records" do
      {:ok, _} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "a"}))
      {:ok, _} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "b"}))

      {count, nil} = DoubleDown.Test.Repo.update_all(NoPkEvent, [set: [name: "updated"]], [])
      assert count == 2

      events = DoubleDown.Test.Repo.all(NoPkEvent)
      assert Enum.all?(events, &(&1.name == "updated"))
    end

    test "get returns nil for no-PK schemas" do
      {:ok, _} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "a"}))
      assert nil == DoubleDown.Test.Repo.get(NoPkEvent, 1)
    end

    test "exists? returns true when records exist" do
      {:ok, _} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "a"}))
      assert DoubleDown.Test.Repo.exists?(NoPkEvent) == true
    end

    test "coexists with PK schemas in the same store" do
      {:ok, _} = DoubleDown.Test.Repo.insert(User.changeset(%{name: "Alice"}))
      {:ok, _} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "a"}))
      {:ok, _} = DoubleDown.Test.Repo.insert(NoPkEvent.changeset(%{name: "b"}))

      assert [%User{name: "Alice"}] = DoubleDown.Test.Repo.all(User)
      assert length(DoubleDown.Test.Repo.all(NoPkEvent)) == 2
    end
  end

  # -------------------------------------------------------------------
  # query / query! — raw SQL, always fallback
  # -------------------------------------------------------------------

  describe "query" do
    test "delegates to fallback" do
      store =
        InMemory.new([],
          fallback_fn: fn _contract, :query, ["SELECT 1"], _state -> {:ok, %{rows: [[1]]}} end
        )

      {{:ok, %{rows: [[1]]}}, _} = InMemory.dispatch(DoubleDown.Repo, :query, ["SELECT 1"], store)
    end

    test "delegates to fallback with params" do
      store =
        InMemory.new([],
          fallback_fn: fn _contract, :query, ["SELECT $1", [42]], _state ->
            {:ok, %{rows: [[42]]}}
          end
        )

      {{:ok, %{rows: [[42]]}}, _} =
        InMemory.dispatch(DoubleDown.Repo, :query, ["SELECT $1", [42]], store)
    end

    test "raises helpful error when no fallback" do
      store = InMemory.new()

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :query, ["SELECT 1"], store)

      assert_raise ArgumentError, ~r/cannot service :query/, fn -> raise_fn.() end
    end
  end

  describe "query!" do
    test "delegates to fallback" do
      store =
        InMemory.new([],
          fallback_fn: fn _contract, :query!, ["SELECT 1"], _state -> %{rows: [[1]]} end
        )

      {%{rows: [[1]]}, _} = InMemory.dispatch(DoubleDown.Repo, :query!, ["SELECT 1"], store)
    end

    test "raises helpful error when no fallback" do
      store = InMemory.new()

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :query!, ["SELECT 1"], store)

      assert_raise ArgumentError, ~r/cannot service :query!/, fn -> raise_fn.() end
    end
  end

  # -------------------------------------------------------------------
  # Catch-all dispatch — unrecognised operations delegate to fallback
  # -------------------------------------------------------------------

  describe "catch-all dispatch" do
    test "unrecognised operation delegates to fallback" do
      store =
        InMemory.new([],
          fallback_fn: fn _contract, :some_future_op, [42], _state -> :handled end
        )

      {:handled, _} = InMemory.dispatch(DoubleDown.Repo, :some_future_op, [42], store)
    end

    test "unrecognised operation raises helpful error when no fallback" do
      store = InMemory.new()

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :some_future_op, [42], store)

      assert_raise ArgumentError, ~r/cannot service :some_future_op/, fn -> raise_fn.() end
    end
  end

  # -------------------------------------------------------------------
  # stream — always fallback
  # -------------------------------------------------------------------

  describe "stream" do
    test "delegates to fallback" do
      query = Ecto.Query.from(u in User)

      store =
        InMemory.new([],
          fallback_fn: fn _contract, :stream, [_query], _state ->
            Stream.map([%User{id: 1, name: "Alice"}], & &1)
          end
        )

      {stream, _} = InMemory.dispatch(DoubleDown.Repo, :stream, [query], store)
      assert [%User{name: "Alice"}] = Enum.to_list(stream)
    end

    test "raises helpful error when no fallback" do
      store = InMemory.new()

      {%DoubleDown.Contract.Dispatch.Defer{fun: raise_fn}, _} =
        InMemory.dispatch(DoubleDown.Repo, :stream, [User], store)

      assert_raise ArgumentError, ~r/cannot service :stream/, fn -> raise_fn.() end
    end
  end
end
