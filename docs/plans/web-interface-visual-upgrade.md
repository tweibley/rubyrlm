# RubyRLM Web Interface: Visual-Explainer-Grade Upgrade

## Context

The current `viewer.rb` is a monolithic Sinatra app (~400 lines) with all HTML/CSS/JS embedded in a single `html_template` method. It serves JSONL logs through two API endpoints and renders a three-panel SPA (session list, step navigator, timeline). It works, but it's a basic log viewer -- no diagrams, no analytics, no interactive querying, no theming.

The visual explainer generates self-contained HTML with Mermaid.js diagrams, Chart.js visualizations, CSS depth tiers, dark/light themes, animations, KPI dashboards, collapsible sections, and print-friendly output. The goal is to bring these capabilities into the RubyRLM web interface, customized for RLM workflows: iterative exec/final chains, recursive sub-calls, context exploration, and live query submission.

---

## Phase 1: Foundation -- Directory Structure & Design System

### 1.1 Break the Monolith

Create a proper web module under the gem:

```
lib/rubyrlm/web/
  app.rb                        # Sinatra::Base application (replaces viewer.rb)
  routes/
    api.rb                      # JSON API routes
    pages.rb                    # HTML page route(s)
  services/
    session_loader.rb           # Parse JSONL, build session trees, aggregate stats
  public/
    css/
      design-system.css         # Custom properties, depth tiers, themes
      components.css            # Component-specific styles
    js/
      app.js                    # SPA controller + router
      components/
        session-list.js         # Left sidebar sessions
        step-navigator.js       # Middle sidebar steps
        timeline.js             # Main timeline with collapsible cards
        exec-chain.js           # Mermaid exec chain flowchart
        recursion-tree.js       # Mermaid recursion tree
        charts.js               # Chart.js integrations
        kpi-dashboard.js        # Analytics KPI cards
        query-panel.js          # Interactive query UI
        context-inspector.js    # Context data tree view
      lib/
        theme-manager.js        # Dark/light toggle + theme registry
        diagram-renderer.js     # Mermaid wrapper with zoom/pan
        chart-renderer.js       # Chart.js wrapper
        animation.js            # Stagger fade-in, scale-fade, draw-in
        sse-client.js           # EventSource wrapper
      utils.js                  # Formatting, escaping, time helpers
```

**Files to modify:**
- `viewer.rb` -- gut and replace with thin launcher: `require 'rubyrlm/web/app'; RubyRLM::Web::App.run! port: 8080`
- `rubyrlm.gemspec` -- add `sinatra`, `puma`, `rackup` as runtime dependencies via `add_dependency`
- `Gemfile` -- no change needed (already has sinatra/puma/rackup)
- `lib/rubyrlm.rb` -- add `require "rubyrlm/web/app"`

**New files:**
- `lib/rubyrlm/web/app.rb` -- Sinatra::Base subclass, sets `public_folder`, registers route modules
- `lib/rubyrlm/web/routes/api.rb` -- `GET /api/sessions`, `GET /api/sessions/:id`, `GET /api/sessions/:id/tree`
- `lib/rubyrlm/web/routes/pages.rb` -- `GET /` serves the SPA shell HTML
- `lib/rubyrlm/web/services/session_loader.rb` -- JSONL parser with `list_sessions`, `load_session`, `build_recursion_tree`

### 1.2 CSS Design System (`public/css/design-system.css`)

Port visual-explainer patterns to CSS custom properties:

- **Theme variables**: `--color-bg`, `--color-surface-{0..3}`, `--color-border`, `--color-accent`, `--color-text`, `--color-text-muted`
- **Depth tiers**: `.node--hero` (elevated shadow, accent-tinted bg), `.node--elevated`, `.node` (default), `.node--recessed` (inset shadow)
- **Dark theme** (`[data-theme="dark"]`): Preserve current color palette (`#0a0a0a` bg, `#10b981` accent, etc.)
- **Light theme** (`[data-theme="light"]`): Professional light palette
- **Typography**: Google Fonts (e.g., DM Sans / DM Mono pairing), proper heading hierarchy
- **Scrollbar styling**, focus states, transition defaults
- **Animations**: `@keyframes` for fade-in, scale-fade, draw-in; respect `prefers-reduced-motion`

Use **Tailwind CLI** during development to generate a pre-built CSS file (`public/css/tailwind.css`). Ship the built file with the gem -- no CDN dependency at runtime, no build step for users. Run `npx tailwindcss -i ./src/input.css -o ./public/css/tailwind.css --minify` as a dev task. Add a `tailwind.config.js` with the custom color palette and font config currently in `viewer.rb`.

### 1.3 Frontend Library Integration

Add to the SPA shell HTML:
- **Mermaid.js** (CDN with vendored fallback) -- for exec chain and recursion tree diagrams
- **Chart.js** (CDN with vendored fallback) -- for latency sparklines, token usage charts
- Keep **Prism.js** for Ruby syntax highlighting (already present)
- Keep **Font Awesome** for icons (already present)

