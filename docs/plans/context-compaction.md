# Context Compaction (Episode-Style Compression)

## Status: Implemented

## Context

Models cannot attend uniformly across their context window — a "Dumb Zone" emerges where retrieval quality degrades as context grows. RubyRLM previously used a hard `max_messages: 50` cap with a sliding-window truncation strategy that simply dropped the oldest messages. This lost strategic context (what was tried, what worked, key findings) without replacement.

Inspired by Slate's episode-based architecture (Random Labs, 2026-03-09), this feature adds LLM-powered compression of older messages before they would otherwise be silently dropped.

## Architecture

Extracted into a dedicated `Compaction::MessageCompactor` class injected into `Client`. When the message array exceeds a configurable threshold (default 70% of `max_messages`), all messages between the two pinned messages (system + initial user) are compressed into a single summary using a cheap/fast Gemini model (`gemini-2.0-flash-lite` by default). The summary replaces the dropped messages at index 2. Hard truncation still runs as a safety net after compaction.

```
completion loop iteration N
  → append assistant + user messages
  → maybe_compact_and_truncate!(messages, metadata, usage_summary)
      → @compactor.maybe_compact!(messages)
          → if threshold crossed: call compaction LLM, replace middle with summary
      → truncate_messages!(messages)  # safety net, usually no-op after compaction
```

## Files Changed

| File | Change |
|------|--------|
| `lib/rubyrlm/compaction/message_compactor.rb` | New — `MessageCompactor` class with `maybe_compact!`, `Result` struct, lazy backend |
| `lib/rubyrlm/prompts/compaction_prompt.rb` | New — system/user prompts for the compaction LLM call |
| `lib/rubyrlm/client.rb` | Added compaction config kwargs, `maybe_compact_and_truncate!`, wiring |
| `lib/rubyrlm/errors.rb` | Added `CompactionError < Error` |
| `lib/rubyrlm.rb` | Added requires |
| `spec/compaction/message_compactor_spec.rb` | New — 8 unit tests |
| `spec/client_spec.rb` | Added 4 integration tests |

## Configuration

```ruby
RubyRLM::Client.new(
  compaction: true,                          # enable/disable (default: true)
  compaction_threshold: 0.7,                 # fraction of max_messages that triggers (default: 0.7)
  compaction_model: "gemini-2.0-flash-lite", # model for summarization (default)
  # ... existing options
)
```

## Metadata

Compaction events are tracked in `CompletionResult#metadata[:compaction_events]`:
```ruby
[{ messages_before: 35, messages_after: 3, latency_s: 1.2, model: "gemini-2.0-flash-lite" }]
```
