defmodule AngelTradingWeb.ClientLoginLive do
  use AngelTradingWeb, :live_view
  alias AngelTrading.API

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "New Client")}
  end

  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, params: params)}
  end

  def render(assigns) do
    ~H"""
    <div class="flex m-auto max-w-6xl px-4 sm:px-6 lg:px-8 justify-center">
      <.simple_form :let={f} for={%{}} as={:user} autocomplete="off" phx-submit="login">
        <.input field={f[:client_code]} value={@params["client_code"]} placeholder="Client code" />
        <.input
          field={f[:password]}
          type="password"
          value={@params["password"]}
          placeholder="Pin"
          maxlength="4"
          minlength="4"
        />
        <.input field={f[:totp_secret]} value={@params["totp_secret"]} placeholder="Totp secret" />
        <:actions>
          <.button class="w-full dark:bg-gray-500">ADD CLIENT</.button>
        </:actions>
      </.simple_form>
      <.bottom_nav active_page={:client} />
    </div>
    """
  end

  def handle_event(
        "login",
        %{
          "user" =>
            %{"client_code" => client_code, "password" => password, "totp_secret" => totp_secret} =
              params
        },
        socket
      )
      when bit_size(client_code) != 0 and bit_size(password) != 0 and bit_size(totp_secret) != 0 do
    with {:ok, totp} <- AngelTrading.TOTP.totp_now(params["totp_secret"]),
         {:ok,
          %{
            "data" => %{
              jwt_token: token,
              refresh_token: refresh_token,
              feed_token: feed_token
            }
          }} <-
           API.login(%{
             client_code: client_code,
             password: password,
             totp: totp
           }) do
      client_code = params["client_code"]

      {:noreply,
       redirect(socket,
         to:
           ~p"/session/#{client_code}/#{token}/#{refresh_token}/#{feed_token}/#{password}/#{totp_secret}"
       )}
    else
      {:error, error} ->
        message =
          case error do
            <<message::binary>> -> message
            %{"message" => message} -> message
          end

        {
          :noreply,
          socket
          |> push_patch(to: ~p"/client/login?#{params}")
          |> put_flash(:error, message)
        }
    end
  end

  def handle_event("login", %{"user" => params}, socket) do
    {
      :noreply,
      socket
      |> push_patch(to: ~p"/client/login?#{params}")
      |> put_flash(:error, "Invalid credentials")
    }
  end
end
