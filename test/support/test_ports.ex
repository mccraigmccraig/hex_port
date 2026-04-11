# Port facades for test contracts.
# These are in a separate file from the contracts so that the contracts
# are fully compiled before the Port modules try to read __callbacks__/0.

defmodule DoubleDown.Test.Greeter.Port do
  use DoubleDown.Facade, contract: DoubleDown.Test.Greeter, otp_app: :double_down
end

# Facade for DoubleDown.Repo.Contract (library-provided contract).
# In a real app this would be defined in the application's namespace,
# e.g. MyApp.Repo. Here we use DoubleDown.Repo.Port for test purposes.
defmodule DoubleDown.Repo.Port do
  use DoubleDown.Facade, contract: DoubleDown.Repo.Contract, otp_app: :double_down
end

defmodule DoubleDown.Test.Counter.Port do
  use DoubleDown.Facade, contract: DoubleDown.Test.Counter, otp_app: :double_down
end

defmodule DoubleDown.Test.BangVariants.Port do
  use DoubleDown.Facade, contract: DoubleDown.Test.BangVariants, otp_app: :double_down
end

defmodule DoubleDown.Test.ZeroArg.Port do
  use DoubleDown.Facade, contract: DoubleDown.Test.ZeroArg, otp_app: :double_down
end

defmodule DoubleDown.Test.Documented.Port do
  use DoubleDown.Facade, contract: DoubleDown.Test.Documented, otp_app: :double_down
end

defmodule DoubleDown.Test.MultiParam.Port do
  use DoubleDown.Facade, contract: DoubleDown.Test.MultiParam, otp_app: :double_down
end

defmodule DoubleDown.Test.AliasedTypes.Port do
  use DoubleDown.Facade, contract: DoubleDown.Test.AliasedTypes, otp_app: :double_down
end
