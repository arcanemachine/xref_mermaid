defmodule XrefMermaid.IntegrationTest do
  # Builds and installs the archive, then runs the task in the fixture project, each in its own `mix` process: the
  # way the task really runs (loaded from an archive, after Mix prunes the code path to compile the project).
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @root Path.expand("..", __DIR__)
  @fixture Path.join(@root, "test/fixtures/sample_app")

  setup %{tmp_dir: tmp_dir} do
    archive = Path.join(tmp_dir, "xref_mermaid.ez")
    env = [{"MIX_ENV", "dev"}, {"MIX_ARCHIVES", Path.join(tmp_dir, "archives")}]
    {_, 0} = mix(["archive.build", "-o", archive], @root, env)
    {_, 0} = mix(["archive.install", archive, "--force"], @root, env)
    %{env: [{"MIX_BUILD_PATH", Path.join(tmp_dir, "build")} | env], tmp_dir: tmp_dir}
  end

  defp mix(args, dir, env), do: System.cmd("mix", args, cd: dir, env: env, stderr_to_stdout: true)

  defp chart(args, %{env: env, tmp_dir: tmp_dir}) do
    output = Path.join(tmp_dir, "chart.mmd")
    {log, status} = mix(["xref.mermaid" | args] ++ ["-o", output], @fixture, env)
    assert status == 0, log
    {File.read!(output), log}
  end

  test "draws a path slice from the compiled fixture", context do
    {text, log} = chart(["lib/sample/orders.ex"], context)

    assert log =~ "Wrote "
    refute log =~ "warning:"
    refute log =~ "dot -T"

    for line <- [
          ~s(f_orders__place_1["place/1..2"]),
          ~s(f_orders__valid_q_1["valid?/1"]),
          ~s(f_orders__valid_b_1["valid!/1"]),
          ~s(f_orders______2["#lt;~#gt;/2"]),
          ~s(f_orders__total_1["total/1"]),
          ~s(f_orders__Line__describe_1["Line.describe/1"]),
          ~s(f_orders__impl_String_Chars__to_string_1["[impl String.Chars] to_string/1"]),
          "f_orders__place_1 --> f_repo__save_1",
          "f_orders__total_1 --> f_totals__total_1",
          "f_orders__paths_0 --> f_a_b__run_0",
          "f_orders__paths_0 --> f_a_b_2__run_0",
          "f_orders__label_1 --> f_orders__Line__describe_1",
          "f_orders -. export .-> f_receipt",
          "class f_orders__finish_2 private"
        ] do
      assert text =~ line
    end
  end

  test "follows calls from and to functions, through generated ones", context do
    {text, _log} =
      chart(
        ["--from", "Sample.Orders.place", "--to", "Sample.Totals.total/1", "--depth", "2"],
        context
      )

    assert text =~ "f_repo__save_1 --> f_repo__changeset_1"
    assert text =~ "f_repo__save_1 --> f_repo__insert_1"
    assert text =~ "class f_repo__changeset_1,f_repo__insert_1 generated"
    assert text =~ "f_orders__receipt_1 --> f_orders__total_1"
    assert text =~ "class f_orders__place_1,f_totals__total_1 start"
    refute text =~ "f_receipt"
  end

  test "draws an overview", context do
    {text, _log} = chart(["--overview", "--level", "3"], context)
    assert text =~ ~s(d_lib_sample__["lib/sample/*"])
    assert text =~ ~s(d_lib_sample_a_["lib/sample/a/"])
    assert text =~ "d_lib_sample__ -. runtime ×1 .-> d_lib_sample_a_"
  end

  test "names the closest functions for an unknown one", %{env: env} do
    {log, status} =
      mix(["xref.mermaid", "--from", "Sample.Orders.plcae/2", "-o", "x.mmd"], @fixture, env)

    assert status != 0
    assert log =~ "No function Sample.Orders.plcae/2"
    assert log =~ "Sample.Orders.place/1"
  end
end
