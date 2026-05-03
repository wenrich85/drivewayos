defmodule DrivewayOS.Onboarding.Steps.Email do
  @moduledoc """
  Email wizard step. Generic over N providers in the `:email`
  category via `Steps.PickerStep`. As of Phase 4b, both providers
  (Postmark + Resend) are API-first — picker cards route to each
  provider's `/onboarding/<provider>/start` controller path which
  fires provisioning synchronously and redirects back.

  V1 provider universe: Postmark, Resend. Wizard's "any one
  provider connected = step done" semantics mean a tenant doesn't
  see Resend's card if Postmark is already set up (and vice-versa).
  Switching is support-driven.
  """
  use DrivewayOS.Onboarding.Steps.PickerStep,
    category: :email,
    intro_copy:
      "Pick the email provider for booking confirmations and reminders. " <>
        "You can change later by emailing support."

  @impl true
  def id, do: :email

  @impl true
  def title, do: "Send booking emails"
end
