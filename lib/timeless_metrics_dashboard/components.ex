if Code.ensure_loaded?(Phoenix.Component) do
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

    @doc "Displays a pre-encoded SVG data URI with an optional title."
    attr(:title, :string, default: nil)
    attr(:data_uri, :string, required: true)

    def chart_embed(assigns) do
      ~H"""
      <div>
        <h6 :if={@title} class="card-subtitle text-muted mb-2"><%= @title %></h6>
        <img src={@data_uri} alt={@title || "metric chart"} style="display:block;max-width:100%;height:auto" />
      </div>
      """
    end
  end
end
