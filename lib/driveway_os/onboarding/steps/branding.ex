defmodule DrivewayOS.Onboarding.Steps.Branding do
  @moduledoc """
  Branding wizard step. Collects the four shop-identity fields the
  customer-facing booking page needs:

    * support_email (REQUIRED — gates step completion)
    * logo_url (optional)
    * primary_color_hex (optional, default #3b82f6 from DaisyUI)
    * support_phone (optional)

  Only support_email is required because it's the only field that
  *breaks* something if missing — confirmation emails would have
  no reply-to. Logo + color + phone are polish the operator can
  always come back to via /admin/branding.

  The form mirrors the field shape used by the existing
  /admin/branding LV; both write to Tenant via the same `:update`
  action.
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :branding

  @impl true
  def title, do: "Make it yours"

  @impl true
  def complete?(%Tenant{support_email: nil}), do: false
  def complete?(%Tenant{support_email: ""}), do: false
  def complete?(%Tenant{support_email: _}), do: true

  @impl true
  def render(assigns) do
    ~H"""
    <form id="step-branding-form" phx-submit="step_submit" class="space-y-3">
      <div>
        <label class="label" for="branding-email">
          <span class="label-text font-medium">Support email *</span>
        </label>
        <input
          id="branding-email"
          type="email"
          name="branding[support_email]"
          value={@current_tenant.support_email || ""}
          placeholder="hello@yourshop.com"
          class="input input-bordered w-full"
          required
        />
        <p :if={@errors[:support_email]} class="text-error text-xs mt-1">
          {@errors[:support_email]}
        </p>
      </div>

      <div>
        <label class="label" for="branding-logo">
          <span class="label-text font-medium">Logo URL</span>
          <span class="label-text-alt text-base-content/50">Optional</span>
        </label>
        <input
          id="branding-logo"
          type="url"
          name="branding[logo_url]"
          value={@current_tenant.logo_url || ""}
          placeholder="https://yourshop.com/logo.png"
          class="input input-bordered w-full"
        />
      </div>

      <div class="grid grid-cols-2 gap-3">
        <div>
          <label class="label" for="branding-color">
            <span class="label-text font-medium">Brand color</span>
            <span class="label-text-alt text-base-content/50">Optional</span>
          </label>
          <input
            id="branding-color"
            type="text"
            name="branding[primary_color_hex]"
            value={@current_tenant.primary_color_hex || "#3b82f6"}
            placeholder="#3b82f6"
            class="input input-bordered w-full font-mono"
          />
        </div>
        <div>
          <label class="label" for="branding-phone">
            <span class="label-text font-medium">Support phone</span>
            <span class="label-text-alt text-base-content/50">Optional</span>
          </label>
          <input
            id="branding-phone"
            type="tel"
            name="branding[support_phone]"
            value={@current_tenant.support_phone || ""}
            placeholder="+1 555-555-1234"
            class="input input-bordered w-full"
          />
        </div>
      </div>
    </form>
    """
  end

  @impl true
  def submit(%{"branding" => params}, socket) do
    tenant = socket.assigns.current_tenant

    attrs = %{
      support_email: params["support_email"] |> to_string() |> String.trim(),
      logo_url: params["logo_url"] |> to_string() |> String.trim() |> presence(),
      primary_color_hex: params["primary_color_hex"] |> to_string() |> String.trim() |> presence(),
      support_phone: params["support_phone"] |> to_string() |> String.trim() |> presence()
    }

    case tenant
         |> Ash.Changeset.for_update(:update, attrs)
         |> Ash.update(authorize?: false) do
      {:ok, updated} ->
        {:ok, Phoenix.Component.assign(socket, :current_tenant, updated)}

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        msg = errors |> Enum.map_join("; ", &Map.get(&1, :message, "is invalid"))
        {:error, msg}
    end
  end

  defp presence(""), do: nil
  defp presence(v), do: v
end
