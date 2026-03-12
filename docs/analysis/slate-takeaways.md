# Slate Architecture Analysis — Takeaways for RubyRLM

**Source:** https://randomlabs.ai/blog/slate (2026-03-09, Random Labs Team)
**Date:** 2026-03-12

## Overview

Slate introduces a "thread weaving" agent architecture that moves beyond ReAct and
vanilla RLM by solving five compounding problems: working memory management, strategic
coherence, expressivity, task decomposition, and synchronization between isolated
execution contexts.

RubyRLM already implements the RLM paradigm that Slate builds upon. This analysis
identifies concrete improvements inspired by Slate's architecture.

---

## 1. Context Compaction

**Problem:** Models cannot attend uniformly across their context window. As context
grows, a "Dumb Zone" emerges where retrieval quality degrades. RubyRLM currently uses a
hard `max_messages: 50` cap with no compression strategy.

**Slate's approach:** Episode boundaries provide natural compaction points. Each thread
action generates a compressed representation of its step history, retaining only
important results rather than the full tactical trace.

**Proposed improvement:** Implement episode-style compression — when message history
approaches the limit, compress older iterations into a structured summary rather than
truncating. This preserves strategic context while freeing working memory.

**Effort:** Medium

---

## 2. Rich Subcall Returns (Episodic Memory)

**Problem:** When `llm_query` spawns a child client at depth>1, the parent receives only
the final answer. It is blind to what the child explored, what it tried, and what
failed. Slate calls this "blind N-step execution."

**Slate's approach:** Each thread action produces an "episode" — a compressed summary of
what happened, not just the result. Episodes are composable: one thread's episode can
become another thread's input context.

**Proposed improvement:** Extend `llm_query` to return richer metadata alongside the
answer — a compressed summary of the child's exploration path, key findings, and
failures encountered. This lets the parent model course-correct.

**Effort:** Medium

---

## 3. Parallel Subcall Dispatch

**Problem:** RubyRLM executes `llm_query` subcalls sequentially. Real software tasks
decompose naturally into parallel workstreams. Sequential execution limits throughput.

**Slate's approach:** The orchestrator can dispatch several threads simultaneously and
synthesize their episodes before continuing. Slate found this to be qualitatively
different from sequential step-by-step agents and faster in practice.

**Proposed improvement:** Add a `parallel_queries` helper (or similar) to the REPL that
dispatches multiple `llm_query` calls concurrently and returns all results. Leverage
Ruby's threading or async primitives.

**Effort:** Medium

---

## 4. Cross-Model Routing

**Problem:** Different subtasks have different complexity profiles. Using the same model
for everything is wasteful — exploration subcalls don't need the strongest model.

**Slate's observation:** Using different models (e.g., Sonnet + Codex) across threads
works well because episode boundaries act as clean handoffs with no loss of context
coherence.

**Proposed improvement:** Promote per-subcall `model_name` in `llm_query` as a
first-class feature. Consider adding a default routing heuristic — e.g., use a
cheaper/faster model for exploration and a stronger model for the main loop. The
`model_name` parameter already exists; this is about documentation, defaults, and
making it ergonomic.

**Effort:** Low

---

## 5. Budget Guards

**Problem:** Unbounded recursion leads to over-decomposition. RubyRLM's `max_depth`
setting limits recursion depth but doesn't guard against breadth explosion (many
subcalls at the same depth) or runaway cost.

**Slate's observation:** Given an interface that offers unbounded decomposition, the
harness needs an underlying guard against over-decomposition.

**Proposed improvement:** Add aggregate budget controls across the recursion tree:
total subcall count limit, cumulative cost ceiling (USD), and cumulative token limit.
Surface these in `CompletionResult` metadata alongside existing cache stats.

**Effort:** Low

---

## Validation of Existing RubyRLM Design

Slate's analysis also validates several design choices already present in RubyRLM:

- **Ruby REPL as interface:** Slate emphasizes that model inductive bias toward the
  interface determines effectiveness. Ruby is expressive and well-represented in
  training data.
- **REPL helpers:** `fetch`, `sh`, `grep`, `patch_file`, `chunk_text` give the model a
  powerful, familiar toolkit — exactly the kind of high-expressivity interface Slate
  advocates.
- **Depth limiting:** `max_depth` is the right primitive for guarding against
  over-decomposition.
- **Sub-call caching:** `SubCallCache` with SHA256 deduplication prevents redundant work
  across the recursion tree.
- **Per-subcall model selection:** The `model_name` parameter on `llm_query` already
  enables cross-model composition.

---

## Priority

| # | Improvement | Effort | Impact |
|---|-------------|--------|--------|
| 1 | Context compaction | Medium | High — unlocks longer tasks |
| 2 | Rich subcall returns | Medium | High — enables parent adaptation |
| 3 | Parallel subcall dispatch | Medium | Medium — throughput gains |
| 4 | Cross-model routing | Low | Medium — cost efficiency |
| 5 | Budget guards | Low | Medium — safety/predictability |
