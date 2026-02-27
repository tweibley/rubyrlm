# Docker-Based Isolated REPL Backend

## Context

RubyRLM executes LLM-generated Ruby code via `LocalRepl`, which uses `instance_eval` directly in the host process — no process, filesystem, or network isolation. The README explicitly warns against production use without Docker sandboxing. This plan adds a `DockerRepl` class that runs code inside a Docker container while preserving the same interface (`execute(code) → ExecutionResult`), enabling safe execution of untrusted prompts.

## Architecture

`DockerRepl` implements the same duck-type interface as `LocalRepl`. One Docker container lives per REPL session (persists across `execute()` calls within a single completion). Communication uses **newline-delimited JSON over TCP** — the container runs a small agent script that listens on a fixed port, the host connects via a Docker-mapped ephemeral port.

Host-dependent helpers (`llm_query`, `patch_file`, `grep`) are served via RPC callbacks over the same TCP connection. Container-local helpers (`sh`, `chunk_text`) run inside the container. `fetch` is proxied through the host by default (since `--network none`), but can run container-locally when `allow_network: true` is set.

```
Host Process                          Docker Container
┌──────────────┐    TCP (JSON-RPC)    ┌──────────────┐
│  DockerRepl   │◄──────────────────►│   agent.rb    │
│  - execute()  │   port 0:9867       │  - eval code  │
│  - RPC server │                     │  - sh, chunk  │
│  - shutdown() │                     │  - RPC calls  │
└──────────────┘                      └──────────────┘
```

## Implementation Steps

### 1. Create protocol module
**New file:** `lib/rubyrlm/repl/docker_repl/protocol.rb`

Shared constants (`CONTAINER_PORT = 9867`) and helpers for encoding/decoding newline-delimited JSON messages. Message types:
- `execute` — host sends code, container returns result
- `init` — host sends serialized context
- `host_rpc` — container requests host-side helper dispatch

### 2. Create container manager
**New file:** `lib/rubyrlm/repl/docker_repl/container_manager.rb`

Manages Docker container lifecycle via `docker` CLI (no gem dependency). Methods: `start!`, `stop!`, `running?`. Handles:
- `docker create` with `--memory 256m`, `--cpu-quota 50000`, `--network none`, `--read-only`, `--tmpfs /tmp:rw,noexec,size=64m`, `--publish 0:9867`, `--rm`
- Port discovery via `docker port`
- Verification via `docker info` with clear error if Docker unavailable
- Force-kill fallback on stop failure

### 3. Create host RPC server
**New file:** `lib/rubyrlm/repl/docker_repl/host_rpc_server.rb`

Dispatches RPC callback requests from the container. Routes:
| Helper | Runs on | Reason |
|---|---|---|
| `llm_query` | Host | Needs Client's backend, API keys |
| `patch_file` | Host | Writes to workspace filesystem |
| `grep` | Host | Reads workspace via ripgrep |
| `fetch` | Host (default) | Preserves network isolation |
| `context` | Host | Context data lives on host |
| `sh` | Container | Should run sandboxed |
| `chunk_text` | Container | Pure computation |

Reuses `patch_file_safely` and `grep_codebase` logic from `LocalRepl`.

### 4. Create DockerRepl main class
**New file:** `lib/rubyrlm/repl/docker_repl.rb`

Constructor: `new(context:, llm_query_proc:, timeout_seconds:, **options)` — same as `LocalRepl` plus Docker options via splat.

Key methods:
- `execute(code)` — lazily starts container, sends code over TCP, handles interleaved RPC callbacks, returns `ExecutionResult`
- `shutdown` — closes socket, stops container
- `ensure_started!` — starts container, connects TCP, sends initial context

Timeout enforcement: tracks a deadline per `execute()` call; returns timeout `ExecutionResult` if exceeded.

Error handling: catches `ReplError`, `IOError`, `Errno::ECONNRESET` and returns `ExecutionResult(ok: false)` — the Client's iteration loop sees it as a failed execution and the LLM can react.

### 5. Create Dockerfile and container agent
**New file:** `docker/Dockerfile.repl`
- Base: `ruby:3.3-slim`
- Non-root `agent` user
- Copies only `agent.rb` — no gems, stdlib only
- `EXPOSE 9867`, `CMD ["ruby", "/home/agent/agent.rb"]`

