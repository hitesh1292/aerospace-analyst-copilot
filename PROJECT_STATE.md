# PROJECT_STATE — read this first

One-paragraph orientation for a new (human or model) session, then a map. Do not re-derive settled
decisions; do not restructure; check "open" items before assuming something is missing.

**What this is:** Aerospace Analyst Copilot — agentic RAG over SEC EDGAR + NTSB + Launch Library 2;
FastAPI + Postgres + Qdrant + LiteLLM + LangGraph + Chainlit on Railway. Portfolio project,
production-shaped at portfolio scale, Senior-level scope. Status: **planning + design complete;
build starts at W1 of the 16-week plan. Nothing is deployed yet.**

## The map
| Artifact | Location | What it settles |
|---|---|---|
| 16-week plan (7 tabs incl. Project Introduction, Sub-Tasks, Live Metrics) | Aerospace_Copilot_16wk_Plan_v10.xlsx | what gets built, when, how, and how success is measured |
| Architecture diagrams (3) | docs/architecture.html | target-state (W16) components, query flow, agent loop |
| Decisions ledger D01–D31 | docs/DECISIONS.md | every tradeoff + revisit triggers; Verdict lines pending |
| Hardening spec (herd, SLO, consistency, shedding, SIGTERM, pools) | docs/adr/0010-*.md | concrete configs; two VERIFY items for W14 |
| Agent FSM + eval harness spec | docs/adr/0011-*.md | states, termination semantics, 2-layer evals, coverage audit |
| Consolidated reasoning | docs/PLAYBOOK.md | the WHY across 0010+0011; read before changing mechanisms |
| Phase 2 multi-agent design (deferred) | docs/FUTURE_ARCHITECTURE.md | designed, not planned; thresholds for when it would ever be justified |
| AI collaboration rules | CLAUDE.md | build-mode policy (SELF/ASSIST/GEN) — binding |
| Repo layout + creation script | REPO_STRUCTURE.md | copy-paste tree + one-command scaffold |
| Environment | pyproject.toml | uv-ready deps (CPU torch pinned via index); commit uv.lock |
| Living docs | docs/TODO, FAILURES, LESSONS, WATCHOUTS | maintained via /log-* and /weekly-review |
| Intro for outsiders | README.md | plain-language what/why + honest landscape |
| Copy-ready repo tree + bootstrap | docs/REPO_STRUCTURE.md + scripts/bootstrap_repo.sh | one command creates the layout |
| Env + deps for uv | pyproject.toml | `uv sync` (CPU torch + D32 lint preconfigured) |
| System design synthesis + interview essentials | docs/SYSTEM_DESIGN.md | ten-minute read; targets → measured at W15 |
| UI preview progression (W5 → W8 → W16) | docs/app_mockups.html | per-week frames to compare the real build against; W16 fixes tagged |

## Decided (do not reopen without a revisit trigger firing)
Scope (3 sources, D01), stack (D03–D08), retrofit-hostile W1 commitments (D32), model tiering + escalation (D09, D22), LangGraph (D10),
retrieval shape (D05–D07, D11–D12), eval philosophy (D13 as amended by D31, D14), hardening (D24–D29), W1-retrofit-proofing (D32),
FSM semantics incl. termination set + fail-open judge (D30), two-layer evals (D31).

## Open / pending
- Verdict lines in DECISIONS.md (written after living with each decision ≥2 weeks).
- W8 GLM go/no-go (scheduled decision, D09). W14 VERIFY items: Railway grace period, PG conn limit.
- Mockup fixes: RESOLVED — corrected mockups at docs/app_mockups.html (fixes tagged); 40-ticker expansion now a W14 task.
- docs/SLO.md to be written at W12 per D25. Stretch tasks (multimodal, bakeoff) — cut freely.

## Rules that trip people up (full list: docs/WATCHOUTS.md)
Timing chain 15<30<60<70 changes together · sessions per-operation (pool math) · no stale-serve on
temporal keys · eval runs bypass admission · judge fails open by design.
