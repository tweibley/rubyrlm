# Cross-Model Routing

## Status: Planned

## Context

Different subtasks have different complexity profiles. Using the same expensive model for everything is wasteful — exploration subcalls, simple lookups, and summarization don't need the strongest model. Slate found that using different models across threads works well because episode boundaries act as clean handoffs. RubyRLM already supports per-subcall `model_name` in `llm_query`, but it's not ergonomic or well-documented as a first-class feature.

## Problem

The `model_name:` parameter on `llm_query` exists but:
1. It's not documented in the system prompt shown to the model
2. There's no default routing heuristic
3. The model has to explicitly choose a model name (which it may not know)
4. Cost savings are not surfaced

## Architecture

### Phase 1: Documentation & Defaults

Make the system prompt aware of available models and their cost/capability profiles:

```
llm_query(sub_prompt, model_name: nil)
  - Available models (cheapest to most capable):
    - "gemini-2.0-flash-lite" — fast, cheap, good for simple lookups
    - "gemini-2.5-flash" — balanced, good for most tasks
    - "gemini-2.5-pro" — strongest, use for complex reasoning
  - Default: uses the same model as the parent
  - Tip: use a cheaper model for data extraction and summarization
```

### Phase 2: Automatic Routing Heuristic (Optional)

Add a `subcall_model:` config option that sets the default model for `llm_query` subcalls when the caller doesn't specify one:

```ruby
RubyRLM::Client.new(
  model_name: "gemini-2.5-pro",           # main loop model
  subcall_model: "gemini-2.5-flash",       # default for llm_query subcalls
)
```

This lets users run the main reasoning loop on a strong model while automatically routing subcalls to a cheaper one.

## Implementation Steps

### 1. Update system prompt
Add model roster and routing guidance to `SystemPrompt.build`. The available models can be derived from the `Pricing::RATES` table.

### 2. Add `subcall_model` config option
New keyword arg on `Client#initialize`. When set, `llm_query` uses it as the default model instead of `@model_name` when `model_name:` is not explicitly provided by the caller.

### 3. Surface per-model costs in metadata
Extend `UsageSummary` to track usage per-model (not just aggregate). This lets users see the cost breakdown between main loop and subcalls.

### 4. Tests
- System prompt includes model roster
- `subcall_model` routes subcalls to specified model
- Per-model cost breakdown in usage summary

## Files to Modify

| File | Change |
|------|--------|
| `lib/rubyrlm/prompts/system_prompt.rb` | Add model roster and routing guidance |
| `lib/rubyrlm/client.rb` | Add `subcall_model:` config, use in `llm_query` default |
| `lib/rubyrlm/completion.rb` | Optional: per-model usage tracking in `UsageSummary` |
| `lib/rubyrlm/pricing.rb` | Expose model list for system prompt generation |
| `spec/client_spec.rb` | New routing tests |

## Dependencies

- None (independent of other improvements)
