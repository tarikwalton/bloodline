# Bloodline minimum viable baseline

## Evidence and scope

Reviewed main commit `23e8d664b6470126573995dc10fa05aa7c44f198` on 2026-10-16 (America/Phoenix). Repository contents and all 14 Luau source files were inspected statically. README, project mapping, shared/client folders, and place/map exports were absent from the root listing. No runtime validation was performed.

This baseline documents existing source and proposes the smallest useful playable milestone. Missing from GitHub does not mean nonexistent: recover existing Studio work before rebuilding it.

## Initial assumptions

| Topic | Proposed baseline |
| --- | --- |
| Runtime | Roblox Studio and Luau |
| Source workflow | Prefer Rojo after recovering the actual hierarchy; no mapping exists yet |
| Gameplay | One graybox arena, FFA, one gun, one knife |
| Authority | Preserve server validation and server-owned health, kills, and match state |
| UI | Minimal live HUD using the existing dark/crimson UI kit as reference |
| Validation scale | Two local clients first; 50-player capacity is a later target |
| Deferred | Progression, monetization, trading, abilities, new modes, map polish, bot expansion |
| Ownership/schedule | No issue assignee, estimate, or delivery date is assumed |

## Dependency inventory: first supported recovery work

The following paths are referenced by existing code and absent from the inspected repository snapshot. Their implementations, interfaces, and provenance require recovery.

| Expected path | Source evidence |
| --- | --- |
| ReplicatedStorage.Shared.Constants.Enums | CombatService, MatchService, PlayerService, WeaponService, KillService |
| ReplicatedStorage.Shared.Config.GameConfig | ServerMain and multiple services |
| ReplicatedStorage.Shared.Config.ModeConfig | MatchService |
| ReplicatedStorage.Shared.Config.MapConfig | MapService |
| ReplicatedStorage.Shared.Config.MovementConfig | WeaponService |
| ReplicatedStorage.Shared.Config.BotConfig | Bot, BotBrain, BotService |
| ReplicatedStorage.Shared.Utilities.Signal | Multiple services |
| ReplicatedStorage.Shared.Utilities.Maid | PlayerService |
| ReplicatedStorage.Shared.Utilities.CombatMath | LagCompensationService, BotBrain |
| ReplicatedStorage.Shared.Net.Net | ServerMain and multiple services |
| ReplicatedStorage.Shared.Registry.WeaponRegistry | WeaponService, KillService, BotBrain |
| Server.Core.Combatants | Multiple services; relative to intended server root |
| Server.Weapons.HitQuery | MapService, PlayerService, WeaponService, BotBrain |
| Server.Weapons.GunHandler and MeleeHandler | WeaponService |

Runtime fixtures also require inventory: ServerStorage.Maps, Workspace.ActiveMap, Workspace.Effects, Workspace.Lobby and LobbySpawns, per-map Spawns, and weapon assets. CombatService comments reference an empty StarterCharacterScripts.Health script to disable default regeneration. Client scripts and remote consumers are absent from this snapshot.

The intended server root is inferred from relative imports: ServerMain expects sibling Services; services expect sibling Core, Weapons, Modes, and Bots under that root. Confirm the exact Studio placement during recovery. Existing files belong in this hierarchy only after references are checked.

## M0 — Reproducible two-player FFA

Outcome: a contributor starts from a clean checkout, follows verified instructions, launches two local clients, and completes two consecutive rounds.

### M0 acceptance checklist

- [ ] Required sources and assets are versioned or have explicit acquisition instructions and provenance.
- [ ] Exact tool versions, hierarchy/mapping, and setup/run steps are documented.
- [ ] Startup finishes without missing-module errors or indefinite waits on missing required Instances.
- [ ] Two clients spawn, equip a gun and knife, and deal server-validated damage.
- [ ] Spawn protection and combat-disabled states reject damage.
- [ ] Death, kill credit, scoring, and respawn work without duplicate processing.
- [ ] HUD shows live health, ammo, match state/timer, score, and results.
- [ ] Configured round end works and the next round resets correctly.
- [ ] Two consecutive rounds pass; late join and disconnect behavior are recorded.
- [ ] Malformed, out-of-state, and over-rate weapon requests are checked.
- [ ] Test report includes commit, environment, steps, expected/actual results, and defects.

Source inspection and a server-ready log alone do not satisfy this milestone.

## Linear starter backlog

