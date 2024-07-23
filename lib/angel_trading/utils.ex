defmodule AngelTrading.Utils do
  @max_age :infinity

  require Explorer.DataFrame, as: DF
  require Explorer.Series, as: S

  @doc """
  Encrypt any Erlang term.

  ## Examples

      iex> AngelTrading.Utils.encrypt(:my_context, %{data: "secret"})
      <<...>>

  """
  @spec encrypt(atom(), any(), integer()) :: binary()
  def encrypt(context, term, max_age \\ @max_age) do
    Plug.Crypto.encrypt(secret(), to_string(context), term, max_age: max_age)
  end

  @doc """
  Decrypt cipher-text into an Erlang term.

  ## Examples

      iex> AngelTrading.Utils.decrypt(:my_context, <<...>>)
      {:ok, %{data: "secret"}}

  """
  @spec decrypt(atom(), binary(), integer()) :: {:ok, any()} | {:error, atom()}
  def decrypt(context, ciphertext, max_age \\ @max_age) when is_binary(ciphertext) do
    Plug.Crypto.decrypt(secret(), to_string(context), ciphertext, max_age: max_age)
  end

  def quote_stream_process(client_code), do: :"#{client_code}-quote-stream"
  def order_stream_process(client_code), do: :"#{client_code}-order-stream"

  # Using float calculation as of now. Since most of the data is coming from angel api.
  # I could add ex_money to manage calculations in decimal money format.
  def formatted_holdings(holdings) do
    holdings
    |> Enum.filter(&filter_holding/1)
    |> Enum.map(&format_holding/1)
  end

  defp filter_holding(%{symbol_token: symbol_token, quantity: quantity, close: close})
       when symbol_token == nil or quantity == 0 or close == 0,
       do: false

  defp filter_holding(_), do: true

  defp format_holding(
         %TradeGalleon.Brokers.AngelOne.Responses.Portfolio.Holding{
           average_price: average_price,
           close: close,
           ltp: ltp,
           quantity: quantity,
           realised_quantity: realised_quantity,
           symbol_token: symbol_token
         } = holding
       ) do
    average_price = if average_price > 0, do: average_price, else: close
    close = if realised_quantity > 0, do: close, else: average_price
    invested = quantity * average_price
    current = quantity * ltp
    overall_gain_or_loss = quantity * (ltp - average_price)
    overall_gain_or_loss_percent = overall_gain_or_loss / invested * 100
    todays_profit_or_loss = quantity * (ltp - close)
    ltp_percent = (ltp - close) / close * 100
    todays_profit_or_loss_percent = todays_profit_or_loss / invested * 100

    Map.merge(holding, %{
      invested: invested,
      current: current,
      in_overall_profit?: current > invested,
      is_gain_today?: ltp > close,
      overall_gain_or_loss: overall_gain_or_loss,
      overall_gain_or_loss_percent: overall_gain_or_loss_percent,
      todays_profit_or_loss: todays_profit_or_loss,
      todays_profit_or_loss_percent: todays_profit_or_loss_percent,
      ltp_percent: ltp_percent,
      id: symbol_token
    })
  end

  def calculated_overview(holdings) do
    total_invested = holdings |> Enum.map(& &1.invested) |> Enum.sum()
    total_overall_gain_or_loss = holdings |> Enum.map(& &1.overall_gain_or_loss) |> Enum.sum()
    total_todays_gain_or_loss = holdings |> Enum.map(& &1.todays_profit_or_loss) |> Enum.sum()

    %{
      holdings: holdings |> Enum.sort_by(& &1.trading_symbol, :desc),
      total_invested: total_invested,
      total_current: holdings |> Enum.map(& &1.current) |> Enum.sum(),
      total_overall_gain_or_loss: total_overall_gain_or_loss,
      total_todays_gain_or_loss: total_todays_gain_or_loss,
      in_overall_profit_today?: total_todays_gain_or_loss > 0,
      in_overall_profit?: total_overall_gain_or_loss > 0,
      total_overall_gain_or_loss_percent: total_overall_gain_or_loss / total_invested * 100,
      total_todays_gain_or_loss_percent: total_todays_gain_or_loss / total_invested * 100
    }
  end

  def formatted_candle_data(candle_data) do
    candle_data
    |> Enum.map(&format_candle_data/1)
    |> calculate_rsi()
  end

  defp format_candle_data([timestamp, open, high, low, close, volume]) do
    %{
      time:
        timestamp
        |> String.split("+")
        |> List.first()
        |> Timex.parse!("{ISO:Extended:Z}")
        |> Timex.to_unix(),
      open: open,
      high: high,
      low: low,
      close: close,
      volume: volume
    }
  end

  def stock_long_name(trading_symbol) do
    symbol = trading_symbol |> String.split("-") |> List.first()

    case AngelTrading.YahooFinance.search(symbol) do
      {:ok, [%{long_name: long_name}]} when byte_size(long_name) > 0 -> long_name
      _ -> trading_symbol
    end
  end

  defp calculate_rsi(candle_data) do
    quote_data =
      candle_data
      |> DF.new()
      |> DF.mutate(
        price_change:
          S.subtract(
            close,
            S.shift(close, 1)
          )
      )
      |> DF.mutate(
        gain: if(S.greater(price_change, 0), do: price_change, else: 0),
        loss: if(S.less(price_change, 0), do: -price_change, else: 0)
      )
      |> DF.mutate(
        avg_gain: S.window_mean(gain, 14, min_periods: 1),
        avg_loss: S.window_mean(loss, 14, min_periods: 1)
      )

    quote_data_first_13 = DF.slice(quote_data, 0..12)

    quote_data_at_14 =
      quote_data
      |> DF.mutate(
        avg_gain: S.window_mean(gain, 14, min_periods: 14),
        avg_loss: S.window_mean(loss, 14, min_periods: 14)
      )
      |> DF.slice(13..13)

    quote_data_after_14 =
      quote_data_at_14
      |> DF.concat_rows(quote_data |> DF.slice(14..-1//1))
      |> DF.mutate_with(
        &[
          avg_gain: S.divide(S.add(&1["gain"], S.multiply(13, S.shift(&1["avg_gain"], 1))), 14),
          avg_loss: S.divide(S.add(&1["loss"], S.multiply(13, S.shift(&1["avg_loss"], 1))), 14)
        ]
      )
      |> DF.slice(1..-1//1)

    quote_data_first_13
    |> DF.concat_rows(quote_data_at_14)
    |> DF.concat_rows(quote_data_after_14)
    |> DF.mutate(rs: S.divide(avg_gain, avg_loss))
    |> DF.mutate(rs: if(S.is_nan(rs), do: 0, else: rs))
    |> DF.mutate(rsi: S.subtract(100, S.divide(100, S.add(1, rs))))
    |> DF.to_rows()
  end

  defp secret(), do: Application.get_env(:angel_trading, :encryption_key)
end
