# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-03-12

### Added
- Core RLM client with Gemini backend, multi-turn conversation, and streaming support
- Local and Docker-isolated REPL runtimes with configurable execution timeout
- AST-based code validation (Ripper syntax checking + dangerous call detection)
- Sub-call caching with SHA256-keyed deduplication for `llm_query`
- Patch tracking with undo support (`undo_last_patch` / `undo_all_patches`)
- Per-model USD cost tracking with cache-aware billing
- Shared backend client for child RLMs to reduce per-subcall overhead
- Web UI with session management, streaming timeline, and Mermaid diagram rendering
- Theme-aware HTML and PNG exports with glassmorphism styling
- Session continuation and Controller view with inline prompt
- Time-scoped filtering and cache tracking in analytics dashboard
- Docker session reuse and keep-alive configuration options
- LocalRepl helper primitives for common agent workflows
- JSONL structured logging
- `rlm` CLI executable
- Custom Night Owl syntax highlighting theme

### Fixed
- Docker container DNS resolution and `network_mode` wiring
- Docker agent symbol/string key mismatch for `allow_network`
- Session continuation logic and UI display
- Kramdown rendering with GFM parser dependency
- CSS specificity for headless Chrome export rendering
- UI pivot masking during live stream execution tracking
- Cache-busting for static assets
