#!/bin/bash
export GITHUB_TOKEN=$(gh auth token)
cd "$(dirname "$0")"
exec mix run --no-start --no-halt --eval '
  path = "/Users/ivanalvarezfrias/projects/05-ivan/apus_landing/WORKFLOW.md"
  IO.puts("Setting workflow path: #{path}")
  IO.puts("File exists: #{File.regular?(path)}")
  Application.put_env(:symphony_elixir, :workflow_file_path, path)
  IO.puts("Env after put: #{inspect(Application.get_env(:symphony_elixir, :workflow_file_path))}")
  {:ok, _} = Application.ensure_all_started(:symphony_elixir)
  IO.puts("App started. tracker_kind: #{inspect(SymphonyElixir.Config.tracker_kind())}")
  Process.sleep(:infinity)
'
