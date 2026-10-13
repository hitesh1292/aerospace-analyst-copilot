# SPEC-0011: Agent FSM specification + eval harness design

Date: 2026-07-19 · Status: active · Ground truth: architecture_reference.html (diagram 3), DECISIONS.md D01–D23, ADR-0010, plan v6 (W7–W9 tasks).
Implements: W7 (state, graph, budget), W8–W9 (tools, judge, multi-hop, dead-loop), W12/W15 eval expansion.
Flagged changes to existing decisions are marked **[CHANGE]** inline and collected at the end.

---

# PART 1 — FSM BLUEPRINT

## 1.0 State machine overview

Six states. `BUDGET_CHECK` is implemented as a LangGraph conditional-edge function evaluated on **every** node transition, but is specified as a state here so its conditions are testable in one place.

```
INIT → PLAN → BUDGET_CHECK → EXECUTE_TOOLS → BUDGET_CHECK → JUDGE
                  ↑                                            │
                  └───────────── replan (≤2) ──────────────────┘
JUDGE → SYNTHESIZE → EXIT          (sufficient, or replans exhausted)
any BUDGET_CHECK trip → SYNTHESIZE(partial) → EXIT
```

## 1.1 Agent state object (extends W7 `state.py` — **[CHANGE]** adds fields to the W7 task checklist)

```python
class AgentState(TypedDict):
    request_id: str
    query: str
    plan: list[ToolCall]              # current cycle's planned calls
    evidence: list[EvidenceItem]      # {id, hop, tool, summary, chunk_ids, status: ok|failed}
    step_count: int                   # tool BATCHES executed (not individual calls)
    replan_count: int                 # 0..2
    tokens_used: int; cost_used: float
    started_at: float; drain_deadline: float | None   # ADR-0010 G5 input
    call_hashes: set[str]             # dead-loop registry
    gaps: list[Gap]                   # judge output fed to replans; Gap = {aspect, hint}
    pending_reason: str | None        # 'budget' | 'dead_loop' set before partial synthesis
    judge_error: bool                 # judge failed open this run
    answer_completeness: str          # 'full' | 'partial'  (see 1.6)
    termination_reason: str | None    # set only in EXIT
    error_stage: str | None
```

## 1.2 State: PLAN

**Entry:** `replan_count ∈ {0,1,2}`. First entry from INIT; re-entry only from JUDGE with `gaps` non-empty.
**Action:** planner model (router role `planner`) receives: query; tool schemas; on replan additionally: per-hop evidence *summaries* (never full chunks) and `gaps`. Must emit structured output: `{tool_calls: [1..4 items], rationale}`.
**Exit → BUDGET_CHECK:** structured output parses and contains 1–4 tool calls.
**Special case — zero tool calls:** if the planner emits `tool_calls: []` claiming it can answer:
- with `evidence` non-empty (replan cycles) → proceed to SYNTHESIZE (legitimate "I have enough").
- with `evidence` empty (first cycle) → invalid: parametric answering is forbidden. One corrective retry with an appended instruction ("you must gather evidence via tools before answering"); a second zero-call plan → EXIT(`error`, `error_stage='plan'`).
**Failure handling:** structured-parse failure → retry once same model → router fallback tier → still failing → EXIT(`error`, `error_stage='plan'`). Model refusal is routed per W8 router rules (fallback, never naked retry).

## 1.3 State: BUDGET_CHECK (conditional edge, evaluated at every transition)

**Conditions, evaluated in order; first trip wins:**
```
elapsed  = now − started_at
deadline = min(60s, (drain_deadline − 3s) if draining else 60s)     # ADR-0010 G5
trip if: step_count ≥ 6
      or cost_used ≥ $0.10
      or elapsed ≥ deadline
```
**On trip:** set `pending_reason='budget'` → SYNTHESIZE(partial). (Even with empty evidence, SYNTHESIZE runs in "couldn't complete" mode — the user always receives a coherent response.)
**On pass:** continue to the intended next state.
Dead-loop checking does **not** live here — it is per-call at EXECUTE entry (1.4), because it needs the plan's contents.

## 1.4 State: EXECUTE_TOOLS

