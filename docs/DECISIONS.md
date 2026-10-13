# DECISIONS.md — Architecture & Tooling Tradeoffs (living document)

> How to maintain this: every significant choice gets an entry BEFORE or AS you build it, not after.
> Each entry answers: what did I choose, what did I reject, what did that cost me, and what would make me change my mind.
> After living with a decision ≥2 weeks, add a **Verdict** line: was the tradeoff worth it in practice?
> Status values: `active` | `superseded by #N` | `revisit-triggered`.
> This file + docs/adr/ is what separates "I used X" from "I chose X over Y because Z, and here's what it cost."

---

## D01 — Three data sources, not eight — `active`
- **Chose:** SEC EDGAR + NTSB + Launch Library 2. **Rejected:** V2 spec's 8 sources (FAA SDRs/ADs, NOTAMs, CelesTrak, BTS, OpenSky).
- **Why:** Connectors are the easiest, least interview-relevant part of the system. Depth (evals, temporal correctness, failure handling) on 3 sources beats shallow breadth on 8. NOTAM access (NASA DIP) is approval-gated and could stall weeks.
- **Cost accepted:** Less impressive-sounding source count; no geospatial/PostGIS story at launch.
- **Revisit when:** v1.0.0 ships and evals are green — sources 4+ are the L2 roadmap.
- **Verdict:** _(fill in ~W6)_

## D02 — 16 weeks @ ~11 hrs/wk, not 8 @ 15 — `active`
- **Why:** 8-week plan stacked LangGraph learning + quality layer into one sprint at ~90% overrun probability. Sustainable cadence survives interview weeks (milestones = always-shippable pause points).
- **Cost:** Later ship date; motivation risk over a longer arc. Mitigated by W5 first-live-app milestone.
- **Revisit when:** consistently finishing weeks in <9 hrs → pull schedule left.

## D03 — Railway over EC2/nginx or Kubernetes — `active`
- **Why:** Deploy-from-repo in hours not days; managed Postgres/Redis addons; SSL free; ~$5–10/mo. K8s teaches ops, not the GenAI skills this project targets.
- **Cost:** Less "raw infra" credibility; platform limits (restarts → SIGTERM handling is D-required, W14); vendor coupling.
- **Scale story:** stateless API means Railway → ECS/K8s at 10K+/day is a migration, not a redesign (see README scale section).

## D04 — APScheduler over Airflow — `active`
- **Why:** Saves ~1 week of setup; 3 sources × simple schedules don't need DAG dependencies, backfill UI, or a scheduler HA story. I already know Airflow professionally — zero learning ROI here.
- **Cost:** No retry/backfill UI, no cross-job dependency graph. Acceptable: ingestion_runs table + Grafana covers observability.
- **Revisit when:** >5 sources or inter-job dependencies appear.

## D05 — Postgres FTS over OpenSearch/Elastic — `active`
- **Why:** One less service to run/pay for; corpus <1M chunks is well inside FTS territory; Railway-native.
- **Cost (be honest in README):** `ts_rank` is not true BM25 (no doc-length normalization tuning); weaker analyzers for hyphenated identifiers — test event-ID queries explicitly (W4 checklist).
- **Revisit when:** identifier-query evals fail, or corpus >1M chunks → OpenSearch/Vespa.

## D06 — Qdrant Cloud free tier over ChromaDB local / pgvector — `active`
- **Why:** Cloud-from-day-1 is a hard requirement (scale-defensible answer); Chroma-local is the tutorial smell interviewers discount. vs pgvector: dedicated ANN service demonstrates the production shape and keeps vector load off the one Postgres.
- **Cost:** Free-tier limits (1 GB / cluster sleep behavior); one more external dependency + failure mode (circuit breaker W14).
- **Revisit when:** free tier caps out → paid Qdrant vs pgvector cost comparison (pgvector likely wins at small scale — that analysis is README material).

## D07 — nomic-embed-text (local, Ollama) over OpenAI/Voyage embeddings — `active`
- **Why:** $0 at portfolio volume; strong open model; forces learning batching, prefixes, backfill mechanics.
- **Cost:** CPU backfill is slow (run overnight); must remember task prefixes (`search_document:` / `search_query:`) — silent quality degradation if omitted; ties dev to Ollama being up.
- **Revisit when:** embedding-model bakeoff (W6+, L2) shows a paid model buying >5 pts recall@10.

## D08 — LiteLLM self-hosted gateway over direct SDKs / Portkey — `active`
- **Why:** Model = config entry, not code. Enables free↔paid swaps, fallback chains, W8 go/no-go, vLLM-as-config-change story. Portkey adds a SaaS dependency for features I should build once myself (router, W8).
- **Cost:** One more service; LiteLLM version churn; debugging through a proxy adds a layer.
- **ROI:** the single highest leverage-per-hour tool choice in the stack.

