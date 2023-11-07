defmodule AngelTradingWeb.Dashboard.Components.PortfolioComponent do
  use AngelTradingWeb, :live_component
  alias AngelTrading.Utils

  def update(assigns, socket) do
    {:ok, socket |> assign(assigns) |> get_portfolio_data()}
  end

  defp get_portfolio_data(%{assigns: %{holdings: holdings, profile: profile}} = socket) do
    holdings = Utils.formatted_holdings(holdings)

    socket
    |> Utils.calculated_overview(holdings)
    |> assign(name: profile["name"])
  end
end
