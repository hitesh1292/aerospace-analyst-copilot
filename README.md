# Aerospace Analyst Copilot

An agentic RAG system that answers analyst questions over three public aerospace data sources —
SEC EDGAR filings, the NTSB aviation incident database, and Launch Library 2 launch schedules —
with every answer grounded in citations that link back to the original public record.

**Purpose.** A portfolio project built production-shaped at portfolio scale: every discipline of a
production system (evals gating CI, grounding validation, temporal correctness, SLOs, admission
control, observability) present and measurable, at Senior-engineer scope on free-tier infrastructure.
It exists to demonstrate — and to learn, by building — how grounded LLM systems are engineered, not
to compete with commercial products.

## The problem it addresses
The raw data is public but hostile to questions. An analyst asking "do the risk factors Boeing
disclosed in its latest 10-K show up in its actual incident record?" today spends 2–4 hours across
EDGAR full-text search, NTSB queries, and manual cross-referencing. The gap isn't access — it's
synthesis: multi-source questions need retrieval, joining, and honest sourcing. This system answers
in seconds with clickable citations, a confidence signal, and explicit refusal when the evidence
isn't there.

## Competitive landscape (honest framing)
- **AlphaSense** — commercial financial-research copilot over filings, transcripts, and broker
  research; vastly broader corpus and enterprise features. This project differs in scope (three
  sources, aerospace-only), in transparency (public evals, published grounding rates), and in being
  a learning artifact, not a product.
- **Bloomberg Terminal / BQuant AI features** — unmatched data breadth and market data integration.
  No comparison intended; this project's aerospace-incident + launch-schedule joins are simply a
  niche those tools don't target.
- **Slingshot Aerospace / space-domain awareness platforms** — proprietary sensor and tracking data
  with real operational customers. This project uses only public data by design; its launch-schedule
  source is informational, not operational.
- **Open-source "chat with EDGAR" demos** — the closest genre. The difference is engineering depth:
  calibrated eval gates in CI, temporal validity on time-bounded records, injection defense on an
  untrusted corpus, defined SLOs, and a bounded agent FSM — the parts tutorials skip.

This is portfolio-scale work: no claim of superiority over commercial tools, and its limitations are
documented rather than hidden (see docs/DECISIONS.md and eval reports).

## The app views (per design mockups)
One Chainlit app; a `?dev=1` flag reveals the engineering layer.
1. **Analyst view** — chat with streamed answers; per-query source chips ("EDGAR · 2 filings"); the
   right panel is always evidence: the source passage with supporting text highlighted, a "View on
   SEC EDGAR" link, and copy-with-citation. Feedback stars sit on the answer. Nothing
   engineering-flavored appears here.
2. **Dev view (`?dev=1`)** — same skeleton plus: the agent's plan and budget usage above the answer,
   a monospace trace strip (request_id, latency, cost, grounding score, Langfuse link) below it, and
   a trace-details panel (retrieval routes with rank + rerank scores, tokens, model, temporal-validity
   check, Grafana links). By v1.0.0 it also carries the A/B experiment badge and a replay-checkpoint
   link that re-runs a past agent execution from its LangGraph checkpoint.

**Known limitation (stated, not hidden):** `?dev=1` is a demo convenience, not access control —
anyone with the param sees the trace layer. Acceptable for a public-data portfolio project;
L2 upgrade: API-key-gated debug role.

## Where everything lives
Start with **PROJECT_STATE.md** (the map), then docs/DECISIONS.md (D01–D31), docs/adr/ (deep
specs, esp. 0010 hardening and 0011 FSM+evals), docs/PLAYBOOK.md (the reasoning), the 16-week plan
xlsx (tasks, sub-tasks, metrics), and docs/architecture.html (three diagrams).
