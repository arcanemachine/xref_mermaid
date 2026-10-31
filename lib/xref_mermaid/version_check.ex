defmodule XrefMermaid.VersionCheck do
  @moduledoc """
  A development feature, which may be removed: when `XREF_MERMAID_VERSION_CHECK=1` is set, warns that GitHub's
  `main` has commits this archive was not built from.

  The archive's commit is read with `git` when it is built. The check gives up silently on any error (no `git` at
  build time, no network, a commit GitHub doesn't know) and waits at most a few seconds.
  """

  # The commit is read at compile time, so Mix recompiles the module when the checkout has moved to another commit.
  @commit (try do
             {commit, 0} =
               System.cmd("git", ["rev-parse", "HEAD"], cd: __DIR__, stderr_to_stdout: true)

             String.trim(commit)
           rescue
             _ -> nil
           end)

  def __mix_recompile__? do
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: __DIR__, stderr_to_stdout: true)
    String.trim(commit) != @commit
  rescue
    _ -> false
  end

  @doc """
  Returns the warning, in a list, when the check is on and `commit` is behind GitHub's `main`; `[]` otherwise.
  """
  def warnings(commit \\ @commit) do
    if System.get_env("XREF_MERMAID_VERSION_CHECK") == "1" and commit != nil and behind?(commit) do
      [
        "this xref_mermaid archive is older than GitHub's main; reinstall it with " <>
          "`mix archive.install github arcanemachine/xref_mermaid --force`"
      ]
    else
      []
    end
  end

  # GitHub compares `main` with the commit: `ahead` (or `diverged`) means `main` has commits the archive lacks.
  defp behind?(commit) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    url = ~c"https://api.github.com/repos/arcanemachine/xref_mermaid/compare/#{commit}...main"
    headers = [{~c"user-agent", ~c"xref_mermaid"}, {~c"accept", ~c"application/vnd.github+json"}]

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    case :httpc.request(:get, {url, headers}, [timeout: 3000, connect_timeout: 2000, ssl: ssl],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} ->
        String.contains?(body, ~s("status":"ahead")) or
          String.contains?(body, ~s("status":"diverged"))

      _ ->
        false
    end
  catch
    _, _ -> false
  end
end
