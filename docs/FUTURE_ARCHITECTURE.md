# FUTURE_ARCHITECTURE — Phase 2: supervisor + specialist sub-agents (designed, deliberately deferred)

Date: 2026-07-19 · Status: **documented future state — not on the W1–W16 plan** · Ground truth: PROJECT_STATE.md, DECISIONS.md D01–D31, ADR-0010, SPEC-0011, PLAYBOOK.md.

## The judgment call, up front

**Do not build this within the current plan's horizon, and probably not for a long time after.** The honest trigger for a supervisor pattern here is not traffic and never will be — multi-agent adds zero throughput (replicas and admission control do that); it addresses *coordination and context* problems this project does not have at 3 sources and a 6-step budget. The concrete thresholds in §5 — source count ≥5–6, ≥25–30% of agent queries genuinely capacity-bound at the step cap, or measured context-pressure quality decay — are all far from where this system operates, and my own hardening work (D24–D29) explicitly sized everything for tens of queries/day on a CPU-bound single instance, which multi-agent would immediately violate (it triples reranker contention and 2–3.5x's per-query model calls). The only engagement I'd endorse is the already-planned post-v1.0.0 **measured spike**: branch, convert, run the X-set, publish single-vs-multi accuracy/cost/latency, merge nothing. This document's value is the design *plus* the evidence of knowing when not to build it.

## 1 · Current state (one paragraph)

A single bounded agent (SPEC-0011): PLAN emits 1–4 tool calls; BUDGET_CHECK enforces steps ≤6, cost ≤$0.10, wall-clock ≤60s, drain deadline; EXECUTE_TOOLS runs calls in parallel with per-call timeouts, failures-as-evidence, and deterministic dead-loop hashing; a sufficiency JUDGE maps sub-questions to evidence (fails open) and drives ≤2 replans; SYNTHESIZE produces a cited answer in full or partial mode; EXIT names one of four termination reasons. One context window holds everything; the grounding validator sits outside the loop as the safety net.

## 2 · Phase 2 design, state by state

