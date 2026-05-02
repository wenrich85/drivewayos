defmodule DrivewayOS.Onboarding.Steps.Schedule do
  @moduledoc """
  Schedule wizard step. Customers can only see concrete time slots
  once the operator publishes weekly availability blocks; this step
  prompts them to create at least one.

  Like Steps.Services, the wizard step itself is a redirect to
  /admin/schedule where the full BlockTemplate editor already lives.
  """
  @behaviour DrivewayOS.Onboarding.Step

  use Phoenix.Component

  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.BlockTemplate

  require Ash.Query

  @impl true
  def id, do: :schedule

  @impl true
  def title, do: "Set your weekly hours"

  @impl true
  def complete?(%Tenant{} = tenant) do
    {:ok, blocks} =
      BlockTemplate |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

    not Enum.empty?(blocks)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-base-content/70">
        Customers can only book times when you're available. Add at least one
        weekly block — say, 9am–5pm Tuesdays — to get going.
      </p>
      <a href="/admin/schedule" class="btn btn-primary btn-sm gap-1">
        Open schedule editor
        <span class="hero-arrow-top-right-on-square w-3 h-3" aria-hidden="true"></span>
      </a>
      <p class="text-xs text-base-content/60">
        We'll bring you back here when you're done.
      </p>
    </div>
    """
  end

  @impl true
  def submit(_params, socket), do: {:ok, socket}
end
