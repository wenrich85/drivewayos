defmodule DrivewayOS.Scheduling.Appointment do
  @moduledoc """
  Tenant-scoped appointment — a customer's booking for a specific
  service at a specific time.

  V1 keeps the model simple:

    * `vehicle_description` and `service_address` are flat strings on
      the appointment (no separate Vehicle / Address resources yet).
      V2 splits them out so customers can save vehicles + addresses
      and reuse them across bookings.
    * No block templates / time slots — customers pick any future
      time. V2 adds operator-defined block templates + a route
      optimizer.
    * Stripe payment integration lands in Slice 7. For now an
      appointment can be created without a payment.

  Status lifecycle:

      pending → confirmed → in_progress → completed
                  ↓
                cancelled
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Scheduling,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "appointments"
    repo DrivewayOS.Repo

    references do
      reference :customer, on_delete: :restrict
      reference :service_type, on_delete: :restrict
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :tenant_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :scheduled_at, :utc_datetime do
      allow_nil? false
      public? true
    end

    attribute :duration_minutes, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :status, :atom do
      constraints one_of: [:pending, :confirmed, :in_progress, :completed, :cancelled]
      default :pending
      allow_nil? false
      public? true
    end

    attribute :price_cents, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :vehicle_description, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :service_address, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 300
    end

    attribute :notes, :string do
      public? true
      constraints max_length: 1000
    end

    # Operator-only notes for this specific appointment. Distinct
    # from `Customer.admin_notes` (pinned across all the customer's
    # bookings) and from `:notes` (the customer-supplied booking
    # comment). Use case: "this driveway is steep, bring ramps",
    # "customer asked to skip the wheels this time."
    attribute :operator_notes, :string do
      public? true
      constraints max_length: 1000
    end

    # Multi-car households: customer wants the tech to do 2+ cars in
    # one visit. The primary `vehicle_description` carries the first
    # car (kept for backwards compatibility with every list view that
    # already renders it). Additional cars land here as a list of
    # %{"description" => string, "price_cents" => integer} maps. The
    # customer-facing wizard always fills in service.base_price for
    # each entry; admin can override per-vehicle on the detail page
    # (multi-car discount, premium-service surcharge).
    attribute :additional_vehicles, {:array, :map} do
      public? true
      default []
    end

    attribute :cancellation_reason, :string do
      public? true
      constraints max_length: 300
    end

    # Stripe Checkout Session id created at booking time (when the
    # tenant has Connect onboarded). Survives the redirect cycle to
    # Stripe and back so the webhook handler can resolve the
    # session → appointment.
    attribute :stripe_checkout_session_id, :string do
      public? true
      constraints max_length: 100
    end

    # PaymentIntent id, set on `checkout.session.completed`. Useful
    # for refunds, reconciliation, and proving "yes Stripe knows
    # about this charge."
    attribute :stripe_payment_intent_id, :string do
      public? true
      constraints max_length: 100
    end

    attribute :payment_status, :atom do
      # `:failed` is set by the `payment_intent.payment_failed`
      # webhook (or any other declined-charge signal). The customer
      # can retry by re-running the booking; we don't auto-retry on
      # the operator's behalf because Stripe's own retry rules
      # already handle transient declines.
      constraints one_of: [:unpaid, :pending, :paid, :refunded, :failed]
      default :unpaid
      allow_nil? false
      public? true
    end

    attribute :paid_at, :utc_datetime_usec do
      public? true
    end

    # Stamped by the ReminderScheduler GenServer right after it
    # dispatches the 24h-before-the-appointment reminder email.
    # Set-once: queries find the next batch by `is_nil(reminder_sent_at)`,
    # so reprocessing the same row is impossible.
    attribute :reminder_sent_at, :utc_datetime_usec do
      public? true
    end

    # Optional self-reported channel from the booking wizard
    # ("How did you hear about us?"). Free-form string so future
    # tenant-customized values land cleanly; the V1 wizard renders
    # a fixed dropdown defined in BookingLive.@acquisition_channels.
    attribute :acquisition_channel, :string do
      public? true
      constraints max_length: 60
    end

    # True when the booking redeemed a loyalty punch-card credit:
    # price_cents is forced to 0 at create time and the customer's
    # loyalty_count is reset. The completion hook ALSO checks this
    # to skip incrementing loyalty (you don't earn a punch on a
    # punch-redemption wash).
    attribute :is_loyalty_redemption, :boolean do
      default false
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :customer, DrivewayOS.Accounts.Customer do
      allow_nil? false
      public? true
    end

    belongs_to :service_type, DrivewayOS.Scheduling.ServiceType do
      allow_nil? false
      public? true
    end

    # Optional FKs to saved Vehicle / Address rows. Nil for
    # Starter-tier bookings (which only have free-text
    # vehicle_description / service_address) or for guests who
    # didn't save the vehicle/address. The denormalized strings on
    # this resource always remain populated — they're the source
    # of truth for the appointment's snapshot.
    belongs_to :vehicle, DrivewayOS.Fleet.Vehicle do
      allow_nil? true
      public? true
    end

    belongs_to :address, DrivewayOS.Fleet.Address do
      allow_nil? true
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :book do
      primary? true

      accept [
        :customer_id,
        :service_type_id,
        :scheduled_at,
        :duration_minutes,
        :price_cents,
        :vehicle_description,
        :service_address,
        :notes,
        :vehicle_id,
        :address_id,
        :acquisition_channel,
        :is_loyalty_redemption,
        :additional_vehicles
      ]

      # If additional_vehicles is non-empty, normalize each entry
      # into %{"description" => string, "price_cents" => integer}
      # form (entries with a missing price get the primary's
      # price_cents as default), then recompute the total. This
      # keeps the customer wizard simple — it can pass either bare
      # strings OR maps without prices and we fill the rest in.
      # Operators can still override after the fact via the admin
      # :update_vehicle_prices path. Duration isn't multiplied —
      # washing the second car overlaps prep on the first, and most
      # operators want to keep the published window honest rather
      # than tripling it.
      change fn changeset, _ ->
        case Ash.Changeset.get_attribute(changeset, :additional_vehicles) do
          extras when is_list(extras) and extras != [] ->
            base = Ash.Changeset.get_attribute(changeset, :price_cents) || 0
            normalized = normalize_vehicle_entries(extras, base)
            total = base + Enum.reduce(normalized, 0, &(&1["price_cents"] + &2))

            changeset
            |> Ash.Changeset.force_change_attribute(:additional_vehicles, normalized)
            |> Ash.Changeset.force_change_attribute(:price_cents, total)

          _ ->
            changeset
        end
      end

      validate compare(:scheduled_at, greater_than: &DateTime.utc_now/0),
        message: "must be in the future"

      # Defense-in-depth: confirm customer_id + service_type_id both
      # exist IN THE CURRENT TENANT'S DATA SLICE. Without this, a
      # caller could insert an appointment with a customer_id from a
      # different tenant (the simple FK only checks the row exists,
      # not that it's in our tenant). Phase 5 of the original
      # migration plan calls for composite FKs at the DB layer for
      # this — until then, this validation closes the gap.
      validate fn changeset, _ ->
        tenant = changeset.tenant

        with :ok <-
               check_in_tenant(
                 DrivewayOS.Accounts.Customer,
                 Ash.Changeset.get_attribute(changeset, :customer_id),
                 tenant,
                 :customer_id
               ),
             :ok <-
               check_in_tenant(
                 DrivewayOS.Scheduling.ServiceType,
                 Ash.Changeset.get_attribute(changeset, :service_type_id),
                 tenant,
                 :service_type_id
               ) do
          :ok
        end
      end
    end

    update :update do
      primary? true

      accept [:scheduled_at, :duration_minutes, :notes]
    end

    # Dedicated action so an admin tweaking operator_notes can't
    # accidentally re-write the customer's `notes` or shift
    # scheduled_at via a generic :update.
    update :set_operator_notes do
      accept [:operator_notes]
    end

    # Admin override for per-vehicle pricing. Takes the new primary
    # `price_cents` plus the full additional_vehicles list (each
    # with its own price) and recomputes the booking's total in one
    # atomic step. Existing customer-side wizard never calls this
    # action; the customer flow only sets descriptions.
    update :update_vehicle_prices do
      argument :primary_price_cents, :integer, allow_nil?: false
      argument :additional_vehicles, {:array, :map}, default: []
      require_atomic? false

      change fn changeset, _ ->
        primary = Ash.Changeset.get_argument(changeset, :primary_price_cents) || 0
        extras = Ash.Changeset.get_argument(changeset, :additional_vehicles) || []
        normalized = normalize_vehicle_entries(extras, primary)
        total = primary + Enum.reduce(normalized, 0, &(&1["price_cents"] + &2))

        changeset
        |> Ash.Changeset.force_change_attribute(:additional_vehicles, normalized)
        |> Ash.Changeset.force_change_attribute(:price_cents, total)
      end
    end

    # Move an existing booking to a new time. Status is preserved
    # (pending stays pending, confirmed stays confirmed) — the
    # alternative is a cancel + rebook which loses history and may
    # double-charge through Stripe. Rejected for terminal states.
    update :reschedule do
      argument :new_scheduled_at, :utc_datetime, allow_nil?: false
      require_atomic? false

      validate fn changeset, _ ->
        case changeset.data.status do
          s when s in [:pending, :confirmed] -> :ok
          other -> {:error, field: :status, message: "can't reschedule a #{other} appointment"}
        end
      end

      validate fn changeset, _ ->
        new_at = Ash.Changeset.get_argument(changeset, :new_scheduled_at)

        case DateTime.compare(new_at, DateTime.utc_now()) do
          :gt -> :ok
          _ -> {:error, field: :new_scheduled_at, message: "must be in the future"}
        end
      end

      change fn changeset, _ ->
        new_at = Ash.Changeset.get_argument(changeset, :new_scheduled_at)
        Ash.Changeset.force_change_attribute(changeset, :scheduled_at, new_at)
      end
    end

    update :confirm do
      change set_attribute(:status, :confirmed)
    end

    update :start_wash do
      change set_attribute(:status, :in_progress)
    end

    update :complete do
      # The after_action hook below is non-atomic (it touches a
      # second resource), so the whole action runs in a regular
      # txn. The two writes (appointment status + customer count)
      # land in the same DB transaction so a crash mid-action
      # rolls both back.
      require_atomic? false

      change set_attribute(:status, :completed)

      # Loyalty: bump the customer's loyalty_count when their
      # wash actually happens. Best-effort — if the increment
      # fails (e.g. customer was deleted concurrently), the
      # status transition still commits. Tenant.loyalty_threshold
      # being nil doesn't change anything here; the count rolls
      # forward regardless and the /me display only shows the
      # progress bar when threshold is set.
      change fn changeset, _ctx ->
        Ash.Changeset.after_action(changeset, fn _, appt ->
          # Redemption appointments don't earn a punch — that
          # would let a customer cycle one free wash forever.
          unless appt.is_loyalty_redemption do
            DrivewayOS.Scheduling.LoyaltyHooks.bump_after_complete(appt)
          end

          {:ok, appt}
        end)
      end
    end

    update :cancel do
      argument :cancellation_reason, :string

      change set_attribute(:status, :cancelled)
      change set_attribute(:cancellation_reason, arg(:cancellation_reason))
    end

    update :attach_stripe_session do
      accept [:stripe_checkout_session_id, :payment_status]
    end

    update :mark_paid do
      argument :stripe_payment_intent_id, :string

      # The after_action hook below isn't atomic-eligible (Ash's
      # AfterAction change doesn't implement atomic/3), so we drop
      # out of atomic mode for this action. Same pattern as
      # `:complete` (loyalty hook) and `:reschedule`.
      require_atomic? false

      change set_attribute(:payment_status, :paid)
      change set_attribute(:paid_at, &DateTime.utc_now/0)
      change set_attribute(:status, :confirmed)
      change set_attribute(:stripe_payment_intent_id, arg(:stripe_payment_intent_id))

      # Phase 3 Task 10: kick off accounting sync for this paid
      # appointment. `after_action` runs only on a successful commit,
      # so we never enqueue for a rolled-back update. Errors during
      # `Oban.insert` are swallowed — the payment flow must never
      # block on accounting plumbing (worst case: the operator can
      # manually re-trigger sync from the admin UI).
      change after_action(fn _changeset, appointment, _ctx ->
               try do
                 DrivewayOS.Accounting.SyncWorker.new(%{
                   "tenant_id" => appointment.tenant_id,
                   "appointment_id" => appointment.id
                 })
                 |> Oban.insert()
               rescue
                 e ->
                   require Logger
                   Logger.warning("Accounting sync enqueue failed: #{Exception.message(e)}")
               end

               {:ok, appointment}
             end)
    end

    update :mark_refunded do
      change set_attribute(:payment_status, :refunded)
    end

    update :mark_payment_failed do
      change set_attribute(:payment_status, :failed)
    end

    read :by_payment_intent_or_session do
      argument :payment_intent_id, :string
      argument :session_id, :string

      filter expr(
               (not is_nil(^arg(:payment_intent_id)) and
                  stripe_payment_intent_id == ^arg(:payment_intent_id)) or
                 (not is_nil(^arg(:session_id)) and
                    stripe_checkout_session_id == ^arg(:session_id))
             )
    end

    update :mark_reminder_sent do
      change set_attribute(:reminder_sent_at, &DateTime.utc_now/0)
    end

    read :due_for_reminder do
      argument :window_start, :utc_datetime_usec, allow_nil?: false
      argument :window_end, :utc_datetime_usec, allow_nil?: false

      filter expr(
               is_nil(reminder_sent_at) and
                 status in [:pending, :confirmed] and
                 scheduled_at >= ^arg(:window_start) and
                 scheduled_at <= ^arg(:window_end)
             )
    end

    read :by_stripe_session do
      argument :session_id, :string, allow_nil?: false
      filter expr(stripe_checkout_session_id == ^arg(:session_id))
    end

    read :by_payment_intent do
      argument :payment_intent_id, :string, allow_nil?: false
      filter expr(stripe_payment_intent_id == ^arg(:payment_intent_id))
    end

    read :upcoming do
      filter expr(scheduled_at > ^DateTime.utc_now() and status in [:pending, :confirmed])
      prepare build(sort: [scheduled_at: :asc])
    end

    read :for_customer do
      argument :customer_id, :uuid, allow_nil?: false
      filter expr(customer_id == ^arg(:customer_id))
      prepare build(sort: [scheduled_at: :desc])
    end
  end

  # Helper for the cross-tenant FK validation above. Verifies the
  # given id belongs to a row in the current tenant's data slice.
  defp check_in_tenant(_resource, nil, _tenant, _field), do: :ok

  defp check_in_tenant(resource, id, tenant, field) do
    case Ash.get(resource, id, tenant: tenant, authorize?: false) do
      {:ok, _} -> :ok
      _ -> {:error, field: field, message: "must belong to the current tenant"}
    end
  end

  # Coerce one of the three shapes the wizard / admin / API may
  # send into the canonical map shape:
  #   "Honda Pilot"                                  → %{description, price_cents: default}
  #   %{"description" => "Honda"}                    → %{description, price_cents: default}
  #   %{"description" => "Honda", "price_cents" => 7500} → identity
  # Atom keys are normalized to string keys so the storage layer
  # has a single shape regardless of caller.
  @doc false
  def normalize_vehicle_entries(entries, default_price_cents) when is_list(entries) do
    Enum.map(entries, &normalize_vehicle_entry(&1, default_price_cents))
  end

  defp normalize_vehicle_entry(desc, default) when is_binary(desc) do
    %{"description" => String.trim(desc), "price_cents" => default}
  end

  defp normalize_vehicle_entry(%{} = entry, default) do
    desc =
      entry
      |> Map.get("description", Map.get(entry, :description, ""))
      |> to_string()
      |> String.trim()

    price =
      case Map.get(entry, "price_cents", Map.get(entry, :price_cents)) do
        nil -> default
        n when is_integer(n) -> n
        n when is_binary(n) -> parse_price_or(n, default)
        _ -> default
      end

    %{"description" => desc, "price_cents" => price}
  end

  defp parse_price_or(s, fallback) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> fallback
    end
  end
end
