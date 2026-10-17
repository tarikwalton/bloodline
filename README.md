# BLOODLINE

A Roblox arena combat project inspired by KAT.

## Status

Early development. The repository currently contains 14 Luau server-side source files. The expected Studio hierarchy, shared modules, client scripts, and map/weapon assets are not included in the baseline snapshot. A clean-checkout startup and gameplay session have **not** been verified.

The first goal is **M0 — Reproducible two-player FFA**: recover dependencies, establish setup, and complete two consecutive local rounds.

- [Baseline, dependency inventory, and M0 acceptance](docs/MVP_BASELINE.md)
- [Linear project](https://linear.app/bloodlinerblx/project/bloodline-mvp-baseline-646d32ef30bc)

## Proposed MVP

One graybox arena, free-for-all, one gun, one knife, respawns, match scoring, and a minimal HUD. These are planning defaults, not claims of completed features. Progression, monetization, trading, abilities, more modes, and 50-player performance validation are deferred.

## Requirements and getting started

Roblox Studio is the target runtime; scripts use Luau. No Node application or package.json is needed by the current source.

**Setup is blocked on dependency recovery.** This repository cannot yet be documented as a standalone runnable game.

1. Start with [BLO-5: dependency recovery](https://linear.app/bloodlinerblx/issue/BLO-5/inventory-and-recover-required-project-dependencies).
2. Locate the original Studio place/export and compare its modules and assets against the dependency inventory.
3. Establish the actual source-to-Studio mapping and document tool versions and exact acquisition/import steps.
4. Run a local server with two clients and record the M0 checklist results.

Prefer a versioned Rojo mapping once the original hierarchy and assets are recovered. Rojo is a proposed workflow, not an installed or configured dependency.

## Source guide

Current files are flat at repository root. Code expects nested folders; moving files without their dependencies is insufficient.

| Source | Responsibility indicated by code |
| --- | --- |
| ServerMain.server.luau | Initializes networking; loads services, calls all Init methods, then all Start methods |
| CombatService.luau | Server health/armor and damage/death pipeline |
| WeaponService.luau, ProjectileService.luau, LagCompensationService.luau | Weapon requests, projectiles, and lag compensation |
| PlayerService.luau, KillService.luau | Player lifecycle and kill processing |
| MapService.luau, MatchService.luau | Map lifecycle, match state, scoreboard, results |
| ModeBase.luau, FreeForAll.luau | Mode base and free-for-all implementation |
| Bot.luau, BotBrain.luau, BotService.luau | Bot representation, behavior, and coordination |

These responsibilities come from static source review; they do not establish runtime correctness.

## Architecture and configuration

Services share references through Init(services); Start begins service work. CombatService owns server-side health and damage permissions. MatchService defines Waiting → Intermission → Loading → InProgress → Ended → lobby/Waiting transitions.

Expected shared configuration modules include GameConfig, ModeConfig, MapConfig, MovementConfig, and BotConfig. Their values and schemas must be recovered before documenting round timings, damage, spawn behavior, or defaults.

## Testing

Follow the [M0 checklist](docs/MVP_BASELINE.md#m0-acceptance-checklist). Record tested commit, environment, expected/actual results, and defects. No runtime test has been run for this documentation baseline.

## Design reference

An existing artifact named **BLOODLINE UI Kit.html** is available outside this repository. It uses a dark palette with crimson accents. Import or link a verified repository-accessible reference after checking asset/font rights; the artifact is a visual reference, not an implemented Roblox HUD.

## Contributing and rights

Use a focused branch and pull request; include validation and distinguish proposals from verified behavior. Keep secrets out of source. Track follow-up work in the Linear project above.

No license file is present in the inspected snapshot. Record asset provenance and obtain an explicit licensing decision before adding a license or redistributing third-party assets.
