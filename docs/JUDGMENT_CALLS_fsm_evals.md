> **MERGED:** reasoning consolidated into docs/PLAYBOOK.md — read that first. This file is kept as the ADR-linked original.

# Judgment calls behind SPEC-0011 (FSM + eval harness)

Audience: a future Claude/Sonnet/Opus session or future me. The spec has the *what*; this has the
*why*. Before changing any mechanism below, check whether the reasoning still applies — most of these
choices trade theoretical elegance for measurability and reproducibility on purpose.

## Why the sufficiency judge condition is "sub-question mapping," not "is this enough?"
A bare yes/no sufficiency question invites rubber-stamping — cheap models agree with whatever they're
shown. Forcing the judge to enumerate sub-questions and map each to specific evidence ids makes
laziness structurally visible: an unmapped sub-question IS the gap, in the judge's own output, with no
separate "generate gaps" step to skip. It also makes the judge auditable (the mapping is on the trace)
and makes P1/P2 evals possible at all — you can't grade replan targeting if gaps are freeform vibes.
The cost: a slightly longer judge prompt and output. Worth it.

## Why the judge fails OPEN (treated as sufficient) instead of failing closed
A dead judge failing closed converts every answerable query into replans-until-cap — burning budget to
produce a worse answer than just synthesizing. Failing open answers with what exists and flags
`judge_error=true`, which F1-c asserts on, so fail-opens are counted, not hidden. The risk (an
insufficient answer slips through) is caught downstream by the grounding validator, which is exactly
why that layer exists outside the FSM. If someone proposes fail-closed "for safety": the safety layer
is the validator, not the judge.

## Why replan cap = 2, specifically
Cost math: worst case is 3 plan calls + 3 batches + 3 judge calls ≈ 9–11 model calls, which lands just
under the $0.10/query cap on the free tier with headroom for synthesis. Empirically (industry-wide,
not just here), hop-3 recall gains are marginal while loop risk compounds — "one more hop will find
it" is the canonical agent failure. And T1-c depends on the cap being small: an unanswerable query
must fail FAST and honestly, in bounded cost. Raising the cap requires re-doing the $0.10 math and the
ADR-0010 timing chain (15s < 30s < 60s < 70s) together, not alone.

## Why dead-loop detection is normalization + exact hash, not embedding similarity
Determinism. Eval cases T1-d and T1-f assert precise behavior (this batch dead-loops, that one
continues); an embedding threshold at 0.95 makes those assertions flaky across model versions and
turns a safety mechanism into a nondeterministic one. The normalization (casefold, whitespace,
punctuation-except-identifiers, sorted keys) catches the common rephrasings cheaply; what it misses,
the replan cap and step cap bound anyway — dead-loop is defense-in-depth, not the only wall. The
identifier-preservation exception ([A-Z0-9-]{4,}) exists because "AD 2024-15-08" vs "ad 2024 15 08"
must NOT collide-or-differ incorrectly in an identifier-heavy domain. Embedding similarity stays L2,
and if added, T1 assertions must be re-scoped to distribution-level checks.

## Why answer_completeness is a field, not a fifth termination_reason
The four-reason set {answered, budget, dead_loop, error} is ground truth in the diagrams and prior
docs, and it answers one clean question: WHY did the loop stop. "Answered partially after exhausting
replans" is a different axis — HOW GOOD is what came out — and conflating axes is how enum soup
starts. Keeping reasons pure also keeps the T1 assertions and the termination-distribution health
metric stable. The field costs one trace column.

## Why zero-tool-call plans are forbidden on the first cycle but allowed later
Frontier and mid-tier models genuinely know aerospace and public-company facts and WILL answer
parametrically if allowed — the most dangerous failure in a grounded system because it looks perfect.
First-cycle zero-call plans are therefore invalid by construction (F1-e baits this exactly). But after
a replan cycle, "I now have enough" is legitimate and blocking it would force useless extra calls. The
asymmetry is the point.

## Why Layer 2 could not be RAGAS
RAGAS scores properties of (question, contexts, answer) triples — text artifacts. Orchestration
correctness is about control flow: which route fired, what sequence of judge verdicts occurred, how
many steps ran, what the exit reason was. Those live in the TRACE, not the answer; the same perfect
answer can come from a correct run or a pathological one that got lucky. Forcing trace properties
through a text-metric framework would mean losing exactly the objectivity that makes these checks
gate-worthy. Hence: assertions where the property is objective (cheap, deterministic, per-commit-able),
LLM-judge only where the property is genuinely subjective (replan targeting), with a 4-criterion 0/1
rubric because graded scales invite judge drift and 0/1 criteria can be calibrated against hand grades.

## Why routes are scored separately and multi-hop thresholds are lower
Fast-path and agent-route answers have different difficulty and different failure modes; blending them
lets the easy 32 items mask decay in the hard 10. Lower X-set thresholds are honesty, not laxity —
setting cross-source recall at 0.8 on day one would either block all progress or pressure threshold-
gaming. Thresholds can ratchet UP later (a ratchet is a good changelog entry); starting strict and
quietly lowering them is the anti-pattern this avoids.

## Why RAGAS got promoted from report-only (D13 amendment) here and not earlier
D13's caution was about outsourcing the PRIMARY quality signal to a framework before understanding it.
By the time this spec executes (W12+), the custom harness, gold-facts grading, and calibration exist;
RAGAS then adds standardized, comparable retrieval metrics cheaply — as an engine inside our
orchestration, not a replacement for it. The gate logic, cadence, and calibration discipline stay ours.
If RAGAS metrics and the custom judge disagree systematically, trust the calibrated one and write the
disagreement up (that write-up is planned: W15 RAGAS cross-check task).
