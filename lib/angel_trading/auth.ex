defmodule AngelTrading.Auth do
  use Tesla

  @routes %{
    login: "rest/auth/angelbroking/user/v1/loginByPassword",
    profile: "rest/secure/angelbroking/user/v1/getProfile"
  }

  def login(%{"clientcode" => _, "password" => _, "totp" => _} = params) do
    client()
    |> post(@routes.login, params)
    |> gen_response()
  end

  def profile(token) do
    client(token)
    |> get(@routes.profile)
    |> gen_response()
  end

  defp client(token \\ nil) do
    headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"},
      {"X-UserType", "USER"},
      {"X-SourceID", "WEB"},
      {"X-ClientLocalIP", Application.get_env(:angel_trading, :local_ip)},
      {"X-ClientPublicIP", Application.get_env(:angel_trading, :public_ip)},
      {"X-MACAddress", Application.get_env(:angel_trading, :mac_address)},
      {"X-PrivateKey", Application.get_env(:angel_trading, :api_key)}
    ]

    headers =
      if token do
        [{"authorization", "Bearer " <> token} | headers]
      else
        headers
      end

    middleware = [
      {Tesla.Middleware.BaseUrl, Application.get_env(:angel_trading, :api_endpoint)},
      Tesla.Middleware.JSON,
      {Tesla.Middleware.Headers, headers}
    ]

    IO.inspect(middleware)

    Tesla.client(middleware)
  end

  defp gen_response({:ok, %{body: %{"message" => message} = body}})
       when message == "SUCCESS",
       do: {:ok, body}

  defp gen_response({:ok, %{body: body}}), do: {:error, body}
end
