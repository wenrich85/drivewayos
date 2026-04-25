defmodule DrivewayOSWeb.Auth.RegisterLive do
  @moduledoc """
  Customer self-registration form. Tenant-scoped — mounted only on
  `{slug}.lvh.me/register`. On success, automatically signs the new
  customer in (mints a JWT, hands it to the session controller).

  V1 keeps the form minimal: name, email, password, optional phone.
  Address + vehicle are collected at booking time (stored as flat
  strings on Appointment for V1 — split into Vehicle + Address
  resources in V2).

  Same email can register on a different tenant — they're independent
  rows by design (multitenancy invariant).
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook

  alias DrivewayOS.Accounts.Customer

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_tenant] do
      {:ok,
       socket
       |> assign(:page_title, "Create your account")
       |> assign(:errors, %{})
       |> assign(:form, %{
         "email" => "",
         "name" => "",
         "phone" => ""
       })}
    else
      {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("submit", %{"register" => params}, socket) do
    tenant = socket.assigns.current_tenant

    case Customer
         |> Ash.Changeset.for_create(
           :register_with_password,
           %{
             email: params["email"] |> to_string() |> String.trim() |> String.downcase(),
             password: params["password"],
             password_confirmation: params["password"],
             name: params["name"] |> to_string() |> String.trim(),
             phone: params["phone"]
           },
           tenant: tenant.id
         )
         |> Ash.create(authorize?: false) do
      {:ok, %{__metadata__: %{token: token}}} ->
        {:noreply, redirect(socket, to: ~p"/auth/customer/store-token?token=#{token}")}

      {:error, %Ash.Error.Invalid{} = e} ->
        {:noreply,
         socket
         |> assign(:errors, ash_errors_to_map(e))
         |> assign(:form, params)}

      _ ->
        {:noreply,
         socket
         |> assign(:errors, %{base: "Could not create your account."})
         |> assign(:form, params)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen flex items-center justify-center bg-base-200 px-4 py-12">
      <div class="card w-full max-w-md bg-base-100 shadow-lg">
        <div class="card-body">
          <h1 class="card-title text-2xl">Create your account</h1>
          <p class="text-base-content/70 mb-2">
            Sign up to book at {@current_tenant.display_name}.
          </p>

          <div :if={@errors[:base]} class="alert alert-error text-sm">{@errors[:base]}</div>

          <form id="register-form" phx-submit="submit" class="space-y-4">
            <div>
              <label class="label" for="register-name">
                <span class="label-text">Your name</span>
              </label>
              <input
                id="register-name"
                type="text"
                name="register[name]"
                value={@form["name"]}
                class="input input-bordered w-full"
                required
              />
              <p :if={@errors[:name]} class="text-error text-sm mt-1">{@errors[:name]}</p>
            </div>

            <div>
              <label class="label" for="register-email">
                <span class="label-text">Email</span>
              </label>
              <input
                id="register-email"
                type="email"
                name="register[email]"
                value={@form["email"]}
                class="input input-bordered w-full"
                required
              />
              <p :if={@errors[:email]} class="text-error text-sm mt-1">{@errors[:email]}</p>
            </div>

            <div>
              <label class="label" for="register-phone">
                <span class="label-text">Phone (optional)</span>
              </label>
              <input
                id="register-phone"
                type="tel"
                name="register[phone]"
                value={@form["phone"]}
                placeholder="+1 512 555 0100"
                class="input input-bordered w-full"
              />
            </div>

            <div>
              <label class="label" for="register-password">
                <span class="label-text">Password</span>
              </label>
              <input
                id="register-password"
                type="password"
                name="register[password]"
                class="input input-bordered w-full"
                required
              />
              <p class="text-xs text-base-content/60 mt-1">
                10+ chars, at least one upper, one lower, one digit.
              </p>
              <p :if={@errors[:password]} class="text-error text-sm mt-1">
                {@errors[:password]}
              </p>
            </div>

            <button type="submit" class="btn btn-primary w-full">Create account</button>
          </form>

          <p class="text-sm text-center text-base-content/70 mt-4">
            Already have an account? <.link patch={~p"/sign-in"} class="link">Sign in</.link>
          </p>
        </div>
      </div>
    </main>
    """
  end

  defp ash_errors_to_map(%Ash.Error.Invalid{errors: errors}) do
    Enum.reduce(errors, %{}, fn err, acc ->
      field = Map.get(err, :field) || :base
      message = Map.get(err, :message) || inspect(err)
      Map.put(acc, field, message)
    end)
  end
end
