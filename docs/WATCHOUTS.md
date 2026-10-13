# WATCHOUTS.md — traps to avoid (append-only)

> Forward-looking. Seeded from planning; grows from FAILURES.md promotions.

## Seeded (from planning phase)
- [ ] nomic-embed-text REQUIRES task prefixes (`search_document:` / `search_query:`) — omitting silently degrades retrieval
- [ ] Chunk by TOKENS not characters — char-based chunks silently truncate at embed time
- [ ] `model.encode()` in batches — per-chunk loop is 30–50x slower
- [ ] Rerank the top-50, not top-10 — the reranker's value is rescuing ranks 15–40
- [ ] Validate grounding against the SPECIFIC cited chunk, not pooled chunks
- [ ] Test the EMPTY-retrieval path early — first hallucination comes from the model answering parametrically
- [ ] Wall-clock timeout on the agent loop — steps/tokens caps don't catch a hung tool call
- [ ] `return_exceptions=True` → CHECK which results are exceptions before passing to prompts
- [ ] Cache keys must include temporal validity — never resurrect expired records
- [ ] Refusal/parse-fail → different model, never naked retry on the same one
- [ ] Postgres ts_rank ≠ true BM25 — test identifier queries explicitly, say so in ADR
- [ ] Router prefixes: /api/v1/health, not /health (the 404 lesson)
- [ ] Repo in WSL filesystem, never /mnt/c (10–20x IO penalty)
- [ ] Torch CPU wheel BEFORE sentence-transformers drags in CUDA (~2.5 GB wasted)
- [ ] WSL clock skew after sleep breaks SSL: `sudo hwclock -s`
- [ ] Pin Chainlit + LangGraph; upgrade in a branch only
- [ ] Groq rotates model IDs — read from config, verify current ID, never hardcode
- [ ] Judge model+prompt are pinned; changing either invalidates score history
- [ ] Don't tune prompts against the eval set — 5 held-out scenarios never influence development

## Promoted from FAILURES
- (none yet)
- [ ] STRETCH tasks (multimodal, bakeoff) never delay a checkpoint - cut them without guilt if behind
- [ ] Sessions per-OPERATION, never per-request — session-per-request silently breaks the D29 pool math
- [ ] Stale-while-revalidate is BANNED on temporal/validity cache keys (D24 + D20)
- [ ] The timing chain 15s < 30s < 60s < 70s was chosen together — never change one number alone (D30)
- [ ] Eval runs bypass admission control (or run at idle) — otherwise results depend on system load (D27)
- [ ] Judge fails OPEN, grounding validator is the safety net — don't "fix" it to fail closed (D30)
