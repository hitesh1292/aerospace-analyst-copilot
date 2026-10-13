# SYSTEM_DESIGN — Aerospace Analyst Copilot

Interview-structured synthesis. Detail lives in the linked artifacts; this doc is the ten-minute
top-to-bottom read and the interview rehearsal script. Numbers marked **(target)** are planned;
replace with measured values at W15–16 — a design doc with real p95s beats one with aspirations.

## 1 · Problem and requirements
Aerospace analysts answer multi-source questions ("do Boeing's disclosed risk factors match its
incident record?") in 2–4 hours of manual EDGAR/NTSB/launch-data work. The system answers in
seconds with citations that click through to the original public record.

**Functional:** natural-language Q&A over SEC EDGAR (40 tickers, 2 yrs), NTSB incidents, Launch
Library 2; per-claim citations with source links; explicit refusal on insufficient evidence;
time-validity on all time-bounded records; user feedback per answer.
**Non-functional (SLOs, D25):** 99.0% availability; fast-path p95 ≤ 8s; agent p95 ≤ 30s; ≥90% of
answers grounded ≥0.85 (quality is an SLO because in an LLM system quality decay is an outage);
< $0.05 blended cost/query **(target)**. Budget/dead-loop exits are designed degradation, excluded
from the error SLO.
**Explicit non-goals:** multi-tenancy/auth, model training, real-time streaming ingestion,
multi-agent orchestration (post-v1 spike), commercial data licensing.

## 2 · Capacity and estimates
Corpus ~12–15K chunks (~800 tokens each) → well inside Postgres FTS and a small Qdrant collection.
Traffic: tens of queries/day real; design validated to 16 concurrent in-flight (admission hard cap).
Cost envelope: free-tier models default, ~$0.02–0.05/query, paid rescue on grounding failure only
(rescue rate is a tracked metric with a >15% revisit trigger, D22). Infra ≈ $10–25/mo on Railway.

## 3 · Data model (db/models.py, D26)
`documents` (source, source_url, raw + parsed, filing metadata) → `chunks` (text, breadcrumb,
token_count, chunking_version, effective_from/to, embedding_status pending|embedded|failed,
content_hash) → vectors in Qdrant (point id = chunk_id). Operational tables: `ingestion_runs`,
`interactions` (request_id, route, latency, cost, termination_reason, grounding), `feedback`
(rating, text, joined by request_id). Postgres is the only write-primary; Qdrant is derived and
rebuildable.

## 4 · API contract
`POST /api/v1/query` → `{answer, citations[{chunk_id, source_url, confidence, grounding}],
route, request_id, degraded?}` · `POST /api/v1/feedback` · `GET /api/v1/health` (flips 503 while
draining) · `GET /metrics` (Prometheus). Stateless; every request carries request_id end to end.

## 5 · Read path (diagrams: docs/architecture.html)
Admission control (D27: AGENT_MAX 4 / FAST 12 / hard 16, degrade ladder) → scope guardrail → cache
(exact-match, validity-keyed, single-flight, D20/D24) → complexity classifier → **fast path**
(retrieve→rerank→synthesize) or **agent FSM** (SPEC-0011: plan → budget check [steps 6, $0.10, 60s,
drain] → parallel tools → sufficiency judge [sub-question→evidence mapping; fails open] → ≤2
replans → synthesize) → grounding validator with one paid-tier rescue (D22) → response → trace +
metrics + feedback. Termination is always one of {answered, budget, dead_loop, error} with an
orthogonal completeness flag (D30).

## 6 · Retrieval design (D05–D07, D11–D12)
Hybrid: Postgres FTS (ts_rank — deliberately not called BM25) + Qdrant dense (nomic-embed, task
prefixes) → RRF (rank fusion; no score normalization across incomparable scales) → cross-encoder
rerank of top-50 → top-8 → confidence floor. Domain twist: identifier-heavy text (AD numbers, tail
numbers, tickers) makes the lexical leg unusually strong; RRF weights are eval-tuned, and reranking
is skip-gated on exact-identifier hits. Temporal validity filters at *retrieval* time, not synthesis.

## 7 · Write path and consistency (D26)
APScheduler (jittered) workers per source → Postgres → status-column outbox → sync worker (5 min,
batch 128, FOR UPDATE SKIP LOCKED, idempotent upserts) → Qdrant. Stated divergence window ≤15 min
typical; the FTS leg makes new content findable immediately, so the window is tolerable by design.
Nightly reconciliation (count + 1% hash sample; drift >0.5% → targeted repair). Dual-write and CDC
were rejected — see PLAYBOOK §8.

## 8 · Reliability (ADR-0010)
Single-flight + jitter (herd) · admission + degrade ladder (shedding) · circuit breakers + timeouts
per dependency · SIGTERM drain that reuses the budget exit (every deploy exercises the same tested
path as every budget trip) · pools derived by formula from admission caps (PG 15, Qdrant 8, Redis
20, HTTP 12). The coupled timing chain: follower wait 15s < agent p95 30s < wall-clock 60s < lock
TTL 70s — changed together or not at all.

## 9 · Quality: evals and observability (D13/D14/D31, SPEC-0011)
Two layers: RAGAS-scored labeled sets (E/N/L fast-path + X multi-hop; routes never blended; X
thresholds deliberately lower) and custom orchestration evals (trace assertions for routing,
termination distribution, replan sequencing, budget-bait adherence, fault injection; one
4-criterion 0/1 rubric for replan targeting). Judges pinned; calibrated against hand grades with a
reported agreement number. CI gates on deterministic checks per commit; judged suites on merge;
four checkpoint gates (CP1–CP4). Observability: full Langfuse traces (debuggable-from-trace-alone
standard), Prometheus/Grafana with five panels and SLO burn alerts.

## 10 · Security
Threat model: the **corpus is the untrusted input** — injection arrives via ingested public
documents, not just users. Defenses: data-not-instructions delimiting, ingestion-time screening +
quarantine, adversarial eval scenarios that attack through the corpus; input scope classifier; rate
limiting; securities disclaimer on advice-shaped output. Deliberate non-defense: no ITAR classifier
(public-domain data isn't export-controlled — D17); `?dev=1` is stated as demo convenience, not
access control (L2: API-key-gated debug role).

## 11 · Scale path (the memorized answer)
**1K/day:** bigger instance + second stateless replica, paid Qdrant — ~$100–200/mo, LLM spend now
dominant. **10K/day:** 3–5 replicas, pgbouncer + read replica, replicated Qdrant, semantic response
cache (revisits D20 with eval-validated threshold), LiteLLM multi-provider balancing — ~$1–2K/mo.
**100K/day:** ECS/K8s autoscaling, queue-based ingestion, sharded Qdrant, committed-use inference
pricing, trace sampling — ~$10–20K/mo, ~80% inference — which is why the router and cache are the
real scale story.

## 12 · Failure modes (what breaks first, in order)
1. Free-tier model quality (grounding misses) → measured rescue rate → D09 tier flip trigger.
2. Qdrant free-tier limits → pgvector-vs-paid analysis (planned README comparison).
3. EDGAR parsing drift on odd filings → raw bytes stored, re-parse without re-download.
4. Single instance restarts → drain path + 99.0% (not 99.9) availability promise.
5. Eval-set overfitting → 5 held-out scenarios never used in development.

## 13 · Honest limitations
No auth/multi-tenancy; n≈dozens for live metrics (reported with n, never as percentages alone);
single region; no load testing at real concurrency; no operational history. Framing: production-
shaped at portfolio scale — the disciplines are present and measured; what's missing is traffic and
time, not rigor.

---

# INTERVIEW ESSENTIALS — what a Staff-level interviewer will probe

Universal first, then company flavors. For each: the one-breath answer this project earns, and
where the receipts live.

**"How do you know it works?"** — the #1 GenAI-era question, and where most candidates die.
Answer: two-layer evals with calibrated judges and a reported judge-human agreement number; CI
gated on deterministic checks; quality as an SLO with burn alerts. Receipts: SPEC-0011, eval
reports, CP1–CP4. Know cold: why gold *facts* beat gold prose, why routes are scored separately,
why the judge is pinned, what n your numbers carry.

**"How do you stop hallucination?"** — layered, and know the layers' order: retrieval-only prompt
with refusal path → per-claim grounding validation against the *specific cited chunk* → numeric
strict-matching → paid rescue → temporal validity so "correct but expired" can't happen. The
sophisticated follow-up is "what still gets through?" — have the answer: derived numbers, judge
false-positives (quantified by calibration), and stale-within-window content.

**"Walk me through one request"** — rehearse §5 until you can do it in 90 seconds and at
20-minute depth. Practice the branch points: why this query fast-paths, what makes the judge
replan, which of the four exits fires and why.

**"What's your cost model?"** — per-query economics by route, the routing ladder (free default,
measured escalation), caching layers, and the honest statement that at 100K/day this is an
inference-economics problem, not a compute one.

**"How does it fail?"** — §12 in order, plus the philosophy: designed degradation over heroics,
every exit named, drain reuses tested paths. Staff interviewers probe whether you *designed* the
failure behavior or discovered it.

**Company flavors:**
- **Google** — SLO/error-budget literacy (why 99.0, what burn alerts buy over static thresholds,
  what's excluded from the budget and why), consistency reasoning (§7: why a stated divergence
  window beats a real-time promise), and capacity math done aloud without notes.
- **Meta** — measurement and experimentation: the A/B mechanics (hash bucketing, why n limits what
  you can claim), metrics tiers, the feedback→eval-scenario loop (production failures become
  permanent regression tests — say this sentence; it lands).
- **NVIDIA** — inference economics: token accounting (why cache-write vs cache-read are tracked
  separately), batching in the embedding pipeline, CPU-vs-GPU reasoning (§: why the reranker runs
  CPU here, at what latency it moves off-box, why vLLM behind the gateway is a config change —
  D18's threshold answer), KV-cache/prompt-caching mechanics conceptually.
- **SpaceX / Anduril / defense-adjacent** — bounded autonomy (the FSM's four exits, budget caps,
  dead-loop determinism), honest degradation under load, corpus-as-threat-surface security, and the
  ITAR judgment call (knowing public-domain data isn't export-controlled signals real domain
  literacy; a fake ITAR classifier signals the opposite).

**The gaps to own before they're found (asked as "what would you do differently / with 10x?"):**
no distributed-systems war stories at real scale (answer with the scale path + what you'd measure
first), no model training depth (point to the inference-layer focus and your day-job ML), no
multi-agent in v1 (answer: evaluated and deferred with a threshold — the single-vs-multi eval spike
is the planned post-v1 experiment). Owning a gap with a plan reads Staff; hiding it reads mid.
