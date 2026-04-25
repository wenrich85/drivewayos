defmodule DrivewayOS.Platform.PlatformUserTest do
  @moduledoc """
  V1 Slice 1: PlatformUser — DrivewayOS operators (us / our staff).

  Separate from the tenant-scoped Customer resource that lands in a
  later slice. PlatformUsers don't belong to a tenant; they sign in
  at admin.drivewayos.com using a separate AshAuthentication setup
  with its own token resource + signing secret so that rotating one
  population's tokens doesn't invalidate the other.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform.PlatformUser

  require Ash.Query

  describe "register_with_password" do
    test "creates a platform user with email + hashed password" do
      {:ok, user} =
        PlatformUser
        |> Ash.Changeset.for_create(:register_with_password, %{
          email: "ops-#{System.unique_integer([:positive])}@drivewayos.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Ops Admin"
        })
        |> Ash.create(authorize?: false)

      assert user.id
      assert user.name == "Ops Admin"
      assert user.role == :support
      assert user.hashed_password
    end

    test "rejects duplicate email globally" do
      email = "dupe-ops-#{System.unique_integer([:positive])}@drivewayos.com"

      {:ok, _a} = register_user!(email: email, name: "First")

      assert {:error, %Ash.Error.Invalid{}} =
               PlatformUser
               |> Ash.Changeset.for_create(:register_with_password, %{
                 email: email,
                 password: "Password123!",
                 password_confirmation: "Password123!",
                 name: "Second"
               })
               |> Ash.create(authorize?: false)
    end

    test "rejects passwords < 10 chars" do
      assert {:error, %Ash.Error.Invalid{}} =
               PlatformUser
               |> Ash.Changeset.for_create(:register_with_password, %{
                 email: "weak-#{System.unique_integer([:positive])}@drivewayos.com",
                 password: "short1!",
                 password_confirmation: "short1!",
                 name: "Weak"
               })
               |> Ash.create(authorize?: false)
    end

    test "rejects malformed emails" do
      assert {:error, %Ash.Error.Invalid{}} =
               PlatformUser
               |> Ash.Changeset.for_create(:register_with_password, %{
                 email: "not-an-email",
                 password: "Password123!",
                 password_confirmation: "Password123!",
                 name: "Bad Email"
               })
               |> Ash.create(authorize?: false)
    end
  end

  describe "roles" do
    test "defaults to :support" do
      {:ok, user} = register_user!()
      assert user.role == :support
    end

    test "can be elevated to :owner" do
      {:ok, user} = register_user!()

      {:ok, owner} =
        user
        |> Ash.Changeset.for_update(:update, %{role: :owner})
        |> Ash.update(authorize?: false)

      assert owner.role == :owner
    end
  end

  defp register_user!(opts \\ []) do
    email =
      Keyword.get(opts, :email, "platform-#{System.unique_integer([:positive])}@drivewayos.com")

    name = Keyword.get(opts, :name, "Platform User")

    PlatformUser
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: email,
      password: "Password123!",
      password_confirmation: "Password123!",
      name: name
    })
    |> Ash.create(authorize?: false)
  end
end
