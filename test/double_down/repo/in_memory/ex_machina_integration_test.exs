defmodule DoubleDown.Repo.InMemory.ExMachinaIntegrationTest do
  use ExUnit.Case, async: true

  import DoubleDown.Test.Factory

  alias DoubleDown.Test.Factory.User
  alias DoubleDown.Test.Factory.Post

  # In a real app this would be MyApp.Repo — here we use the test facade
  alias DoubleDown.Test.Repo

  setup do
    DoubleDown.Double.fallback(DoubleDown.Repo, DoubleDown.Repo.InMemory)
    :ok
  end

  # -------------------------------------------------------------------
  # Basic factory usage — insert via ExMachina, read via Repo
  # -------------------------------------------------------------------

  describe "ExMachina insert" do
    test "factory-inserted records are readable via get" do
      user = insert(:user, name: "Alice")

      assert user.id != nil
      assert user.name == "Alice"

      found = Repo.get(User, user.id)
      assert found.name == "Alice"
    end

    test "factory-inserted records are readable via all" do
      insert(:user, name: "Alice")
      insert(:user, name: "Bob")
      insert(:user, name: "Carol")

      users = Repo.all(User)
      assert length(users) == 3
      names = Enum.map(users, & &1.name) |> Enum.sort()
      assert names == ["Alice", "Bob", "Carol"]
    end

    test "factory-inserted records are readable via get_by" do
      insert(:user, name: "Alice", email: "alice@example.com")
      insert(:user, name: "Bob", email: "bob@example.com")

      found = Repo.get_by(User, email: "alice@example.com")
      assert found.name == "Alice"
    end

    test "exists? returns true for factory-inserted records" do
      insert(:user)
      assert Repo.exists?(User)
    end

    test "exists? returns false when no records" do
      refute Repo.exists?(User)
    end
  end

  # -------------------------------------------------------------------
  # Aggregates on factory data
  # -------------------------------------------------------------------

  describe "aggregates on factory data" do
    test "count" do
      insert(:user)
      insert(:user)
      insert(:user)

      assert 3 == Repo.aggregate(User, :count, :id)
    end

    test "avg age" do
      insert(:user, age: 20)
      insert(:user, age: 30)
      insert(:user, age: 40)

      assert 30.0 == Repo.aggregate(User, :avg, :age)
    end

    test "min/max" do
      insert(:user, age: 18)
      insert(:user, age: 65)

      assert 18 == Repo.aggregate(User, :min, :age)
      assert 65 == Repo.aggregate(User, :max, :age)
    end
  end

  # -------------------------------------------------------------------
  # Multiple schema types
  # -------------------------------------------------------------------

  describe "multiple schemas" do
    test "records of different schemas are independent" do
      insert(:user, name: "Alice")
      insert(:post, title: "Hello World")

      assert length(Repo.all(User)) == 1
      assert length(Repo.all(Post)) == 1
    end
  end

  # -------------------------------------------------------------------
  # Read-after-write consistency
  # -------------------------------------------------------------------

  describe "read-after-write" do
    test "insert then immediate read" do
      user = insert(:user, name: "Alice")
      assert ^user = Repo.get(User, user.id)
    end

    test "insert then update then read" do
      user = insert(:user, name: "Alice")

      cs = Ecto.Changeset.cast(user, %{name: "Alicia"}, [:name])
      {:ok, updated} = Repo.update(cs)

      found = Repo.get(User, user.id)
      assert found.name == "Alicia"
      assert found.name == updated.name
    end

    test "insert then delete then read" do
      user = insert(:user, name: "Alice")
      {:ok, _} = Repo.delete(user)

      assert nil == Repo.get(User, user.id)
      assert [] == Repo.all(User)
    end
  end

  # -------------------------------------------------------------------
  # Failure simulation with factory data
  # -------------------------------------------------------------------

  describe "failure simulation over factory data" do
    test "layer expects over factory-populated store" do
      insert(:user, name: "Alice")
      insert(:user, name: "Bob")

      # Next insert! will raise — ExMachina calls insert! directly
      DoubleDown.Double.expect(DoubleDown.Repo, :insert!, fn [struct] ->
        cs = Ecto.Changeset.change(struct) |> Ecto.Changeset.add_error(:name, "taken")
        raise Ecto.InvalidChangesetError, action: :insert, changeset: cs
      end)

      assert_raise Ecto.InvalidChangesetError, fn ->
        insert(:user, name: "Carol")
      end

      # Existing records still there
      assert length(Repo.all(User)) == 2
    end
  end

  # -------------------------------------------------------------------
  # Timestamps
  # -------------------------------------------------------------------

  describe "timestamps" do
    test "factory-inserted records have timestamps" do
      user = insert(:user)
      assert user.inserted_at != nil
      assert user.updated_at != nil
    end
  end
end
