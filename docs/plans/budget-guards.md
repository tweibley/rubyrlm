# Budget Guards

## Status: Implemented

## Context

RubyRLM's `max_depth` setting limits recursion depth but doesn't guard against breadth explosion (many subcalls at the same depth) or runaway cost. A single completion can spawn many `llm_query` calls, each spawning their own child completions, with no aggregate limit on total subcalls, tokens, or USD spend. Slate emphasizes that "given an interface that offers unbounded decomposition, the harness needs an underlying guard against over-decomposition."

## Problem

```ruby
# Model can do this without any guard:
100.times { |i| llm_query("Analyze item #{i}") }
# → 100 child completions, each potentially running 30 iterations
```

No budget enforcement exists for:
- Total subcall count across the recursion tree
- Cumulative token usage
- Cumulative USD cost

## Architecture

Add a shared `BudgetTracker` that is threaded through the recursion tree. The tracker is created by the root client and passed to all children. Each `llm_query` call checks the budget before proceeding. When a budget is exceeded, the subcall returns a budget-exceeded message instead of making the LLM call.

```ruby
RubyRLM::Client.new(
  budget: {
    max_subcalls: 20,           # total llm_query calls across entire tree (default: nil = unlimited)
    max_total_tokens: 500_000,  # cumulative tokens across all LLM calls (default: nil)
    max_cost_usd: 1.00          # cumulative USD spend (default: nil)
  }
)
```

## Implementation Steps

### 1. Create `BudgetTracker` class
New file: `lib/rubyrlm/budget_tracker.rb`

Thread-safe (Mutex-protected) tracker with:
- `check_subcall!` — increments subcall count, raises `BudgetExceededError` if over limit
- `add_usage(tokens:, cost:)` — accumulates usage, raises if over limit
- `stats` — returns `{ subcalls:, total_tokens:, total_cost:, limits: }`

### 2. Thread through recursion tree
Root client creates `BudgetTracker` from the `budget:` config hash. Child clients receive the same tracker instance (shared reference). The tracker is passed alongside `parent_run_id` in `llm_query`'s child client construction.

### 3. Check budget before subcalls
In `Client#llm_query`, call `@budget_tracker.check_subcall!` before creating a child client or making a single-shot fallback call.

### 4. Track usage against budget
After each `UsageSummary#add` call, forward the usage delta to `@budget_tracker.add_usage(...)`.

### 5. Surface in CompletionResult
Add `metadata[:budget]` with the tracker's stats. This lets callers see how much of the budget was consumed.

### 6. Graceful degradation
When budget is exceeded mid-completion, `llm_query` returns a string like `"[Budget exceeded: max_subcalls limit of 20 reached]"` instead of raising. The model can then decide how to proceed (e.g., use cached results, finalize with partial data).

### 7. Tests
- Budget tracker unit tests (counting, limits, thread safety)
- Integration: subcall count limit stops further subcalls
- Integration: cost limit stops further subcalls
- Budget stats in metadata

## Files to Create/Modify

| File | Change |
|------|--------|
| `lib/rubyrlm/budget_tracker.rb` | New — thread-safe budget tracking |
| `lib/rubyrlm/errors.rb` | Add `BudgetExceededError < Error` |
| `lib/rubyrlm/client.rb` | Add `budget:` config, thread tracker through tree, check before subcalls |
| `lib/rubyrlm.rb` | Add require |
| `spec/budget_tracker_spec.rb` | New — unit tests |
| `spec/client_spec.rb` | Integration tests |

## Dependencies

- None (independent of other improvements)
- Pairs well with cross-model routing (cheaper models help stay within budget)
