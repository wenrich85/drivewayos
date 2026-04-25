defmodule DrivewayOS.Platform.PlatformUser do
  @moduledoc """
  DrivewayOS operator / support-staff user. Signs in at
  `admin.drivewayos.com` with email + password (small population, no
  social-auth needed — that's for end customers in `Accounts.Customer`
  later).

  Lives at the platform tier — does NOT belong to a tenant. Adding
  PlatformUser as a `Customer.role` would force `Customer.tenant_id`
  nullable, which breaks the multitenancy invariant.

  Roles:

      :owner      — full platform access (you)
      :support    — impersonate tenants, read-only metrics; default
      :read_only  — observability only
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication]

  require Ash.Query

  @type t :: %__MODULE__{}

  postgres do
    table "platform_users"
    repo DrivewayOS.Repo
  end

  authentication do
    tokens do
      enabled? true
      token_resource DrivewayOS.Platform.PlatformToken
      require_token_presence_for_authentication? true
      token_lifetime {7, :days}

      signing_secret fn _, _ ->
        Application.fetch_env(:driveway_os, :platform_token_signing_secret)
      end
    end

    strategies do
      password :password do
        identity_field :email
        hashed_password_field :hashed_password

        register_action_accept [:name]
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    attribute :role, :atom do
      constraints one_of: [:owner, :support, :read_only]
      default :support
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? true
      sensitive? true
    end

    attribute :email_verified_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_email, [:email]
  end

  validations do
    # Password complexity — same rules will land on Customer in the
    # auth slice.
    validate(
      fn changeset, _ctx ->
        case Ash.Changeset.get_argument(changeset, :password) do
          nil ->
            :ok

          password when is_binary(password) ->
            cond do
              String.length(password) < 10 ->
                {:error, field: :password, message: "must be at least 10 characters"}

              not String.match?(password, ~r/[A-Z]/) ->
                {:error, field: :password, message: "must contain at least one uppercase letter"}

              not String.match?(password, ~r/[a-z]/) ->
                {:error, field: :password, message: "must contain at least one lowercase letter"}

              not String.match?(password, ~r/[0-9]/) ->
                {:error, field: :password, message: "must contain at least one number"}

              true ->
                :ok
            end

          _ ->
            :ok
        end
      end,
      on: [:create]
    )

    # Reject obvious email garbage. Permissive, just enough to catch
    # input like "haha" or "@example.com" before AshAuthentication
    # tries to send mail to it.
    validate fn changeset, _ctx ->
      case Ash.Changeset.get_attribute(changeset, :email) do
        nil -> :ok
        %Ash.CiString{} = ci -> validate_email_format(to_string(ci))
        email when is_binary(email) -> validate_email_format(email)
        _ -> :ok
      end
    end
  end

  actions do
    defaults [:read, update: :*]
  end

  defp validate_email_format(email) do
    if String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) do
      :ok
    else
      {:error, field: :email, message: "must be a valid email address"}
    end
  end
end
