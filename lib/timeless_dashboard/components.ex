defmodule TimelessDashboard.Components do
  @moduledoc false

  use Phoenix.Component

  @doc "Time range selector button group."
  attr(:selected, :string, required: true)
  attr(:ranges, :list, default: ["15m", "1h", "6h", "24h", "7d"])

  def time_picker(assigns) do
    ~H"""
    <div style="display:flex;gap:4px;margin-bottom:12px">
      <button
        :for={range <- @ranges}
        phx-click="select_time_range"
        phx-value-range={range}
        style={"padding:4px 12px;border:1px solid #d1d5db;border-radius:4px;cursor:pointer;font-size:13px;" <>
          if(range == @selected, do: "background:#2563eb;color:#fff;border-color:#2563eb;", else: "background:#fff;color:#374151;")}
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
    ~H"""
    <div style="margin-bottom:16px">
      <h4 :if={@title} style="margin:0 0 8px 0;font-size:14px;font-weight:600"><%= @title %></h4>
      <%= Phoenix.HTML.raw(@svg) %>
    </div>
    """
  end
end
