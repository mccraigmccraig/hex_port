defmodule HexPort.Test.Greeter do
  use HexPort, otp_app: :hex_port

  defport greet(name :: String.t()) :: String.t()

  defport fetch_greeting(name :: String.t()) ::
            {:ok, String.t()} | {:error, term()}
end

defmodule HexPort.Test.Greeter.Impl do
  @behaviour HexPort.Test.Greeter.Behaviour

  @impl true
  def greet(name), do: "Hello, #{name}!"

  @impl true
  def fetch_greeting(name), do: {:ok, "Hello, #{name}!"}
end

defmodule HexPort.Test.Counter do
  use HexPort, otp_app: :hex_port

  defport increment(amount :: integer()) :: integer()
  defport get_count() :: integer()
end

# -- Contract for bang variant testing --

defmodule HexPort.Test.BangVariants do
  use HexPort, otp_app: :hex_port

  # Auto-detected bang (return type has {:ok, T})
  defport auto_bang(id :: String.t()) ::
            {:ok, String.t()} | {:error, term()}

  # Forced bang even though no {:ok, T} in return type
  defport forced_bang(id :: String.t()) :: String.t() | nil,
    bang: true

  # Suppressed bang even though return type has {:ok, T}
  defport suppressed_bang(id :: String.t()) ::
            {:ok, String.t()} | {:error, term()},
          bang: false

  # Custom unwrap function
  defport custom_bang(id :: String.t()) :: String.t() | nil,
    bang: fn
      nil -> {:error, :not_found}
      value -> {:ok, value}
    end

  # No bang (return type has no {:ok, T})
  defport no_bang(id :: String.t()) :: String.t()
end

# -- Contract for zero-arg testing --

defmodule HexPort.Test.ZeroArg do
  use HexPort, otp_app: :hex_port

  defport health_check() :: :ok
  defport get_version() :: {:ok, String.t()} | {:error, term()}
end

# -- Contract for @doc propagation testing --

defmodule HexPort.Test.Documented do
  use HexPort, otp_app: :hex_port

  @doc "Fetches a user by their ID."
  defport get_user(id :: String.t()) :: {:ok, map()} | {:error, term()}

  defport list_users() :: [map()]
end

# -- Contract with multi-param for key helper testing --

defmodule HexPort.Test.MultiParam do
  use HexPort, otp_app: :hex_port

  defport find(tenant :: String.t(), type :: atom(), id :: String.t()) ::
            {:ok, map()} | {:error, term()}
end
