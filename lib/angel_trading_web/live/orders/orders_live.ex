defmodule AngelTradingWeb.OrdersLive do
  use AngelTradingWeb, :live_view
  alias AngelTrading.{Account, API, Utils}
  import Number.Currency, only: [number_to_currency: 1, number_to_currency: 2]
  require Logger

  def mount(%{"client_code" => client_code}, %{"user_hash" => user_hash}, socket) do
    client_code = String.upcase(client_code)

    if connected?(socket) do
      :ok = AngelTradingWeb.Endpoint.subscribe("orders-for-#{client_code}")
      # :timer.send_interval(2000, self(), :subscribe_to_feed)
    end

    user_clients =
      case Account.get_client_codes(user_hash) do
        {:ok, %{body: data}} when is_map(data) -> Map.values(data)
        _ -> []
      end

    socket =
      with true <- client_code in user_clients,
           {:ok, %{body: client_data}} when is_binary(client_data) <-
             Account.get_client(client_code),
           {:ok,
            %{
              token: token,
              client_code: client_code,
              feed_token: feed_token,
              refresh_token: refresh_token
            }} <- Utils.decrypt(:client_tokens, client_data) do
        socket
        |> assign(:page_title, "Orders")
        |> assign(:token, token)
        |> assign(:client_code, client_code)
        |> assign(:feed_token, feed_token)
        |> assign(:refresh_token, refresh_token)
        |> get_order_data()
      else
        _ ->
          socket
          |> put_flash(:error, "Invalid client")
          |> push_navigate(to: "/")
      end

    {:ok, socket}
  end

  defp get_order_data(%{assigns: %{token: token}} = socket) do
    with {:ok, %{"data" => profile}} <- API.profile(token),
         {:ok, %{"data" => funds}} <- API.funds(token),
         {:ok, %{"data" => order_book}} <- API.order_book(token),
         {:ok, %{"data" => trade_book}} <- API.trade_book(token) do
      socket
      |> assign(name: profile["name"])
      |> assign(funds: funds)
      |> assign(order_book: order_book || [])
      |> assign(trade_book: trade_book || [])
    else
      {:error, %{"message" => message}} ->
        socket
        |> put_flash(:error, message)
        |> push_navigate(to: "/")
    end
  end
end