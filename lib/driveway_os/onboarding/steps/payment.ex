defmodule DrivewayOS.Onboarding.Steps.Payment do
  @moduledoc """
  Payment wizard step. Generic over N providers in the `:payment`
  category — uses `Steps.PickerStep` for the render + complete? +
  submit shape. V1 surfaces Stripe + Square. Each card routes to its
  own OAuth start. Switching providers post-onboarding is
  support-driven.

  See `Onboarding.Steps.PickerStep` for the picker contract.
  """
  use DrivewayOS.Onboarding.Steps.PickerStep,
    category: :payment,
    intro_copy:
      "Pick the payment processor you want to use. " <>
        "You can change later by emailing support."

  @impl true
  def id, do: :payment

  @impl true
  def title, do: "Take card payments"
end