Wrap each in a renderer class (`diagram-renderer.js`, `chart-renderer.js`) that handles:
- Theme-aware rendering (Mermaid dark/light themes synced to CSS)
- Zoom controls for diagrams (buttons + scroll-to-zoom + drag-to-pan)
- Responsive container resize observation

### 1.4 Server-Side Session Parsing (`session_loader.rb`)

Move JSONL parsing from client-side JS to server-side Ruby. This enables:
- Enriched session list (stats, error counts, token totals) without loading full files
- Cross-session aggregation (Phase 3)
- Recursion tree building across log files (scan for `parent_run_id` relationships)
- Backward-compatible parsing (handle both old and new log formats)

### 1.5 API Endpoints (Phase 1)

| Endpoint | Replaces | Returns |
|----------|----------|---------|
| `GET /api/sessions` | `/api/logs` | Enriched list: `{id, timestamp, model, iterations, errors, tokens, has_recursion}` |
| `GET /api/sessions/:id` | `/api/logs/:filename` | Parsed session: `{run_start, iterations[], run_end, computed_stats}` |
| `GET /api/sessions/:id/raw` | (new) | Raw JSONL text |

---

## Phase 2: Enhanced Session Visualization

### 2.1 Mermaid Exec Chain Diagram

Generate a flowchart from iteration data showing the exec/final flow:

```
graph TD
  S["Prompt: Calculate 2^(2^2)"] --> E1["Exec 1: puts 2**(2**2)"]
  E1 -->|"ok: 16"| E2["Exec 2: verify..."]
  E2 -->|"error: NoMethodError"| E3["Exec 3: fix..."]
  E3 -->|"ok: 16"| F["Final: 16"]
```

- Node colors: green for success, red for errors, blue for final
- Edge labels show truncated execution results
- Click a node to scroll to the timeline card
- ELK layout for sessions with many iterations

### 2.2 Recursion Tree Visualization

For sessions with recursive sub-calls (`llm_query()`), render a tree:

```
graph TD
  R0["Root run (depth=0)\n10 iterations"] --> R1["Sub-run (depth=1)\n3 iterations"]
  R0 --> R2["Sub-run (depth=1)\n5 iterations"]
```

- Built from `parent_run_id` links across log files
- Show single root node gracefully when no recursion exists
- Click a node to load that sub-session

### 2.3 Iteration Latency & Token Charts

- **Latency sparkline**: Chart.js line chart (no axes labels, minimal) in the session stats panel
- **Per-iteration token bar chart**: Stacked bars showing prompt vs candidate tokens

**Requires a minor change to `client.rb`**: Add `usage: response[:usage]` to the `iteration_data` hash at line ~94 so per-iteration token counts are logged. The `SessionLoader` handles old logs missing this field gracefully.

### 2.4 Enhanced Code Rendering

- Line numbers (Prism line-numbers plugin)
- Copy-to-clipboard button on each code block
- Collapsible long code blocks (show first 10 lines, expand button)

### 2.5 Collapsible Iteration Cards

- **Collapsed**: Step number, EXEC/FINAL badge, status icon, first line of code, latency
- **Expanded**: Full code block, full execution output
- Default: collapse all except last step and any error steps
- CSS transition animation for expand/collapse

### 2.6 Animated Transitions

- Staggered fade-in on session load (each card 50ms after previous via CSS `--i` variable)
- Scale-fade for KPI stat numbers
- Draw-in for progress bar
- Respect `prefers-reduced-motion`

### 2.7 View Mode Toggle

Add a toggle above the timeline: **Timeline** (current linear view) | **Flow** (Mermaid diagram view)

**Files to create:** `exec-chain.js`, `recursion-tree.js`, `charts.js`; update `timeline.js` for collapsible cards
**Files to modify:** `client.rb` (add per-iteration usage), `session_loader.rb` (add tree building), `api.rb` (add tree endpoint)

---

## Phase 3: Analytics Dashboard

### 3.1 Analytics Service (`services/analytics_service.rb`)

Aggregate across all JSONL files:
- Total sessions, iterations, tokens
- Average iterations/session, latency/iteration
- Success rate (error-free iterations / total)
- Model breakdown (sessions and tokens per model)
- Time-series data (sessions and tokens by day)
- Top error classes with counts
- Repair rate (malformed JSON recovery %)

### 3.2 KPI Dashboard

Visual-explainer-style KPI cards with:
- Large number + trend indicator (vs previous period)
- Status badge (healthy/warning/critical)
- Background sparkline
- Depth tiers: hero for top metrics, elevated for breakdowns

**KPIs:** Total Sessions, Avg Iterations/Session, Total Tokens, Success Rate, Avg Latency, Repair Rate

### 3.3 Charts

- **Stacked bar chart**: Prompt vs candidate tokens per session over time
- **Pie chart**: Token distribution across models
- **Line chart**: Token usage trend
- **Per-iteration breakdown**: How prompt tokens grow as context accumulates within a session

### 3.4 Session Comparison

