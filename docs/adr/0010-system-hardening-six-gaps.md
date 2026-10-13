# ADR-0010: System hardening — six gaps resolved

Date: 2026-07-19 · Status: active · Scope: exactly the six gaps below, nothing else.
Ground truth: architecture_reference.html (3 diagrams), DECISIONS.md D01–D23, plan v6.
Each section names the component it modifies (by diagram box) or the new component it adds.

---

## G1 — Thundering herd protection

**Decision:** single-flight locking on the response cache, stale-while-revalidate serving, and jitter on every scheduled or retried external call. No queue, no distributed lock manager.

**Component change:** extends the Redis box (diagram 1) and the cache step inside "Intake + guardrails" (diagram 2). Code lives in `src/cache/redis_cache.py` + `keys.py`. No new box. Note: this resolves the "cache stampede protection" line previously parked as a W14 future improvement — it is now design, not roadmap.

**Why this shape:** the herd risks here are (a) N identical queries missing cache simultaneously and each launching a full agent run, (b) APScheduler jobs synchronizing after a restart and hammering EDGAR/LL2, (c) retries synchronizing after a provider blip. Single-flight kills (a); jitter kills (b) and (c). Tradeoff: followers of a locked computation wait, adding latency on the unlucky requests — acceptable versus paying for N agent runs.

**Implementation:**

```
# single-flight around any cache-mediated computation
key   = normalize(query) + validity_bucket          # from keys.py; validity-aware per D20
lock  = f"lock:{key}"                               # SET NX EX 70  (70s > 60s agent wall-clock cap)

on request:
  if cache hit (fresh): return it
  if cache hit (stale, expired < 300s ago):
      return stale copy immediately; if SET NX succeeds, refresh in background task
  if SET NX lock succeeds:
      compute; write cache; DEL lock
  else:                                             # someone else is computing
      poll cache every 500ms up to 15s
      on fill: return it
      on timeout: compute anyway (lock holder may have died; result is idempotent)
```

Config: lock TTL 70s; follower poll 500ms; follower wait cap 15s; stale-serve window 300s (never applied to temporal/validity-sensitive keys — those skip stale-serve entirely, consistent with D20).
Jitter: APScheduler jobs get `jitter=120` (seconds); all tenacity retries use exponential backoff with full jitter (`wait_random_exponential(multiplier=1, max=30)`); circuit-breaker half-open probes add ±20% random delay.

**Interacts with:** G4 (single-flight reduces the load spikes shedding must absorb) and G2 (follower wait cap of 15s stays inside the agent p95 SLO of 30s).

---

## G2 — SLO definition

**Decision:** four SLOs, measured at the API middleware over rolling 7 days, with two-stage budget-burn alerts. Numbers are commitments, not aspirations — sized for a free-tier, single-instance stack.

| SLO | Target | Notes |
|---|---|---|
| Availability | 99.0% monthly | ~7.3h/month budget; honest for Railway single instance |
| Latency, fast path | p95 ≤ 8s, p50 ≤ 3s | measured at middleware, per route label |
| Latency, agent route | p95 ≤ 30s, p50 ≤ 12s | wall-clock budget cap (60s) is the hard stop above this |
| Quality | ≥90% of answered queries with grounding ≥0.85 | an SLO because this is an LLM system; degradation here is an incident |

Error-rate objective: <2% of requests end in 5xx or `termination_reason=error` (7-day). Budget/dead_loop exits are **designed degradation, not SLO violations** — tracked separately with a soft ceiling of 8%.

**Component change:** extends the Observability box (diagram 1). Artifacts: `docs/SLO.md` (the table above + rationale), Prometheus recording rules for per-route p95 and error ratios, Grafana alerts rewritten as burn alerts. **Flagged change to an existing task:** the W12 alert list (p95>30s, >5% errors, etc.) is superseded — replace those static-threshold alerts with: warn at 50% of 7-day error/latency budget consumed, act at 90%. The cost alert ($2.50/day) and fallback alert (>20%) remain as-is; they are operational guards, not SLOs.

**Interacts with:** G4 (shedding triggers key off SLO burn), G5 (drain deadline must fit inside the latency SLO story), and the Live Metrics sheet (targets there already match these numbers — no conflict found).

---

## G3 — Postgres–Qdrant consistency

**Decision:** status-column outbox on the chunks table, at-least-once sync with idempotent upserts, a defined divergence window, and nightly reconciliation. Postgres is always write-primary; Qdrant is never written except by the sync worker.