**Primitives assumed:** a lead agent that delegates task briefs to specialist sub-agents (one per source: EDGAR, NTSB, LL2), each with its own context window, its own scoped tools (that source's retrieval + SQL views), and its own small budget; a **shared workspace** (Postgres tables) where sub-agents write structured findings and the lead reads summaries; full parent/child tracing for auditability. This maps naturally onto LangGraph subgraphs (already noted as the W7 L4 item), so D10 holds.

**INIT — unchanged.**

**PLAN → DELEGATE (replaced).** The lead no longer emits tool calls; it emits **sub-agent briefs**: `{sub_agent, task, entities (canonical ids — see reconciliation), expected_output_schema, sub_budget {steps ≤3, cost ≤$0.03, wall_clock ≤25s}}`. The lead's competence shifts from "which tool" to "which specialist, told what, allotted how much" — the judge's sub-question decomposition (D30) becomes load-bearing here, since sub-questions map to briefs.

**BUDGET_CHECK — persists, becomes hierarchical (modified).** Global caps keep their semantics; new: per-sub-agent budgets nest inside them, and cost accounting becomes **concurrent** — spend must be reserved/settled via atomic counters, because three sub-agents spending in parallel can overshoot a cap between checks (a race that cannot occur today).

**EXECUTE_TOOLS → DISPATCH + sub-agent loops (replaced).** Each specialist runs its own mini-FSM (plan→retrieve→summarize, bounded by its sub-budget, with its **own** dead-loop hash registry) and writes findings to the workspace: `{claims[], chunk_ids[], entities_seen[], confidence, status, termination_sub_reason}`. The lead never sees raw chunks — only findings. This is the context-isolation benefit *and* the new trust boundary (§3). Dispatch runs sub-agents as a task group with a straggler deadline and a heartbeat/lease on each (a sub-agent that dies without writing status must not hang the lead).

**NEW STATE: VERIFY.** Because a sub-agent's "status: complete" is otherwise unverifiable, the lead samples each sub-agent's findings — resolve N claimed chunk_ids and check the claim text is plausibly supported (cheap lexical/NLI screen). Fail → treat that sub-agent's findings as suspect: re-dispatch once or mark the source degraded. The terminal grounding validator remains the backstop; VERIFY exists so a fabricating sub-agent is caught before it shapes replanning.

**NEW RESPONSIBILITY: RECONCILE (folded into JUDGE).** Cross-source entity conflicts (EDGAR resolves "RTX" via CIK; NTSB stores operator strings like "Raytheon Technologies Corp"/legacy names) require a canonical entity map (ticker↔CIK↔NTSB operator aliases) maintained in the workspace; the judge flags findings about non-reconciled entities as gaps rather than merging them.

**JUDGE — persists (modified inputs).** Same sub-question→evidence mapping and fail-open semantics (D30 holds), but over workspace findings, plus reconciliation. Replan becomes **re-delegation**: gaps route to the specific sub-agent(s); cap stays 2; a lead-level hash over briefs catches re-delegation loops (§4, D30 impact).

**SYNTHESIZE — persists nearly unchanged.** Input is findings grouped by source and hop; citations stay chunk-level, which imposes a hard rule: **provenance (chunk_ids) must survive every workspace hop** — summaries without chunk_ids are uncitable and therefore worthless.

**EXIT — persists.** The four-reason set holds at the top level; each sub-agent contributes a `termination_sub_reason` vector and a per-source status onto the trace (an extension in the spirit of `answer_completeness`, not a fifth reason).

## 3 · New failure modes (genuinely new vs shape-change)

1. **Sub-agent hallucinated completion** — *genuinely new.* Today the lead sees raw tool results; there is no intermediate party who can claim work it didn't do. A specialist returning confident, fabricated summaries (or "nothing found" after a lazy search) is a new trust boundary. Mitigations: schema-forced chunk_ids on every claim, VERIFY sampling, terminal grounding validator.
2. **Partial sub-agent failure** — *shape-change.* Equivalent to today's partial tool failure (eval F1-a), but the failed unit is now a whole loop with retry semantics; the lead must choose re-dispatch vs proceed-degraded, and the answer must name the missing source (same honesty rule as today).
3. **Coordination deadlock / silent straggler** — *mostly shape-change of the hung-tool problem, with one genuinely new mechanic:* the lead waiting on a workspace status that never arrives because a sub-agent died mid-write. The wall-clock cap still bounds the damage (ADR-0010's "the termination everyone forgets"), but heartbeats/leases are new machinery that doesn't exist today.
4. **Cost blowup from parallel calls** — *shape-change in kind, new in magnitude and mechanics.* Budgets exist, but per-agent-query calls go ~2–3.5x (each specialist plans and summarizes; the lead delegates and verifies), and the concurrent-overshoot race (§2) is new. Anthropic's own published experience with multi-agent research systems is instructive: token usage runs an order of magnitude above simple chat — the economics only close when task value is high.
5. **Entity conflicts across sub-agents** — *genuinely new.* One context window means one referent for "RTX" today. Independent resolution can produce findings that are individually consistent and jointly wrong — the subtlest bug class in this design, hence the canonical entity map and reconcile-as-gap behavior.
6. **Compounding summarization loss** — *genuinely new.* Findings are summaries of summaries by synthesis time; nuance decays across each agent boundary (the telephone-game class). Mitigation: findings carry short verbatim quotes + chunk_ids, and synthesis may re-fetch cited chunks directly — the workspace is an index, not the evidence itself.
7. **Duplicated work across specialists** — *new inefficiency, not a correctness bug.* Per-agent hash registries can't see each other; overlapping retrievals waste budget. Acceptable at small N; a shared read-only "already-retrieved" index is the fix if it ever matters.

## 4 · Impact on D24–D31 and the eval harness (nothing carries for free)

- **D24 (herd/single-flight/jitter): holds as-is.** Request-level, outside the agent entirely.
- **D25 (SLOs): modified.** Parallel specialists can *reduce* latency on independent-hop queries, but lead delegation + VERIFY add calls; the agent p95 ≤30s target must be re-measured, not assumed. **Timing chain: holds only with a new inner link** — sub-agent wall-clock 25s < global 60s — giving 15s < 25s < 30s < 60s < 70s; the chain must be re-derived as a set (PLAYBOOK §3 rule applies).
- **D26 (Postgres–Qdrant consistency): holds as-is.** Ingestion is untouched; the workspace is a new table family with its own (simple, single-writer-per-key) semantics.
- **D27 (admission): modified, and this is the sharpest conflict.** AGENT_MAX=4 was derived from CPU-bound reranking; three specialists reranking in parallel triples contention, forcing AGENT_MAX toward 1–2 — unacceptable — so **moving rerank off-box (the D12 Cohere swap) becomes a prerequisite of Phase 2, not an option.**
- **D28 (SIGTERM drain): mechanism holds, implementation doubles.** The drain deadline must propagate into every sub-budget; the task group must cancel-and-settle; partial findings in the workspace feed the partial answer. Reusing the budget exit remains right.
- **D29 (pool formula): the formula survives — that was its point — but every input changes.** Per-query concurrent holds multiply ~3x: provider HTTP 12→~24, Qdrant 8→~12–16; Postgres gains workspace writes. Recompute; don't tune one side (WATCHOUTS rule).
- **D30 (FSM semantics): partially invalidated.** Holds: four-reason set at top level, judge mapping condition, fail-open, first-cycle zero-tool rule (now per sub-agent). **Invalidated as-is: global dead-loop detection** — per-context hash registries can't see cross-agent repeats, and three specialists can each independently retry; required: per-sub-agent registries *plus* a lead-level hash over delegation briefs to catch re-delegation loops. This is a redesign of the mechanism, not a tweak.
- **D31 (evals): extended, not invalidated.** Layer 1 (answer-level RAGAS) holds untouched. Layer 2 keeps R1/T1/P1/P2/B1/F1 and **requires a new family, O1 — orchestration assertions:** delegation correctness (right specialists per query), workspace provenance integrity (every finding's chunk_ids resolve), VERIFY-sampling fired and caught a planted fabricating sub-agent (a poisoned test double — the multi-agent analog of corpus injection), per-sub-agent budget adherence, straggler-deadline behavior, and entity-reconciliation cases with planted conflicting aliases. P2's rubric extends to delegation-brief quality; all trace assertions must handle nested parent/child spans. Roughly +15–20 eval cases and a trace-schema change.

## 5 · The threshold question, answered with numbers

Traffic volume is the wrong axis: 10 or 10,000 queries/day changes replicas and caps (D27/D29), never the agent topology. The real triggers, in the order they'd plausibly fire:

1. **Source expansion to ≥5–6 heterogeneous sources** (the shelved V2 vision: FAA SDRs/ADs, NOTAMs, TLEs) *and* measured tool-selection degradation — single-plan tool-choice error >10% on the eval suite. This is the most likely real trigger, and it's a product decision (reopening D01), not an emergent one.
2. **Capacity-bound queries:** >25–30% of genuinely answerable X-set questions terminating on `budget` at the 6-step cap after retrieval/prompt fixes — evidence the single loop can't hold the required breadth.
3. **Context pressure:** evidence assembly routinely consuming >60–70% of the synthesis context with a *measured* grounding/correctness decline correlated to evidence size — the context-isolation argument, and the only one Anthropic's multi-agent pattern is really about at small scale.
4. **Persistent multi-hop accuracy gap:** X-set correctness plateauing ≥10 points below single-source sets despite fixes — at which point the post-v1 spike graduates from curiosity to decision-grade experiment.

**Consistency check against D24–D29:** the hardening work sized this system for tens of queries/day, single instance, CPU-bound rerank, $0.10/query. None of the four triggers is near firing at that operating point — 3 sources, small corpus, 2-hop questions — and trigger-free migration would *break* D27 as shown above. So the consistent, plain answer: **at portfolio scale this migration is very likely never justified; it becomes a live question only if the project deliberately grows past ~5 sources, which is a D01 revisit, not a scaling event.** Nothing in this document implies imminence.

## 6 · Cost and complexity budget

**Engineering surface:** lead/delegation logic, a specialist mini-FSM template ×3, workspace schema with provenance guarantees, VERIFY sampler, canonical entity map + reconciliation, hierarchical budgets with atomic reservation, heartbeat/lease machinery, nested tracing, drain propagation. Rough estimate: **+2,500–4,000 lines, approximately doubling the agent layer**, plus ~15–20 new eval cases (O1), new dashboard panels, and a trace-schema migration. Part-time, that's **3–4 weeks** to production-shape — against a **6–8 hour** spike that answers the only question that currently matters.

**Runtime economics:** ~2–3.5x model calls per agentic query → roughly $0.05–0.12 vs today's $0.02–0.04, breaking the current $0.10 cap and forcing a budget redesign; latency improves only when hops were genuinely independent, and VERIFY gives some of it back.

**New failure surface:** two entirely new bug classes (fabricating intermediaries, cross-agent entity conflicts), one new race (concurrent budget overshoot), one redesigned safety mechanism (dead-loop), one hardening decision converted from option to prerequisite (off-box rerank).

## 7 · Closing judgment

I would not build this at any point in the current plan's horizon, and I'd say so in an interview as the point of the document: the supervisor pattern solves coordination and context-isolation problems that appear at ≥5 heterogeneous sources or research-breadth workloads, and this system — by deliberate, documented scope decisions — has neither. The committed path stands: ship v1 single-agent; run the post-v1 spike as a measured experiment on the X-set; publish the comparison table; and let trigger #1 (a deliberate source-expansion decision reopening D01) be the only event that turns this design from evidence of restraint into a build plan. If that day comes, this document is the starting spec — with the D27 prerequisite, the D30 dead-loop redesign, and the O1 eval family as the first three work items.
