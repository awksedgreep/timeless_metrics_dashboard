defmodule TimelessDashboard.MixProject do
  use Mix.Project

  def project do
    [
      app: :timeless_dashboard,
      version: "0.1.1",
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
      {:timeless, path: "../timeless"},
      {:telemetry, "~> 1.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0", optional: true},
      {:phoenix_live_dashboard, "~> 0.8", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true}
    ]
  end
end