**Component change:** extends the ingestion band (diagram 1): the "embeddings → Qdrant" arrow becomes an explicit sync worker with state. **Flagged schema change to an existing task:** W2 migration adds `embedding_status` (`pending|embedded|failed`) and `content_hash` to chunks. One small **new component**: a nightly reconciliation job (APScheduler, `scripts/reconcile_qdrant.py`).

**Protocol (normal writes):**

```
ingest/chunk:  INSERT chunk (embedding_status='pending', content_hash=sha256(text))
sync worker (every 5 min, batch 128):
  rows = SELECT ... WHERE embedding_status='pending' ORDER BY id LIMIT 128 FOR UPDATE SKIP LOCKED
  vectors = embed(rows)                     # batched, nomic prefixes
  qdrant.upsert(points: id=chunk_id, payload={chunking_version, content_hash, effective_to})
  on ack: UPDATE embedding_status='embedded'
  on failure: leave 'pending' (retry next cycle); after 3 failures mark 'failed' + counter metric
deletes/supersession: soft-delete flag in Postgres → worker deletes points by id → hard-delete after
```

Idempotency: Qdrant upsert by chunk_id makes retries safe; `FOR UPDATE SKIP LOCKED` makes the worker safe to run even if a redeploy overlaps two instances briefly.

**Tolerable divergence window:** new chunks searchable in the vector leg within one sync cycle — target 95% ≤ 15 min, hard expectation ≤ 30 min. During the window, RRF still surfaces new content through the FTS leg (lexical-before-semantic is the documented, accepted behavior). Reconciliation: nightly count comparison + 1% random `content_hash` sample; drift >0.5% → alert + targeted re-upsert of the diff. Full rebuild only on `chunking_version` bump (existing rebuild script), never as drift response.

**Interacts with:** G5 (worker batches are idempotent, so `shutdown(wait=False)` is safe) and G6 (worker reserves 2 Postgres connections in the pool math).

---

## G4 — Load shedding

**Decision:** admission control at the middleware — per-route concurrency semaphores with bounded waits and a degrade ladder — sitting *in front of* the per-query budget check. Admission decides whether and in what mode a query runs; the budget check (unchanged) decides how long it may keep running. These are deliberately separate layers.

**Component change:** extends the "Intake + guardrails" box (diagram 2) — flagged extension, admission is now the first thing after request_id. Code: `src/api/admission.py` wired in middleware. The Budget check box (diagram 3) is **not** modified by this gap.

**Implementation:**

```
caps (single instance, ≥2 vCPU / 4 GB assumed):
  AGENT_MAX  = 4     # reranker + multi-call loops are CPU/token heavy
  FAST_MAX   = 12
  INFLIGHT_HARD = 16 # absolute in-flight cap at middleware

per request:
  if inflight >= INFLIGHT_HARD: 429 + Retry-After: 30       (health checks & cache hits bypass)
  route = classifier result
  acquire semaphore(route) with wait timeout: fast 5s, agent 10s
  on timeout:
    agent request  -> degrade to fast path, answer carries notice
                      "High load — served as a single-pass answer; retry later for deep analysis"
    fast request   -> 429 + Retry-After: 30
degrade trigger from SLOs: while a latency burn alert (G2) is firing,
  APScheduler pauses ingestion + reconciliation jobs (serving preempts background work)
```

Tradeoff accepted: degraded agent queries silently get shallower answers — mitigated by the visible notice and a `degraded=true` label on the trace and Prometheus counter (so degradation volume is measurable, and shows up in the weekly ritual).

**Interacts with:** G2 (triggers), G6 (pool sizes are derived from these caps), G1 (single-flight prevents herd-induced cap exhaustion), G5 (draining flips admission to reject-all).

---

## G5 — SIGTERM handling

**Decision:** drain-then-degrade shutdown that reuses the agent's existing budget-exit path instead of inventing a new abort mechanism. In-flight work finishes or gracefully partials; nothing is dropped mid-answer.

**Component change:** extends the FastAPI box (diagram 1: lifespan/signal handling) and **extends the Budget check box in diagram 3** — the drain deadline becomes a fourth input alongside steps, cost, and wall-clock. No new component. This ADR is the spec for the existing W14 SIGTERM task.

