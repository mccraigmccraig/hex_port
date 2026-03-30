# Port facades for test contracts.
# These are in a separate file from the contracts so that the contracts
# are fully compiled before the Port modules try to read __port_operations__/0.

defmodule HexPort.Test.Greeter.Port do
  use HexPort.Port, contract: HexPort.Test.Greeter, otp_app: :hex_port
end

# Port facade for HexPort.Repo (library-provided contract).
# In a real app this would be defined by the consuming application.
defmodule HexPort.Repo.Port do
  use HexPort.Port, contract: HexPort.Repo, otp_app: :hex_port
end

defmodule HexPort.Test.Counter.Port do
  use HexPort.Port, contract: HexPort.Test.Counter, otp_app: :hex_port
end

defmodule HexPort.Test.BangVariants.Port do
  use HexPort.Port, contract: HexPort.Test.BangVariants, otp_app: :hex_port
end

defmodule HexPort.Test.ZeroArg.Port do
  use HexPort.Port, contract: HexPort.Test.ZeroArg, otp_app: :hex_port
end

defmodule HexPort.Test.Documented.Port do
  use HexPort.Port, contract: HexPort.Test.Documented, otp_app: :hex_port
end

defmodule HexPort.Test.MultiParam.Port do
  use HexPort.Port, contract: HexPort.Test.MultiParam, otp_app: :hex_port
end

defmodule HexPort.Test.AliasedTypes.Port do
  use HexPort.Port, contract: HexPort.Test.AliasedTypes, otp_app: :hex_port
end
