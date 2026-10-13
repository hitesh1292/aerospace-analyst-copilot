> **MERGED:** reasoning consolidated into docs/PLAYBOOK.md — read that first. This file is kept as the ADR-linked original.

# Judgment calls behind ADR-0010 (read this before re-opening any of the six gaps)

Audience: a future Claude/Sonnet/Opus session (or future me) picking up this repo. The ADR has the
*what*; this file has the *why*. Do not re-solve these problems — if a fix seems wrong, check whether
the constraint that shaped it still holds first.

## The constraints that shaped everything
Single developer, single Railway instance, free-tier dependencies, ~tens of queries/day real traffic,
and a stated target of "production-shaped at portfolio scale, Senior-level scope." Every gap had a
fancier industry answer (distributed locks, multi-window burn alerting, CDC, priority queues,
zero-downtime resume, pgbouncer). Each was rejected not from ignorance but because at this scale the
fancier answer adds untested surface without adding demonstrated judgment. The interview value is in
knowing the threshold where the fancy answer becomes necessary — several are named in the ADR.

## G1 · Why single-flight and not a queue or distributed lock manager
The herd here is small-N identical work, not high-QPS contention. Redis SET NX is one round trip and
~15 lines. The subtle calls: lock TTL (70s) must exceed the agent wall-clock cap (60s) or the lock can
expire mid-computation and re-admit the herd; followers who time out COMPUTE ANYWAY rather than
erroring, because a died lock-holder must not strand users; and stale-while-revalidate is banned for
temporal/validity keys — serving a stale-but-fast answer about an expired record would silently undo
the temporal-correctness work (D20). If you're tempted to add stale-serve there: that's the trap.

## G2 · Why these numbers and why grounding is an SLO
99.0% availability is deliberately unheroic — a single free-tier instance restarts; promising 99.9%
would be resume inflation and every reviewer knows it. Honest targets are the credibility play.
Budget/dead_loop exits are excluded from the error SLO on purpose: they are the system WORKING
(designed degradation). Counting them as failures would create pressure to remove the safety exits —
a perverse incentive. Grounding-as-SLO is unusual and intentional: in an LLM product, quality decay is
an outage even when latency is green. Static alerts were replaced by budget-burn alerts because static
thresholds either page constantly at tiny n or never; burn rates tolerate noise.

## G3 · Why a status column and not CDC/Debezium or dual-write
Dual-write (app writes Postgres AND Qdrant inline) was rejected because a Qdrant blip would then fail
ingestion, coupling the write path to the least reliable dependency. CDC was rejected as an entire
Kafka-shaped infrastructure for one consumer (same logic as D16). The status-column outbox gives
at-least-once with idempotent upserts — the only semantics that stay correct when a redeploy kills the
worker mid-batch (which WILL happen; see G5). The divergence window is stated (≤15 min typical)
rather than minimized because RRF covers the gap: new content is lexically findable immediately.
Anyone proposing "make it real-time" should first show a query that failed because of the window.

## G4 · Why admission control is a separate layer from the budget check
These answer different questions and must not be merged: admission = "may this query start, and in
what mode?" (system-wide, protects everyone); budget = "may this query continue?" (per-query,
protects cost). Merging them makes one query's behavior depend invisibly on system state, which
destroys eval reproducibility — eval runs must bypass admission or run at idle. The degrade ladder
(agent → fast-path with a visible notice) was chosen over pure 429s because a shallower answer with
honesty beats a rejection for an analyst mid-task. AGENT_MAX=4 is not arbitrary: the CPU-bound
reranker means concurrent agent runs contend for cores; raising it without moving rerank off-box
(Cohere swap, D12) just converts shedding into latency SLO burn.

## G5 · Why drain reuses the budget exit instead of a new abort path
The budget path (graceful-exit node, partial synthesis, termination logging) is already built and
already tested by the $0.01-cap test. A second abort mechanism would be new, rarely-exercised code
that runs only during deploys — the worst possible place for untested surface. Making the drain
deadline a fourth budget input means every deploy exercises the same code path as every budget trip.
Resume-from-checkpoint after deploy was consciously deferred: checkpoints already persist, so the
option stays open, but resume UX (user has left; who receives the answer?) is a product question, not
a reliability one.

## G6 · Why pools derive from admission caps
Pool sizing has no independent truth — it is arithmetic downstream of G4. Writing the formula into the
repo (pool_max = cap × holds + reserves) makes the coupling explicit so nobody tunes one side alone.
The per-operation (not per-request) session rule is what makes 15 connections serve 16 in-flight
requests; if someone converts to session-per-request "for convenience," the math breaks silently —
that's the specific regression to watch for in review. Two values are intentionally marked VERIFY
(Railway grace period, Postgres plan connection limit): they are platform facts that drift, and baking
in a guess would be exactly the false precision this project avoids.

## Cross-cutting: the ordering that must stay true
follower wait (15s) < agent p95 SLO (30s) < wall-clock cap (60s) < single-flight lock TTL (70s).
If any of these numbers changes, re-check the whole chain — they were chosen together, not separately.
