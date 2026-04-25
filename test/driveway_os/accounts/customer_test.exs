defmodule DrivewayOS.Accounts.CustomerTest do
  @moduledoc """
  V1 Slice 2A: tenant-scoped Customer with password auth.

  Cross-tenant isolation is the load-bearing invariant of this slice.
  Tests verify both the positive case (same email on two tenants =
  two independent customers) and the negative cases (queries without
  `tenant:` raise; reading tenant A's customers from tenant B's
  context returns nothing).

  OAuth providers (Google, Apple, Facebook) come in Slice 2C; this
  slice is password-only.
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

  describe "multitenancy invariants" do
    test "Ash.read! without set_tenant raises" do
      assert_raise Ash.Error.Invalid, fn ->
        Customer |> Ash.read!()
      end
    end

    test "registering without tenant raises" do
      assert_raise Ash.Error.Invalid, fn ->
        Customer
        |> Ash.Changeset.for_create(:register_with_password, %{
          email: "no-tenant@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "No Tenant"
        })
        |> Ash.create!(authorize?: false)
      end
    end
  end

  describe "register_with_password (tenant-scoped)" do
    test "creates a Customer attached to the given tenant", %{tenant_a: tenant} do
      {:ok, customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "alice-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Alice"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      assert customer.id
      assert customer.tenant_id == tenant.id
      assert customer.name == "Alice"
      assert customer.role == :customer
      assert customer.hashed_password
    end

    test "rejects passwords < 10 chars", %{tenant_a: tenant} do
      assert {:error, %Ash.Error.Invalid{}} =
               Customer
               |> Ash.Changeset.for_create(
                 :register_with_password,
                 %{
                   email: "weak-#{System.unique_integer([:positive])}@example.com",
                   password: "short1!",
                   password_confirmation: "short1!",
                   name: "Weak"
                 },
                 tenant: tenant.id
               )
               |> Ash.create(authorize?: false)
    end

    test "rejects passwords missing complexity", %{tenant_a: tenant} do
      # Missing uppercase
      assert {:error, %Ash.Error.Invalid{}} =
               Customer
               |> Ash.Changeset.for_create(
                 :register_with_password,
                 %{
                   email: "nocaps-#{System.unique_integer([:positive])}@example.com",
                   password: "lowercase123!",
                   password_confirmation: "lowercase123!",
                   name: "No Caps"
                 },
                 tenant: tenant.id
               )
               |> Ash.create(authorize?: false)
    end

    test "rejects malformed emails", %{tenant_a: tenant} do
      assert {:error, %Ash.Error.Invalid{}} =
               Customer
               |> Ash.Changeset.for_create(
                 :register_with_password,
                 %{
                   email: "not-an-email",
                   password: "Password123!",
                   password_confirmation: "Password123!",
                   name: "Bad Email"
                 },
                 tenant: tenant.id
               )
               |> Ash.create(authorize?: false)
    end
  end

  describe "cross-tenant email uniqueness" do
    test "same email is unique WITHIN a tenant", %{tenant_a: tenant} do
      email = "samename-#{System.unique_integer([:positive])}@example.com"

      {:ok, _first} = register!(tenant, email)

      assert {:error, %Ash.Error.Invalid{}} = register!(tenant, email)
    end

    test "same email CAN register on two different tenants",
         %{tenant_a: a, tenant_b: b} do
      email = "shared-#{System.unique_integer([:positive])}@example.com"

      {:ok, on_a} = register!(a, email)
      {:ok, on_b} = register!(b, email)

      assert on_a.id != on_b.id
      assert on_a.tenant_id == a.id
      assert on_b.tenant_id == b.id
    end
  end

  describe "cross-tenant read isolation" do
    test "reading customers in tenant A's context returns only tenant A's rows",
         %{tenant_a: a, tenant_b: b} do
      {:ok, on_a} = register!(a, "iso-a-#{System.unique_integer([:positive])}@example.com")

      {:ok, _on_b} =
        register!(b, "iso-b-#{System.unique_integer([:positive])}@example.com")

      {:ok, a_rows} =
        Customer
        |> Ash.Query.set_tenant(a.id)
        |> Ash.read(authorize?: false)

      ids = Enum.map(a_rows, & &1.id)
      assert on_a.id in ids
      assert length(a_rows) == 1
    end

    test "reading customers in tenant B's context cannot see tenant A's rows",
         %{tenant_a: a, tenant_b: b} do
      {:ok, on_a} =
        register!(a, "leak-a-#{System.unique_integer([:positive])}@example.com")

      {:ok, b_rows} =
        Customer
        |> Ash.Query.set_tenant(b.id)
        |> Ash.read(authorize?: false)

      refute on_a.id in Enum.map(b_rows, & &1.id)
    end
  end

  describe "sign_in_with_password" do
    test "succeeds with correct credentials in the right tenant",
         %{tenant_a: tenant} do
      email = "signin-#{System.unique_integer([:positive])}@example.com"
      {:ok, _customer} = register!(tenant, email)

      {:ok, [signed_in]} =
        Customer
        |> Ash.Query.for_read(
          :sign_in_with_password,
          %{email: email, password: "Password123!"},
          tenant: tenant.id
        )
        |> Ash.read(authorize?: false)

      assert signed_in.tenant_id == tenant.id
      assert to_string(signed_in.email) == email
    end

    test "fails with wrong password", %{tenant_a: tenant} do
      email = "signin-bad-#{System.unique_integer([:positive])}@example.com"
      {:ok, _customer} = register!(tenant, email)

      assert {:error, _} =
               Customer
               |> Ash.Query.for_read(
                 :sign_in_with_password,
                 %{email: email, password: "WrongPassword!"},
                 tenant: tenant.id
               )
               |> Ash.read(authorize?: false)
    end

    test "fails when sign-in is attempted in the wrong tenant",
         %{tenant_a: a, tenant_b: b} do
      email = "wrong-tenant-#{System.unique_integer([:positive])}@example.com"
      {:ok, _customer} = register!(a, email)

      # Customer registered on A. Trying to sign in via tenant B's
      # context must fail — this is the headline cross-tenant invariant.
      assert {:error, _} =
               Customer
               |> Ash.Query.for_read(
                 :sign_in_with_password,
                 %{email: email, password: "Password123!"},
                 tenant: b.id
               )
               |> Ash.read(authorize?: false)
    end
  end

  defp register!(tenant, email) do
    Customer
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: email,
        password: "Password123!",
        password_confirmation: "Password123!",
        name: "Test #{email}"
      },
      tenant: tenant.id
    )
    |> Ash.create(authorize?: false)
  end

  defp create_tenant!(name) do
    Tenant
    |> Ash.Changeset.for_create(:create, %{
      slug: "cust-test-#{System.unique_integer([:positive])}",
      display_name: name
    })
    |> Ash.create(authorize?: false)
  end
end
