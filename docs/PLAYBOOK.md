# PLAYBOOK — consolidated judgment calls (ADR-0010 + SPEC-0011)

The single reasoning reference behind the hardening and FSM/eval decisions (D24–D31). Merges and
supersedes reading order of JUDGMENT_CALLS_system_gaps.md and JUDGMENT_CALLS_fsm_evals.md (both kept
as ADR-linked originals). If a mechanism seems wrong, check whether its shaping constraint still
holds before redesigning.

## 1 · The governing constraint
Single developer, single Railway instance, free-tier dependencies, tens of queries/day, Senior-level
scope. Every problem here had a fancier industry answer (distributed locks, CDC, priority queues,
multi-window burn alerting, resume-after-deploy, pgbouncer). Each was rejected because at this scale
it adds untested surface without demonstrated judgment. The interview asset is knowing the threshold
where the fancy answer becomes necessary — several are named in the ADRs.

## 2 · Determinism is a design requirement, not a preference
Three decisions share one root: eval reproducibility.
- Dead-loop detection is normalize+exact-hash (identifiers preserved via [A-Z0-9-]{4,}), not embedding
  similarity — T1 assertions must not flake across model versions. Similarity is L2; adding it means
  re-scoping T1 to distribution-level checks.
- Eval runs bypass admission control (or run at idle) — otherwise scores depend on concurrent load.
- Judges, RAGAS internals, and rubric prompts are pinned; changing any invalidates score history.

## 3 · One timing chain, chosen together
follower wait 15s < agent p95 SLO 30s < wall-clock cap 60s < single-flight lock TTL 70s.
The lock must outlive the longest computation it guards; the follower wait must fit inside the SLO;
the cap is the hard stop above the SLO. Also coupled: replan cap 2 exists inside the $0.10 cost cap
(worst case ≈ 9–11 model calls). Change any number → re-derive the whole chain and the cost math.

## 4 · Layers that answer different questions stay separate
- Admission ("may this query start, in what mode?") vs budget ("may it continue?"): merging them makes
  one query's behavior depend invisibly on system state — the reproducibility failure again.
- Judge vs grounding validator: the judge fails OPEN (sufficient + judge_error flag) because a dead
  judge must not turn answerable queries into errors; unsupported answers are caught downstream by the
  validator. The safety layer is the validator. Don't move safety into the judge.
- Layer 1 vs Layer 2 evals: RAGAS scores text artifacts; orchestration correctness lives in the
  trace. The same perfect answer can come from a correct run or a lucky pathological one — which is
  precisely why Layer 2 could not be forced into RAGAS.

## 5 · Reuse tested paths instead of building rare-path code
SIGTERM drain injects a deadline into the existing budget check, so every deploy exercises the same
exit as every budget trip (already tested by the $0.01-cap test). Same instinct elsewhere: dead-loop
and budget trips exit through the same partial-synthesis node; failed tools become evidence items the
judge reasons about rather than a parallel error channel.

## 6 · Honest degradation over silent failure or heroics
- Budget/dead_loop exits are designed degradation — excluded from the error SLO on purpose, because
  counting them as failures pressures removal of the safety exits (perverse incentive).
- Shedding degrades agent→fast-path WITH a visible notice and a degraded=true trace label; a shallower
  honest answer beats a 429 for an analyst mid-task, and degradation volume stays measurable.
- answer_completeness is a field, not a 5th termination reason: WHY the loop stopped and HOW GOOD the
  answer is are different axes; conflating them starts enum soup and breaks T1 assertions.
- 99.0% availability, not 99.9: single free-tier instance; inflated targets are resume inflation every
  reviewer recognizes.

## 7 · The corpus and the models are the untrusted parties
- Zero-tool-call plans are forbidden on the FIRST cycle only: models genuinely know aerospace facts
  and will answer parametrically — the failure that looks perfect. After a replan, "I have enough" is
  legitimate; the asymmetry is the point.
- The judge condition is sub-question→evidence MAPPING, not "is this enough?", because cheap models
  rubber-stamp yes/no questions; unmapped sub-questions ARE the gaps, in the judge's own output.
- Stale-while-revalidate is banned on temporal keys: a fast stale answer about an expired record would
  silently undo the temporal-correctness work (D20). This is the trap most likely to be reintroduced
  by a well-meaning cache optimization.

## 8 · Consistency is a protocol plus a stated window, not a promise
Postgres is write-primary; Qdrant is written only by the sync worker (status-column outbox,
at-least-once, idempotent upserts — the only semantics that survive a redeploy mid-batch). The
divergence window (≤15 min typical) is STATED rather than minimized because RRF's FTS leg makes new
content findable immediately. Dual-write and CDC were rejected, not overlooked. Anyone proposing
"make it real-time" should first produce a query that failed because of the window.

## 9 · Superseded / amended points (explicit)
- D13's "RAGAS = report-only" clause → amended by D31 (RAGAS is now the Layer-1 metric engine; the
  custom harness still orchestrates and gates; per-commit gate remains deterministic checks).
- W12 static alert thresholds → superseded by D25 burn alerts (cost + fallback alerts survive).
- W14 future-improvement "cache stampede (L3)" → resolved at design time by D24.
- Flat "30 scenarios" counting → superseded by SPEC-0011 sets (42 Layer-1 items + ~40 Layer-2 cases);
  CP2–CP4 gate contents now reference the sets.
