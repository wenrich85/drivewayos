defmodule DrivewayOS.Accounts.Changes.SetCustomerFromOAuth do
  @moduledoc """
  Maps an OAuth provider's `user_info` map onto Customer attributes.

  Each provider returns a slightly different shape:

      Google:    %{"email" => "...", "name" => "First Last", "picture" => "...", "sub" => "..."}
      Facebook:  %{"email" => "...", "name" => "First Last", "id" => "..."}
      Apple:     %{"email" => "...", "name" => %{"firstName" => "...", "lastName" => "..."}, "sub" => "..."}
                 (and on subsequent sign-ins, "name" may be missing entirely — Apple only sends
                  it on the first authorization. Fall back to the email local-part.)

  All three normalize through this single change so the register
  actions stay declarative.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    user_info = Ash.Changeset.get_argument(changeset, :user_info) || %{}

    email = Map.get(user_info, "email")
    name = extract_name(user_info, email)

    changeset
    |> Ash.Changeset.change_attribute(:email, email)
    |> Ash.Changeset.change_attribute(:name, name)
  end

  defp extract_name(%{"name" => %{"firstName" => first, "lastName" => last}}, _email)
       when is_binary(first) and is_binary(last) do
    String.trim("#{first} #{last}")
  end

  defp extract_name(%{"name" => name}, _email) when is_binary(name) and name != "", do: name

  defp extract_name(_user_info, email) when is_binary(email) do
    # Last resort — Apple sometimes returns no `name` on second-and-later
    # sign-ins. Use the email's local part as a placeholder so the row
    # is creatable; the customer can edit it later.
    email
    |> String.split("@", parts: 2)
    |> hd()
  end

  defp extract_name(_, _), do: "Customer"
end