## D09 — Free-tier models default (GLM-4-Flash/Air, Groq) + paid escalation — `active`
- **Why:** $5–75/mo budget is a real constraint; cheap-first-with-escalation is also the *correct* production pattern, not just the poor one. Paid Claude Haiku/gpt-4o-mini reserved for eval comparison + W13 grounding-failure escalation.
- **Cost:** Flaky tool-calling and citations on weak models → structured-output enforcement + retry-then-fallback (W8) exist because of this decision. Quality ceiling documented via paid-tier eval delta table.
- **Revisit:** scheduled — W8 CP2 GO/NO-GO: grounding <85% on GLM → swap synthesis to Haiku.

## D10 — LangGraph over hand-rolled FSM — `active`
- **Why:** Checkpointing/replay/interrupts for free; hiring-market keyword at target firms. Honest context: my production doc pipeline avoided frameworks — this workload (cyclic, resumable, budget-gated) is where a graph framework earns its keep.
- **Cost:** Abstraction opacity; version churn; harder profiling. Exit ramp: >2 days fighting the abstraction → ~300-line hand-rolled FSM (pre-authorized in plan).
- **Interview line:** know exactly what LangGraph gives over a while loop (durable state, replay, interrupts) and what it costs.

## D11 — RRF merge over score normalization / native hybrid query — `active`
- **Why:** Rank-based fusion sidesteps incomparable score scales (ts_rank vs cosine); trivially debuggable (both lists logged per trace).
- **Cost:** Two round trips vs one native hybrid call; k=60 is a magic constant until W6 tuning.
- **Revisit when:** eval-tuned weighted RRF (L2); expect lexical to deserve extra weight in an identifier-heavy domain — measure, chart, README.

## D12 — bge-reranker-base local over Cohere Rerank API — `active`
- **Why:** Free; CPU-viable at top-50; teaches cross-encoder mechanics.
- **Cost:** 1–3s latency on CPU; memory (~1.1 GB).
- **Revisit when:** p95 rerank >2s consistently or Railway memory pressure → Cohere (pennies/query, one HTTP call). Pre-approved swap.

## D13 — Custom YAML eval harness over RAGAS/promptfoo as primary — `active`
- **Why:** "I built my eval harness" > "I ran RAGAS" in interviews; deterministic checks + gold-facts rubric + judge calibration need full control. RAGAS runs as report-only supplement; promptfoo is the L2 CI option.
- **Cost:** ~8–10 hrs of build time frameworks would give free; risk of harness bugs measured wrong (mitigation: sabotage test W4).

## D14 — Single calibrated LLM judge over multi-model panel — `active`
- **Why:** Panels triple cost while leaving rubric quality and calibration untouched. Human-graded 15-answer calibration set + reported agreement number (W15) is the credible move.
- **Cost:** Single-judge bias risk — mitigated by deterministic checks carrying the CI gate and judge pinned (model+prompt versioned; changing either invalidates score history).

## D15 — Chainlit over Streamlit/Next.js — `active`
- **Why:** Native chat + streaming + feedback API ≈ zero UI code for the W5 stub; Streamlit chat is clunkier; Next.js is a frontend project I'm not running this quarter.
- **Cost:** Less UI flexibility; version churn (pin it, upgrade in a branch); less transferable frontend skill.

## D16 — Polling ingestion over streaming/queues — `active`
- **Why:** True aviation streaming (SWIM) is enterprise-gated; one consumer needs no Kafka. Jittered polling + high-water marks is the right call at this scale.
- **ADR note:** state precisely when streaming becomes necessary (freshness SLA < poll interval) — that boundary statement is worth more than cargo-culting a message bus.

## D17 — Prompt-injection defense over ITAR output classifier — `active`
- **Why:** Public-domain data isn't export-controlled; ITAR classifier = security theater that domain-savvy interviewers (SpaceX/Anduril) would flag. The corpus IS the untrusted input — injection-via-documents is the real attack surface. Securities disclaimer kept (legitimate).
- **Cost:** none. Strictly better.

## D18 — CPU-only everywhere; ignore MX330; no vLLM — `active`
- **Why:** 2 GB VRAM can't hold a synthesis-worthy model; MX330 speedup on embed/rerank is 2–4x for a CUDA-in-WSL setup tax + torch-pin fights; serving path (Railway) is CPU anyway. vLLM needs GPUs + volume I don't have; renting one ($150–400/mo) obliterates the budget for zero portfolio gain.
- **Kept:** OpenAI-compatible vLLM endpoint slots behind LiteLLM as config — documented as L4, cited in interviews as gateway-abstraction payoff.

