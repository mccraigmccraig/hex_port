# Test implementation modules for DoubleDown.Contract.SpecWarnings tests.
#
# These must be in test/support/ (not in the test file) so they get compiled
# to beam files on disk, which Code.Typespec.fetch_specs/1 requires.

defmodule DoubleDown.Test.SpecImpl.Matching do
  @spec greet(String.t()) :: {:ok, String.t()} | {:error, term()}
  def greet(name), do: {:ok, "Hello #{name}"}

  @spec fetch(atom(), integer()) :: String.t() | nil
  def fetch(_schema, _id), do: nil

  @spec list_all() :: list(String.t())
  def list_all, do: []
end

defmodule DoubleDown.Test.SpecImpl.ParamMismatch do
  @spec greet(list()) :: {:ok, String.t()} | {:error, term()}
  def greet(_names), do: {:ok, "Hello"}
end

defmodule DoubleDown.Test.SpecImpl.ReturnMismatch do
  @spec greet(String.t()) :: {:ok, binary()} | {:error, atom()}
  def greet(name), do: {:ok, "Hello #{name}"}
end

defmodule DoubleDown.Test.SpecImpl.NoSpec do
  def greet(name), do: {:ok, "Hello #{name}"}
end

# Simple Ecto schema for cross-contract state tests.
defmodule DoubleDown.Test.SimpleUser do
  use Ecto.Schema

  schema "users" do
    field(:name, :string)
  end

  def changeset(user \\ %__MODULE__{}, attrs) do
    user |> Ecto.Changeset.cast(attrs, [:name])
  end
end
