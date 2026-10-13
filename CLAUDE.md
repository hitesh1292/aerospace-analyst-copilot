# Aerospace Analyst Copilot — Claude Code Project Guide

Agentic RAG over SEC EDGAR + NTSB + Launch Library 2. FastAPI + Postgres + Qdrant + LiteLLM + LangGraph + Chainlit, deployed on Railway. Solo builder, ~11 hrs/wk, 16-week plan (see plan xlsx / docs/TODO.md).

## THE PRIME DIRECTIVE — learning policy (do not violate)

This is a learning-first project. Every sub-task carries a Build Mode:

- **SELF** → DO NOT write or edit this code, even if asked casually. Instead: explain concepts, point to docs, review my written code, ask Socratic questions. If I'm stuck >30–45 min I will explicitly say "downgrade to assist" — only then debug WITH me (smallest possible diff, explain why).
- **AI-ASSIST** → I write first. You review, explain errors, propose minimal fixes with reasoning.
- **AI-GEN** → You may generate fully (boilerplate: CI yaml, Dockerfile, configs, scaffolds, chart scripts). Always add brief comments so I can read every line.

When unsure which mode applies: ask, or default to SELF behavior. SELF-marked domains: chunking, retrieval/RRF, synthesis prompts, agent state/graph/budget, evals harness, grounding validator, temporal filtering, multi-hop.

## What you SHOULD do proactively (any mode)

- Maintain the docs system (see below) — structuring my raw notes is always allowed and encouraged.
- Flag when current work contradicts a DECISIONS.md entry, or deserves a new entry.
- Flag newbie traps from docs/WATCHOUTS.md when relevant to the file being touched.
- Run/write tests, run ruff, run the eval harness, summarize eval reports.

## Docs system (you are the scribe; I am the author of substance)

- `docs/TODO.md` — current week's tasks. Keep synced with reality; check off, carry over, never silently delete.
- `docs/FAILURES.md` — every bug/dead-end that cost >30 min. I dump raw notes; you structure into the entry format. Never soften what went wrong.
- `docs/LESSONS.md` — distilled "what I now understand." You may propose entries from FAILURES; I approve wording.
- `docs/WATCHOUTS.md` — forward-looking traps. Append-only.
- `docs/DECISIONS.md` — tradeoffs ledger. You may DRAFT entries when you see a decision being made; I finalize. Verdict lines are mine alone.
- `docs/adr/` — one file per major decision, long-form, linked from DECISIONS.md.
- `docs/PLAYBOOK.md` — consolidated judgment calls behind ADR-0010 + SPEC-0011. Read before touching the agent, cache, admission, pools, or evals.
- `docs/SLO.md` (to be written W12 per D25) — targets are commitments; alerts are burn-based.
- `PROJECT_STATE.md` — the map; new sessions read it first.
- End of each week: run `/weekly-review`.

## Conventions

- Python 3.12, uv, lockfile committed. Ruff clean before commit.
- All routes under `/api/v1` (health check: `curl localhost:8000/api/v1/health` — bare /health 404s).
- Prompts are versioned files in `src/synthesis/prompts/`, never inline strings.
- Every LLM call goes through the LiteLLM gateway; never import a provider SDK directly.
- Every external call: timeout + tenacity retry; every query: request_id threaded through Langfuse/Postgres/logs.
- Migrations via alembic only; models carry source_url and effective_from/to.
- Repo lives in WSL filesystem (~/projects), never /mnt/c.

## Commands

- `uv run pytest` · `uv run ruff check --fix` · `uv run python evals/harness.py --suite all`
- `docker compose up -d` (postgres, redis, litellm) · `railway logs`
