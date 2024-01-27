defmodule AngelTradingWeb.WatchlistLive do
  use AngelTradingWeb, :live_view
  alias AngelTrading.{Account, API, Utils, YahooFinance}
  alias Phoenix.LiveView.AsyncResult
  require Logger

  embed_templates "*"

  def mount(%{"client_code" => client_code}, %{"user_hash" => user_hash}, socket) do
    socket =
      with {:ok, %{body: %{"clients" => clients} = user}} <-
             Account.get_user(user_hash),
           user_clients <- Map.values(clients),
           {:valid_client, true} <- {:valid_client, client_code in user_clients},
           {:ok, %{body: data}} when is_binary(data) <- Account.get_client(client_code),
           {:ok, %{token: token, feed_token: feed_token}} <- Utils.decrypt(:client_tokens, data) do
        if connected?(socket) do
          :ok = Phoenix.PubSub.subscribe(AngelTrading.PubSub, "quote-stream-#{client_code}")
          Process.send_after(self(), :subscribe_to_feed, 500)
          :timer.send_interval(30000, self(), :subscribe_to_feed)
        end

        watchlist = assign_quotes(user["watchlist"] || [], token)

        socket
        |> assign(
          token: token,
          feed_token: feed_token,
          client_code: client_code,
          watchlist: watchlist,
          quote: nil,
          order: %{type: "LIMIT", price: nil, quantity: nil}
        )
        |> stream_configure(:watchlist, dom_id: &"watchlist-quote-#{&1["symboltoken"]}")
        |> stream(:watchlist, watchlist)
        |> assign_async(:token_list, fn -> {:ok, %{token_list: []}} end)
      else
        e ->
          IO.inspect(e)

          socket
          |> put_flash(:error, "Invalid client")
          |> push_navigate(to: "/")
      end

    {:ok,
     socket
     |> assign(:page_title, "Watchlist")
     |> assign(:user_hash, user_hash)}
  end

  def handle_params(
        _,
        _,
        %{assigns: %{live_action: :quote, quote: quote, client_code: client_code}} = socket
      )
      when is_nil(quote),
      do: {:noreply, push_patch(socket, to: ~p"/client/#{client_code}/watchlist")}

  def handle_params(_, _, %{assigns: %{live_action: :index}} = socket),
    do: {:noreply, socket |> assign(:quote, nil) |> assign(:candle_data, nil)}

  def handle_params(_, _, socket), do: {:noreply, socket}

  def handle_info(
        :subscribe_to_feed,
        %{
          assigns: %{
            client_code: client_code,
            token: token,
            feed_token: feed_token
          }
        } = socket
      ) do
    socket_process = :"#{client_code}"

    with nil <- Process.whereis(socket_process),
         {:ok, pid} when is_pid(pid) <-
           API.socket(client_code, token, feed_token, "quote-stream-" <> client_code) do
      subscribe_to_quote_feed(socket)
    else
      pid when is_pid(pid) ->
        Logger.info(
          "[Watchlist] web socket (#{socket_process} #{inspect(pid)}) already established"
        )

        subscribe_to_quote_feed(socket)

      e ->
        Logger.error("[Watchlist] Error connecting to web socket (#{socket_process})")
        IO.inspect(e)
    end

    {:noreply, socket}
  end

  def handle_info(
        %{payload: new_quote},
        %{assigns: %{live_action: :quote, quote: quote}} = socket
      ) do
    socket =
      if(new_quote.token == quote["symbolToken"]) do
        ltp = new_quote.last_traded_price / 100
        close = new_quote.close_price / 100
        ltp_percent = (ltp - close) / close * 100

        socket
        |> get_candle_data(quote["exchange"], quote["symbolToken"])
        |> assign(
          quote:
            Map.merge(quote, %{
              "ltp" => ltp,
              "ltp_percent" => ltp_percent,
              "is_gain_today?" => ltp > close
            })
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(
        %{payload: quote_data},
        %{assigns: %{watchlist: watchlist}} = socket
      ) do
    new_ltp = quote_data.last_traded_price / 100
    close = quote_data.close_price / 100
    ltp_percent = (new_ltp - close) / close * 100

    updated_watchlist_quote =
      Enum.find(watchlist, &(&1["symboltoken"] == quote_data.token))

    socket =
      if updated_watchlist_quote && updated_watchlist_quote["ltp"] != new_ltp do
        updated_watchlist_quote =
          updated_watchlist_quote
          |> Map.put("ltp", new_ltp)
          |> Map.put("close", close)
          |> Map.put("ltp_percent", ltp_percent)
          |> Map.put("is_gain_today?", close < new_ltp)

        socket
        |> stream_insert(
          :watchlist,
          updated_watchlist_quote,
          at: -1
        )
      end || socket

    {:noreply, socket}
  end

  def handle_event(
        "search",
        %{"search" => query},
        socket
      )
      when byte_size(query) < 3 do
    {
      :noreply,
      assign_async(
        socket,
        :token_list,
        fn -> {:ok, %{token_list: []}} end
      )
    }
  end

  def handle_event(
        "search",
        %{"search" => query},
        %{assigns: %{watchlist: watchlist, token: token}} = socket
      ) do
    async_fn = fn ->
      case YahooFinance.search(query) do
        {:ok, yahoo_quotes} when yahoo_quotes != [] ->
          watchlist_symbols = watchlist |> Enum.map(& &1["tradingsymbol"]) |> MapSet.new()

          token_list =
            yahoo_quotes
            |> Enum.map(
              &(&1.symbol
                |> String.slice(0..(String.length(query) - 1))
                |> String.split(".")
                |> List.first())
            )
            |> MapSet.new()
            |> Enum.map(&API.search_token(token, "NSE", &1))
            |> Enum.flat_map(fn
              {:ok, %{"data" => token_list}} -> token_list
              _ -> []
            end)
            |> Enum.uniq_by(& &1["tradingsymbol"])
            |> Enum.filter(&String.ends_with?(&1["tradingsymbol"], "-EQ"))
            |> Enum.map(
              &(&1
                |> Map.put_new(
                  "in_watchlist?",
                  MapSet.member?(watchlist_symbols, &1["tradingsymbol"])
                )
                |> Map.put_new("name", Utils.stock_long_name(&1["tradingsymbol"])))
            )

          {:ok,
           %{
             token_list: token_list
           }}

        _ ->
          {:error, %{token_list: []}}
      end
    end

    {:noreply,
     socket
     |> assign(:token_list, fn -> AsyncResult.loading() end)
     |> assign_async(:token_list, async_fn)}
  end

  def handle_event(
        "toggle-token-watchlist",
        %{"token" => token},
        %{
          assigns: %{
            token: user_token,
            watchlist: watchlist,
            token_list: token_list,
            user_hash: user_hash
          }
        } = socket
      ) do
    new_watch =
      token_list
      |> Map.get(:result, [])
      |> Enum.filter(&(&1["symboltoken"] == token))
      |> assign_quotes(user_token)
      |> List.first()
      |> Map.put("timestamp", Timex.to_unix(Timex.now()))

    token_exist? = watchlist |> Enum.find(&(&1["symboltoken"] == token))

    %{assigns: %{watchlist: watchlist}} =
      socket =
      if token_exist? do
        socket
        |> assign(watchlist: Enum.filter(watchlist, &(&1["symboltoken"] != token)))
        |> put_flash(:info, "Removed #{new_watch["tradingsymbol"]} from watchlist.")
      else
        socket
        |> assign(watchlist: [new_watch | watchlist])
        |> put_flash(:info, "Added #{new_watch["tradingsymbol"]} from watchlist.")
      end

    socket =
      case Account.update_watchlist(user_hash, watchlist) do
        :ok ->
          if token_exist? do
            stream_delete(socket, :watchlist, new_watch)
          else
            stream_insert(
              socket,
              :watchlist,
              new_watch,
              at: 0
            )
          end
          |> assign(watchlist: watchlist)
          |> assign_async(:token_list, fn -> {:ok, %{token_list: []}} end)
          |> subscribe_to_quote_feed()

        _ ->
          socket
          |> put_flash(:error, "Failed to update watchlist.")
      end

    {:noreply, socket}
  end

  def handle_event(
        "select-holding",
        %{"exchange" => exchange, "symbol" => symbol_token},
        socket
      ) do
    {:noreply,
     socket
     |> get_candle_data(exchange, symbol_token)
     |> get_quote(exchange, symbol_token)}
  end

  defp get_quote(%{assigns: %{token: token}} = socket, exchange, symbol_token) do
    with {:ok, %{"data" => %{"fetched" => [quote]}}} <-
           API.quote(token, exchange, [symbol_token]) do
      %{"ltp" => ltp, "close" => close} = quote

      ltp_percent = (ltp - close) / close * 100

      quote = Map.merge(quote, %{"ltp_percent" => ltp_percent, "is_gain_today?" => ltp > close})

      socket
      |> assign(quote: quote)
    else
      e ->
        IO.inspect(e)

        socket
        |> put_flash(:error, "[Quote] : Failed to fetch quote")
    end
  end

  defp get_candle_data(
         %{assigns: %{token: token, quote: prev_quote}} = socket,
         exchange,
         symbol_token
       ) do
    with {:ok, %{"data" => candle_data}} <-
           API.candle_data(
             token,
             exchange,
             symbol_token,
             "FIFTEEN_MINUTE",
             Timex.now("Asia/Kolkata")
             |> Timex.shift(weeks: if(prev_quote, do: 0, else: -1))
             |> Timex.shift(hours: if(prev_quote, do: -1, else: 0))
             |> Timex.format!("{YYYY}-{0M}-{0D} {h24}:{0m}"),
             Timex.now("Asia/Kolkata")
             |> Timex.shift(hours: 1)
             |> Timex.format!("{YYYY}-{0M}-{0D} {h24}:{0m}")
           ) do
      candle_data = Utils.formatted_candle_data(candle_data)

      if prev_quote do
        send_update(CandleChart,
          id: "quote-chart-wrapper",
          event: "update-chart",
          dataset: candle_data
        )

        socket
      else
        assign(socket, candle_data: candle_data)
      end
    else
      e ->
        IO.inspect(e)

        socket
        |> put_flash(:error, "[Quote] : Failed to fetch candle data")
    end
  end

  defp subscribe_to_quote_feed(
         %{assigns: %{client_code: client_code, watchlist: watchlist}} = socket
       ) do
    WebSockex.send_frame(
      :"#{client_code}",
      {:text,
       Jason.encode!(%{
         correlationID: client_code,
         action: 1,
         params: %{
           mode: 2,
           tokenList: [
             %{
               exchangeType: 1,
               tokens: Enum.map(watchlist, & &1["symboltoken"])
             }
           ]
         }
       })}
    )

    socket
  end

  defp assign_quotes(watchlist, token) do
    with {:ok, %{"data" => %{"fetched" => quotes}}} <-
           API.quote(token, "NSE", Enum.map(watchlist, & &1["symboltoken"])) do
      watchlist_map =
        Enum.reduce(watchlist, %{}, fn w, acc ->
          Map.merge(acc, %{w["symboltoken"] => w})
        end)

      quotes
      |> Enum.map(fn %{"symbolToken" => symbol_token, "ltp" => ltp, "close" => close} ->
        watch = watchlist_map[symbol_token]
        ltp_percent = (ltp - close) / close * 100

        watch
        |> Map.put("ltp", ltp)
        |> Map.put("close", close)
        |> Map.put("ltp_percent", ltp_percent)
        |> Map.put("is_gain_today?", close < ltp)
      end)
      |> Enum.sort(&(&1["timestamp"] >= &2["timestamp"]))
    else
      _ ->
        watchlist
    end
  end
end
