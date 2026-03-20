defmodule SymphonyElixir.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{Adapter, Client}
  alias SymphonyElixir.Codex.DynamicTool

  # -- Config validation -------------------------------------------------------

  describe "config validation with kind github" do
    test "requires api_token when kind is github" do
      write_workflow_file!(
        workflow_path(),
        tracker_kind: "github",
        tracker_api_token: nil,
        tracker_repo: "myorg/myrepo"
      )

      assert {:error, :missing_github_api_token} = Config.validate!()
    end

    test "requires repo when kind is github" do
      write_workflow_file!(
        workflow_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test",
        tracker_repo: nil
      )

      assert {:error, :missing_github_repo} = Config.validate!()
    end

    test "validates successfully with kind github and required fields" do
      write_workflow_file!(
        workflow_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test",
        tracker_repo: "myorg/myrepo"
      )

      assert :ok = Config.validate!()
    end
  end

  # -- Adapter routing ---------------------------------------------------------

  describe "adapter routing" do
    test "routes to GitHub.Adapter when kind is github" do
      write_workflow_file!(
        workflow_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test",
        tracker_repo: "myorg/myrepo"
      )

      assert Tracker.adapter() == Adapter
    end
  end

  # -- Config accessors --------------------------------------------------------

  describe "GitHub config accessors" do
    test "github_repo returns configured repo" do
      write_workflow_file!(workflow_path(), tracker_kind: "github", tracker_api_token: "ghp_test", tracker_repo: "myorg/myrepo")
      assert Config.github_repo() == "myorg/myrepo"
    end

    test "github_project_number returns configured project number" do
      write_workflow_file!(workflow_path(), tracker_kind: "github", tracker_api_token: "ghp_test", tracker_repo: "myorg/myrepo", tracker_project_number: 42)
      assert Config.github_project_number() == 42
    end

    test "github_project_number returns nil when not configured" do
      write_workflow_file!(workflow_path(), tracker_kind: "github", tracker_api_token: "ghp_test", tracker_repo: "myorg/myrepo")
      assert Config.github_project_number() == nil
    end

    test "tracker_active_states and tracker_terminal_states return configured values" do
      write_workflow_file!(workflow_path(), tracker_kind: "github", tracker_api_token: "ghp_test", tracker_repo: "myorg/myrepo", tracker_active_states: ["Todo", "In Progress"], tracker_terminal_states: ["Done"])
      assert Config.tracker_active_states() == ["Todo", "In Progress"]
      assert Config.tracker_terminal_states() == ["Done"]
    end
  end

  # -- Client: parse_repo ------------------------------------------------------

  describe "Client.parse_repo/1" do
    test "parses owner/repo" do
      assert {:ok, {"myorg", "myrepo"}} = Client.parse_repo("myorg/myrepo")
    end

    test "handles trimming" do
      assert {:ok, {"myorg", "myrepo"}} = Client.parse_repo(" myorg / myrepo ")
    end

    test "rejects invalid formats" do
      assert {:error, :invalid_repo_format} = Client.parse_repo("noslash")
      assert {:error, :invalid_repo_format} = Client.parse_repo("/nope")
      assert {:error, :invalid_repo_format} = Client.parse_repo("nope/")
    end
  end

  # -- Issue normalization (real GraphQL payloads) ------------------------------

  describe "normalize_project_item" do
    test "normalizes a project item with Status field value" do
      item = %{
        "id" => "PVTI_abc",
        "fieldValueByName" => %{"name" => "In Progress"},
        "content" => %{
          "id" => "I_kwABC",
          "number" => 42,
          "title" => "Fix the bug",
          "body" => "It's broken",
          "state" => "OPEN",
          "url" => "https://github.com/myorg/myrepo/issues/42",
          "createdAt" => "2026-01-15T10:00:00Z",
          "updatedAt" => "2026-01-15T12:00:00Z",
          "assignees" => %{"nodes" => [%{"login" => "octocat"}]},
          "labels" => %{"nodes" => [%{"name" => "Bug"}, %{"name" => "Priority"}]}
        }
      }

      issue = Client.normalize_project_item_for_test(item, "myorg/myrepo")

      assert issue.id == "I_kwABC"
      assert issue.identifier == "myorg/myrepo#42"
      assert issue.title == "Fix the bug"
      assert issue.description == "It's broken"
      assert issue.state == "In Progress"
      assert issue.priority == nil
      assert issue.branch_name == nil
      assert issue.url == "https://github.com/myorg/myrepo/issues/42"
      assert issue.assignee_id == "octocat"
      assert issue.blocked_by == []
      assert issue.labels == ["bug", "priority"]
      assert issue.created_at == ~U[2026-01-15 10:00:00Z]
      assert issue.updated_at == ~U[2026-01-15 12:00:00Z]
    end

    test "falls back to OPEN/CLOSED when no Status field" do
      item = %{
        "id" => "PVTI_def",
        "fieldValueByName" => nil,
        "content" => %{
          "id" => "I_kwDEF",
          "number" => 7,
          "title" => "Simple issue",
          "body" => nil,
          "state" => "CLOSED",
          "url" => "https://github.com/myorg/myrepo/issues/7",
          "createdAt" => "2026-01-10T08:00:00Z",
          "updatedAt" => nil,
          "assignees" => %{"nodes" => []},
          "labels" => %{"nodes" => []}
        }
      }

      issue = Client.normalize_project_item_for_test(item, "myorg/myrepo")

      assert issue.state == "CLOSED"
      assert issue.assignee_id == nil
      assert issue.labels == []
    end

    test "returns nil for non-issue content (draft items)" do
      item = %{
        "id" => "PVTI_draft",
        "fieldValueByName" => %{"name" => "Todo"},
        "content" => %{}
      }

      assert Client.normalize_project_item_for_test(item, "myorg/myrepo") == nil
    end

    test "returns nil for nil content" do
      assert Client.normalize_project_item_for_test(%{"content" => nil}, "myorg/myrepo") == nil
    end
  end

  describe "normalize_repo_issue" do
    test "normalizes a plain repo issue" do
      raw = %{
        "id" => "I_kwGHI",
        "number" => 99,
        "title" => "Add feature",
        "body" => "Please add this",
        "state" => "OPEN",
        "url" => "https://github.com/owner/repo/issues/99",
        "createdAt" => "2026-03-01T09:00:00Z",
        "updatedAt" => "2026-03-02T14:30:00Z",
        "assignees" => %{"nodes" => [%{"login" => "dev1"}, %{"login" => "dev2"}]},
        "labels" => %{"nodes" => [%{"name" => "Enhancement"}]}
      }

      issue = Client.normalize_repo_issue_for_test(raw, "owner/repo")

      assert issue.id == "I_kwGHI"
      assert issue.identifier == "owner/repo#99"
      assert issue.state == "OPEN"
      assert issue.assignee_id == "dev1"
      assert issue.labels == ["enhancement"]
    end
  end

  describe "normalize_issue_by_id" do
    test "picks Status from projectItems when available" do
      node = %{
        "id" => "I_kwJKL",
        "number" => 10,
        "title" => "Test",
        "body" => nil,
        "state" => "OPEN",
        "url" => "https://github.com/o/r/issues/10",
        "createdAt" => "2026-02-01T00:00:00Z",
        "updatedAt" => nil,
        "assignees" => %{"nodes" => []},
        "labels" => %{"nodes" => []},
        "projectItems" => %{
          "nodes" => [
            %{"fieldValueByName" => %{"name" => "Done"}}
          ]
        }
      }

      issue = Client.normalize_issue_by_id_for_test(node, "o/r")

      assert issue.state == "Done"
    end

    test "falls back to GitHub state when no projectItems" do
      node = %{
        "id" => "I_kwMNO",
        "number" => 11,
        "title" => "No project",
        "body" => nil,
        "state" => "CLOSED",
        "url" => "https://github.com/o/r/issues/11",
        "createdAt" => "2026-02-01T00:00:00Z",
        "updatedAt" => nil,
        "assignees" => %{"nodes" => []},
        "labels" => %{"nodes" => []},
        "projectItems" => %{"nodes" => []}
      }

      issue = Client.normalize_issue_by_id_for_test(node, "o/r")

      assert issue.state == "CLOSED"
    end
  end

  # -- DynamicTool: github_graphql ---------------------------------------------

  describe "github_graphql dynamic tool" do
    test "tool_specs advertises github_graphql when tracker kind is github" do
      write_workflow_file!(workflow_path(), tracker_kind: "github", tracker_api_token: "ghp_test", tracker_repo: "myorg/myrepo")
      assert [%{"name" => "github_graphql"}] = DynamicTool.tool_specs()
    end

    test "executes github_graphql with mock client" do
      test_pid = self()

      response =
        DynamicTool.execute(
          "github_graphql",
          %{"query" => "query { viewer { login } }", "variables" => %{}},
          github_client: fn query, variables, opts ->
            send(test_pid, {:github_client_called, query, variables, opts})
            {:ok, %{"data" => %{"viewer" => %{"login" => "octocat"}}}}
          end
        )

      assert_received {:github_client_called, "query { viewer { login } }", %{}, []}
      assert response["success"] == true
      assert [%{"text" => text}] = response["contentItems"]
      assert Jason.decode!(text) == %{"data" => %{"viewer" => %{"login" => "octocat"}}}
    end

    test "github_graphql validates required query" do
      response =
        DynamicTool.execute("github_graphql", %{"variables" => %{}},
          github_client: fn _q, _v, _o -> flunk("should not be called") end
        )

      assert response["success"] == false
      assert [%{"text" => text}] = response["contentItems"]
      assert Jason.decode!(text)["error"]["message"] =~ "query"
    end

    test "github_graphql handles transport errors" do
      response =
        DynamicTool.execute("github_graphql", %{"query" => "query { viewer { login } }"},
          github_client: fn _q, _v, _o -> {:error, {:github_api_status, 403}} end
        )

      assert response["success"] == false
      assert [%{"text" => text}] = response["contentItems"]
      assert Jason.decode!(text)["error"]["message"] =~ "403"
    end
  end

  # -- create_comment ----------------------------------------------------------

  describe "create_comment" do
    test "calls addComment mutation via client" do
      write_workflow_file!(workflow_path(), tracker_kind: "github", tracker_api_token: "ghp_test", tracker_repo: "myorg/myrepo")

      Application.put_env(:symphony_elixir, :github_client_module, __MODULE__.MockGraphQLClient)

      try do
        Agent.start_link(
          fn ->
            %{"data" => %{"addComment" => %{"commentEdge" => %{"node" => %{"id" => "IC_abc"}}}}}
          end,
          name: :mock_github_response
        )

        assert :ok = Adapter.create_comment("I_abc123", "Test comment")
      after
        Application.delete_env(:symphony_elixir, :github_client_module)
        if Process.whereis(:mock_github_response), do: Agent.stop(:mock_github_response)
      end
    end
  end

  # -- Adapter delegation via mock ---------------------------------------------

  describe "adapter delegation" do
    test "fetch_issue_states_by_ids delegates to client module" do
      write_workflow_file!(workflow_path(), tracker_kind: "github", tracker_api_token: "ghp_test", tracker_repo: "myorg/myrepo", tracker_project_number: 1)

      issues = [
        %Issue{id: "I_abc", identifier: "myorg/myrepo#1", title: "Test", state: "Ready",
               blocked_by: [], labels: [], assigned_to_worker: true}
      ]

      Application.put_env(:symphony_elixir, :github_client_module, __MODULE__.MockAdapterClient)

      try do
        Agent.start_link(fn -> issues end, name: :mock_adapter_issues)

        {:ok, [issue]} = Adapter.fetch_issue_states_by_ids(["I_abc"])
        assert issue.id == "I_abc"
        assert issue.state == "Ready"
      after
        Application.delete_env(:symphony_elixir, :github_client_module)
        if Process.whereis(:mock_adapter_issues), do: Agent.stop(:mock_adapter_issues)
      end
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp workflow_path do
    Application.get_env(:symphony_elixir, :workflow_file_path)
  end

  # Mock that returns pre-built issues for adapter delegation tests
  defmodule MockAdapterClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_issue_states_by_ids(_ids) do
      {:ok, Agent.get(:mock_adapter_issues, & &1)}
    end

    def graphql(_query, _variables \\ %{}, _opts \\ []), do: {:ok, %{"data" => %{}}}
  end

  # Mock that returns raw GraphQL responses for mutation tests
  defmodule MockGraphQLClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_ids), do: {:ok, []}

    def graphql(_query, _variables \\ %{}, _opts \\ []) do
      {:ok, Agent.get(:mock_github_response, & &1)}
    end
  end
end
