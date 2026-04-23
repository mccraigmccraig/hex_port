# Port facades for test contracts.
# These are in a separate file from the contracts so that the contracts
# are fully compiled before the Port modules try to read __callbacks__/0.

defmodule DoubleDown.Test.Greeter.Port do
  use DoubleDown.ContractFacade, contract: DoubleDown.Test.Greeter, otp_app: :double_down
end

# Facade for DoubleDown.Repo (library-provided contract).
# In a real app this would be defined in the application's namespace,
# e.g. MyApp.Repo. Here we use DoubleDown.Test.Repo for test purposes.
defmodule DoubleDown.Test.Repo do
  use DoubleDown.ContractFacade, contract: DoubleDown.Repo, otp_app: :double_down
end

defmodule DoubleDown.Test.Counter.Port do
  use DoubleDown.ContractFacade, contract: DoubleDown.Test.Counter, otp_app: :double_down
end

defmodule DoubleDown.Test.ZeroArg.Port do
  use DoubleDown.ContractFacade, contract: DoubleDown.Test.ZeroArg, otp_app: :double_down
end

defmodule DoubleDown.Test.Documented.Port do
  use DoubleDown.ContractFacade, contract: DoubleDown.Test.Documented, otp_app: :double_down
end

defmodule DoubleDown.Test.MultiParam.Port do
  use DoubleDown.ContractFacade, contract: DoubleDown.Test.MultiParam, otp_app: :double_down
end

defmodule DoubleDown.Test.AliasedTypes.Port do
  use DoubleDown.ContractFacade, contract: DoubleDown.Test.AliasedTypes, otp_app: :double_down
end

defmodule DoubleDown.Test.Greeter.PortWithUserDoc do
  @moduledoc "User-provided documentation for the greeter facade."
  use DoubleDown.ContractFacade, contract: DoubleDown.Test.Greeter, otp_app: :double_down
end

defmodule DoubleDown.Test.Greeter.PortWithFalseDoc do
  @moduledoc false
  use DoubleDown.ContractFacade, contract: DoubleDown.Test.Greeter, otp_app: :double_down
end