Project: [Bloodline MVP Baseline](https://linear.app/bloodlinerblx/project/bloodline-mvp-baseline-646d32ef30bc). Issues are Backlog, unassigned, and attached to M0. Dependencies are encoded in Linear.

### [BLO-5: Inventory and recover required project dependencies](https://linear.app/bloodlinerblx/issue/BLO-5/inventory-and-recover-required-project-dependencies)

Priority: High. Depends on: none.

Audit the 14 existing Luau files before replacing any systems. Imported dependencies absent from the repository include Shared.Config (GameConfig, ModeConfig, MapConfig, MovementConfig, BotConfig), Shared.Constants.Enums, Shared.Utilities (Signal, Maid, CombatMath), Shared.Net.Net, Shared.Registry.WeaponRegistry, Server.Core.Combatants, and Server.Weapons (HitQuery, GunHandler, MeleeHandler).

Acceptance criteria:
- [ ] Inventory every import, runtime Instance, remote contract, client script, and weapon/map asset.
- [ ] Locate any existing Studio place/export and compare its contents to GitHub.
- [ ] Record each dependency as present, recovered, missing, or deferred, with provenance.
- [ ] Recover available sources; identify remaining blockers without inventing API behavior.
- [ ] Identify Workspace Lobby/LobbySpawns, ActiveMap, Effects and ServerStorage.Maps requirements.

### [BLO-6: Establish reproducible Studio project mapping](https://linear.app/bloodlinerblx/issue/BLO-6/establish-reproducible-studio-project-mapping)

Priority: High. Depends on: BLO-5.

Preserve current services and establish a repeatable source-to-Studio workflow. Prefer Rojo mapping after dependency recovery; record the chosen workflow and tool versions.

Acceptance criteria:
- [ ] Map entry script, Services, Modes, Bots, Core, Weapons, shared modules, and client code to the expected Instance hierarchy.
- [ ] Include or document acquisition of required assets and workspace fixtures.
- [ ] A clean checkout reconstructs the project without hidden local files.
- [ ] Required services initialize and start without missing-module errors.
- [ ] Record startup evidence and any remaining blockers.

### [BLO-7: Document verified setup, architecture, and MVP boundaries](https://linear.app/bloodlinerblx/issue/BLO-7/document-verified-setup-architecture-and-mvp-boundaries)

Priority: High. Depends on: BLO-6.

Use the baseline README draft and update it with the recovered project's actual setup. The draft alone does not satisfy this issue.

Acceptance criteria:
- [ ] Document prerequisites, exact setup/run steps, source hierarchy, and config locations.
- [ ] Explain server service initialization, damage ownership, match lifecycle, and remote responsibilities.
- [ ] Distinguish implemented behavior, tested behavior, and proposals.
- [ ] Include known gaps, smoke-test steps, design reference location, asset provenance, and unresolved license status.
- [ ] Verify the instructions from a clean checkout and link evidence.

### [BLO-8: Integrate one complete FFA combat loop](https://linear.app/bloodlinerblx/issue/BLO-8/integrate-one-complete-ffa-combat-loop)

Priority: High. Depends on: BLO-6.

Integrate existing systems into one graybox arena with one gun and one knife. Repair or supply missing pieces after recovery instead of rewriting working services.

Acceptance criteria:
- [ ] Two clients spawn and equip/fire/use the selected weapons.
- [ ] Server validates requests and owns health, kill credit, and scoring.
- [ ] Spawn protection and combat-disabled states reject damage.
- [ ] Death and respawn complete without duplicate kill credit.
- [ ] Round ends by configured condition, produces results, and resets for another round.

### [BLO-9: Connect a minimal Bloodline HUD to server state](https://linear.app/bloodlinerblx/issue/BLO-9/connect-a-minimal-bloodline-hud-to-server-state)

Priority: Medium. Depends on: BLO-8.

Implement only the HUD needed to play and verify M0. Use the existing BLOODLINE UI Kit as visual reference; confirm asset/font availability and licensing before importing assets.

Acceptance criteria:
- [ ] Health, weapon/ammo, timer/state, score, and results use live state rather than placeholders.
- [ ] HUD updates across death, respawn, round end, and reset.
- [ ] Dark/crimson styling follows the design reference while maintaining readable status text.
- [ ] Desktop two-client test has no overlapping or clipped essential UI.
- [ ] Wider device support is recorded as follow-up scope.

### [BLO-10: Verify and record M0 acceptance](https://linear.app/bloodlinerblx/issue/BLO-10/verify-and-record-m0-acceptance)

Priority: High. Depends on: BLO-7, BLO-8, BLO-9.

Run the M0 smoke checklist against an identified commit and document results. Do not mark complete based on source inspection alone.

Acceptance criteria:
- [ ] Clean-checkout setup and startup pass.
- [ ] Two local clients complete two consecutive rounds with combat, respawns, scoring, HUD, results, and reset.
- [ ] Check late join, disconnect, spawn-protected damage, and malformed/out-of-state/over-rate weapon requests.
- [ ] Record environment, commit, test steps, expected/actual results, and evidence.
- [ ] Log defects separately; unresolved blocking defects prevent milestone completion.

