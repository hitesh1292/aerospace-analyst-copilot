#!/usr/bin/env bash
# Creates the full aerospace-copilot tree per docs/REPO_STRUCTURE.md. Run in an EMPTY repo dir.
set -euo pipefail
dirs=".github/workflows .claude/commands .claude/skills/docs-scribe alembic/versions \
src/api/routers src/db src/ingestion src/retrieval src/gateway src/synthesis/prompts \
src/agent/tools src/guardrails src/obs src/cache \
evals/graders/prompts evals/scenarios/retrieval evals/scenarios/agent evals/scenarios/temporal \
evals/scenarios/adversarial evals/scenarios/ragas evals/scenarios/holdout evals/calibration evals/reports \
ui/.chainlit dashboards experiments/multimodal_tables experiments/model_bakeoff scripts notebooks \
docs/adr tests/unit tests/integration"
for d in $dirs; do mkdir -p "$d"; done

pyfiles="src/__init__.py src/main.py src/config.py src/exceptions.py \
src/api/__init__.py src/api/middleware.py src/api/deps.py src/api/schemas.py src/api/admission.py \
src/api/routers/__init__.py src/api/routers/health.py src/api/routers/query.py src/api/routers/feedback.py \
src/db/__init__.py src/db/engine.py src/db/models.py src/db/repos.py \
src/ingestion/__init__.py src/ingestion/base.py src/ingestion/edgar.py src/ingestion/ntsb.py \
src/ingestion/ll2.py src/ingestion/chunking.py src/ingestion/scheduler.py \
src/retrieval/__init__.py src/retrieval/interface.py src/retrieval/fts.py src/retrieval/vector.py \
src/retrieval/embeddings.py src/retrieval/rrf.py src/retrieval/rerank.py src/retrieval/temporal.py \
src/gateway/__init__.py src/gateway/client.py src/gateway/router.py src/gateway/escalation.py \
src/synthesis/__init__.py src/synthesis/synthesize.py src/synthesis/grounding.py \
src/agent/__init__.py src/agent/state.py src/agent/graph.py src/agent/budget.py src/agent/judge.py \
src/agent/loops.py src/agent/fastpath.py src/agent/tools/__init__.py src/agent/tools/retrieval_tool.py \
src/agent/tools/sql_tool.py src/guardrails/__init__.py src/guardrails/scope.py src/guardrails/injection.py \
src/guardrails/disclaimer.py src/obs/__init__.py src/obs/logging.py src/obs/tracing.py src/obs/metrics.py \
src/cache/__init__.py src/cache/keys.py src/cache/redis_cache.py src/cache/breakers.py \
evals/harness.py evals/graders/deterministic.py evals/graders/judge.py \
ui/app.py ui/components.py scripts/seed_db.py scripts/backfill_embeddings.py scripts/rebuild_index.py \
scripts/reconcile_qdrant.py tests/conftest.py"
for f in $pyfiles; do [ -f "$f" ] || touch "$f"; done

touch src/gateway/litellm_config.yaml ui/.chainlit/config.toml alembic.ini alembic/env.py \
  .env.example .gitignore .pre-commit-config.yaml Dockerfile docker-compose.yml railway.toml \
  .github/workflows/ci.yml docs/adr/0000-template.md \
  src/synthesis/prompts/synthesis_v1.md src/synthesis/prompts/planner_v1.md \
  src/synthesis/prompts/judge_v1.md src/synthesis/prompts/sufficiency_v1.md \
  src/synthesis/prompts/classifier_v1.md evals/graders/prompts/replan_targeting_v1.md \
  notebooks/00_edgar_exploration.ipynb notebooks/01_chunking_eyeball.ipynb notebooks/02_retrieval_debug.ipynb
echo "3.12" > .python-version
echo "Tree created. Next: copy pyproject.toml + docs/ + .claude/ + CLAUDE.md from the scaffold, then: uv sync"
