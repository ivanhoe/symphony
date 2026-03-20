defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Projects v2 backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Config

  @add_comment_mutation """
  mutation SymphonyAddComment($subjectId: ID!, $body: String!) {
    addComment(input: {subjectId: $subjectId, body: $body}) {
      commentEdge {
        node { id }
      }
    }
  }
  """

  @project_metadata_query """
  query SymphonyGitHubProjectMetadata($owner: String!, $projectNumber: Int!) {
    organization(login: $owner) {
      projectV2(number: $projectNumber) {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            options { id name }
          }
        }
      }
    }
  }
  """

  @project_metadata_user_query """
  query SymphonyGitHubProjectMetadataUser($owner: String!, $projectNumber: Int!) {
    user(login: $owner) {
      projectV2(number: $projectNumber) {
        id
        field(name: "Status") {
          ... on ProjectV2SingleSelectField {
            id
            options { id name }
          }
        }
      }
    }
  }
  """

  @update_project_item_field_mutation """
  mutation SymphonyUpdateProjectItemField($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
    updateProjectV2ItemFieldValue(input: {
      projectId: $projectId,
      itemId: $itemId,
      fieldId: $fieldId,
      value: { singleSelectOptionId: $optionId }
    }) {
      projectV2Item { id }
    }
  }
  """

  @issue_project_item_query """
  query SymphonyGitHubIssueProjectItem($issueId: ID!) {
    node(id: $issueId) {
      ... on Issue {
        projectItems(first: 10) {
          nodes {
            id
            project { id number }
          }
        }
      }
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case client_module().graphql(@add_comment_mutation, %{subjectId: issue_id, body: body}) do
      {:ok, %{"data" => %{"addComment" => %{"commentEdge" => _}}}} ->
        :ok

      {:ok, %{"errors" => errors}} ->
        {:error, {:github_graphql_errors, errors}}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    case Config.github_project_number() do
      project_number when is_integer(project_number) ->
        update_project_item_status(issue_id, state_name, project_number)

      nil ->
        {:error, :github_project_number_required_for_state_update}
    end
  end

  defp update_project_item_status(issue_id, state_name, project_number) do
    repo = Config.github_repo()

    with {:ok, {owner, _repo_name}} <- Client.parse_repo(repo),
         {:ok, project_id, field_id, options} <- fetch_project_metadata(owner, project_number),
         {:ok, option_id} <- find_option_id(options, state_name),
         {:ok, item_id} <- find_project_item_id(issue_id, project_id) do
      case client_module().graphql(@update_project_item_field_mutation, %{
             projectId: project_id,
             itemId: item_id,
             fieldId: field_id,
             optionId: option_id
           }) do
        {:ok, %{"data" => %{"updateProjectV2ItemFieldValue" => _}}} ->
          :ok

        {:ok, %{"errors" => errors}} ->
          {:error, {:github_graphql_errors, errors}}

        {:error, reason} ->
          {:error, reason}

        _ ->
          {:error, :issue_update_failed}
      end
    end
  end

  defp fetch_project_metadata(owner, project_number) do
    variables = %{owner: owner, projectNumber: project_number}

    with {:ok, body} <- try_org_then_user_metadata(variables) do
      project_data =
        get_in(body, ["data", "organization", "projectV2"]) ||
          get_in(body, ["data", "user", "projectV2"])

      case project_data do
        %{"id" => project_id, "field" => %{"id" => field_id, "options" => options}}
        when is_list(options) ->
          {:ok, project_id, field_id, options}

        _ ->
          {:error, :github_project_metadata_not_found}
      end
    end
  end

  defp try_org_then_user_metadata(variables) do
    case client_module().graphql(@project_metadata_query, variables) do
      {:ok, %{"data" => %{"organization" => %{"projectV2" => _}}}} = success ->
        success

      {:ok, _org_response} ->
        client_module().graphql(@project_metadata_user_query, variables)

      {:error, _reason} = error ->
        error
    end
  end

  defp find_option_id(options, state_name) do
    normalized = String.downcase(String.trim(state_name))

    case Enum.find(options, fn opt ->
           String.downcase(String.trim(opt["name"] || "")) == normalized
         end) do
      %{"id" => option_id} -> {:ok, option_id}
      nil -> {:error, {:github_status_option_not_found, state_name}}
    end
  end

  defp find_project_item_id(issue_id, project_id) do
    case client_module().graphql(@issue_project_item_query, %{issueId: issue_id}) do
      {:ok, %{"data" => %{"node" => %{"projectItems" => %{"nodes" => items}}}}}
      when is_list(items) ->
        case Enum.find(items, fn item ->
               get_in(item, ["project", "id"]) == project_id
             end) do
          %{"id" => item_id} -> {:ok, item_id}
          nil -> {:error, :github_issue_not_in_project}
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :github_issue_project_item_lookup_failed}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end
end
