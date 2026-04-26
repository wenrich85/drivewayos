# Idempotent dev seeds — run with `mix run priv/repo/seeds.exs`
# (or `mix ecto.reset` to drop+migrate+seed in one step).
#
# Creates two demo tenants so you can test the multi-tenant flows
# end-to-end in your browser at lvh.me. Skips anything already
# present so re-running is safe.

require Ash.Query

alias DrivewayOS.Accounts.Customer
alias DrivewayOS.Platform
alias DrivewayOS.Platform.PlatformUser
alias DrivewayOS.Scheduling.BlockTemplate

password = "Password123!"

defmodule SeedHelpers do
  require Ash.Query

  def get_or_create_tenant(slug, attrs) do
    case Platform.get_tenant_by_slug(slug) do
      {:ok, tenant} ->
        IO.puts("  ✓ Tenant already exists: #{slug}")
        {:already_existed, tenant, nil}

      _ ->
        {:ok, %{tenant: tenant, admin: admin}} = Platform.provision_tenant(attrs)
        IO.puts("  ✓ Created tenant: #{slug}")
        {:created, tenant, admin}
    end
  end

  def get_or_create_customer(tenant, email, attrs) do
    existing =
      Customer
      |> Ash.Query.filter(email == ^email)
      |> Ash.Query.set_tenant(tenant.id)
      |> Ash.read(authorize?: false)

    case existing do
      {:ok, [c | _]} ->
        IO.puts("    ✓ Customer already exists: #{email}")
        c

      _ ->
        {:ok, c} =
          Customer
          |> Ash.Changeset.for_create(:register_with_password, attrs, tenant: tenant.id)
          |> Ash.create(authorize?: false)

        IO.puts("    ✓ Created customer: #{email}")
        c
    end
  end

  def get_or_create_platform_user(email, attrs) do
    require Ash.Query

    existing =
      PlatformUser
      |> Ash.Query.filter(email == ^email)
      |> Ash.read(authorize?: false)

    case existing do
      {:ok, [u | _]} ->
        IO.puts("  ✓ Platform user already exists: #{email}")
        u

      _ ->
        {:ok, u} =
          PlatformUser
          |> Ash.Changeset.for_create(:register_with_password, attrs)
          |> Ash.create(authorize?: false)

        IO.puts("  ✓ Created platform user: #{email}")
        u
    end
  end

  def add_block_templates(tenant) do
    {:ok, existing} =
      BlockTemplate
      |> Ash.Query.set_tenant(tenant.id)
      |> Ash.read(authorize?: false)

    if existing == [] do
      blocks = [
        %{name: "Mon mornings", day_of_week: 1, start_time: ~T[09:00:00],
          duration_minutes: 180, capacity: 2},
        %{name: "Wed mornings", day_of_week: 3, start_time: ~T[09:00:00],
          duration_minutes: 180, capacity: 2},
        %{name: "Sat all day", day_of_week: 6, start_time: ~T[08:00:00],
          duration_minutes: 480, capacity: 4}
      ]

      Enum.each(blocks, fn attrs ->
        BlockTemplate
        |> Ash.Changeset.for_create(:create, attrs, tenant: tenant.id)
        |> Ash.create!(authorize?: false)
      end)

      IO.puts("    ✓ Seeded #{length(blocks)} block templates")
    else
      IO.puts("    ✓ Block templates already present (#{length(existing)})")
    end
  end
end

IO.puts("\n=== DrivewayOS dev seeds ===\n")

# Tenant 1: Acme Wash Co
IO.puts("Tenant 1: acme-wash")

{_, tenant_a, _} =
  SeedHelpers.get_or_create_tenant("acme-wash", %{
    slug: "acme-wash",
    display_name: "Acme Wash Co",
    admin_email: "acme-admin@example.com",
    admin_name: "Anna Acme",
    admin_password: password,
    admin_phone: "+15125550100"
  })

SeedHelpers.get_or_create_customer(tenant_a, "alice@example.com", %{
  email: "alice@example.com",
  password: password,
  password_confirmation: password,
  name: "Alice Customer"
})

SeedHelpers.add_block_templates(tenant_a)

# Tenant 2: Bravo Detail Inc
IO.puts("\nTenant 2: bravo-detail")

{_, tenant_b, _} =
  SeedHelpers.get_or_create_tenant("bravo-detail", %{
    slug: "bravo-detail",
    display_name: "Bravo Detail Inc",
    admin_email: "bravo-admin@example.com",
    admin_name: "Bobby Bravo",
    admin_password: password,
    admin_phone: "+15125550200"
  })

SeedHelpers.get_or_create_customer(tenant_b, "bob@example.com", %{
  email: "bob@example.com",
  password: password,
  password_confirmation: password,
  name: "Bob Customer"
})

SeedHelpers.add_block_templates(tenant_b)

# Platform admin (you, the SaaS operator)
IO.puts("\nPlatform admin")

SeedHelpers.get_or_create_platform_user("operator@drivewayos.com", %{
  email: "operator@drivewayos.com",
  password: password,
  password_confirmation: password,
  name: "DrivewayOS Operator"
})

IO.puts("""

=== READY TO TEST ===

Marketing site (signup, etc.):
  http://lvh.me:4000          (or http://localhost:4000)

Tenant: Acme Wash Co
  http://acme-wash.lvh.me:4000
  Admin   : acme-admin@example.com / #{password}
  Customer: alice@example.com      / #{password}

Tenant: Bravo Detail Inc
  http://bravo-detail.lvh.me:4000
  Admin   : bravo-admin@example.com / #{password}
  Customer: bob@example.com        / #{password}

Platform admin (the SaaS operator):
  http://admin.lvh.me:4000
  operator@drivewayos.com / #{password}

Both tenants have block templates seeded (Mon/Wed mornings + Sat
all day) so the booking form will show concrete slots.

Sign in at  /sign-in  on each tenant subdomain.
Admin only: /admin, /admin/appointments, /admin/customers,
            /admin/services, /admin/schedule, /admin/domains
""")