- Select two sessions from dropdowns
- Split-pane side-by-side display
- Comparison summary table (iteration count, latency, errors, tokens)
- Synced scrolling between timelines

### 3.5 Navigation

Add top-level mode toggle: **Sessions** | **Analytics** | **Query** (Phase 4)
- Left sidebar becomes context-dependent per mode
- Main content switches between timeline/dashboard/query panel

**New files:** `analytics_service.rb`, `kpi-dashboard.js`
**API:** `GET /api/analytics`, `GET /api/sessions/:id1/compare/:id2`

---

## Phase 4: Interactive Query Interface

### 4.1 Query Service (`services/query_service.rb`)

Bridges the web UI to `RubyRLM::Client`:
- Creates a Client with a `StreamingLogger` that writes events to both JSONL and a thread-safe `Queue`
- Runs `completion()` in a background thread
- Returns `run_id` for SSE streaming
- Supports cancellation

### 4.2 Streaming Logger (`services/streaming_logger.rb`)

Wraps `JsonlLogger` to also push events to a Queue:
```ruby
def log(event)
  @jsonl_logger.log(event)
  @queue.push(event)
end
```
Leverages the existing `@logger.log(payload)` pattern in `client.rb`.

### 4.3 SSE Route (`routes/sse.rb`)

`GET /api/query/:id/stream` -- streams iteration events as Server-Sent Events:
```
event: iteration
data: {"iteration":1,"action":"exec","code":"...","execution":{...}}
```

### 4.4 Query Panel UI

- Prompt textarea + model selector + config controls (max_iterations, max_depth, temperature)
- "Run" button -- POSTs to `/api/query`, opens SSE stream
- Live iteration cards appear one at a time with animation
- Cancel button for running queries
- "Re-run" button on completed sessions (pre-fills prompt)
- Safety warning banner about arbitrary code execution

### 4.5 Context Data Inspector

Tree-view component for exploring `context` data:
- Expandable key-value pairs with type annotations
- Truncated strings with "show more"
- Array items with indices
- Search/filter within the tree

**New files:** `query_service.rb`, `streaming_logger.rb`, `routes/sse.rb`, `query-panel.js`, `context-inspector.js`
**API:** `POST /api/query`, `GET /api/query/:id/stream`, `DELETE /api/query/:id`

---

## Phase 5: Export & Sharing

### 5.1 Export Service (`services/export_service.rb`)

Generate self-contained HTML in visual-explainer style:
- Inline all CSS (design system + components)
- Pre-render Mermaid diagrams as inline SVG (no JS dependency)
- Render charts as PNG data URIs for print
- Embed session data as JSON
- Include selected theme
- Target: under 500KB per session export

### 5.2 Print CSS (`public/css/print.css`)

- Hide navigation, controls, interactive elements
- Expand all collapsible sections
- Force light theme colors
- Page breaks between sections

**API:** `POST /api/sessions/:id/export` (returns downloadable HTML file)

---

## Implementation Order & Dependencies

```
Phase 1 (Foundation) ---- prerequisite for all others
  |- 1.1 Directory structure
  |- 1.2 Sinatra app refactor
  |- 1.3 Design system CSS + pre-built Tailwind
  |- 1.4 Session loader service
  |- 1.5 API endpoints
  |- 1.6 Frontend library integration

After Phase 1, build Phases 2, 3, and 4 in parallel:
  Phase 2 (Visualization) -- Mermaid diagrams, collapsible cards, animations
  Phase 3 (Analytics)      -- KPI dashboard, charts, comparison view
  Phase 4 (Interactive)    -- Query panel, SSE streaming, context inspector

Phase 5 (Export) -- after Phases 2-3 are complete
```

**Dependency note:** sinatra, puma, and rackup are required runtime dependencies (added to gemspec).

---

## Verification Plan

After each phase:

1. **Phase 1**: `ruby viewer.rb` starts, `GET /` serves the SPA, `GET /api/sessions` returns enriched session list, existing logs render in the new design with dark/light toggle
2. **Phase 2**: Sessions display Mermaid exec chain diagram, collapsible cards work, latency sparklines render, animations play on load
3. **Phase 3**: Analytics mode shows KPI dashboard with real data from logs, comparison view works with two selected sessions
4. **Phase 4**: Submit a prompt from the UI, watch iterations stream in live, cancel works, re-run works
5. **Phase 5**: Export a session as HTML, open the file standalone in a browser, print preview looks clean

Run `bundle exec rspec` after each phase to ensure no regressions in existing tests. Add new specs for `SessionLoader`, `AnalyticsService`, `QueryService`.

---

## Key Files to Modify

| File | Change |
|------|--------|
| `viewer.rb` | Replace with thin launcher |
| `rubyrlm.gemspec` | Add sinatra/puma/rackup as `add_dependency` |
| `lib/rubyrlm/client.rb:94` | Add `usage: response[:usage]` to iteration_data |
| `lib/rubyrlm.rb` | Add `require "rubyrlm/web/app"` |
