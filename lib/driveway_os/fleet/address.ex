defmodule DrivewayOS.Fleet.Address do
  @moduledoc """
  Customer service address (where the wash happens). Tenant-scoped.

  On insert, the `:add` action calls
  `DrivewayOS.Fleet.Geocoder.lookup/1` with the zip; the default
  stub returns nil/nil so the row saves cleanly even before a real
  geocoding provider is configured. Phase B's route optimizer
  uses lat/lon when present.

  Like `Vehicle`, the `:add` action validates that `customer_id`
  belongs to the current tenant — defense in depth.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Fleet,
    data_layer: AshPostgres.DataLayer

  @type t :: %__MODULE__{}

  postgres do
    table "addresses"
    repo DrivewayOS.Repo

    references do
      reference :customer, on_delete: :delete
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

    attribute :street_line1, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :street_line2, :string do
      public? true
      constraints max_length: 120
    end

    attribute :city, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 60
    end

    attribute :state, :string do
      allow_nil? false
      public? true
      # US state codes — exactly 2 letters.
      constraints match: ~r/^[A-Z]{2}$/i, min_length: 2, max_length: 2
    end

    attribute :zip, :string do
      allow_nil? false
      public? true
      # 5-digit US zip; ZIP+4 (12345-6789) also accepted.
      constraints match: ~r/^\d{5}(-\d{4})?$/, min_length: 5, max_length: 10
    end

    attribute :lat, :float, public?: true
    attribute :lon, :float, public?: true

    attribute :nickname, :string do
      public? true
      constraints max_length: 60
    end

    attribute :instructions, :string do
      public? true
      constraints max_length: 500
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :customer, DrivewayOS.Accounts.Customer do
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]

    create :add do
      primary? true

      accept [
        :customer_id,
        :street_line1,
        :street_line2,
        :city,
        :state,
        :zip,
        :nickname,
        :instructions
      ]

      change fn changeset, _ ->
        # Normalize state to uppercase before persisting.
        case Ash.Changeset.get_attribute(changeset, :state) do
          state when is_binary(state) ->
            Ash.Changeset.force_change_attribute(changeset, :state, String.upcase(state))

          _ ->
            changeset
        end
      end

      change fn changeset, _ ->
        # Cross-tenant FK guard.
        case Ash.Changeset.get_attribute(changeset, :customer_id) do
          nil ->
            changeset

          customer_id ->
            tenant = changeset.tenant

            case Ash.get(DrivewayOS.Accounts.Customer, customer_id,
                   tenant: tenant,
                   authorize?: false
                 ) do
              {:ok, _} ->
                changeset

              _ ->
                Ash.Changeset.add_error(changeset,
                  field: :customer_id,
                  message: "must belong to the current tenant"
                )
            end
        end
      end

      change fn changeset, _ ->
        # Geocode by zip. Stub provider returns nil/nil → row saves
        # cleanly. Real provider lights up via app config in prod.
        case Ash.Changeset.get_attribute(changeset, :zip) do
          zip when is_binary(zip) ->
            case DrivewayOS.Fleet.Geocoder.lookup(zip) do
              {:ok, %{lat: lat, lon: lon}} ->
                changeset
                |> Ash.Changeset.force_change_attribute(:lat, lat)
                |> Ash.Changeset.force_change_attribute(:lon, lon)

              _ ->
                changeset
            end

          _ ->
            changeset
        end
      end
    end

    update :update do
      primary? true

      accept [
        :street_line1,
        :street_line2,
        :city,
        :state,
        :zip,
        :nickname,
        :instructions
      ]
    end

    read :for_customer do
      argument :customer_id, :uuid, allow_nil?: false
      filter expr(customer_id == ^arg(:customer_id))
      prepare build(sort: [inserted_at: :desc])
    end
  end

  @doc """
  Single-line "123 Cedar St Apt 4B, San Antonio TX 78261" rendering
  for select boxes + appointment snapshots. Prepends a nickname
  with " — " when present.
  """
  @spec display_label(t()) :: String.t()
  def display_label(%{nickname: n} = a) when is_binary(n) and n != "",
    do: "#{n} — #{base_label(a)}"

  def display_label(a), do: base_label(a)

  defp base_label(%{
         street_line1: s1,
         street_line2: s2,
         city: city,
         state: state,
         zip: zip
       }) do
    street = if s2 in [nil, ""], do: s1, else: "#{s1} #{s2}"
    "#{street}, #{city} #{state} #{zip}"
  end
end