## D19 — Ollama scoped to embeddings + offline dev only — `active`
- **Why:** All real inference is hosted APIs (see D09/D18). Ollama's jobs: nomic-embed-text locally, optional 8B for train-wifi coding.
- **Watch:** don't let "it runs locally" scope-creep into serving decisions.

## D20 — Exact-match + structured caching over semantic cache — `active`
- **Why:** Semantic response caching risks serving near-miss answers in a correctness-critical domain, and adds an embedding lookup per query. Exact-match (normalized) + structured-data cache (TTL = poll interval), both validity-keyed so cache can never resurrect expired records.
- **Revisit when:** repeat-query rate in prod traffic justifies semantic layer (L2), with a similarity threshold validated on evals first.

## D21 — Multimodal as measured appendix experiment, not a feature — `active`
- **Chose:** Stretch W14 experiment: vision LLM vs pdfplumber vs XBRL on 15–20 SEC tables, published 3-way table. **Rejected:** vision-based table extraction in the serving path.
- **Why:** XBRL is deterministic, free, and correct for tagged financial data; the *measured comparison* teaches the vision API and reads better than a bolted-on feature.
- **Cost accepted:** No "multimodal feature" bullet; stretch task may get cut if behind.
- **Revisit when:** sources with genuinely unstructured docs (scanned PDFs) enter the corpus.

## D22 — Escalation routing: cheap-first with quality rescue — `active`
- **Chose:** W13: grounding-validator failure on free tier → exactly ONE retry on paid tier (Haiku/4o-mini), rescue-rate logged to Grafana. **Rejected:** paid-by-default; unlimited retries.
- **Why:** Uses the $15 test budget purposefully; produces a measured "how often does cheap fail" number — the routing narrative target-firm interviewers ask for.
- **Cost accepted:** Added latency on rescued queries; small paid spend.
- **Revisit when:** rescue-rate >15% sustained → free tier is too weak, flip the default (ties to D09 go/no-go).

## D23 — Model comparison as eval-suite rerun, not a separate system — `active`
- **Chose:** Stretch W15 bakeoff: rerun the 30-scenario suite with only the synthesizer swapped via LiteLLM config (GLM/Groq/Haiku/4o-mini); harness + Langfuse already capture accuracy, grounding, p95, cost per run → one table. **Rejected:** building a dedicated comparison harness or side-by-side UI.
- **Why:** The gateway (D08) + harness (D13) make this a config change × N runs; zero new code is the whole point and the whole demo.
- **Revisit when:** a side-by-side answer view is wanted for the demo → small UI toggle, L3.

## D24 — Thundering herd: single-flight + stale-while-revalidate + jitter — `active` (ADR-0010 G1)
- **Chose:** Redis SET NX single-flight per normalized query key (TTL 70s > 60s wall-clock cap), followers poll then compute-anyway on timeout; stale-serve window 300s (NEVER on temporal/validity keys, per D20); jitter on all APScheduler jobs and retries.
- **Rejected:** queues, distributed lock managers — wrong scale.
- **Revisit when:** real QPS makes follower-wait a measurable latency line.

## D25 — SLOs defined; burn alerts replace static thresholds — `active` (ADR-0010 G2)
- **Chose:** 99.0% availability; fast p95 ≤8s; agent p95 ≤30s; quality SLO ≥90% of answers grounded ≥0.85. Budget/dead_loop exits are designed degradation, excluded from error SLO. Two-stage budget-burn alerts.
- **Supersedes:** W12 static alert thresholds (cost + fallback alerts survive).

## D26 — Postgres→Qdrant consistency: status-column outbox — `active` (ADR-0010 G3)
- **Chose:** chunks gain embedding_status + content_hash; sync worker (5 min, batch 128, FOR UPDATE SKIP LOCKED, idempotent upserts); divergence window ≤15 min typical (FTS leg covers the gap); nightly count+hash reconciliation; full rebuild only on chunking_version bump.
- **Rejected:** dual-write (couples ingestion to Qdrant uptime), CDC (Kafka-shaped infra for one consumer).

## D27 — Admission control + degrade ladder, separate from budget — `active` (ADR-0010 G4)
- **Chose:** AGENT_MAX=4, FAST_MAX=12, INFLIGHT_HARD=16 at middleware; timeout → agent degrades to fast-path with visible notice, fast → 429; SLO burn pauses background jobs. Admission = "may it start"; budget = "may it continue" — never merged (eval runs bypass admission).
- **Revisit when:** rerank moves off-box (D12 swap) → AGENT_MAX can rise.

