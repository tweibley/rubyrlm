# Gemini Multi-Turn + Streaming Support

## Context

The current `gemini_rest.rb` backend has two issues:
1. **Broken multi-turn** — `build_payload` concatenates all messages into a single `USER:` / `ASSISTANT:` text blob in one `contents` entry. Gemini can't distinguish turns, degrading response quality especially for continuations.
2. **No streaming** — Uses `:generateContent` (blocking). The user sees nothing until the full LLM response arrives. Should use `:streamGenerateContent?alt=sse` to stream tokens in real-time.

## Changes

### 1. Fix multi-turn format (`lib/rubyrlm/backends/gemini_rest.rb`)

Replace `build_payload` to properly structure the `contents` array:
- Extract system messages → `systemInstruction.parts[{text}]`
- Map remaining messages to `contents[]` with alternating roles:
  - `role: "user"` → `role: "user"`, `parts: [{text: content}]`
  - `role: "assistant"` → `role: "model"`, `parts: [{text: content}]`
- Gemini requires first content to be `user` role — merge consecutive same-role messages if needed

### 2. Add streaming to GeminiRest (`lib/rubyrlm/backends/gemini_rest.rb`)

Add `stream_complete(messages:, generation_config:, &block)`:
- Uses `streamGenerateContent?alt=sse` endpoint
- Reads response body incrementally with `Net::HTTP#request` + block
- Parses SSE `data: {...}` lines, extracts text from `candidates[0].content.parts`
- Yields `{type: "chunk", text:, accumulated:}` for each chunk
- Yields `{type: "done", text:, usage:, latency_s:}` at end
- Keep existing `complete()` unchanged for backward compat

### 3. Wire streaming through Client (`lib/rubyrlm/client.rb`)

- Add `streaming: false` parameter to constructor
- In `request_action`: if `streaming && backend responds to stream_complete`, use it
- On each chunk, call `log_event(type: "chunk", run_id:, iteration:, text:)`
- Accumulate chunks, parse final action from full text as before
- Repair flow stays blocking (rare path, not worth streaming)

### 4. Enable streaming for web queries (`lib/rubyrlm/web/services/query_service.rb`)

- Pass `streaming: true` when creating Client (since web UI benefits from it)
- No other changes — StreamingLogger already pushes all events to the queue

### 5. Handle chunk events in browser

**`lib/rubyrlm/web/public/js/lib/sse-client.js`:**
- Add `addEventListener('chunk', ...)` → calls `handlers.onChunk`

**`lib/rubyrlm/web/public/js/components/query-panel.js`:**
- Add `onChunk: (event) => this.onChunk(event)` in SSE handler setup
- `onChunk(data)`: create/update a streaming card showing partial text being typed
- When `onIteration` fires, replace the streaming card with the final iteration card

**`lib/rubyrlm/web/public/js/app.js`** (ContinuePrompt):
- Same pattern: add `onChunk` handler in the SSE setup for continuations

### 6. Update tests (`spec/gemini_rest_spec.rb`, `spec/client_spec.rb`)

- Update payload assertions to expect proper `contents[]` array with `user`/`model` roles
- Test system instruction extraction
- Update client spec mocks for new payload format

## Files to modify

| File | Change |
|------|--------|
| `lib/rubyrlm/backends/gemini_rest.rb` | Fix `build_payload`, add `stream_complete`, add `stream_uri` |
| `lib/rubyrlm/client.rb` | Add `streaming` param, conditional `stream_complete` call, emit chunk events |
| `lib/rubyrlm/web/services/query_service.rb` | Pass `streaming: true` to Client |
| `lib/rubyrlm/web/public/js/lib/sse-client.js` | Add chunk event listener |
| `lib/rubyrlm/web/public/js/components/query-panel.js` | Add `onChunk` handler, streaming card |
| `lib/rubyrlm/web/public/js/app.js` | Add `onChunk` in ContinuePrompt SSE setup |
| `spec/gemini_rest_spec.rb` | Update payload expectations |
| `spec/client_spec.rb` | Update mock expectations for new payload format |

## Verification

1. `bundle exec rspec` — all tests pass with new payload format
2. Start server, submit a query — tokens stream in real-time
3. Use Continue on a session — multi-turn means the LLM understands context properly
4. Check JSONL logs — chunk events appear alongside iteration events

## Outcome

**Status: Implemented** (2026-02-27)

All 6 planned changes were implemented across 10 files. 30 tests pass (up from 20).

### What was built

- **Multi-turn fix** — `build_payload` now produces proper Gemini `contents[]` array with `user`/`model` roles instead of a single concatenated text blob
- **Streaming** — `stream_complete` method using `streamGenerateContent?alt=sse` with SSE line parsing and incremental `Net::HTTP` body reading
- **End-to-end pipeline** — Chunks flow: Gemini → `stream_complete` yield → Client `log_event` → StreamingLogger → Queue → SSE route → browser EventSource → streaming card UI
- **Streaming UI** — "THINKING" card with animated dots shows partial LLM text, replaced by final iteration card on `onIteration`
- **All Gemini calls stream** — Main loop, subcalls via `llm_query`, and depth-limit fallback all use `stream_complete` when available

### Additional fixes from quality review

1. Stream error body was unreadable (`response.body` nil in streaming mode) — now reads explicitly
2. `run_end` terminal event detection used wrong key type (string vs symbol) — fixed
3. `BackendError` during streaming could double-count usage tokens — scoped rescue tightly
4. Buffered chunk events could create orphaned streaming cards after disconnect — added guard
5. `ContinuePrompt.onComplete` used stale session data — now reloads from API
6. `@active_runs` hash lacked thread safety — added Mutex

### Files modified

| File | Change |
|------|--------|
| `lib/rubyrlm/backends/gemini_rest.rb` | Fixed `build_payload`, added `stream_complete` + `stream_uri` |
| `lib/rubyrlm/client.rb` | Added `streaming` param, split `request_action` into streaming/blocking with fallback |
| `lib/rubyrlm/web/services/query_service.rb` | `streaming: true`, fixed terminal event key, added Mutex |
| `lib/rubyrlm/web/public/js/lib/sse-client.js` | Added `chunk` event listener |
| `lib/rubyrlm/web/public/js/components/timeline.js` | Added `buildStreamingCard()` |
| `lib/rubyrlm/web/public/js/components/query-panel.js` | Added `onChunk` handler with streaming card |
| `lib/rubyrlm/web/public/js/app.js` | Added chunk handling to ContinuePrompt, fixed stale session reload |
| `lib/rubyrlm/web/public/css/components.css` | Added streaming card styles with animations |
| `spec/gemini_rest_spec.rb` | Added `build_payload` shape tests, `stream_complete` tests |
| `spec/client_spec.rb` | Added streaming and fallback tests |
