---
name: skillsh-router
description: Use when you notice a capability gap and are about to look for or install a skill from skills.sh (e.g. "how do I do X", "is there a skill for X", or you're considering calling find-skills / npx skills). Explains how to check learned routes first and defers actual discovery to find-skills.
---

# skillsh-router

A thin, self-updating routing layer on top of `find-skills` (vercel-labs/skills). It does not replace find-skills — it decides *when* find-skills' search-and-install round trip is actually needed, and remembers the answer once a pattern repeats.

## How it works

Three hooks (SessionStart, UserPromptSubmit, PostToolUse) run outside the model and maintain `data/routes.json`:

- Every `npx skills add <pkg> -g` you (or find-skills) run is recorded against the package it installed.
- Once the **same package** has been installed via `skills add` **3 times**, it's promoted from a candidate to a *route*: a keyword set mapped to that skill.
- From then on, SessionStart injects the full list of routes at the start of every session, and UserPromptSubmit injects a one-line suggestion whenever a new prompt's keywords clearly match a route.

You never edit `data/routes.json`, `data/.pending-find.json`, or call the hook scripts directly — they are fully automatic.

## What to do

1. **Check for an injected route first.** If context already contains a `🔁 skillsh-router 学習ルート` suggestion (from UserPromptSubmit) or a "学習済みルート" list (from SessionStart) that clearly matches what you need, use that skill directly via the `Skill` tool. Do **not** run `npx skills find` or invoke find-skills for something a route already answers — that's the entire point of this layer.
2. **No matching route → let find-skills handle it.** Don't hand-roll skill discovery. Let find-skills' own trigger conditions fire naturally (asking "how do I X", "is there a skill for X", wanting to extend capabilities), and let it run `npx skills find <query>` → filter by quality (installs, source reputation, stars) → `npx skills add <owner/repo@skill> -g -y`. The PostToolUse hook observes this automatically; you don't need to do anything extra for the learning to happen.
3. **Global installs only get learned.** Routes are only built from `-g`/`--global` installs, so they resolve the same way regardless of which project you're in. A project-local `skills add` (no `-g`) still works, it's just invisible to this router.
4. **A suggested route is a hint, not a rule.** If the user's actual intent doesn't match what the injected route implies, ignore the suggestion and reason normally (fall back to find-skills, or to your own judgment) — a stale or over-broad keyword match should never force the wrong skill.
5. **Optional: sharpen a candidate's keywords.** If you just resolved a genuinely new capability via find-skills and can tell the keywords under which it'll likely be asked for again, you may run `bin/note-route <owner/repo@skill> <keyword> [<keyword> ...>]` to seed/extend that candidate's keyword list ahead of the next `hit_count` update. This is optional and never required — the counting and promotion themselves are always automatic.

## Non-goals

- This skill does not search skills.sh itself, evaluate skill quality, or decide which package to install — that's find-skills' job.
- It does not gate or block `npx skills` commands — it only makes the "have I basically already answered this?" check fast and automatic.