## D28 — SIGTERM drain reuses the budget exit — `active` (ADR-0010 G5)
- **Chose:** drain deadline becomes a 4th budget input; in-flight agents exit via the existing partial-synthesis path; health flips 503; APScheduler shutdown(wait=False) is safe because D26 sync is idempotent. VERIFY at W14: Railway grace period.
- **Rejected:** a second abort mechanism (untested deploy-only code) and resume-after-deploy UX (deferred; checkpoints keep it possible).

## D29 — Pool sizing by formula from admission caps — `active` (ADR-0010 G6)
- **Chose:** pool_max = admission cap × per-request holds + background reserves. asyncpg max 15 (sessions per-operation, NOT per-request), Qdrant 8, Redis 20, provider HTTP 12. VERIFY at W14: Railway Postgres plan connection limit.
- **Rule:** G4 caps and pools are one decision — change together.

## D30 — Agent FSM semantics — `active` (SPEC-0011 Part 1)
- **Chose:** 6 states; termination_reason stays {answered, budget, dead_loop, error} with error-overrides precedence; orthogonal answer_completeness (full|partial) field. Judge = sub-question→evidence mapping (gaps are the unmapped items), fails OPEN with judge_error flag. Dead-loop = deterministic normalize+hash with identifier preservation ([A-Z0-9-]{4,}); embedding-similarity deferred to L2. Zero-tool plans forbidden first cycle only. Replan cap 2, tied to $0.10 math and the D24 timing chain.
- **Chain (change together or not at all):** follower wait 15s < agent p95 30s < wall-clock 60s < lock TTL 70s.

## D31 — Two-layer eval harness; RAGAS promoted — `active` (SPEC-0011 Part 2, amends D13)
- **Chose:** Layer 1 = RAGAS metrics as engine over 4 labeled sets (E/N/L fast-path + X multi-hop), routes scored separately, X thresholds deliberately lower; Layer 2 = custom trace assertions (routing, termination, replan, budget-bait, fault injection) + one 4-criterion 0/1 rubric (replan targeting). Custom harness still orchestrates + gates; deterministic checks remain per-commit.
- **Amends D13:** RAGAS moves from report-only to Layer-1 metric engine; pinned (judge model, embeddings, version) like D14.

## D32 — Retrofit-hostile decisions made at file-creation time — `active`
- **Chose (all W1–W2, ~zero hours):** (1) response envelope carries `status` + `request_id` from day one so async `{"status":"processing"}` is representable later WITHOUT a contract break — but the poll endpoint itself is DEFERRED until a real consumer needs it (evals want blocking; agent p95 30s fits HTTP; Chainlit streams); (2) `embedding_model_version` + `reranker_version` on chunks and `prompt_version` on interactions in the first migration — without them, W6 recall deltas and the bakeoff can't separate model change from corpus growth; (3) request_id middleware at W1 so W2–W4 ingestion bugs are debugged with correlated logs; (4) fixed JSON log schema (request_id, route, latency_ms, cost, extras) at W1 so W12 dashboards don't collide with a log-format migration; (5) secrets access enforced by ruff banned-api (`os.environ`/`os.getenv` only in config.py) from PR #1 — a failing CI check, not a convention.
- **Principle:** columns, envelopes, correlation ids, and formats are free at creation and migrations later; when in doubt, reserve the shape now and build the machinery when needed.
- **Rejected:** building the async poll endpoint at W1 (infrastructure without a consumer; complicates every eval assertion).

## D32 — Retrofit-hostile decisions made at file-creation time — `active` (W1–W2)
- **Chose:** five near-zero-cost early commitments: (1) versioned /v1/query response envelope with status + request_id (async-capable later; poll endpoint itself DEFERRED until a real consumer — evals want blocking); (2) embedding_model_version, reranker_version, prompt_version columns in the W2 migration alongside chunking_version — preserves W6 recall attribution and A/B/post-hoc analysis; (3) request_id middleware at W1 so W2–W5 ingestion bugs are correlated; (4) fixed JSON log schema (request_id, route, latency_ms, cost, extras) from W1 — no W12 logging-format migration; (5) config.py-only env access enforced as a ruff banned-API rule from PR #1 (TID251), making a secrets-manager swap a one-file change.
- **Why:** these are free at file creation and expensive as migrations; the theme is the same as effective_from/to and source_url in W2.
- **Rejected:** building the async poll endpoint now (job storage + result retrieval with no consumer; agent p95 30s fits blocking HTTP; Chainlit streams).

---

## Template for new entries

## D## — <decision> — `active`
- **Chose / Rejected:**
- **Why:**
- **Cost accepted:**
- **Revisit when:**
- **Verdict (after ≥2 weeks living with it):**
