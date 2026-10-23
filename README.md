# PROJECT: BLOODLINE

Source for the BLOODLINE Roblox place, laid out for [Rojo](https://rojo.space) 7.

The open Studio place is still the source of truth. This repo mirrors its scripts so
changes can be reviewed and versioned. Sync is one-way (Studio to GitHub) until the
export has been checked against a `rojo build` of the place.

## Layout

| Folder | Maps to | Synced by Rojo |
| --- | --- | --- |
| `src/ReplicatedFirst` | ReplicatedFirst | yes |
| `src/ReplicatedStorage` | ReplicatedStorage | yes |
| `src/ServerScriptService` | ServerScriptService | yes |
| `src/StarterPlayer/StarterPlayerScripts` | StarterPlayerScripts | yes |
| `src/StarterPlayer/StarterCharacterScripts` | StarterCharacterScripts | yes |
| `studio-only/` | scripts inside StarterGui, ServerStorage, Workspace, StarterPack | no, review and history only |
| `legacy/` | the first 14 combat files uploaded on their own | no, to be matched to their live paths |

File naming follows Rojo: `Name.luau` is a ModuleScript, `Name.server.luau` a Script,
`Name.client.luau` a LocalScript, and a script with child scripts becomes a folder with
an `init.*.luau` file. `*.meta.json` files carry `Enabled = false` and keep Rojo from
deleting Studio-only children.

Skipped everywhere: `ScriptBackups`, `OldBackups_SafeToDelete`, `MapsBackup`,
`WeaponSources` and anything named `Before…` (the backup convention).

## Exporting from Studio

1. Open the place in Studio. Run `tools/export/StudioExport.luau` followed by
   `print(ExportSummary())` to see the file and line count. Nothing in the place changes.
2. Call `Export(1)`, save the JSON to `tools/export/chunks/001.json`, then call
   `Export(to + 1)` with the previous chunk's `to` until `done` is true.
3. Run `python3 tools/export/write_export.py --clean tools/export/chunks/*.json`.
4. Commit on a branch and open a pull request. The diff is what changed in Studio.

## Safety rules for Rojo

- Every service and exported folder sets `ignoreUnknownInstances`, so Rojo leaves
  remotes, GUIs, models and values that only exist in Studio alone.
- Do not `rojo serve` into the live place until a `rojo build` of this repo has been
  compared with Studio. Back up first (`ServerStorage.ScriptBackups/Before…`).
- GUIs, maps and models stay in Studio. Their scripts in `studio-only/` are a snapshot,
  so edit those in Studio, then re-export.
