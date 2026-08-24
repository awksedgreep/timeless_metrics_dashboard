defmodule TimelessMetricsDashboard.MixProject do
  use Mix.Project

  @version "0.4.11"
  @source_url "https://github.com/awksedgreep/timeless_metrics_dashboard"

  def project do
    [
      app: :timeless_metrics_dashboard,
      version: @version,
      elixir: ">= 1.18.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Phoenix LiveDashboard page and telemetry reporter for TimelessMetrics.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:timeless_metrics, ">= 6.6.6 and < 7.0.0"},
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0", optional: true},
      {:phoenix_live_dashboard, "~> 0.8", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:igniter, "~> 0.6", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Mark Cotner"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"] ++ Path.wildcard("docs/*.md")
    ]
  end
end
