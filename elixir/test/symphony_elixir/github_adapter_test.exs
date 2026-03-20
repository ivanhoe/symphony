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
      write_workflow_file!(
        workflow_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test",
        tracker_repo: "myorg/myrepo"
      )

      assert Config.github_repo() == "myorg/myrepo"
    end

    test "github_project_number returns configured project number" do
      write_workflow_file!(
        workflow_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test",
        tracker_repo: "myorg/myrepo",
        tracker_project_number: 42
      )

      assert Config.github_project_number() == 42
    end

    test "github_project_number returns nil when not configured" do
      write_workflow_file!(
        workflow_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test",
        tracker_repo: "myorg/myrepo"
      )

      assert Config.github_project_number() == nil
    end

    test "tracker_active_states and tracker_terminal_states return configured values" do
      write_workflow_file!(
        workflow_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test",
        tracker_repo: "myorg/myrepo",
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done"]
      )

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

  # -- Issue normalization (project items) -------------------------------------

  describe "issue normalization from project items" do
    setup do
      write_workflow_file!(
        workflow_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test",
        tracker_repo: "myorg/myrepo",
        tracker_project_number: 1
      )

      :ok
    end

    test "fetch_issue_states_by_ids normalizes issue with project Status field" do
      issue_nodes = [
        %Issue{
          id: "I_abc123",
          identifier: "myorg/myrepo#42",
          title: "Fix the bug",
          description: "It's broken",
          priority: nil,
          state: "In Progress",
          branch_name: nil,
          url: "https://github.com/myorg/myrepo/issues/42",
          assignee_id: "octocat",
          blocked_by: [],
          labels: ["bug", "priority"],
          created_at: ~U[2026-01-15 10:00:00Z],
          updated_at: ~U[2026-01-15 12:00:00Z]
        }
      ]

      Application.put_env(:symphony_elixir, :github_client_module, __MODULE__.MockIssueClient)

      try do
        Agent.start_link(fn -> issue_nodes end, name: :mock_github_issues)

        {:ok, [issue]} = Adapter.fetch_issue_states_by_ids(["I_abc123"])

        assert issue.id == "I_abc123"
        assert issue.identifier == "myorg/myrepo#42"
        assert issue.title == "Fix the bug"
        assert issue.description == "It's broken"
        assert issue.priority == nil
        assert issue.state == "In Progress"
        assert issue.branch_name == nil
        assert issue.url == "https://github.com/myorg/myrepo/issues/42"
        assert issue.assignee_id == "octocat"
        assert issue.blocked_by == []
        assert issue.labels == ["bug", "priority"]
        assert issue.created_at == ~U[2026-01-15 10:00:00Z]
        assert issue.updated_at == ~U[2026-01-15 12:00:00Z]
      after
        Application.delete_env(:symphony_elixir, :github_client_module)

        if Process.whereis(:mock_github_issues) do
          Agent.stop(:mock_github_issues)
        end
      end
    end

    test "falls back to OPEN/CLOSED when no project Status" do
      issue_nodes = [
        %Issue{
          id: "I_def456",
          identifier: "myorg/myrepo#7",
          title: "Simple issue",
          description: nil,
          priority: nil,
          state: "OPEN",
          branch_name: nil,
          url: "https://github.com/myorg/myrepo/issues/7",
          assignee_id: nil,
          blocked_by: [],
          labels: [],
          created_at: ~U[2026-01-10 08:00:00Z],
          updated_at: nil
        }
      ]

      Application.put_env(:symphony_elixir, :github_client_module, __MODULE__.MockIssueClient)

      try do
        Agent.start_link(fn -> issue_nodes end, name: :mock_github_issues)

        {:ok, [issue]} = Adapter.fetch_issue_states_by_ids(["I_def456"])

        assert issue.state == "OPEN"
        assert issue.assignee_id == nil
      after
        Application.delete_env(:symphony_elixir, :github_client_module)

        if Process.whereis(:mock_github_issues) do
          Agent.stop(:mock_github_issues)
        end
      end
    end
  end

  # -- DynamicTool: github_graphql ---------------------------------------------

  describe "github_graphql dynamic tool" do
    test "tool_specs advertises github_graphql when tracker kind is github" do
      write_workflow_file!(
        workflow_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test",
        tracker_repo: "myorg/myrepo"
      )

      specs = DynamicTool.tool_specs()
      assert [%{"name" => "github_graphql"}] = specs
    end

    test "executes github_graphql with mock client" do
      test_pid = self()

      response =
        DynamicTool.execute(
          "github_graphql",
          %{
            "query" => "query { viewer { login } }",
            "variables" => %{}
          },
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
        DynamicTool.execute(
          "github_graphql",
          %{"variables" => %{}},
          github_client: fn _q, _v, _o -> flunk("should not be called") end
        )

      assert response["success"] == false
      assert [%{"text" => text}] = response["contentItems"]
      assert Jason.decode!(text)["error"]["message"] =~ "query"
    end

    test "github_graphql handles transport errors" do
      response =
        DynamicTool.execute(
          "github_graphql",
          %{"query" => "query { viewer { login } }"},
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
      write_workflow_file!(
        workflow_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test",
        tracker_repo: "myorg/myrepo"
      )

      Application.put_env(:symphony_elixir, :github_client_module, __MODULE__.MockCommentClient)

      try do
        Agent.start_link(
          fn ->
            %{
              "data" => %{
                "addComment" => %{
                  "commentEdge" => %{"node" => %{"id" => "IC_abc"}}
                }
              }
            }
          end,
          name: :mock_github_response
        )

        assert :ok = Adapter.create_comment("I_abc123", "Test comment")
      after
        Application.delete_env(:symphony_elixir, :github_client_module)

        if Process.whereis(:mock_github_response) do
          Agent.stop(:mock_github_response)
        end
      end
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp workflow_path do
    Application.get_env(:symphony_elixir, :workflow_file_path)
  end

  # Mock client that reads response from Agent state
  defmodule MockClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_issue_states_by_ids(ids) do
      SymphonyElixir.GitHub.Client.fetch_issue_states_by_ids(ids)
    end

    def graphql(_query, _variables \\ %{}, _opts \\ []) do
      response = Agent.get(:mock_github_response, & &1)
      {:ok, response}
    end
  end

  defmodule MockIssueClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}

    def fetch_issue_states_by_ids(_ids) do
      issues = Agent.get(:mock_github_issues, & &1)
      {:ok, issues}
    end

    def graphql(_query, _variables \\ %{}, _opts \\ []) do
      {:ok, %{"data" => %{}}}
    end
  end

  defmodule MockCommentClient do
    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_states), do: {:ok, []}
    def fetch_issue_states_by_ids(_ids), do: {:ok, []}

    def graphql(_query, _variables \\ %{}, _opts \\ []) do
      response = Agent.get(:mock_github_response, & &1)
      {:ok, response}
    end
  end
end
