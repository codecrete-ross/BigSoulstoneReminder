# AGENTS.md

This is the canonical shared governance file for repository-level agent guidance.

If guidance applies across tools, write it here first. Keep `CLAUDE.md` as a thin Claude adapter and avoid duplicating shared instructions across files.

## What This Is

BigSoulstoneReminder is a World of Warcraft addon for Warlocks. It shows a Soulstone reminder and clears only when the player's own Soulstone is active on themselves or on a current group member.

## Project Structure

- `BigSoulstoneReminder.toc` - addon metadata and interface version
- `BigSoulstoneReminder.lua` - all addon code
- `scripts/deploy.ps1` - local deploy script for the WoW addon folder
- `CHANGELOG.md` - curated end-user changelog
- `.pkgmeta` - CurseForge packager config

## Core Workflow

1. Edit `BigSoulstoneReminder.toc` and `BigSoulstoneReminder.lua`.
2. Deploy locally with:
   `powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1`
3. Test in-game with `/reload` and the addon slash commands.
4. Wait for user confirmation before committing, pushing, tagging, or releasing.

## Key Rules

- Retail only. Keep the addon standalone and lightweight.
- The reminder should clear only when the player's own Soulstone is active. If ownership is unclear, keep the reminder visible.
- Respect aura visibility restrictions. Pause or refresh appropriately instead of assuming state.
- No external dependencies.
- Keep `AGENTS.md`, `CLAUDE.md`, and `.claude/` out of packaged addon artifacts via `.pkgmeta`.

## Slash Commands

- `/bsr status`
- `/bsr refresh`
- `/bsr debug`
- `/bsr demo missing`
- `/bsr demo soon 15`
- `/bsr demo hide`
- `/bsr demo off`
