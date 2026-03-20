defmodule SymphonyElixir.Claude.MCPToolServer do
  @moduledoc """
  MCP tool server that bridges Claude Code's MCP transport to Symphony's
  `DynamicTool` implementations.

  This exposes the same tools available to Codex (e.g. `linear_graphql`,
  `github_graphql`) as MCP tools for the Claude Code SDK session.
  """

  use ClaudeCode.MCP.Server, name: "symphony-tools"

  alias SymphonyElixir.Codex.DynamicTool

  tool :linear_graphql, "Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth." do
    field :query, :string, required: true
    field :variables, :map, required: false

    def execute(args) do
      arguments = %{
        "query" => Map.get(args, :query),
        "variables" => Map.get(args, :variables, %{})
      }

      case DynamicTool.execute("linear_graphql", arguments) do
        %{"success" => true, "contentItems" => [%{"text" => text} | _]} ->
          {:ok, text}

        %{"success" => false, "contentItems" => [%{"text" => text} | _]} ->
          {:error, text}

        other ->
          {:error, inspect(other)}
      end
    end
  end

  tool :github_graphql, "Execute a raw GraphQL query or mutation against GitHub using Symphony's configured auth." do
    field :query, :string, required: true
    field :variables, :map, required: false

    def execute(args) do
      arguments = %{
        "query" => Map.get(args, :query),
        "variables" => Map.get(args, :variables, %{})
      }

      case DynamicTool.execute("github_graphql", arguments) do
        %{"success" => true, "contentItems" => [%{"text" => text} | _]} ->
          {:ok, text}

        %{"success" => false, "contentItems" => [%{"text" => text} | _]} ->
          {:error, text}

        other ->
          {:error, inspect(other)}
      end
    end
  end
end
