defmodule XrefMermaid.IntegrationTest do
  # Builds and installs the archive, then runs the task in the fixture project, each in its own `mix` process: the
  # way the task really runs (loaded from an archive, after Mix prunes the code path to compile the project).
  # Everything is built in a temporary directory.
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  @root Path.expand("..", __DIR__)
  @fixture Path.join(@root, "test/fixtures/sample_app")

  setup_all do
    tmp_dir =
      Path.join(System.tmp_dir!(), "xref_mermaid_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    archive = Path.join(tmp_dir, "xref_mermaid.ez")
    archives = [{"MIX_ENV", "dev"}, {"MIX_ARCHIVES", Path.join(tmp_dir, "archives")}]
    build_env = [{"MIX_BUILD_PATH", Path.join(tmp_dir, "archive_build")} | archives]
    {_, 0} = mix(["archive.build", "-o", archive], @root, build_env)
    {_, 0} = mix(["archive.install", archive, "--force"], @root, build_env)

    %{env: [{"MIX_BUILD_PATH", Path.join(tmp_dir, "fixture_build")} | archives], tmp_dir: tmp_dir}
  end

  defp mix(args, dir, env), do: System.cmd("mix", args, cd: dir, env: env, stderr_to_stdout: true)

  defp chart(args, %{env: env, tmp_dir: tmp_dir}) do
    output = Path.join(tmp_dir, "chart.mmd")
    {log, status} = mix(["xref.mermaid" | args] ++ ["-o", output], @fixture, env)
    assert status == 0, log
    {File.read!(output), log}
  end

  defp failure(args, %{env: env, tmp_dir: tmp_dir}) do
    {log, status} =
      mix(["xref.mermaid" | args] ++ ["-o", Path.join(tmp_dir, "x.mmd")], @fixture, env)

    assert status != 0
    log
  end

  test "draws a path slice from the compiled fixture", context do
    {text, log} = chart(["lib/sample/orders.ex"], context)

    assert log =~ "Wrote "
    refute log =~ "warning:"
    refute log =~ "dot -T"

    Enum.each(
      [
        ~s(f_orders__place_1["place/1..2"]),
        ~s(f_orders__valid_q_1["valid?/1"]),
        ~s(f_orders__valid_b_1["valid!/1"]),
        ~s(f_orders___lt_tilde_gt_2["#lt;~#gt;/2"]),
        ~s(f_orders__total_1["total/1"]),
        ~s(f_orders__Line__describe_1["Line.describe/1"]),
        ~s(f_orders__impl_String_Chars__to_string_1["[impl String.Chars] to_string/1"]),
        "f_orders__place_1 --> f_repo__save_1",
        "f_orders__total_1 --> f_totals__total_1",
        "f_orders__paths_0 --> f_a_b__run_0",
        "f_orders__paths_0 --> f_a_b_2__run_0",
        "f_orders__label_1 --> f_orders__Line__describe_1",
        "f_orders -. export .-> f_receipt",
        "class f_orders slice",
        "class f_orders__finish_2 private"
      ],
      &assert(text =~ &1)
    )
  end

  test "reads path prefixes relative to the current directory too", context do
    {relative, _log} = chart(["lib/sample/orders.ex"], context)
    {dotted, _log} = chart(["./lib/sample/orders.ex"], context)
    {absolute, _log} = chart([Path.join(@fixture, "lib/sample/orders.ex")], context)
    assert dotted == relative
    assert absolute == relative

    {whole, _log} = chart(["."], context)
    {lib, _log} = chart(["lib/"], context)
    assert whole == lib
  end

  test "follows calls from and to functions, through generated ones", context do
    args = ["--from", "Sample.Orders.place", "--to", "Sample.Totals.total/1", "--depth", "2"]
    {text, _log} = chart(args, context)

    assert text =~ "f_repo__save_1 --> f_repo__changeset_1"
    assert text =~ "f_repo__save_1 --> f_repo__insert_1"
    assert text =~ "class f_repo__changeset_1,f_repo__insert_1 generated"
    assert text =~ "f_orders__receipt_1 --> f_orders__total_1"
    assert text =~ "class f_orders__place_1,f_totals__total_1 start"
    refute text =~ "f_receipt"
  end

  test "adds specs and docs, and numbers calls in the order the code runs them", context do
    {text, _log} = chart(["--from", "Sample.Repo.save/1", "--details", "--call-order"], context)

    assert text =~
             ~s|f_repo__save_1["save/1<br>(Orders.t()) :: {:ok, Orders.t()}<br>Saves a record."]|

    assert text =~ "f_repo__save_1 -->|1| f_repo__changeset_1"
    assert text =~ "f_repo__save_1 -->|2| f_repo__insert_1"
  end

  test "passes the drawing options through", context do
    args = [
      "lib/sample/totals.ex",
      "--incoming",
      "--all-functions",
      "--external",
      "--legend",
      "--link",
      "x://{path}:{line}"
    ]

    {text, _log} = chart(args, context)

    assert text =~ "f_orders__total_1 --> f_totals__total_1"
    assert text =~ "f_orders@{ view: collapsed }"
    assert text =~ ~s(f_orders__label_1["label/1"])
    assert text =~ "f_totals__total_1 --> x_Enum__sum_1"
    assert text =~ ~s(subgraph legend_ ["Legend"])
    assert text =~ ~s(click f_totals__total_1 href "x://#{@fixture}/lib/sample/totals.ex:2")
  end

  test "draws an overview", context do
    {text, _log} = chart(["--overview", "--level", "3"], context)
    assert text =~ ~s(d_lib_sample__["lib/sample/*"])
    assert text =~ ~s(d_lib_sample_a_["lib/sample/a/"])
    assert text =~ "d_lib_sample__ -. runtime ×1 .-> d_lib_sample_a_"
  end

  test "stops with a message on what it can't draw", context do
    assert failure(["--from", "Sample.Orders.plcae/2"], context) =~
             ~r/No function Sample.Orders.plcae\/2 in the project. Closest: .*Sample.Orders.place\/1/

    assert failure(["--from", "Sample.Orders"], context) =~ "Can't read \"Sample.Orders\""
    assert failure(["lib/nope"], context) =~ "No file of the project starts with lib/nope"
    assert failure([], context) =~ "Give path prefixes, --from, --to or --overview"
    assert failure(["lib/", "--expanded", "--collapsed"], context) =~ "not both"
    assert failure(["--overview", "lib/"], context) =~ "--overview draws the whole project"
    assert failure(["--overview", "--legend"], context) =~ "--overview takes only --level"
    assert failure(["--overview", "--details"], context) =~ "--overview takes only --level"
    assert failure(["lib/", "--level", "2"], context) =~ "--level goes with --overview"
    assert failure(["--overview", "--level", "0"], context) =~ "--level must be 1 or more"
    assert failure(["lib/", "--depth", "2"], context) =~ "--depth goes with --from or --to"

    assert failure(["--from", "Sample.Orders.place", "--depth", "-1"], context) =~
             "--depth must be 0 or more"

    assert failure(["--from", "Sample.Orders.place", "--incoming"], context) =~
             "--incoming goes with path prefixes"
  end

  test "stops with a message outside a project and on an unwritable output", %{
    env: env,
    tmp_dir: tmp_dir
  } do
    {log, status} = mix(["xref.mermaid", "--overview", "-o", "x.mmd"], tmp_dir, env)
    assert status != 0
    assert log =~ "Could not find a Mix.Project"

    missing = Path.join(tmp_dir, "missing/dir/x.mmd")
    {log, status} = mix(["xref.mermaid", "--overview", "-o", missing], @fixture, env)
    assert status != 0
    assert log =~ "Can't write #{missing}: no such file or directory"
  end

  test "warns in an umbrella app that callers in the other apps are missing", %{
    env: env,
    tmp_dir: tmp_dir
  } do
    app = Path.join(@root, "test/fixtures/umbrella/apps/core")
    output = Path.join(tmp_dir, "core.mmd")

    {log, 0} = mix(["xref.mermaid", "--to", "Core.hello/0", "-o", output], app, env)
    assert log =~ "calls from its other apps aren't read"

    {log, 0} = mix(["xref.mermaid", "--from", "Core.hello/0", "-o", output], app, env)
    refute log =~ "warning:"
  end

  test "stops at an umbrella root", %{env: env} do
    umbrella = Path.join(@root, "test/fixtures/umbrella")
    {log, status} = mix(["xref.mermaid", "--overview", "-o", "x.mmd"], umbrella, env)
    assert status != 0
    assert log =~ "not from the umbrella root"
  end
end
