# AGENTS.md

This is the canonical shared governance file for repository-level agent guidance.

If guidance applies across tools, write it here first. Keep `CLAUDE.md` as a thin Claude adapter and avoid duplicating shared instructions across files.

## What This Is

BigSoulstoneReminder is a World of Warcraft addon for Warlocks. It shows a Soulstone reminder and clears only when the player's own Soulstone is active on themselves or on a current group member.

## Project Structure

- `BigSoulstoneReminder.toc` - addon metadata and interface versions for Retail and Forever
- `BigSoulstoneReminder.lua` - all addon code
- `scripts/deploy.ps1` - local deployment to installed Retail and Forever clients
- `CHANGELOG.md` - curated end-user changelog
- `.pkgmeta` - CurseForge packager config

## Core Workflow

1. Update the addon for both clients and add release notes to `CHANGELOG.md`.
2. Deploy locally with `powershell -ExecutionPolicy Bypass -File .\scripts\deploy.ps1`. The script finds installed Retail and Forever clients and uses the latest changelog version in their TOCs. Use `-WoWInstallRoot` to specify a World of Warcraft directory or `-WoWAddOnsRoot` to deploy to a single AddOns directory.
3. For authorized in-game checks, use `/reload` and the addon slash commands in both clients.
4. Wait for user confirmation before committing, pushing, tagging, or releasing. Submit the release commit through a pull request to `main`. After merging, tag the released commit with the changelog version and run `git push origin <version>`. Publish the GitHub release for that tag. The existing push webhook packages the addon on CurseForge. Verify that the file lists both Retail and Forever.

## Key Rules

- Support Retail and Forever in one standalone addon. Use `WOW_PROJECT_CAMELOT` to identify Forever.
- Retail uses the Soulstone spell. Forever uses the Create Soulstone spellbook ranks and the stones' item cooldowns and Soulstone Resurrection buffs. [Retail API source](https://github.com/Gethe/wow-ui-source/tree/live/Interface/AddOns/Blizzard_APIDocumentationGenerated) · [Forever API source](https://github.com/Gethe/wow-ui-source/tree/forever/Interface/AddOns/Blizzard_APIDocumentationGenerated) · [Forever spell ranks](https://zephras.com/forever/enUS/spell/693/)
- The reminder should clear only when the player's own Soulstone is active. If ownership is unclear, keep the reminder visible.
- Respect aura visibility restrictions. Pause or refresh appropriately instead of assuming state.
- No external dependencies.
- Keep `AGENTS.md`, `CLAUDE.md`, `.claude/`, and `scripts/` out of packaged addon artifacts via `.pkgmeta`.

## Slash Commands

- `/bsr status`
- `/bsr refresh`
- `/bsr debug`
- `/bsr demo missing`
- `/bsr demo soon 15`
- `/bsr demo hide`
- `/bsr demo off`
