defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by agent backend turns.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.GitHub.Client, as: GitHubClient

  @linear_graphql_tool "linear_graphql"
  @github_graphql_tool "github_graphql"

  @graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        client = Keyword.get(opts, :linear_client, &Client.graphql/3)
        execute_graphql(arguments, client)

      @github_graphql_tool ->
        client = Keyword.get(opts, :github_client, &GitHubClient.graphql/3)
        execute_graphql(arguments, client)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case Config.tracker_kind() do
      "github" ->
        [graphql_tool_spec(@github_graphql_tool, "GitHub")]

      _ ->
        [graphql_tool_spec(@linear_graphql_tool, "Linear")]
    end
  end

  defp graphql_tool_spec(name, provider) do
    %{
      "name" => name,
      "description" => "Execute a raw GraphQL query or mutation against #{provider} using Symphony's configured auth.",
      "inputSchema" => @graphql_input_schema
    }
  end

  defp execute_graphql(arguments, client) do
    with {:ok, query, variables} <- normalize_graphql_arguments(arguments),
         {:ok, response} <- client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_graphql_arguments(arguments) when is_map(arguments) do
    with {:ok, query} <- normalize_query(arguments),
         {:ok, variables} <- normalize_variables(arguments) do
      {:ok, query, variables}
    end
  end

  defp normalize_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    %{
      "success" => success,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(response)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{"error" => %{"message" => "GraphQL tool requires a non-empty `query` string."}}
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "GraphQL tool expects either a GraphQL query string or an object with `query` and optional `variables`."}}
  end

  defp tool_error_payload(:invalid_variables) do
    %{"error" => %{"message" => "GraphQL `variables` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{"error" => %{"message" => "Symphony is missing Linear auth. Set `tracker.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."}}
  end

  defp tool_error_payload(:missing_github_api_token) do
    %{"error" => %{"message" => "Symphony is missing GitHub auth. Set `tracker.api_key` in `WORKFLOW.md` or export `GITHUB_TOKEN`."}}
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{"error" => %{"message" => "Linear GraphQL request failed with HTTP #{status}.", "status" => status}}
  end

  defp tool_error_payload({:github_api_status, status}) do
    %{"error" => %{"message" => "GitHub GraphQL request failed with HTTP #{status}.", "status" => status}}
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{"error" => %{"message" => "Linear GraphQL request failed.", "reason" => inspect(reason)}}
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{"error" => %{"message" => "GitHub GraphQL request failed.", "reason" => inspect(reason)}}
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "GraphQL tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