**Sequence (assume 30s platform grace period — verify Railway's current value and set `DRAIN_BUDGET = grace − 5s`):**

```
on SIGTERM:
  1. draining = True; /api/v1/health returns 503     -> platform stops routing new traffic
  2. admission (G4) rejects new queries: 503 + Retry-After: 20
  3. fast-path in-flight: allowed to complete (p95 8s fits comfortably)
  4. agent in-flight: budget manager override on next node transition:
       remaining_wall_clock = min(remaining_wall_clock, drain_deadline − now − 3s)
     -> loop exits through the EXISTING budget path: synthesize-with-partials,
        termination_reason = 'budget' (drain sub-reason logged on the trace)
  5. APScheduler.shutdown(wait=False)                 -> safe: G3 batches are idempotent
  6. flush Langfuse + metrics; close pools reverse order (redis, qdrant, postgres)
  7. exit 0 before the platform SIGKILL
```

Why reuse the budget path: the graceful-exit node, partial-answer synthesis, and termination logging already exist and are already tested by the $0.01-cap test — a second abort mechanism would be new untested surface. LangGraph checkpoints persist state regardless, so resume-after-deploy remains possible later without changing this design.

**Interacts with:** G4 (step 2), G3 (step 5), G2 (drain adds ≤ grace-period latency to at most a handful of requests — inside the monthly availability budget).

---

## G6 — Connection pool sizing

**Decision:** derive every pool from the G4 admission caps plus background reserves — a formula, not vibes. Single uvicorn process (async); pools are per-process, so if workers ever go to 2, halve everything.

**Component change:** config values only, in `db/engine.py`, `src/cache/redis_cache.py`, `src/gateway/client.py`, qdrant client init. Extends existing boxes; no new component. This ADR is the spec for the existing W14 pool-sizing task.

**Derivation and values:**

```
peak concurrent requests = INFLIGHT_HARD = 16 (G4)
each request holds ≤1 Postgres conn at a time (sessions are per-operation in repos, never per-request)

Postgres (asyncpg):  min 2, max 15
  = 16 request slots × ~0.7 avg hold ratio (11) + sync/reconcile workers (2) + scheduler misc (2)
  keep total ≤ 15 to leave headroom for DBeaver + alembic under Railway's plan connection limit
  (verify the plan limit; if < 25, drop max to 10 — queries queue briefly rather than erroring)
  command_timeout 10s; pool acquire timeout 5s (surfaced as 503, counted against G2 error budget)

Qdrant (httpx inside qdrant-client): max_connections 8, keepalive 6, timeout 3s
  vector queries are short; 12 fast-path slots queue briefly on 8 conns without SLO impact,
  and the free tier rate-limits anyway

Redis (redis-py async): max 20 (cheap), socket_timeout 1s, health_check_interval 30

Provider HTTP via LiteLLM: max_connections 12, keepalive 6
  = AGENT_MAX × ~2 concurrent calls (parallel tools) + FAST_MAX × short synthesis bursts;
  per-call timeouts stay owned by the router config, not the transport
```

Rule to keep in the repo: **pool_max = (admission cap × per-request holds) + background reserves**, recomputed whenever G4 caps change — the two numbers are one decision.

---

## Consistency audit (against attached diagrams, plan v6, DECISIONS.md)

1. **W12 alert thresholds** in the plan sheet and Grafana task are superseded by G2 burn alerts — update the W12 checklist wording when you get there (cost + fallback alerts survive unchanged). Live Metrics sheet targets already match the SLO numbers; no conflict.
2. **W2 schema task** gains two columns (`embedding_status`, `content_hash`) per G3 — add to the migration checklist now, cheap; retrofitting later is a migration.
3. **W14 future-improvements line** "cache stampede protection (L3)" is resolved by G1 — strike it or mark done-by-design.
4. **Diagram 2** "Intake + guardrails" box now includes admission control (G4) and drain rejection (G5); **diagram 3** Budget check gains the drain-deadline input (G5). architecture_reference.html needs those two caption-level edits — no topology change.
5. **No conflicts** with D01–D23: G1 respects D20's validity-keyed caching (stale-serve skips temporal keys); G5 reuses rather than replaces the budget exit; wall-clock cap (60s) > agent p95 SLO (30s) > follower wait (15s) — the ordering is coherent.
6. **Assumption to verify at W14:** Railway's SIGTERM grace period and the Postgres plan connection limit — both are config inputs above, marked "verify," not guesses baked in.
