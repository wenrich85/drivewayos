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
      <div class="w-full max-w-md space-y-6">
        <header class="text-center space-y-2">
          <h1 class="text-3xl font-bold tracking-tight">Create your account</h1>
          <p class="text-sm text-base-content/70">
            Sign up to book at <span class="font-semibold">{@current_tenant.display_name}</span>.
          </p>
        </header>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6 space-y-4">
            <div :if={@errors[:base]} role="alert" class="alert alert-error">
              <span class="hero-exclamation-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
              <span class="text-sm">{@errors[:base]}</span>
            </div>

            <form id="register-form" phx-submit="submit" class="space-y-4">
              <div>
                <label class="label" for="register-name">
                  <span class="label-text font-medium">Your name</span>
                </label>
                <input
                  id="register-name"
                  type="text"
                  name="register[name]"
                  value={@form["name"]}
                  autocomplete="name"
                  class="input input-bordered w-full"
                  required
                />
                <p :if={@errors[:name]} class="text-error text-xs mt-1">{@errors[:name]}</p>
              </div>

              <div>
                <label class="label" for="register-email">
                  <span class="label-text font-medium">Email</span>
                </label>
                <input
                  id="register-email"
                  type="email"
                  name="register[email]"
                  value={@form["email"]}
                  autocomplete="email"
                  class="input input-bordered w-full"
                  required
                />
                <p :if={@errors[:email]} class="text-error text-xs mt-1">{@errors[:email]}</p>
              </div>

              <div>
                <label class="label" for="register-phone">
                  <span class="label-text font-medium">Phone</span>
                  <span class="label-text-alt text-base-content/50">Optional</span>
                </label>
                <input
                  id="register-phone"
                  type="tel"
                  name="register[phone]"
                  value={@form["phone"]}
                  autocomplete="tel"
                  placeholder="+1 512 555 0100"
                  class="input input-bordered w-full"
                />
              </div>

              <div>
                <label class="label" for="register-password">
                  <span class="label-text font-medium">Password</span>
                </label>
                <input
                  id="register-password"
                  type="password"
                  name="register[password]"
                  autocomplete="new-password"
                  class="input input-bordered w-full"
                  required
                />
                <p class="text-xs text-base-content/60 mt-1">
                  10+ characters · at least one upper, one lower, one digit.
                </p>
                <p :if={@errors[:password]} class="text-error text-xs mt-1">
                  {@errors[:password]}
                </p>
              </div>

              <button type="submit" class="btn btn-primary w-full gap-2">
                <span class="hero-user-plus w-5 h-5" aria-hidden="true"></span>
                Create account
              </button>
            </form>
          </div>
        </section>

        <p class="text-center text-sm text-base-content/60">
          Already have an account?
          <.link patch={~p"/sign-in"} class="link link-primary font-medium">Sign in</.link>
        </p>
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
