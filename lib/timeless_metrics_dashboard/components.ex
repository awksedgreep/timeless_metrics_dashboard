defmodule TimelessMetricsDashboard.Components do
  @moduledoc false

  use Phoenix.Component

  @doc "Time range selector button group."
  attr(:selected, :string, required: true)
  attr(:ranges, :list, default: ["15m", "1h", "6h", "24h", "7d"])

  def time_picker(assigns) do
    ~H"""
    <div class="btn-group btn-group-sm" role="group" aria-label="Time range selector">
      <button
        :for={range <- @ranges}
        phx-click="select_time_range"
        phx-value-range={range}
        type="button"
        class={"btn #{if(range == @selected, do: "btn-primary", else: "btn-outline-secondary")}"}
      >
        <%= range %>
      </button>
    </div>
    """
  end

  @doc "Wraps an SVG chart string with an optional title."
  attr(:title, :string, default: nil)
  attr(:svg, :string, required: true)

  def chart_embed(assigns) do
    assigns = assign(assigns, :svg_data_uri, svg_data_uri(assigns.svg))

    ~H"""
    <div>
      <h6 :if={@title} class="card-subtitle text-muted mb-2"><%= @title %></h6>
      <img src={@svg_data_uri} alt={@title || "metric chart"} style="display:block;max-width:100%;height:auto" />
    </div>
    """
  end

  defp svg_data_uri(svg), do: "data:image/svg+xml;base64," <> Base.encode64(svg)
end
