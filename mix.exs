defmodule DoubleDown.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()

  def project do
    [
      app: :double_down,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: "https://github.com/mccraigmccraig/double_down",
      homepage_url: "https://github.com/mccraigmccraig/double_down",
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
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
            DoubleDown.Contract,
            DoubleDown.Facade,
            DoubleDown.Dispatch
          ],
          Testing: [
            DoubleDown.Testing,
            DoubleDown.Double,
            DoubleDown.Log
          ],
          Repo: [
            DoubleDown.Repo,
            DoubleDown.Repo.Test,
            DoubleDown.Repo.InMemory,
            DoubleDown.Repo.MultiStepper
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
    Builds on the Mox pattern — generates behaviours and dispatch facades
    from `defcallback` declarations — and adds stateful test doubles powerful
    enough to test Ecto.Repo operations without a database.
    """
  end

  defp package do
    [
      name: "double_down",
      files: ~w(lib docs .formatter.exs mix.exs README.md CHANGELOG.md LICENSE VERSION),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/mccraigmccraig/double_down"
      }
    ]
  end
end
