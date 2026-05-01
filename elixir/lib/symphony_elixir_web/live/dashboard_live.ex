defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(params, _session, socket) do
    socket =
      socket
      |> assign(:issue_identifier, Map.get(params, "issue_identifier"))
      |> assign_payloads()
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign_payloads()
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <p class="hero-copy">
              Current state, retry pressure, token usage, and orchestration health for the active Symphony runtime.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
          </div>
        </div>
      </header>

      <%= if @issue_identifier do %>
        <%= issue_detail(assigns) %>
      <% else %>
        <%= dashboard(assigns) %>
      <% end %>
    </section>
    """
  end

  defp dashboard(assigns) do
    ~H"""
    <%= if @payload[:error] do %>
      <section class="error-card">
        <h2 class="error-title">
          Snapshot unavailable
        </h2>
        <p class="error-copy">
          <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
        </p>
      </section>
    <% else %>
      <section class="metric-grid">
        <article class="metric-card">
          <p class="metric-label">Running</p>
          <p class="metric-value numeric"><%= @payload.counts.running %></p>
          <p class="metric-detail">Active issue sessions in the current runtime.</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Retrying</p>
          <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
          <p class="metric-detail">Issues waiting for the next retry window.</p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Total tokens</p>
          <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
          <p class="metric-detail numeric">
            In <%= format_int(@payload.codex_totals.input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
          </p>
        </article>

        <article class="metric-card">
          <p class="metric-label">Runtime</p>
          <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
          <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
        </article>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Rate limits</h2>
            <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
          </div>
        </div>

        <pre class="code-panel"><%= pretty_value(@payload.rate_limits) %></pre>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Running sessions</h2>
            <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
          </div>
        </div>

        <%= if @payload.running == [] do %>
          <p class="empty-state">No active sessions.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table data-table-running">
              <colgroup>
                <col style="width: 12rem;" />
                <col style="width: 8rem;" />
                <col style="width: 7.5rem;" />
                <col style="width: 8.5rem;" />
                <col />
                <col style="width: 10rem;" />
              </colgroup>
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>State</th>
                  <th>Session</th>
                  <th>Runtime / turns</th>
                  <th>Codex update</th>
                  <th>Tokens</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @payload.running}>
                  <td>
                    <div class="issue-stack">
                      <span class="issue-id"><%= entry.issue_identifier %></span>
                      <a class="issue-link" href={"/issues/#{entry.issue_identifier}"}>Watch session</a>
                      <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                    </div>
                  </td>
                  <td>
                    <span class={state_badge_class(entry.state)}>
                      <%= entry.state %>
                    </span>
                  </td>
                  <td>
                    <div class="session-stack">
                      <%= if entry.session_id do %>
                        <button
                          type="button"
                          class="subtle-button"
                          data-label="Copy ID"
                          data-copy={entry.session_id}
                          onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                        >
                          Copy ID
                        </button>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </div>
                  </td>
                  <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                  <td>
                    <div class="detail-stack">
                      <span
                        class="event-text"
                        title={entry.last_message || to_string(entry.last_event || "n/a")}
                      ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                      <span class="muted event-meta">
                        <%= entry.last_event || "n/a" %>
                        <%= if entry.last_event_at do %>
                          · <span class="mono numeric"><%= entry.last_event_at %></span>
                        <% end %>
                      </span>
                      <%= if entry.recent_events && entry.recent_events != [] do %>
                        <details class="event-history">
                          <summary>Recent activity</summary>
                          <ol>
                            <li :for={event <- entry.recent_events}>
                              <span class="mono numeric"><%= event.at %></span>
                              <span><%= event.message || to_string(event.event || "n/a") %></span>
                            </li>
                          </ol>
                        </details>
                      <% end %>
                    </div>
                  </td>
                  <td>
                    <div class="token-stack numeric">
                      <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                      <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Retry queue</h2>
            <p class="section-copy">Issues waiting for the next retry window.</p>
          </div>
        </div>

        <%= if @payload.retrying == [] do %>
          <p class="empty-state">No issues are currently backing off.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table" style="min-width: 680px;">
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Attempt</th>
                  <th>Due at</th>
                  <th>Error</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @payload.retrying}>
                  <td>
                    <div class="issue-stack">
                      <span class="issue-id"><%= entry.issue_identifier %></span>
                      <a class="issue-link" href={"/issues/#{entry.issue_identifier}"}>Watch session</a>
                      <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                    </div>
                  </td>
                  <td><%= entry.attempt %></td>
                  <td class="mono"><%= entry.due_at || "n/a" %></td>
                  <td><%= entry.error || "n/a" %></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </section>
    <% end %>
    """
  end

  defp issue_detail(assigns) do
    ~H"""
    <%= if @issue_payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Session unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @issue_payload.error.code %>:</strong> <%= @issue_payload.error.message %>
          </p>
          <p class="error-copy"><a href="/">Back to dashboard</a></p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Issue</p>
            <p class="metric-value"><%= @issue_payload.issue_identifier %></p>
            <p class="metric-detail"><a href="/">Back to dashboard</a></p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Status</p>
            <p class="metric-value"><%= @issue_payload.status %></p>
            <p class="metric-detail">
              <%= if @issue_payload.running do %>
                <span class={state_badge_class(@issue_payload.running.state)}><%= @issue_payload.running.state %></span>
              <% else %>
                <span class="state-badge state-badge-warning">Retrying</span>
              <% end %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime / turns</p>
            <p class="metric-value numeric"><%= issue_runtime_and_turns(@issue_payload, @now) %></p>
            <p class="metric-detail">Updates live while the dashboard is connected.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Tokens</p>
            <p class="metric-value numeric"><%= issue_total_tokens(@issue_payload) %></p>
            <p class="metric-detail numeric"><%= issue_token_detail(@issue_payload) %></p>
          </article>
        </section>

        <section class="section-card detail-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Session controls</h2>
              <p class="section-copy">Useful handles for jumping from the browser into the live working copy.</p>
            </div>
          </div>

          <dl class="detail-grid">
            <div>
              <dt>Workspace</dt>
              <dd class="mono"><%= @issue_payload.workspace.path %></dd>
            </div>
            <div>
              <dt>Worker host</dt>
              <dd><%= @issue_payload.workspace.host || "local" %></dd>
            </div>
            <div>
              <dt>Session id</dt>
              <dd>
                <%= if session_id(@issue_payload) do %>
                  <button
                    type="button"
                    class="subtle-button"
                    data-label="Copy session ID"
                    data-copy={session_id(@issue_payload)}
                    onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                  >
                    Copy session ID
                  </button>
                  <span class="mono detail-inline"><%= session_id(@issue_payload) %></span>
                <% else %>
                  n/a
                <% end %>
              </dd>
            </div>
            <div>
              <dt>Raw state</dt>
              <dd><a class="issue-link" href={"/api/v1/#{@issue_payload.issue_identifier}"}>Open JSON details</a></dd>
            </div>
          </dl>
        </section>

        <section class="section-card detail-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Live Codex activity</h2>
              <p class="section-copy">The latest events Symphony has received from the active agent.</p>
            </div>
          </div>

          <%= if @issue_payload.recent_events == [] do %>
            <p class="empty-state">No activity has been reported for this session yet.</p>
          <% else %>
            <ol class="activity-list">
              <li :for={event <- Enum.reverse(@issue_payload.recent_events)}>
                <span class="mono numeric activity-time"><%= event.at %></span>
                <span class="activity-message"><%= event.message || to_string(event.event || "n/a") %></span>
              </li>
            </ol>
          <% end %>
        </section>

        <section class="section-card detail-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Snapshot</h2>
              <p class="section-copy">Raw issue details for checking anything the page does not highlight yet.</p>
            </div>
          </div>

          <pre class="code-panel"><%= pretty_value(@issue_payload) %></pre>
        </section>
      <% end %>
    """
  end

  defp assign_payloads(socket) do
    socket
    |> assign(:payload, load_payload())
    |> assign(:issue_payload, load_issue_payload(socket.assigns[:issue_identifier]))
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp load_issue_payload(nil), do: nil

  defp load_issue_payload(issue_identifier) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} -> payload
      {:error, :issue_not_found} -> %{error: %{code: "issue_not_found", message: "Issue not found"}}
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp issue_runtime_and_turns(%{running: running}, now) when is_map(running) do
    format_runtime_and_turns(running.started_at, running.turn_count, now)
  end

  defp issue_runtime_and_turns(%{retry: retry}, _now) when is_map(retry), do: "retrying"
  defp issue_runtime_and_turns(_issue_payload, _now), do: "n/a"

  defp issue_total_tokens(%{running: %{tokens: tokens}}), do: format_int(tokens.total_tokens)
  defp issue_total_tokens(_issue_payload), do: "n/a"

  defp issue_token_detail(%{running: %{tokens: tokens}}) do
    "In #{format_int(tokens.input_tokens)} / Out #{format_int(tokens.output_tokens)}"
  end

  defp issue_token_detail(_issue_payload), do: "n/a"

  defp session_id(%{running: %{session_id: session_id}}), do: session_id
  defp session_id(_issue_payload), do: nil

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