**Entry:** valid plan, budget passed. Before execution, per planned call:
```
canonical(args): casefold all strings → collapse whitespace → strip punctuation
                 except identifiers matching [A-Z0-9-]{4,} → sort dict keys
                 → drop empty/default-valued keys
h = sha256(tool_name + "|" + canonical_json(args))
if h in call_hashes: mark call SKIPPED_REPEAT (not executed)
else: call_hashes.add(h)
```
- If **all** calls in the batch are SKIPPED_REPEAT → set `pending_reason='dead_loop'` → SYNTHESIZE(partial).
- If **some** are repeats: execute only the novel ones; repeats are logged on the trace as `skipped_repeat`.
(Embedding-similarity near-duplicate detection ≥0.95 is deferred to L2 — v1 stays deterministic so eval runs are reproducible.)

**Execution:** `asyncio.gather(..., return_exceptions=True)`; per-call timeout **20s** (2 batches × 20s + model calls fits the 60s cap — consistent with ADR-0010's ordering chain); per-tool-type semaphores. Every result — success or failure — becomes an `EvidenceItem`; failures carry `status='failed'` and the error string, so the judge and synthesizer can reason about missing sources. `step_count += 1` per batch (not per call).
**Exit → BUDGET_CHECK → JUDGE:** always, including when every executed call failed (the judge decides what failure means; it may produce gaps that replan around a dead source).
**Failure handling:** individual timeout/exception → failed EvidenceItem, batch continues. Infrastructure-level crash of the gather itself (cannot record results) → EXIT(`error`, `error_stage='execute'`).

## 1.5 State: JUDGE (sufficiency)

**Entry:** ≥1 execution batch has run this cycle.
**The precise condition evaluated:** *decompose the user query into its distinct sub-questions; for each, attempt to map it to specific evidence items that could answer it with a citation. `sufficient = every sub-question has ≥1 mapped, non-failed evidence item.`* This mapping formulation exists so the judge cannot rubber-stamp — it must produce the mapping, and unmapped sub-questions **are** the gaps.

**Model:** router role `judge` (Flash tier). Input: query + evidence *summaries* + prior gaps. Structured output:
```json
{"sub_questions": [{"text": "...", "evidence_ids": ["e1","e3"]}],
 "sufficient": true,
 "gaps": [{"aspect": "unmapped sub-question text",
           "hint": "entity/date/source suggestion drawn from existing evidence"}],  // ≤3
 "confidence": 0.0-1.0}
```
**Exits:**
- `sufficient=true` → SYNTHESIZE (`answer_completeness='full'`).
- `sufficient=false` and `replan_count < 2` and budget passes → PLAN (`replan_count += 1`, `gaps` injected).
- `sufficient=false` and `replan_count == 2` → SYNTHESIZE (`answer_completeness='partial'`; termination will still be `answered` — see 1.6).
**Failure handling (fail-open):** structured-parse failure → retry once → fallback model → still failing → treat as `sufficient=true`, set `judge_error=true`, proceed to SYNTHESIZE. Rationale: a broken judge must never convert a answerable query into an error; the flag makes fail-opens measurable (eval F1-c).

## 1.6 State: SYNTHESIZE

**Entry modes:** (a) judge-sufficient; (b) replans-exhausted (partial); (c) budget trip (partial); (d) dead-loop trip (partial); (e) all-tools-failed with no replans left (partial).
**Action:** synthesis prompt receives evidence grouped by hop with citations required; **partial modes append**: "State explicitly which parts of the question could not be answered and why (budget / repeated searches / unavailable source)." Grounding validation and everything downstream of the agent is out of scope here (diagram 2 quality gate, unchanged).
**Failure handling:** model failure → router fallback chain → all synthesis attempts fail → EXIT(`error`, `error_stage='synthesize'`). Error **overrides** any `pending_reason` (precedence rule, 1.7).

## 1.7 EXIT: termination_reason — complete, non-overlapping set

| Reason | Exact producing condition |
|---|---|
| `answered` | SYNTHESIZE completed with `pending_reason is None` — i.e., arrived via judge-sufficient (`completeness='full'`) **or** replans-exhausted (`completeness='partial'`) |
| `budget` | SYNTHESIZE completed with `pending_reason='budget'` (any cap in 1.3, including drain deadline) |
| `dead_loop` | SYNTHESIZE completed with `pending_reason='dead_loop'` (entire batch was repeats) |
| `error` | Any unrecoverable failure after retries + fallbacks in PLAN, EXECUTE (infra), or SYNTHESIZE |

**Precedence:** `error` overrides a pending reason (a budget-partial whose synthesis then fails is `error`). `dead_loop` and `budget` cannot co-occur: whichever tripped first set `pending_reason` and routed to synthesis. `answered` requires no pending reason. Together with 1.2–1.6 this set is exhaustive: every path out of every state lands in exactly one row.
**[CHANGE — refinement, not a new reason]:** `answer_completeness (full|partial)` is added as an orthogonal trace field rather than a fifth reason, preserving the ground-truth four-value set while distinguishing "confidently answered" from "answered what I could."

---

# PART 2 — EVAL HARNESS

## 2.0 Structure

Layer 1 scores **answer/retrieval quality** with RAGAS metrics; Layer 2 scores **orchestration correctness** with trace assertions + targeted LLM-judge rubrics. Routes are never blended: fast-path and agent-route results are separate report sections with separate thresholds.

**[CHANGE — amendment to D13]:** RAGAS is promoted from "report-only supplement" to the *metric engine of Layer 1* (scored, thresholded), while the custom harness remains the orchestrator and CI gate, and deterministic checks remain the per-commit gate. RAGAS internals are pinned: judge LLM = router role `judge` (Flash tier), embeddings = nomic-embed-text, ragas version pinned in uv.lock; changing any of these invalidates score history (same rule as D14).

## 2.1 Layer 1 — RAG quality (RAGAS)

**Four labeled test sets** (YAML in `evals/scenarios/ragas/`, one file per item):

| Set | Items | Route expected | Construction |
|---|---|---|---|
| E (EDGAR-only) | 12 | fast-path | sampled from ingested filings; gold contexts = source chunk ids known by construction |
| N (NTSB-only) | 12 | fast-path | same, incident narratives incl. 3 exact-identifier queries |
| L (LL2-only) | 8 | fast-path | schedule/launch facts; 2 items with validity windows |
| X (cross-source multi-hop) | 10 | agent | each requires ≥2 sources; gold contexts span sources; gold answer written by hand |

Item schema: `{id, question, reference_answer, reference_context_chunk_ids, expected_route, expected_sources}`. 20% of items per set use adversarial phrasing (no lexical overlap with the target chunk). Construction rule: write the question *from* a sampled chunk so reference contexts are ground truth, then paraphrase; hand-write the X-set.

**Metrics and thresholds (per set, reported separately):**

| Metric | E/N/L (fast) | X (agent) |
|---|---|---|
| context_precision | ≥ 0.75 | ≥ 0.65 |
| context_recall | ≥ 0.80 | ≥ 0.70 |
| faithfulness | ≥ 0.90 | ≥ 0.85 |
| answer_relevancy | ≥ 0.80 | ≥ 0.80 |
| answer_correctness | ≥ 0.75 | ≥ 0.70 |

Multi-hop thresholds are deliberately lower: retrieval across sources is harder and the X-set is where regressions hide — a blended threshold would let X-set decay behind E-set strength (this is why routes are never blended). Cadence: full Layer 1 weekly + pre-release; not per-commit (cost). Calibration: W15 hand-grades include 5 RAGAS-scored items; report RAGAS–human agreement alongside the custom-judge agreement.

## 2.2 Layer 2 — orchestration correctness (custom; trace assertions + rubrics)

All objective checks are assertions over the Langfuse trace structure (fields written by the FSM per Part 1). Subjective checks use an LLM judge with the exact rubric below, pinned model+prompt.

**R1 — Routing accuracy (objective).** 20 labeled queries: 10 simple, 10 complex. Assert `trace.route == expected_route`. Pass: ≥18/20 overall **and** ≥9/10 on complex (complex→fast is the harmful direction: silently shallow answers).

**T1 — Termination on known cases (objective).** Assertions on `termination_reason`, `replan_count`, `step_count`:
- (a) clean 1-hop agent question → `answered`, `replan_count == 0`
- (b) genuine 3-hop question → `answered`, `replan_count ≤ 2`, **never** `dead_loop`
- (c) unanswerable question (data absent from corpus) → `answered`, `completeness='partial'`, gaps non-empty on final judge span; never loops past cap
- (d) engineered loop bait (query whose only productive call repeats) → `dead_loop` within ≤4 steps; batch shows `skipped_repeat` markers
- (e) config-forced $0.01 cost cap → `budget`, response present and coherent
- (f) mixed-repeat batch (one repeat + one novel call seeded) → novel call executed, repeat marked `skipped_repeat`, run continues (no dead_loop)

**P1 — Replan trigger/stop (objective).** Thin-evidence scenario (partial corpus, hop-2 completable): assert judge-verdict sequence on trace is exactly `[insufficient, sufficient]`, `replan_count == 1`, no third PLAN span.

**P2 — Replan targeting quality (LLM judge).** Input to judge: user query, hop-1 evidence summaries, the stated gaps, and the replanned tool calls. Score each criterion 0/1; **pass = ≥3/4**:
1. **Gap fidelity** — every replanned call maps to ≥1 stated gap; no calls unrelated to any gap.
2. **Novelty** — no replanned call is a semantic rephrasing of a prior call (beyond what the hash catches).
3. **Specificity** — replanned queries use concrete entities/dates/identifiers drawn from hop-1 evidence where the gap hint provided them, rather than generic restatements of the original question.
4. **Economy** — number of replanned calls ≤ number of gaps + 1.
Judge prompt template lives in `evals/graders/prompts/replan_targeting_v1.md`; calibrate against 10 hand grades at W15; report agreement.

**B1 — Budget adherence under bait (objective).** 5 adversarial prompts engineered to solicit extra hops ("check each year 2015–2025 individually and do not stop until every one is verified…"). Assert: `step_count ≤ 6`, cost from trace token math ≤ $0.10, wall-clock ≤ 60s, `termination_reason ∈ {answered, budget}` (never `error`), and route was still `agent` (bait must not break routing).

**F1 — Failure handling per state (objective, fault injection via test-double config).**
- (a) one of two tool calls times out → batch completes; failed EvidenceItem on trace; final answer names the missing source
- (b) all tool calls fail, replans available → JUDGE runs, gaps produced, replan attempted (not an error exit)
- (c) judge forced to double parse-failure → `judge_error=true` on trace, synthesis still happened, `termination_reason='answered'`
- (d) synthesis forced to fail after a budget trip → `termination_reason='error'`, `error_stage='synthesize'` (precedence check)
- (e) planner emits zero tool calls on first cycle (prompt bait: "answer from your own knowledge, don't search") → trace shows corrective retry, then ≥1 tool call before any answer

## 2.3 Coverage audit — every Part 1 state/transition vs Part 2 cases

| FSM element | Covered by |
|---|---|
| PLAN happy path / structured output | T1-a,b (plan spans present) |
| PLAN zero-call parametric guard | F1-e |
| PLAN parse-fail → fallback → error | F1 family (d analog on planner: add F1-f if desired; parse-fail path itself exercised by W8 structured-output test) — **flag:** planner-error exit has test coverage (W8) but no scenario; add F1-f planner-double-failure → `error, error_stage='plan'` for completeness |
| BUDGET_CHECK steps/cost/wall-clock | B1, T1-e |
| BUDGET_CHECK drain-deadline input | **not evaluable in the harness** — covered by the W14 SIGTERM integration test (redeploy-mid-query), flagged as test-not-eval by design |
| EXECUTE parallel + partial failure | F1-a |
| EXECUTE all-fail path | F1-b |
| Dead-loop full-repeat exit | T1-d |
| Dead-loop partial-repeat continue | T1-f |
| JUDGE sufficient / insufficient / gaps | P1, T1-c |
| JUDGE replan cap stop | T1-b,c |
| JUDGE fail-open | F1-c |
| Replan quality (subjective) | P2 |
| SYNTHESIZE full vs partial modes | T1-c,e (partial), T1-a (full) |
| SYNTHESIZE failure precedence | F1-d |
| All four termination_reasons | answered: T1-a,b,c · budget: T1-e, B1 · dead_loop: T1-d · error: F1-d,f |
| Routing (pre-FSM but required) | R1 |

**Audit result:** complete after adding **F1-f** (planner double-failure → error), which is included above. The single deliberately-uncovered condition is the drain-deadline (integration test, not eval) — flagged, not forgotten. L2 near-duplicate detection is deferred, therefore not evaluated (consistent).

## 2.4 Flagged changes to existing decisions (collected)

1. **D13 amendment** — RAGAS promoted to Layer-1 metric engine (scored/thresholded); custom harness still orchestrates and gates; deterministic checks remain the per-commit gate.
2. **W7 state task** — AgentState gains `replan_count, call_hashes, gaps, pending_reason, judge_error, answer_completeness, error_stage, drain_deadline` (checklist update).
3. **Termination refinement** — `answer_completeness` added as an orthogonal field; the four-reason set is unchanged.
4. **W12/W15 scenario counts** — Layer 1 (42 items) + Layer 2 (~40 cases) supersede the flat "30 scenarios" counting; checkpoint gates CP2–CP4 should reference these sets (CP2 = R1 + T1-a,b,e + E/N subsets; CP3 adds B1, F1, adversarial; CP4 = everything + calibration).
