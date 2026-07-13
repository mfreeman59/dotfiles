# skillsh-router

A learned routing layer on top of [find-skills](https://www.skills.sh/vercel-labs/skills/find-skills) (skills.sh's own skill-discovery meta-skill).

find-skills already knows how to search skills.sh and install what it finds via `npx skills`. What it doesn't do is remember: every capability gap runs the same search → filter → install round trip, even for something you've already resolved several times before.

skillsh-router adds a small, fully deterministic memory around it:

- Every global `npx skills add <pkg> -g` you (or find-skills, acting on your behalf) run is recorded against the package it installed.
- Once the **same package** has been installed **3 times**, it's promoted from a candidate to a *route* — a set of keywords mapped to that already-installed skill.
- From then on, a new prompt whose keywords clearly match a route gets a direct suggestion to use that skill, bypassing find-skills' search entirely. If find-skills does still get invoked (e.g. on a machine where the skill isn't installed yet), it already knows the exact package to install — no search needed.

Everything that needs to be deterministic (matching, counting, promotion) lives in three Claude Code hooks, not in model judgment. The only place judgment is involved is deciding whether an injected suggestion actually fits — see `skills/skillsh-router/SKILL.md`.

## Layout

```
claude/
  install.sh / uninstall.sh   # setup / teardown
  hooks/                       # SessionStart, UserPromptSubmit, PostToolUse
  lib/routes.sh                 # shared routes.json read/write/promote logic
  skills/skillsh-router/         # the router skill Claude reads
  bin/note-route                # optional: seed a candidate's keywords by hand
  data/routes.json               # the learned routes (committed)
  data/.pending-find.json        # find<->add correlation scratch file (gitignored)
```

## Install

```bash
cd ~/dotfiles/claude
./install.sh
```

This is idempotent — re-run it any time after `git pull` on a machine where you've already installed it once. It:

1. Backs up `~/.claude/settings.json`, then merges in the three hook entries (never symlinks the file itself — it holds real live state this repo doesn't otherwise manage).
2. Symlinks `~/.claude/skills/skillsh-router` -> `claude/skills/skillsh-router`.
3. Installs `find-skills` globally via `npx skills add vercel-labs/skills --skill find-skills -g -y`.

Start a new Claude Code session afterward to pick up the SessionStart hook.

## Bringing this to a new machine

Clone dotfiles to `~/dotfiles` as usual, then run `claude/install.sh`. Because `data/routes.json` is committed, whatever you've already learned on other machines comes with it — a route with no matching package installed locally just means find-skills' next install call already knows the exact package, skipping straight past the search step.

## Uninstall

```bash
cd ~/dotfiles/claude
./uninstall.sh
```

Removes the three hook entries and the skill symlink. Leaves `find-skills` and `data/routes.json` in place — delete `claude/data/` by hand if you actually want to forget what's been learned.

## Tuning

- `SKILLSH_ROUTER_THRESHOLD` (env var, default `3`): how many `skills add` hits before a candidate promotes to a route.
- `SKILLSH_ROUTER_PENDING_WINDOW` (env var, default `1800` seconds): how long a `skills find` query stays eligible to be correlated with a later `skills add`.

Both only need to be set in the environment the hooks run in (e.g. exported from your shell profile) — they aren't baked into `install.sh`.
