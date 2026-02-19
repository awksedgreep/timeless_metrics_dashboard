defmodule TimelessMetricsDashboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :timeless_metrics_dashboard,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:timeless_metrics, path: "../timeless_metrics"},
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0", optional: true},
      {:phoenix_live_dashboard, "~> 0.8", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:igniter, "~> 0.6", optional: true}
    ]
  end
end
