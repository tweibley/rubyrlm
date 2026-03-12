# Parallel Subcall Dispatch

## Status: Implemented

## Context

RubyRLM executes `llm_query` subcalls sequentially. Real software tasks decompose naturally into parallel workstreams — e.g., analyzing multiple files, summarizing multiple chunks, or querying different aspects of a problem simultaneously. Sequential execution limits throughput. Slate found that parallel dispatch is "qualitatively different from sequential step-by-step agents and faster in practice."

## Problem

```ruby
# Current: sequential, blocking
summary_a = llm_query("Summarize section A")
summary_b = llm_query("Summarize section B")  # waits for A to finish
summary_c = llm_query("Summarize section C")  # waits for B to finish
```

## Architecture

Add a `parallel_queries` REPL helper that dispatches multiple `llm_query` calls concurrently using Ruby threads and returns all results.

```ruby
# Proposed API
results = parallel_queries(
  "Summarize section A",
  "Summarize section B",
  "Summarize section C"
)
# results => ["summary A", "summary B", "summary C"]

# With per-query model override
results = parallel_queries(
  { prompt: "Summarize A", model_name: "gemini-2.5-flash" },
  { prompt: "Analyze B", model_name: "gemini-2.5-pro" }
)
```

## Implementation Steps

### 1. Add `parallel_queries` to `LocalRepl`
New helper method installed on the REPL host object alongside `llm_query`, `fetch`, etc.

```ruby
def parallel_queries(*queries)
  threads = queries.map do |q|
    prompt, model = q.is_a?(Hash) ? [q[:prompt], q[:model_name]] : [q, nil]
    Thread.new { llm_query(prompt, model_name: model) }
  end
  threads.map(&:value)
end
```

### 2. Thread safety for `SubCallCache`
`SubCallCache` uses a plain Hash. Add a `Mutex` around `get` and `put` to prevent data races when multiple threads access it concurrently.

### 3. Thread safety for `UsageSummary`
If compaction usage is tracked during parallel calls, `UsageSummary#add` needs a mutex. However, since child clients have their own `UsageSummary`, the parent's accumulator is not accessed from child threads. Verify this is the case.

### 4. Add to `DockerRepl`
The Docker REPL's RPC protocol would need to support `parallel_queries` as a new message type, or the container-side agent could implement it using threads internally.

### 5. Update system prompt
Document `parallel_queries` in `SystemPrompt.build` alongside the existing helper documentation.

### 6. Concurrency limit
Add an optional `max_concurrency:` parameter (default: 5) to prevent the model from spawning excessive threads.

### 7. Tests
- Unit test: parallel_queries returns results in order
- Unit test: SubCallCache is thread-safe
- Integration test: concurrent subcalls complete successfully
- Edge case: one query fails, others succeed (return errors inline)

## Files to Modify

| File | Change |
|------|--------|
| `lib/rubyrlm/repl/local_repl.rb` | Add `parallel_queries` helper |
| `lib/rubyrlm/sub_call_cache.rb` | Add mutex for thread safety |
| `lib/rubyrlm/prompts/system_prompt.rb` | Document new helper |
| `lib/rubyrlm/repl/docker_repl.rb` | Support parallel dispatch in RPC |
| `spec/local_repl_spec.rb` | New tests |
| `spec/sub_call_cache_spec.rb` | Thread safety tests |

## Dependencies

- None (independent of compaction)
