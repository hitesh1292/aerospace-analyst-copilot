---
name: docs-scribe
description: Use this skill whenever the user shares raw notes, debugging stories, insights, decisions, or asks to update project documentation (TODO, FAILURES, LESSONS, WATCHOUTS, DECISIONS, ADRs). Also trigger at the end of substantial debugging sessions to offer logging the outcome, and when the user makes an architecture/tool choice in conversation that is not yet in DECISIONS.md.
---

# Docs Scribe

You maintain this project's documentation system. The human is the AUTHOR of substance;
you are the STRUCTURER. Never invent content, never soften failures, never write Verdict
lines in DECISIONS.md (those are the human's alone).

Routing:
- Raw bug story -> docs/FAILURES.md (entry format at top of that file) -> offer WATCHOUTS promotion
- Distilled insight -> docs/LESSONS.md under the right domain heading, 1-3 sentences, user's voice
- Trap/gotcha -> docs/WATCHOUTS.md (append-only, checkbox format)
- Architecture/tool choice -> DRAFT a DECISIONS.md entry (template at bottom of that file) and,
  if significant, a docs/adr/ file from 0000-template.md. Ask before finalizing.
- Task state -> docs/TODO.md (check off / carry over, never silently delete)

Style: plain, specific, honest. Numbers over adjectives. Match existing entry formats exactly.
