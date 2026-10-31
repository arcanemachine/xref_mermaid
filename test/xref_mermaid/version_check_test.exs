defmodule XrefMermaid.VersionCheckTest do
  # These tests change an environment variable.
  use ExUnit.Case, async: false

  alias XrefMermaid.VersionCheck

  test "stays silent when the check is off or the commit is unknown" do
    System.delete_env("XREF_MERMAID_VERSION_CHECK")
    assert VersionCheck.warnings("0000000000000000000000000000000000000000") == []

    System.put_env("XREF_MERMAID_VERSION_CHECK", "1")
    on_exit(fn -> System.delete_env("XREF_MERMAID_VERSION_CHECK") end)
    assert VersionCheck.warnings(nil) == []
  end
end
