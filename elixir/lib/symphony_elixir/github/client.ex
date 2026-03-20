defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  Thin GitHub Projects v2 GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000
  @github_graphql_endpoint "https://api.github.com/graphql"

  @project_items_query """
  query SymphonyGitHubProjectItems($owner: String!, $projectNumber: Int!, $first: Int!, $after: String) {
    organization(login: $owner) {
      projectV2(number: $projectNumber) {
        items(first: $first, after: $after) {
          nodes {
            id
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
            content {
              ... on Issue {
                id
                number
                title
                body
                state
                url
                createdAt
                updatedAt
                assignees(first: 5) { nodes { login } }
                labels(first: 20) { nodes { name } }
              }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @project_items_user_query """
  query SymphonyGitHubProjectItemsUser($owner: String!, $projectNumber: Int!, $first: Int!, $after: String) {
    user(login: $owner) {
      projectV2(number: $projectNumber) {
        items(first: $first, after: $after) {
          nodes {
            id
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
            content {
              ... on Issue {
                id
                number
                title
                body
                state
                url
                createdAt
                updatedAt
                assignees(first: 5) { nodes { login } }
                labels(first: 20) { nodes { name } }
              }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
  """

  @repo_issues_query """
  query SymphonyGitHubRepoIssues($owner: String!, $repo: String!, $states: [IssueState!], $first: Int!, $after: String) {
    repository(owner: $owner, name: $repo) {
      issues(states: $states, first: $first, after: $after) {
        nodes {
          id
          number
          title
          body
          state
          url
          createdAt
          updatedAt
          assignees(first: 5) { nodes { login } }
          labels(first: 20) { nodes { name } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
  """

  @issues_by_ids_query """
  query SymphonyGitHubIssuesByIds($ids: [ID!]!) {
    nodes(ids: $ids) {
      ... on Issue {
        id
        number
        title
        body
        state
        url
        createdAt
        updatedAt
        assignees(first: 5) { nodes { login } }
        labels(first: 20) { nodes { name } }
        projectItems(first: 10) {
          nodes {
            fieldValueByName(name: "Status") {
              ... on ProjectV2ItemFieldSingleSelectValue { name }
            }
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    repo = Config.github_repo()
    Logger.info("GitHub.Client.fetch_candidate_issues called — repo=#{inspect(repo)} project=#{inspect(Config.github_project_number())} has_token=#{is_binary(Config.github_api_token())}")

    cond do
      is_nil(Config.github_api_token()) ->
        {:error, :missing_github_api_token}

      is_nil(repo) ->
        {:error, :missing_github_repo}

      true ->
        {owner, repo_name} = parse_repo!(repo)
        active_states = Config.tracker_active_states()

        case Config.github_project_number() do
          project_number when is_integer(project_number) ->
            fetch_project_items(owner, project_number, active_states)

          nil ->
            github_states = active_states_to_github_states(active_states)
            fetch_repo_issues(owner, repo_name, github_states)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    if state_names == [] do
      {:ok, []}
    else
      repo = Config.github_repo()

      cond do
        is_nil(Config.github_api_token()) ->
          {:error, :missing_github_api_token}

        is_nil(repo) ->
          {:error, :missing_github_repo}

        true ->
          {owner, repo_name} = parse_repo!(repo)

          case Config.github_project_number() do
            project_number when is_integer(project_number) ->
              fetch_project_items(owner, project_number, state_names)

            nil ->
              github_states = active_states_to_github_states(state_names)
              fetch_repo_issues(owner, repo_name, github_states)
          end
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    if ids == [] do
      {:ok, []}
    else
      repo = Config.github_repo()

      case graphql(@issues_by_ids_query, %{ids: ids}) do
        {:ok, %{"data" => %{"nodes" => nodes}}} when is_list(nodes) ->
          issues =
            nodes
            |> Enum.reject(&is_nil/1)
            |> Enum.map(&normalize_issue_by_id(&1, repo))
            |> Enum.reject(&is_nil/1)

          {:ok, issues}

        {:ok, %{"errors" => errors}} ->
          {:error, {:github_graphql_errors, errors}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = %{"query" => query, "variables" => variables}
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      {:ok, body}
    else
      {:ok, response} ->
        Logger.error(
          "GitHub GraphQL request failed status=#{response.status}" <>
            github_error_context(payload, response)
        )

        {:error, {:github_api_status, response.status}}

      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  @doc false
  @spec parse_repo(String.t()) :: {:ok, {String.t(), String.t()}} | {:error, :invalid_repo_format}
  def parse_repo(repo) when is_binary(repo) do
    case String.split(repo, "/", parts: 2) do
      [owner, name] when owner != "" and name != "" ->
        {:ok, {String.trim(owner), String.trim(name)}}

      _ ->
        {:error, :invalid_repo_format}
    end
  end

  # -- Private -----------------------------------------------------------------

  defp parse_repo!(repo) do
    case parse_repo(repo) do
      {:ok, result} -> result
      {:error, reason} -> raise ArgumentError, "Invalid GitHub repo format #{inspect(repo)}: #{inspect(reason)}"
    end
  end

  defp fetch_project_items(owner, project_number, filter_states) do
    fetch_project_items_page(owner, project_number, filter_states, nil, [])
  end

  defp fetch_project_items_page(owner, project_number, filter_states, after_cursor, acc) do
    variables = %{
      owner: owner,
      projectNumber: project_number,
      first: @issue_page_size,
      after: after_cursor
    }

    repo = Config.github_repo()

    with {:ok, body} <- graphql_with_owner_fallback(owner, project_number, variables),
         {:ok, items, page_info} <- decode_project_items_response(body) do
      issues =
        items
        |> Enum.map(&normalize_project_item(&1, repo))
        |> Enum.reject(&is_nil/1)
        |> filter_by_states(filter_states)

      updated_acc = Enum.reverse(issues, acc)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          fetch_project_items_page(owner, project_number, filter_states, next_cursor, updated_acc)

        :done ->
          {:ok, Enum.reverse(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp graphql_with_owner_fallback(_owner, _project_number, variables) do
    case graphql(@project_items_query, variables) do
      {:ok, %{"data" => %{"organization" => %{"projectV2" => _}}}} = success ->
        success

      {:ok, _org_response} ->
        graphql(@project_items_user_query, variables)

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_repo_issues(owner, repo_name, github_states) do
    fetch_repo_issues_page(owner, repo_name, github_states, nil, [])
  end

  defp fetch_repo_issues_page(owner, repo_name, github_states, after_cursor, acc) do
    repo = Config.github_repo()

    variables = %{
      owner: owner,
      repo: repo_name,
      states: github_states,
      first: @issue_page_size,
      after: after_cursor
    }

    case graphql(@repo_issues_query, variables) do
      {:ok, %{"data" => %{"repository" => %{"issues" => issues_data}}}} ->
        nodes = Map.get(issues_data, "nodes", [])
        page_info = Map.get(issues_data, "pageInfo", %{})

        issues =
          nodes
          |> Enum.map(&normalize_repo_issue(&1, repo))
          |> Enum.reject(&is_nil/1)

        updated_acc = Enum.reverse(issues, acc)

        case next_page_cursor(page_info) do
          {:ok, next_cursor} ->
            fetch_repo_issues_page(owner, repo_name, github_states, next_cursor, updated_acc)

          :done ->
            {:ok, Enum.reverse(updated_acc)}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, %{"errors" => errors}} ->
        {:error, {:github_graphql_errors, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_project_items_response(%{"data" => data} = response) do
    Logger.info("GitHub: decode_project_items_response data keys: #{inspect(Map.keys(data))}")

    project_data =
      get_in(data, ["organization", "projectV2"]) ||
        get_in(data, ["user", "projectV2"])

    Logger.info("GitHub: project_data: #{inspect(project_data != nil)}")

    case project_data do
      %{"items" => %{"nodes" => nodes, "pageInfo" => page_info}} when is_list(nodes) ->
        {:ok, nodes, %{
          has_next_page: page_info["hasNextPage"] == true,
          end_cursor: page_info["endCursor"]
        }}

      nil ->
        Logger.error("GitHub: project_data is nil! Full response keys: #{inspect(Map.keys(response))}, data: #{inspect(data) |> String.slice(0, 300)}")
        {:error, :github_project_not_found}

      _ ->
        {:error, :github_unexpected_response}
    end
  end

  defp decode_project_items_response(%{"errors" => errors}) do
    Logger.error("GitHub: decode got errors-only response: #{inspect(errors) |> String.slice(0, 200)}")
    {:error, {:github_graphql_errors, errors}}
  end

  defp decode_project_items_response(_) do
    {:error, :github_unknown_payload}
  end

  defp normalize_project_item(item, repo) when is_map(item) do
    content = Map.get(item, "content")

    case content do
      %{"id" => id} when is_binary(id) ->
        status_value = get_in(item, ["fieldValueByName", "name"])
        state = status_value || github_state_to_display(content["state"])

        %Issue{
          id: id,
          identifier: format_identifier(repo, content["number"]),
          title: content["title"],
          description: content["body"],
          priority: nil,
          state: state,
          branch_name: nil,
          url: content["url"],
          assignee_id: first_assignee_login(content),
          blocked_by: [],
          labels: extract_labels(content),
          created_at: parse_datetime(content["createdAt"]),
          updated_at: parse_datetime(content["updatedAt"])
        }

      _ ->
        nil
    end
  end

  defp normalize_project_item(_item, _repo), do: nil

  defp normalize_repo_issue(issue, repo) when is_map(issue) do
    case issue do
      %{"id" => id} when is_binary(id) ->
        %Issue{
          id: id,
          identifier: format_identifier(repo, issue["number"]),
          title: issue["title"],
          description: issue["body"],
          priority: nil,
          state: github_state_to_display(issue["state"]),
          branch_name: nil,
          url: issue["url"],
          assignee_id: first_assignee_login(issue),
          blocked_by: [],
          labels: extract_labels(issue),
          created_at: parse_datetime(issue["createdAt"]),
          updated_at: parse_datetime(issue["updatedAt"])
        }

      _ ->
        nil
    end
  end

  defp normalize_repo_issue(_issue, _repo), do: nil

  defp normalize_issue_by_id(node, repo) when is_map(node) do
    case node do
      %{"id" => id} when is_binary(id) ->
        status_value =
          node
          |> get_in(["projectItems", "nodes"])
          |> case do
            [%{"fieldValueByName" => %{"name" => name}} | _] when is_binary(name) -> name
            _ -> nil
          end

        state = status_value || github_state_to_display(node["state"])

        %Issue{
          id: id,
          identifier: format_identifier(repo, node["number"]),
          title: node["title"],
          description: node["body"],
          priority: nil,
          state: state,
          branch_name: nil,
          url: node["url"],
          assignee_id: first_assignee_login(node),
          blocked_by: [],
          labels: extract_labels(node),
          created_at: parse_datetime(node["createdAt"]),
          updated_at: parse_datetime(node["updatedAt"])
        }

      _ ->
        nil
    end
  end

  defp normalize_issue_by_id(_node, _repo), do: nil

  defp format_identifier(repo, number) when is_binary(repo) and is_integer(number) do
    "#{repo}##{number}"
  end

  defp format_identifier(_repo, _number), do: nil

  defp first_assignee_login(%{"assignees" => %{"nodes" => [%{"login" => login} | _]}})
       when is_binary(login),
       do: login

  defp first_assignee_login(_), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp filter_by_states(issues, filter_states) do
    normalized_filter =
      filter_states
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    Enum.filter(issues, fn %Issue{state: state} ->
      MapSet.member?(normalized_filter, normalize_state(state))
    end)
  end

  defp normalize_state(state) when is_binary(state) do
    state |> String.trim() |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp github_state_to_display("OPEN"), do: "OPEN"
  defp github_state_to_display("CLOSED"), do: "CLOSED"
  defp github_state_to_display(state) when is_binary(state), do: state
  defp github_state_to_display(_state), do: "OPEN"

  defp active_states_to_github_states(states) do
    states
    |> Enum.map(&normalize_state/1)
    |> Enum.flat_map(fn
      state when state in ["open", "todo", "in progress"] -> ["OPEN"]
      state when state in ["closed", "done", "cancelled", "canceled", "duplicate"] -> ["CLOSED"]
      _ -> ["OPEN"]
    end)
    |> Enum.uniq()
  end

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :github_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp graphql_headers do
    case Config.github_api_token() do
      nil ->
        {:error, :missing_github_api_token}

      token ->
        {:ok,
         [
           {"Authorization", "Bearer #{token}"},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(@github_graphql_endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp github_error_context(_payload, response) do
    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
