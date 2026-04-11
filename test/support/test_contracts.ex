defmodule DoubleDown.Test.Greeter do
  use DoubleDown.Contract

  defcallback(greet(name :: String.t()) :: String.t())

  defcallback(
    fetch_greeting(name :: String.t()) ::
      {:ok, String.t()} | {:error, term()}
  )
end

defmodule DoubleDown.Test.Greeter.Impl do
  @behaviour DoubleDown.Test.Greeter

  @impl true
  def greet(name), do: "Hello, #{name}!"

  @impl true
  def fetch_greeting(name), do: {:ok, "Hello, #{name}!"}
end

defmodule DoubleDown.Test.Counter do
  use DoubleDown.Contract

  defcallback(increment(amount :: integer()) :: integer())
  defcallback(get_count() :: integer())
end

# -- Contract for bang variant testing --

defmodule DoubleDown.Test.BangVariants do
  use DoubleDown.Contract

  # Auto-detected bang (return type has {:ok, T})
  defcallback(
    auto_bang(id :: String.t()) ::
      {:ok, String.t()} | {:error, term()}
  )

  # Forced bang even though no {:ok, T} in return type
  defcallback(forced_bang(id :: String.t()) :: String.t() | nil,
    bang: true
  )

  # Suppressed bang even though return type has {:ok, T}
  defcallback(
    suppressed_bang(id :: String.t()) ::
      {:ok, String.t()} | {:error, term()},
    bang: false
  )

  # Custom unwrap function
  defcallback(custom_bang(id :: String.t()) :: String.t() | nil,
    bang: fn
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end
  )

  # No bang (return type has no {:ok, T})
  defcallback(no_bang(id :: String.t()) :: String.t())
end

# -- Contract for zero-arg testing --

defmodule DoubleDown.Test.ZeroArg do
  use DoubleDown.Contract

  defcallback(health_check() :: :ok)
  defcallback(get_version() :: {:ok, String.t()} | {:error, term()})
end

# -- Contract for @doc propagation testing --

defmodule DoubleDown.Test.Documented do
  use DoubleDown.Contract

  @doc "Fetches a user by their ID."
  defcallback(get_user(id :: String.t()) :: {:ok, map()} | {:error, term()})

  defcallback(list_users() :: [map()])
end

# -- Contract with multi-param for key helper testing --

defmodule DoubleDown.Test.MultiParam do
  use DoubleDown.Contract

  defcallback(
    find(tenant :: String.t(), type :: atom(), id :: String.t()) ::
      {:ok, map()} | {:error, term()}
  )
end

# -- Module used as an aliased type in contracts --

defmodule DoubleDown.Test.Deep.Nested.Widget do
  @type t :: %__MODULE__{id: String.t(), label: String.t()}
  defstruct [:id, :label]
end

# -- Contract that uses aliased types --
# Verifies that defcallback expands aliases to fully-qualified names
# so generated @spec annotations resolve in Port modules.

defmodule DoubleDown.Test.AliasedTypes do
  use DoubleDown.Contract

  alias DoubleDown.Test.Deep.Nested.Widget

  defcallback(
    get_widget(id :: String.t()) ::
      {:ok, Widget.t()} | {:error, term()}
  )

  defcallback(list_widgets(filter :: Widget.t()) :: [Widget.t()])
end
