defmodule DoubleDown.Repo.Impl.AutogenerateTest do
  use ExUnit.Case, async: true

  alias DoubleDown.Repo.Impl.Autogenerate

  # -------------------------------------------------------------------
  # Test schemas covering all PK variants
  # -------------------------------------------------------------------

  defmodule IntIdUser do
    use Ecto.Schema

    schema "users" do
      field(:name, :string)
      timestamps()
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  defmodule BinaryIdUser do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "binary_id_users" do
      field(:name, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  defmodule UuidUser do
    use Ecto.Schema

    @primary_key {:uuid, Ecto.UUID, autogenerate: true}
    schema "uuid_users" do
      field(:name, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  defmodule NoAutoIdUser do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "no_auto_id_users" do
      field(:name, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  defmodule NoPkEvent do
    use Ecto.Schema

    @primary_key false
    schema "events" do
      field(:name, :string)
    end

    def changeset(event \\ %__MODULE__{}, attrs) do
      event |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  defmodule NoTimestampUser do
    use Ecto.Schema

    schema "plain_users" do
      field(:name, :string)
    end

    def changeset(user \\ %__MODULE__{}, attrs) do
      user |> Ecto.Changeset.cast(attrs, [:name])
    end
  end

  # -------------------------------------------------------------------
  # apply_changes/2
  # -------------------------------------------------------------------

  describe "apply_changes/2 :insert" do
    test "applies changeset changes" do
      cs = NoTimestampUser.changeset(%{name: "Alice"})
      record = Autogenerate.apply_changes(cs, :insert)
      assert %NoTimestampUser{name: "Alice"} = record
    end

    test "populates nil timestamps on insert" do
      cs = IntIdUser.changeset(%{name: "Alice"})
      record = Autogenerate.apply_changes(cs, :insert)
      assert %NaiveDateTime{} = record.inserted_at
      assert %NaiveDateTime{} = record.updated_at
    end

    test "preserves explicit timestamps" do
      explicit = ~N[2020-01-01 00:00:00]

      cs =
        IntIdUser.changeset(%IntIdUser{inserted_at: explicit, updated_at: explicit}, %{
          name: "Alice"
        })

      record = Autogenerate.apply_changes(cs, :insert)
      assert record.inserted_at == explicit
      assert record.updated_at == explicit
    end

    test "populates Ecto.UUID PK on insert" do
      cs = UuidUser.changeset(%{name: "Alice"})
      record = Autogenerate.apply_changes(cs, :insert)
      assert is_binary(record.uuid)
      assert record.uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-/
    end

    test "preserves explicit Ecto.UUID PK" do
      explicit = Ecto.UUID.generate()
      cs = UuidUser.changeset(%UuidUser{uuid: explicit}, %{name: "Alice"})
      record = Autogenerate.apply_changes(cs, :insert)
      assert record.uuid == explicit
    end

    test "does not populate :id or :binary_id PKs (handled by maybe_autogenerate_id)" do
      cs = IntIdUser.changeset(%{name: "Alice"})
      record = Autogenerate.apply_changes(cs, :insert)
      # :id type PKs are NOT in :autogenerate — they use :autogenerate_id
      assert record.id == nil
    end

    test "schemas without timestamps are unaffected" do
      cs = NoTimestampUser.changeset(%{name: "Alice"})
      record = Autogenerate.apply_changes(cs, :insert)
      assert %NoTimestampUser{name: "Alice"} = record
    end
  end

  describe "apply_changes/2 :update" do
    test "populates nil updated_at but not inserted_at" do
      existing = %IntIdUser{
        id: 1,
        name: "Alice",
        inserted_at: ~N[2020-01-01 00:00:00],
        updated_at: nil
      }

      cs = IntIdUser.changeset(existing, %{name: "Alicia"})
      record = Autogenerate.apply_changes(cs, :update)
      assert record.inserted_at == ~N[2020-01-01 00:00:00]
      assert %NaiveDateTime{} = record.updated_at
    end
  end

  # -------------------------------------------------------------------
  # get_primary_key/1
  # -------------------------------------------------------------------

  describe "get_primary_key/1" do
    test "returns integer id for default schema" do
      assert Autogenerate.get_primary_key(%IntIdUser{id: 42, name: "Alice"}) == 42
    end

    test "returns nil for nil PK" do
      assert Autogenerate.get_primary_key(%IntIdUser{id: nil, name: "Alice"}) == nil
    end

    test "returns binary_id value" do
      uuid = Ecto.UUID.generate()
      assert Autogenerate.get_primary_key(%BinaryIdUser{id: uuid, name: "Alice"}) == uuid
    end

    test "returns custom PK field value" do
      uuid = Ecto.UUID.generate()
      assert Autogenerate.get_primary_key(%UuidUser{uuid: uuid, name: "Alice"}) == uuid
    end

    test "returns nil for @primary_key false schemas" do
      assert Autogenerate.get_primary_key(%NoPkEvent{name: "test"}) == nil
    end
  end

  # -------------------------------------------------------------------
  # maybe_autogenerate_id/3
  # -------------------------------------------------------------------

  describe "maybe_autogenerate_id/3" do
    defp no_existing_ids(_schema), do: []

    test "integer :id PK — auto-increments from empty" do
      record = %IntIdUser{id: nil, name: "Alice"}

      assert {1, %IntIdUser{id: 1}} =
               Autogenerate.maybe_autogenerate_id(record, IntIdUser, &no_existing_ids/1)
    end

    test "integer :id PK — auto-increments from existing" do
      record = %IntIdUser{id: nil, name: "Bob"}

      assert {6, %IntIdUser{id: 6}} =
               Autogenerate.maybe_autogenerate_id(record, IntIdUser, fn _schema -> [1, 3, 5] end)
    end

    test "integer :id PK — preserves explicit value" do
      record = %IntIdUser{id: 42, name: "Alice"}

      assert {42, %IntIdUser{id: 42}} =
               Autogenerate.maybe_autogenerate_id(record, IntIdUser, &no_existing_ids/1)
    end

    test ":binary_id PK — generates UUID when nil" do
      record = %BinaryIdUser{id: nil, name: "Alice"}
      {id, result} = Autogenerate.maybe_autogenerate_id(record, BinaryIdUser, &no_existing_ids/1)
      assert is_binary(id)
      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-/
      assert result.id == id
    end

    test ":binary_id PK — preserves explicit value" do
      explicit = Ecto.UUID.generate()
      record = %BinaryIdUser{id: explicit, name: "Alice"}

      assert {^explicit, %BinaryIdUser{id: ^explicit}} =
               Autogenerate.maybe_autogenerate_id(record, BinaryIdUser, &no_existing_ids/1)
    end

    test "Ecto.UUID PK — already populated by apply_changes, returned as-is" do
      uuid = Ecto.UUID.generate()
      record = %UuidUser{uuid: uuid, name: "Alice"}

      assert {^uuid, %UuidUser{uuid: ^uuid}} =
               Autogenerate.maybe_autogenerate_id(record, UuidUser, &no_existing_ids/1)
    end

    test "no autogenerate configured — returns error tuple when nil PK" do
      record = %NoAutoIdUser{id: nil, name: "Alice"}

      assert {:error, {:no_autogenerate, message}} =
               Autogenerate.maybe_autogenerate_id(record, NoAutoIdUser, &no_existing_ids/1)

      assert message =~ "Cannot autogenerate primary key"
      assert message =~ "NoAutoIdUser"
    end

    test "no autogenerate configured — works with explicit PK" do
      explicit = Ecto.UUID.generate()
      record = %NoAutoIdUser{id: explicit, name: "Alice"}

      assert {^explicit, %NoAutoIdUser{id: ^explicit}} =
               Autogenerate.maybe_autogenerate_id(record, NoAutoIdUser, &no_existing_ids/1)
    end

    test "@primary_key false — returns {nil, record} unchanged" do
      record = %NoPkEvent{name: "test"}

      assert {nil, ^record} =
               Autogenerate.maybe_autogenerate_id(record, NoPkEvent, &no_existing_ids/1)
    end
  end
end
