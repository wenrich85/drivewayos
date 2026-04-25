defmodule DrivewayOS.Accounts.CustomerOAuthTest do
  @moduledoc """
  V1 Slice 2C: OAuth registration actions.

  AshAuthentication's HTTP callback handler eventually calls a
  `:register_with_<provider>` action with `user_info` and
  `oauth_tokens` arguments. These tests exercise that action layer
  directly with synthetic user_info — they prove our register logic
  + multi-tenancy + upsert-on-email behavior, without needing real
  OAuth credentials.

  The `assent` callback layer (HTTP redirect → token exchange → user
  info fetch) only works with real provider credentials and is tested
  manually once the operator sets each provider up.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant

  require Ash.Query

  setup do
    {:ok, tenant_a} = create_tenant!("Tenant A")
    {:ok, tenant_b} = create_tenant!("Tenant B")
    %{tenant_a: tenant_a, tenant_b: tenant_b}
  end

  describe "register_with_google" do
    test "creates a Customer from Google user_info, scoped to tenant",
         %{tenant_a: tenant} do
      user_info = google_user_info("alice@gmail.com", "Alice Carter")

      {:ok, customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{user_info: user_info, oauth_tokens: %{}},
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      assert customer.tenant_id == tenant.id
      assert to_string(customer.email) == "alice@gmail.com"
      assert customer.name == "Alice Carter"
      # OAuth-only registrations have no password.
      assert is_nil(customer.hashed_password)
    end

    test "upserts on (tenant_id, email) — same Google user clicks twice",
         %{tenant_a: tenant} do
      user_info = google_user_info("repeat@gmail.com", "Repeat Customer")

      {:ok, _first} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{user_info: user_info, oauth_tokens: %{}},
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, second} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{user_info: user_info, oauth_tokens: %{}},
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      # Upsert returns the existing row.
      {:ok, all} =
        Customer
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.Query.filter(email == ^Ash.CiString.new("repeat@gmail.com"))
        |> Ash.read(authorize?: false)

      assert length(all) == 1
      assert hd(all).id == second.id
    end

    test "same Google email creates SEPARATE Customers across tenants",
         %{tenant_a: a, tenant_b: b} do
      user_info = google_user_info("shared@gmail.com", "Shared Identity")

      {:ok, on_a} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{user_info: user_info, oauth_tokens: %{}},
          tenant: a.id
        )
        |> Ash.create(authorize?: false)

      {:ok, on_b} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{user_info: user_info, oauth_tokens: %{}},
          tenant: b.id
        )
        |> Ash.create(authorize?: false)

      assert on_a.id != on_b.id
      assert on_a.tenant_id == a.id
      assert on_b.tenant_id == b.id
    end
  end

  describe "register_with_facebook" do
    test "creates a Customer from Facebook user_info", %{tenant_a: tenant} do
      user_info = %{
        "email" => "bob@fb.com",
        "name" => "Bob Brown",
        "id" => "fb_user_12345"
      }

      {:ok, customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_facebook,
          %{user_info: user_info, oauth_tokens: %{}},
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      assert customer.tenant_id == tenant.id
      assert to_string(customer.email) == "bob@fb.com"
      assert customer.name == "Bob Brown"
    end
  end

  describe "register_with_apple" do
    test "creates a Customer from Apple user_info", %{tenant_a: tenant} do
      user_info = %{
        "email" => "charlie@icloud.com",
        "name" => %{"firstName" => "Charlie", "lastName" => "Stone"},
        "sub" => "001234.abcdef.0123"
      }

      {:ok, customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_apple,
          %{user_info: user_info, oauth_tokens: %{}},
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      assert customer.tenant_id == tenant.id
      assert to_string(customer.email) == "charlie@icloud.com"
      assert customer.name == "Charlie Stone"
    end

    test "Apple may omit name on subsequent sign-ins; falls back to email local-part",
         %{tenant_a: tenant} do
      # On the second-and-later Apple sign-in for the same user, Apple
      # only sends `email` and `sub` — no `name`. We have to handle
      # that case without crashing.
      user_info = %{"email" => "noname@icloud.com", "sub" => "00abc.def.456"}

      {:ok, customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_apple,
          %{user_info: user_info, oauth_tokens: %{}},
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      assert customer.name == "noname"
    end
  end

  describe "OAuth + password coexistence" do
    test "registering via password then signing in via Google with the same email upserts",
         %{tenant_a: tenant} do
      email = "switcher@example.com"

      {:ok, password_customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: email,
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Switcher"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      assert password_customer.hashed_password

      # Now sign in via Google with the same email.
      user_info = google_user_info(email, "Switcher")

      {:ok, google_customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_google,
          %{user_info: user_info, oauth_tokens: %{}},
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      # Same row.
      assert google_customer.id == password_customer.id

      # Reload and confirm hashed_password is preserved (upsert_fields
      # on the OAuth action is empty, so the existing fields don't
      # get clobbered).
      {:ok, reloaded} =
        Ash.get(Customer, google_customer.id, tenant: tenant.id, authorize?: false)

      assert reloaded.hashed_password == password_customer.hashed_password
    end
  end

  # --- Helpers ---

  defp google_user_info(email, name) do
    %{
      "email" => email,
      "name" => name,
      "given_name" => String.split(name, " ") |> hd(),
      "family_name" => String.split(name, " ") |> List.last(),
      "picture" => "https://lh3.googleusercontent.com/a-/example",
      "sub" => "google_user_#{System.unique_integer([:positive])}"
    }
  end

  defp create_tenant!(name) do
    Tenant
    |> Ash.Changeset.for_create(:create, %{
      slug: "oauth-test-#{System.unique_integer([:positive])}",
      display_name: name
    })
    |> Ash.create(authorize?: false)
  end
end
