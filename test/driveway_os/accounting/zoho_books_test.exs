defmodule DrivewayOS.Accounting.ZohoBooksTest do
  @moduledoc """
  Provider behaviour conformance + happy/error paths for each
  callback. HTTP is Mox-stubbed via `ZohoClient.Mock`. Tests pass a
  pre-built AccountingConnection struct (no DB, no provision_tenant)
  to keep the surface fast — the provider doesn't care where the
  connection came from.
  """
  use ExUnit.Case, async: true

  import Mox

  alias DrivewayOS.Accounting.ZohoBooks
  alias DrivewayOS.Accounting.ZohoClient
  alias DrivewayOS.Platform.AccountingConnection

  setup :verify_on_exit!

  defp connection do
    %AccountingConnection{
      tenant_id: "tenant-1",
      provider: :zoho_books,
      external_org_id: "org-99",
      access_token: "at-1",
      refresh_token: "rt-1",
      access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      region: "com"
    }
  end

  describe "create_contact/2" do
    test "happy path returns the new contact map" do
      conn = connection()

      expect(ZohoClient.Mock, :api_post, fn at, org, path, body ->
        assert at == "at-1"
        assert org == "org-99"
        assert path == "/contacts"
        assert body["contact_name"] == "Pat Customer"
        assert body["email"] == "pat@example.com"
        assert body["contact_type"] == "customer"
        {:ok, %{"contact" => %{"contact_id" => "c-1", "contact_name" => "Pat Customer"}}}
      end)

      assert {:ok, %{"contact_id" => "c-1"}} =
               ZohoBooks.create_contact(conn, %{
                 name: "Pat Customer",
                 email: "pat@example.com",
                 phone: "555-0100"
               })
    end

    test "error path propagates the http error" do
      conn = connection()

      expect(ZohoClient.Mock, :api_post, fn _, _, _, _ ->
        {:error, %{status: 422, body: %{"message" => "duplicate"}}}
      end)

      assert {:error, %{status: 422}} =
               ZohoBooks.create_contact(conn, %{name: "X", email: "x@y", phone: nil})
    end
  end

  describe "find_contact_by_email/2" do
    test "returns the first contact when one or more match" do
      conn = connection()

      expect(ZohoClient.Mock, :api_get, fn _at, _org, "/contacts", params ->
        assert params[:email] == "pat@example.com"
        {:ok, %{"contacts" => [%{"contact_id" => "c-1"}, %{"contact_id" => "c-2"}]}}
      end)

      assert {:ok, %{"contact_id" => "c-1"}} =
               ZohoBooks.find_contact_by_email(conn, "pat@example.com")
    end

    test "returns :not_found when contacts list is empty" do
      conn = connection()

      expect(ZohoClient.Mock, :api_get, fn _, _, _, _ ->
        {:ok, %{"contacts" => []}}
      end)

      assert {:error, :not_found} =
               ZohoBooks.find_contact_by_email(conn, "nope@example.com")
    end
  end

  describe "create_invoice/2" do
    test "shapes the request body and returns the invoice map" do
      conn = connection()

      expect(ZohoClient.Mock, :api_post, fn _at, _org, "/invoices", body ->
        assert body["customer_id"] == "c-1"
        assert [item] = body["line_items"]
        assert item["name"] == "Basic Wash"
        assert item["rate"] == 50.0
        assert body["notes"] =~ "Thank you"
        assert body["reference_number"] == "pi_123"
        {:ok, %{"invoice" => %{"invoice_id" => "inv-1"}}}
      end)

      assert {:ok, %{"invoice_id" => "inv-1"}} =
               ZohoBooks.create_invoice(conn, %{
                 contact_id: "c-1",
                 line_items: [%{name: "Basic Wash", amount_cents: 5000, quantity: 1}],
                 payment_id: "pi_123",
                 notes: "Acme Wash — Thank you for your business!"
               })
    end
  end

  describe "record_payment/3" do
    test "ISO8601-encodes the date and posts to the invoice's payments path" do
      conn = connection()

      expect(ZohoClient.Mock, :api_post, fn _at, _org, path, body ->
        assert path == "/invoices/inv-1/payments"
        assert body["amount"] == 50.0
        assert body["date"] == "2026-05-02"
        assert body["payment_mode"] == "creditcard"
        assert body["reference_number"] == "pi_123"
        {:ok, %{"payment" => %{"payment_id" => "pay-1"}}}
      end)

      assert {:ok, %{"payment_id" => "pay-1"}} =
               ZohoBooks.record_payment(conn, "inv-1", %{
                 amount_cents: 5000,
                 payment_date: ~D[2026-05-02],
                 reference: "pi_123"
               })
    end
  end

  describe "get_invoice/2" do
    test "fetches and unwraps the invoice envelope" do
      conn = connection()

      expect(ZohoClient.Mock, :api_get, fn _, _, "/invoices/inv-1", _ ->
        {:ok, %{"invoice" => %{"invoice_id" => "inv-1", "status" => "paid"}}}
      end)

      assert {:ok, %{"status" => "paid"}} = ZohoBooks.get_invoice(conn, "inv-1")
    end
  end
end
