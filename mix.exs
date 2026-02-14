defmodule Crucible.MixProject do
  use Mix.Project

  def project do
    [
      app: :crucible,
      version: "1.0.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Recursive LLM code execution engine for Elixir — give an LLM a stateful REPL",
      package: [
        name: "crucible_rlm",
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/Whoaa512/crucible"},
        files: ~w(lib mix.exs README.md LICENSE)
      ],
      source_url: "https://github.com/Whoaa512/crucible",
      homepage_url: "https://github.com/Whoaa512/crucible",
      docs: [main: "readme", extras: ["README.md"]],
      releases: [
        crucible: [
          steps: [:assemble, &Burrito.wrap/1],
          burrito: [
            targets: [
              macos_aarch64: [os: :darwin, cpu: :aarch64],
              linux_x86_64: [os: :linux, cpu: :x86_64]
            ]
          ]
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Crucible.App, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.27"},
      {:burrito, "~> 1.5", only: :prod, runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
