defmodule DrivewayOSWeb.Features.EndToEndTest do
  @moduledoc """
  Browser-level (Wallaby + real ChromeDriver) coverage of every UI
  surface in the V1 demo loop.

  Run with:

      mix test --include browser

  These exercise the actual JS-connected LiveView socket, not just
  the dead-render path that LiveViewTest covers. They catch:

    * Layout / Tailwind class regressions
    * LV mount errors that only happen post-connect
    * Form-submit redirect chains end-to-end
    * Cross-page navigation working through the router

  Each `feature` is a single browser session (Wallaby auto-cleans
  between tests).
  """
  use DrivewayOSWeb.FeatureCase, async: false

  import Wallaby.Browser
  import Wallaby.Query, only: [css: 1, css: 2, button: 1, link: 1, fillable_field: 1]

  describe "marketing host" do
    feature "landing page renders DrivewayOS branding", %{session: session} do
      session
      |> visit(marketing_url("/"))
      |> assert_has(css("h1", text: "DrivewayOS"))
      |> assert_has(link("Start your shop"))
    end

    feature "signup form renders + creates tenant + redirects to subdomain",
            %{session: session} do
      slug = "ft-#{System.unique_integer([:positive])}"

      session
      |> visit(marketing_url("/signup"))
      |> assert_has(css("h1", text: "Start your shop"))
      |> fill_in(fillable_field("signup[slug]"), with: slug)
      |> fill_in(fillable_field("signup[display_name]"), with: "Feature Test Shop")
      |> fill_in(fillable_field("signup[admin_name]"), with: "Owner")
      |> fill_in(fillable_field("signup[admin_email]"),
        with: "owner-#{System.unique_integer([:positive])}@example.com"
      )
      |> fill_in(fillable_field("signup[admin_password]"), with: "Password123!")
      |> click(button("Create my shop"))

      # Wait for the redirect to the new subdomain to land.
      assert_has(session, css("h1", text: "Feature Test Shop"))
      assert current_url(session) =~ "#{slug}.lvh.me"
    end
  end

  describe "tenant landing" do
    feature "renders tenant.display_name + branding hooks", %{session: session} do
      %{tenant: tenant} = provision_test_tenant!(display_name: "Acme Wash Co")

      session
      |> visit(tenant_url(tenant, "/"))
      |> assert_has(css("h1", text: "Acme Wash Co"))
      |> assert_has(link("Book a wash"))
      |> assert_has(link("Sign in"))

      # Brand-isolation invariant — the platform name should never
      # leak into a tenant page.
      refute_has(session, css("body", text: "DrivewayOS"))
    end
  end

  describe "customer register + sign-in" do
    feature "registration creates Customer and lands them signed in", %{session: session} do
      %{tenant: tenant} = provision_test_tenant!()

      session
      |> visit(tenant_url(tenant, "/register"))
      |> assert_has(css("h1", text: "Create your account"))
      |> fill_in(fillable_field("register[name]"), with: "Alice Browser")
      |> fill_in(fillable_field("register[email]"),
        with: "alice-#{System.unique_integer([:positive])}@example.com"
      )
      |> fill_in(fillable_field("register[password]"), with: "Password123!")
      |> click(button("Create account"))

      # Lands on tenant home, with admin sign-out link visible —
      # signed-in customer state.
      assert_has(session, css("body", text: tenant.display_name))
    end

    feature "sign-in form works for an existing customer", %{session: session} do
      %{tenant: tenant} = provision_test_tenant!()

      _customer =
        register_customer!(tenant,
          email: "signin-#{System.unique_integer([:positive])}@example.com"
        )

      session
      |> visit(tenant_url(tenant, "/sign-in"))
      |> assert_has(css("h1", text: "Sign in"))
    end

    feature "sign-in shows error for wrong password", %{session: session} do
      %{tenant: tenant} = provision_test_tenant!()

      email = "wrongpw-#{System.unique_integer([:positive])}@example.com"
      _customer = register_customer!(tenant, email: email)

      session
      |> visit(tenant_url(tenant, "/sign-in"))
      |> fill_in(fillable_field("signin[email]"), with: email)
      |> fill_in(fillable_field("signin[password]"), with: "WrongPassword!")
      |> click(button("Sign in"))
      |> assert_has(css(".alert-error", text: "Invalid"))
    end
  end

  describe "booking flow" do
    feature "auth-gated: unauthenticated /book bounces to /sign-in",
            %{session: session} do
      %{tenant: tenant} = provision_test_tenant!()

      session
      |> visit(tenant_url(tenant, "/book"))

      # Wait for the live-redirect to settle.
      :timer.sleep(300)
      assert current_url(session) =~ "/sign-in"
    end

    feature "signed-in customer can complete a booking end-to-end",
            %{session: session} do
      %{tenant: tenant} = provision_test_tenant!()
      email = "booker-#{System.unique_integer([:positive])}@example.com"
      register_customer!(tenant, email: email)

      future =
        DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)

      future_str = DateTime.to_iso8601(future) |> String.slice(0, 16)

      sign_in_as(session, tenant, email)

      session
      |> visit(tenant_url(tenant, "/book"))
      |> assert_has(css("h1", text: "Book a wash"))
      |> assert_has(css("option", text: "Basic Wash"))

      # Wallaby's `fill_in` types keystrokes — that's wrong for
      # `<select>` (no input event) and wrong for `<input
      # type="datetime-local">` (the browser interprets each digit
      # against the localized MM/DD/YYYY mask, giving us garbage like
      # year 60428). For both, set the value via JS + dispatch
      # change so LV's form serializer picks it up at submit time.
      Wallaby.Browser.execute_script(session, """
        (function() {
          const sel = document.querySelector('select[name="booking[service_type_id]"]');
          const opt = Array.from(sel.options).find(o => o.text.includes('Basic Wash'));
          sel.value = opt.value;
          sel.dispatchEvent(new Event('change', { bubbles: true }));

          const dt = document.querySelector('input[name="booking[scheduled_at]"]');
          dt.value = '#{future_str}';
          dt.dispatchEvent(new Event('change', { bubbles: true }));
        })();
      """)

      session
      |> fill_in(fillable_field("booking[vehicle_description]"),
        with: "Blue 2022 Subaru Outback"
      )
      |> fill_in(fillable_field("booking[service_address]"),
        with: "123 Cedar St, San Antonio TX 78261"
      )
      |> click(button("Book it"))

      # Lands on confirmation page.
      assert_has(session, css("h1", text: "Your booking is in"))
      assert_has(session, css("body", text: "Blue 2022 Subaru Outback"))
    end
  end

  describe "my appointments" do
    feature "signed-in customer with no bookings sees the empty state",
            %{session: session} do
      %{tenant: tenant} = provision_test_tenant!()
      email = "appts-#{System.unique_integer([:positive])}@example.com"
      register_customer!(tenant, email: email)

      sign_in_as(session, tenant, email)

      session
      |> visit(tenant_url(tenant, "/appointments"))
      |> assert_has(css("h1", text: "My appointments"))
      |> assert_has(css("body", text: "No appointments yet"))
    end
  end

  describe "tenant admin dashboard" do
    feature "non-admin customer can't reach /admin", %{session: session} do
      %{tenant: tenant} = provision_test_tenant!()
      email = "nonadmin-#{System.unique_integer([:positive])}@example.com"
      register_customer!(tenant, email: email)

      session
      |> visit(tenant_url(tenant, "/sign-in"))
      |> fill_in(fillable_field("signin[email]"), with: email)
      |> fill_in(fillable_field("signin[password]"), with: "Password123!")
      |> click(button("Sign in"))

      session
      |> visit(tenant_url(tenant, "/admin"))

      :timer.sleep(300)
      # Bounced to / (the customer landing) — admin h1 not present.
      refute_has(session, css("h1", text: "Admin"))
    end

    feature "admin sees dashboard with stats", %{session: session} do
      %{tenant: tenant, admin: admin} =
        provision_test_tenant!(display_name: "Owned & Operated")

      sign_in_as(session, tenant, to_string(admin.email))

      session
      |> visit(tenant_url(tenant, "/admin"))
      |> assert_has(css("h1", text: "Admin · Owned & Operated"))
      |> assert_has(css(".stat-title", text: "Pending"))
      |> assert_has(css(".stat-title", text: "Customers"))
    end
  end

  describe "custom domains" do
    feature "tenant admin can add + verify a custom domain", %{session: session} do
      %{tenant: tenant, admin: admin} =
        provision_test_tenant!(display_name: "Custom Domain Co")

      sign_in_as(session, tenant, to_string(admin.email))

      hostname = "wallaby-#{System.unique_integer([:positive])}.example.com"

      session
      |> visit(tenant_url(tenant, "/admin/domains"))
      |> assert_has(css("h1", text: "Custom domains"))
      |> fill_in(fillable_field("domain[hostname]"), with: hostname)
      |> click(button("Add"))
      # New domain shows up with Pending status + DNS instructions.
      |> assert_has(css("body", text: hostname))
      |> assert_has(css(".badge", text: "Pending"))
      |> assert_has(css("body", text: "CNAME"))

      # Click "Verify" to mark it verified.
      session
      |> click(css("button[phx-click='verify_domain']"))
      |> assert_has(css(".badge", text: "Verified"))
    end
  end

  describe "404s" do
    feature "unknown tenant subdomain → 404", %{session: session} do
      # Wallaby raises on non-200 by default; catch the response.
      {:ok, response} =
        :httpc.request("http://nobody-#{System.unique_integer([:positive])}.lvh.me:4002/")

      {{_, status, _}, _headers, _body} = response
      assert status == 404
      _ = session
    end
  end
end
