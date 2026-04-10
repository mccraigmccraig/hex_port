defmodule HexPort.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()

  def project do
    [
      app: :hex_port,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: "https://github.com/mccraigmccraig/hex_port",
      homepage_url: "https://github.com/mccraigmccraig/hex_port",
      dialyzer: [plt_add_apps: [:mix]],
      docs: [
        main: "readme",
        extras: [
          "README.md",
          "docs/getting-started.md",
          "docs/testing.md",
          "docs/repo.md",
          "docs/migration.md",
          "CHANGELOG.md"
        ],
        groups_for_extras: [
          Introduction: [
            "README.md",
            "docs/getting-started.md"
          ],
          Guides: [
            "docs/testing.md",
            "docs/repo.md",
            "docs/migration.md"
          ],
          About: [
            "CHANGELOG.md"
          ]
        ],
        groups_for_modules: [
          Core: [
            HexPort.Contract,
            HexPort.Facade,
            HexPort.Dispatch
          ],
          Testing: [
            HexPort.Testing,
            HexPort.Handler,
            HexPort.Log
          ],
          Repo: [
            HexPort.Repo.Contract,
            HexPort.Repo.Test,
            HexPort.Repo.InMemory,
            HexPort.Repo.MultiStepper
          ]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:nimble_ownership, "~> 1.0"},
      {:ecto, "~> 3.12", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    HexPort: Hexagonal architecture ports for Elixir.

    Typed port contracts with async-safe test doubles, dispatch logging,
    and stateful test handlers. Define boundaries with `defport`, swap
    implementations for testing without a database.
    """
  end

  defp package do
    [
      name: "hex_port",
      files: ~w(lib docs .formatter.exs mix.exs README.md CHANGELOG.md LICENSE VERSION),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/hex_port"
      }
    ]
  end
end
