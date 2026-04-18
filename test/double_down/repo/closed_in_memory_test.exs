defmodule DoubleDown.Repo.ClosedInMemoryTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Repo.ClosedInMemory
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

  # -------------------------------------------------------------------
  # Write operations
  # -------------------------------------------------------------------

  describe "insert" do
    test "inserts a valid changeset and stores the record" do
      store = ClosedInMemory.new()
      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})

      {{:ok, user}, store} = ClosedInMemory.dispatch(:insert, [cs], store)
      assert user.name == "Alice"
      assert user.id != nil

      # Read back
      {found, _store} = ClosedInMemory.dispatch(:get, [User, user.id], store)
      assert found.name == "Alice"
    end

    test "rejects invalid changeset" do
      store = ClosedInMemory.new()
      cs = %Ecto.Changeset{valid?: false, errors: [name: {"required", []}]}

      {{:error, ^cs}, ^store} = ClosedInMemory.dispatch(:insert, [cs], store)
    end
  end

  describe "update" do
    test "updates a record in the store" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}])

      cs =
        %User{id: 1, name: "Alice"}
        |> User.changeset(%{name: "Alicia"})

      {{:ok, updated}, store} = ClosedInMemory.dispatch(:update, [cs], store)
      assert updated.name == "Alicia"

      {found, _} = ClosedInMemory.dispatch(:get, [User, 1], store)
      assert found.name == "Alicia"
    end
  end

  describe "delete" do
    test "removes a record from the store" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}])

      {{:ok, _}, store} = ClosedInMemory.dispatch(:delete, [%User{id: 1}], store)

      {found, _} = ClosedInMemory.dispatch(:get, [User, 1], store)
      assert found == nil
    end
  end

  # -------------------------------------------------------------------
  # PK reads — closed-world
  # -------------------------------------------------------------------

  describe "get (closed-world)" do
    test "returns record when present" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = ClosedInMemory.dispatch(:get, [User, 1], store)
      assert user.name == "Alice"
    end

    test "returns nil when absent (no fallback)" do
      store = ClosedInMemory.new()
      {result, _} = ClosedInMemory.dispatch(:get, [User, 999], store)
      assert result == nil
    end

    test "does NOT call fallback on miss" do
      store =
        ClosedInMemory.new([],
          fallback_fn: fn _op, _args, _state ->
            raise "fallback should not be called for get miss"
          end
        )

      {result, _} = ClosedInMemory.dispatch(:get, [User, 999], store)
      assert result == nil
    end
  end

  describe "get! (closed-world)" do
    test "returns record when present" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = ClosedInMemory.dispatch(:get!, [User, 1], store)
      assert user.name == "Alice"
    end

    test "raises when absent" do
      store = ClosedInMemory.new()

      {%DoubleDown.Dispatch.Defer{fn: raise_fn}, _} =
        ClosedInMemory.dispatch(:get!, [User, 999], store)

      assert_raise ArgumentError, ~r/not found/, fn -> raise_fn.() end
    end
  end

  # -------------------------------------------------------------------
  # get_by — scan and filter (closed-world)
  # -------------------------------------------------------------------

  describe "get_by (closed-world)" do
    test "finds record by field" do
      store =
        ClosedInMemory.new([
          %User{id: 1, name: "Alice", email: "alice@example.com"},
          %User{id: 2, name: "Bob", email: "bob@example.com"}
        ])

      {user, _} = ClosedInMemory.dispatch(:get_by, [User, [email: "alice@example.com"]], store)
      assert user.name == "Alice"
    end

    test "returns nil when no match" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}])
      {result, _} = ClosedInMemory.dispatch(:get_by, [User, [name: "Nobody"]], store)
      assert result == nil
    end

    test "matches on multiple clauses" do
      store =
        ClosedInMemory.new([
          %User{id: 1, name: "Alice", email: "alice@example.com"},
          %User{id: 2, name: "Alice", email: "alice2@example.com"}
        ])

      {user, _} =
        ClosedInMemory.dispatch(
          :get_by,
          [User, [name: "Alice", email: "alice2@example.com"]],
          store
        )

      assert user.id == 2
    end
  end

  describe "get_by! (closed-world)" do
    test "returns matching record" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = ClosedInMemory.dispatch(:get_by!, [User, [name: "Alice"]], store)
      assert user.id == 1
    end

    test "raises when no match" do
      store = ClosedInMemory.new()

      {%DoubleDown.Dispatch.Defer{fn: raise_fn}, _} =
        ClosedInMemory.dispatch(:get_by!, [User, [name: "Nobody"]], store)

      assert_raise ArgumentError, ~r/no matching record/, fn -> raise_fn.() end
    end

    test "raises when multiple matches" do
      store =
        ClosedInMemory.new([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Alice"}
        ])

      {%DoubleDown.Dispatch.Defer{fn: raise_fn}, _} =
        ClosedInMemory.dispatch(:get_by!, [User, [name: "Alice"]], store)

      assert_raise ArgumentError, ~r/found 2 records/, fn -> raise_fn.() end
    end
  end

  # -------------------------------------------------------------------
  # Collection reads — closed-world
  # -------------------------------------------------------------------

  describe "all (closed-world)" do
    test "returns all records of a schema" do
      store =
        ClosedInMemory.new([
          %User{id: 1, name: "Alice"},
          %User{id: 2, name: "Bob"},
          %Post{id: 1, title: "Hello"}
        ])

      {users, _} = ClosedInMemory.dispatch(:all, [User], store)
      assert length(users) == 2
      assert Enum.map(users, & &1.name) |> Enum.sort() == ["Alice", "Bob"]
    end

    test "returns empty list when no records" do
      store = ClosedInMemory.new()
      {result, _} = ClosedInMemory.dispatch(:all, [User], store)
      assert result == []
    end
  end

  describe "one (closed-world)" do
    test "returns the single record" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = ClosedInMemory.dispatch(:one, [User], store)
      assert user.name == "Alice"
    end

    test "returns nil when no records" do
      store = ClosedInMemory.new()
      {result, _} = ClosedInMemory.dispatch(:one, [User], store)
      assert result == nil
    end

    test "raises when multiple records" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}, %User{id: 2, name: "Bob"}])
      {%DoubleDown.Dispatch.Defer{fn: raise_fn}, _} = ClosedInMemory.dispatch(:one, [User], store)
      assert_raise ArgumentError, ~r/found 2/, fn -> raise_fn.() end
    end
  end

  describe "one! (closed-world)" do
    test "returns the single record" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = ClosedInMemory.dispatch(:one!, [User], store)
      assert user.name == "Alice"
    end

    test "raises when no records" do
      store = ClosedInMemory.new()

      {%DoubleDown.Dispatch.Defer{fn: raise_fn}, _} =
        ClosedInMemory.dispatch(:one!, [User], store)

      assert_raise ArgumentError, ~r/found none/, fn -> raise_fn.() end
    end

    test "raises when multiple records" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}, %User{id: 2, name: "Bob"}])

      {%DoubleDown.Dispatch.Defer{fn: raise_fn}, _} =
        ClosedInMemory.dispatch(:one!, [User], store)

      assert_raise ArgumentError, ~r/found 2/, fn -> raise_fn.() end
    end
  end

  describe "exists? (closed-world)" do
    test "returns true when records exist" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}])
      {result, _} = ClosedInMemory.dispatch(:exists?, [User], store)
      assert result == true
    end

    test "returns false when no records" do
      store = ClosedInMemory.new()
      {result, _} = ClosedInMemory.dispatch(:exists?, [User], store)
      assert result == false
    end
  end

  # -------------------------------------------------------------------
  # Aggregates
  # -------------------------------------------------------------------

  describe "aggregate (closed-world)" do
    test "count returns number of records" do
      store = ClosedInMemory.new([%User{id: 1}, %User{id: 2}, %User{id: 3}])
      {result, _} = ClosedInMemory.dispatch(:aggregate, [User, :count, :id], store)
      assert result == 3
    end

    test "count returns 0 for empty schema" do
      store = ClosedInMemory.new()
      {result, _} = ClosedInMemory.dispatch(:aggregate, [User, :count, :id], store)
      assert result == 0
    end

    test "sum computes sum of field values" do
      store =
        ClosedInMemory.new([
          %User{id: 1, age: 25},
          %User{id: 2, age: 30},
          %User{id: 3, age: 35}
        ])

      {result, _} = ClosedInMemory.dispatch(:aggregate, [User, :sum, :age], store)
      assert result == 90
    end

    test "avg computes average of field values" do
      store = ClosedInMemory.new([%User{id: 1, age: 20}, %User{id: 2, age: 30}])
      {result, _} = ClosedInMemory.dispatch(:aggregate, [User, :avg, :age], store)
      assert result == 25.0
    end

    test "min returns minimum field value" do
      store = ClosedInMemory.new([%User{id: 1, age: 25}, %User{id: 2, age: 18}])
      {result, _} = ClosedInMemory.dispatch(:aggregate, [User, :min, :age], store)
      assert result == 18
    end

    test "max returns maximum field value" do
      store = ClosedInMemory.new([%User{id: 1, age: 25}, %User{id: 2, age: 40}])
      {result, _} = ClosedInMemory.dispatch(:aggregate, [User, :max, :age], store)
      assert result == 40
    end

    test "returns nil for empty schema (non-count)" do
      store = ClosedInMemory.new()
      {result, _} = ClosedInMemory.dispatch(:aggregate, [User, :sum, :age], store)
      assert result == nil
    end

    test "excludes nil field values" do
      store =
        ClosedInMemory.new([
          %User{id: 1, age: 25},
          %User{id: 2, age: nil},
          %User{id: 3, age: 35}
        ])

      {result, _} = ClosedInMemory.dispatch(:aggregate, [User, :sum, :age], store)
      assert result == 60
    end
  end

  # -------------------------------------------------------------------
  # Bulk writes
  # -------------------------------------------------------------------

  describe "insert_all" do
    test "inserts multiple entries and returns count" do
      store = ClosedInMemory.new()

      entries = [%{name: "Alice", email: "a@b.com"}, %{name: "Bob", email: "b@b.com"}]
      {{count, nil}, store} = ClosedInMemory.dispatch(:insert_all, [User, entries, []], store)
      assert count == 2

      {users, _} = ClosedInMemory.dispatch(:all, [User], store)
      assert length(users) == 2
    end

    test "returns records with :returning option" do
      store = ClosedInMemory.new()

      entries = [%{name: "Alice"}]

      {{1, [user]}, _store} =
        ClosedInMemory.dispatch(:insert_all, [User, entries, [returning: true]], store)

      assert user.name == "Alice"
    end
  end

  describe "delete_all" do
    test "deletes all records of a schema" do
      store = ClosedInMemory.new([%User{id: 1}, %User{id: 2}, %Post{id: 1, title: "Hi"}])

      {{count, nil}, store} = ClosedInMemory.dispatch(:delete_all, [User], store)
      assert count == 2

      {users, _} = ClosedInMemory.dispatch(:all, [User], store)
      assert users == []

      # Post is unaffected
      {posts, _} = ClosedInMemory.dispatch(:all, [Post], store)
      assert length(posts) == 1
    end
  end

  describe "update_all" do
    test "applies set updates to all records" do
      store =
        ClosedInMemory.new([
          %User{id: 1, name: "Alice", age: 25},
          %User{id: 2, name: "Bob", age: 30}
        ])

      {{count, nil}, store} =
        ClosedInMemory.dispatch(:update_all, [User, [set: [age: 99]]], store)

      assert count == 2

      {users, _} = ClosedInMemory.dispatch(:all, [User], store)
      assert Enum.all?(users, &(&1.age == 99))
    end

    test "non-set updates fall to fallback" do
      store = ClosedInMemory.new()

      {%DoubleDown.Dispatch.Defer{fn: raise_fn}, _} =
        ClosedInMemory.dispatch(:update_all, [User, [inc: [age: 1]]], store)

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
        ClosedInMemory.new([],
          fallback_fn: fn :all, [_query], _state -> [%User{id: 1, name: "Alice"}] end
        )

      {result, _} = ClosedInMemory.dispatch(:all, [query], store)
      assert [%User{name: "Alice"}] = result
    end

    test "all with Ecto.Query raises when no fallback" do
      query = Ecto.Query.from(u in User)
      store = ClosedInMemory.new()

      {%DoubleDown.Dispatch.Defer{fn: raise_fn}, _} =
        ClosedInMemory.dispatch(:all, [query], store)

      assert_raise ArgumentError, ~r/cannot service/, fn -> raise_fn.() end
    end
  end

  # -------------------------------------------------------------------
  # Integration with Double API
  # -------------------------------------------------------------------

  describe "Double.fake integration" do
    test "works with Double.fake/2" do
      DoubleDown.Double.fake(DoubleDown.Repo, ClosedInMemory)

      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})
      assert {:ok, user} = DoubleDown.Repo.Port.insert(cs)
      assert user.name == "Alice"

      # Closed-world read
      assert [^user] = DoubleDown.Repo.Port.all(User)
    end

    test "works with Double.fake/3 and seed data" do
      DoubleDown.Double.fake(DoubleDown.Repo, ClosedInMemory, [
        %User{id: 1, name: "Alice"},
        %User{id: 2, name: "Bob"}
      ])

      assert [_, _] = DoubleDown.Repo.Port.all(User)
      assert %User{name: "Alice"} = DoubleDown.Repo.Port.get(User, 1)
      assert nil == DoubleDown.Repo.Port.get(User, 999)
    end

    test "layering expects over ClosedInMemory" do
      DoubleDown.Double.fake(DoubleDown.Repo, ClosedInMemory)

      # First insert succeeds
      DoubleDown.Double.expect(DoubleDown.Repo, :insert, :passthrough)

      # Second insert fails
      DoubleDown.Double.expect(DoubleDown.Repo, :insert, fn [cs] ->
        {:error, Ecto.Changeset.add_error(cs, :email, "taken")}
      end)

      cs = User.changeset(%{name: "Alice", email: "alice@example.com"})
      assert {:ok, _} = DoubleDown.Repo.Port.insert(cs)
      assert {:error, _} = DoubleDown.Repo.Port.insert(cs)
    end
  end

  # -------------------------------------------------------------------
  # Opts-stripping
  # -------------------------------------------------------------------

  describe "opts-accepting variants" do
    test "get with opts" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}])
      {user, _} = ClosedInMemory.dispatch(:get, [User, 1, [prefix: "test"]], store)
      assert user.name == "Alice"
    end

    test "all with opts" do
      store = ClosedInMemory.new([%User{id: 1, name: "Alice"}])
      {users, _} = ClosedInMemory.dispatch(:all, [User, [prefix: "test"]], store)
      assert length(users) == 1
    end
  end
end
