defmodule TimelessMetricsDashboard.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, :timeless_metrics)
    sup_name = :"#{name}_dashboard_sup"
    Supervisor.start_link(__MODULE__, opts, name: sup_name)
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, :timeless_metrics)
    data_dir = Keyword.get(opts, :data_dir, "priv/timeless_metrics")
    metrics = Keyword.get_lazy(opts, :metrics, &TimelessMetricsDashboard.DefaultMetrics.metrics/0)
    reporter_extra = Keyword.get(opts, :reporter, [])

    reporter_opts =
      [store: name, metrics: metrics] ++ reporter_extra

    children = [
      {TimelessMetrics, name: name, data_dir: data_dir},
      {TimelessMetricsDashboard.Reporter, reporter_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
