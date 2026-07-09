defmodule NathanForUs.AdminServiceSimpleTest do
  use ExUnit.Case, async: true

  alias NathanForUs.AdminService

  describe "validate_admin_access/1" do
    test "allows admin users" do
      assert :ok = AdminService.validate_admin_access(%{is_admin: true})
    end

    test "denies non-admin users" do
      assert {:error, :access_denied} = AdminService.validate_admin_access(%{is_admin: false})
    end

    test "denies nil user" do
      assert {:error, :access_denied} = AdminService.validate_admin_access(nil)
    end
  end
end