**New file:** `docker/agent.rb`
- TCP server on port 9867, accepts single connection
- Handles `init` (stores context) and `execute` (evals code via `instance_eval`, captures stdout/stderr)
- Sends `host_rpc` requests for host-dependent helpers, blocks until response
- Implements `sh` and `chunk_text` locally (mirrors `LocalRepl` logic)

### 6. Modify Client to support Docker environment
**Modify:** `lib/rubyrlm/client.rb`

- `validate_config!` (line 161): accept `"docker"` in addition to `"local"`, add `validate_docker_options!` for Docker-specific option validation
- `build_repl` (line 180): `case @environment` dispatching to `LocalRepl` or `DockerRepl`
- `completion` method: wrap iteration loop in `begin/ensure` block calling `repl.shutdown if repl.respond_to?(:shutdown)` for container cleanup

### 7. Add require to module entry point
**Modify:** `lib/rubyrlm.rb`

Add: `require_relative "rubyrlm/repl/docker_repl"`

### 8. Wire Docker through web layer
**Modify:** `lib/rubyrlm/web/services/query_service.rb`

Add `environment:` and `environment_options:` parameters to `start_run`, pass through to `Client.new`.

**Modify:** `lib/rubyrlm/web/routes/sse.rb`

Extract `environment` and `environment_options` from request body, pass to `query_service.start_run`.

### 9. Write tests

**New file:** `spec/docker_repl_spec.rb` — Unit tests with mocked `ContainerManager` and TCP socket. Tests: protocol encoding/decoding, execute sends correct message and parses result, RPC callback dispatch, timeout handling, shutdown calls container stop, connection failure returns error result.

**New file:** `spec/docker_repl_integration_spec.rb` — Tagged `:docker`, skipped unless `ENV["DOCKER_TESTS"]`. Builds image, tests real execution, RPC callbacks, error handling, and cleanup. Add filter to `spec/spec_helper.rb`.

**Modify:** `spec/client_spec.rb` — Add tests for `environment: "docker"` selecting `DockerRepl` (mocked), invalid environment raising `ConfigurationError`.

## Configuration Schema

When `environment: "docker"`, `environment_options` accepts:

| Key | Default | Description |
|---|---|---|
| `image` | `"rubyrlm/repl:latest"` | Docker image name |
| `memory_limit` | `"256m"` | Container memory limit |
| `cpu_quota` | `50000` | CPU microseconds per 100ms (50% of one core) |
| `network_mode` | `"none"` | `"none"` for isolation, `"bridge"` for outbound |
| `allow_network` | `false` | Shorthand: sets `network_mode` to `"bridge"` |
| `connect_timeout` | `10` | Seconds to wait for container agent readiness |

Example:
```ruby
RubyRLM::Client.new(
  backend: "gemini",
  model_name: "gemini-3.1-pro-preview",
  environment: "docker",
  environment_options: { memory_limit: "512m", allow_network: true }
)
```

## Key Files

| File | Action |
|---|---|
| `lib/rubyrlm/repl/docker_repl.rb` | Create |
| `lib/rubyrlm/repl/docker_repl/protocol.rb` | Create |
| `lib/rubyrlm/repl/docker_repl/container_manager.rb` | Create |
| `lib/rubyrlm/repl/docker_repl/host_rpc_server.rb` | Create |
| `docker/Dockerfile.repl` | Create |
| `docker/agent.rb` | Create |
| `lib/rubyrlm/client.rb` | Modify (lines 161, 180, ~154) |
| `lib/rubyrlm.rb` | Modify (add require) |
| `lib/rubyrlm/web/services/query_service.rb` | Modify (add params) |
| `lib/rubyrlm/web/routes/sse.rb` | Modify (add params) |
| `spec/docker_repl_spec.rb` | Create |
| `spec/docker_repl_integration_spec.rb` | Create |
| `spec/client_spec.rb` | Modify |
| `spec/spec_helper.rb` | Modify (add docker filter) |

## Verification

1. **Unit tests:** `bundle exec rspec spec/docker_repl_spec.rb` — no Docker required
2. **Build image:** `docker build -t rubyrlm/repl:latest -f docker/Dockerfile.repl docker/`
3. **Integration tests:** `DOCKER_TESTS=1 bundle exec rspec spec/docker_repl_integration_spec.rb`
4. **Full suite:** `bundle exec rspec` — existing tests pass, Docker tests skipped by default
5. **Manual smoke test:** IRB session creating a Client with `environment: "docker"` and running a completion
6. **Web UI test:** Start web server, submit a query with Docker environment enabled, verify SSE streaming works end-to-end
