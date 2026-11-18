# LevelScout

Leveling planner addon for WoW: Forever (client 1.60.1, Interface 16001).

CurseForge: [LevelScout](https://www.curseforge.com/wow/addons/levelscout) (project 1806231).
Source: https://github.com/denix56/LevelScout

## Requirements

- **[QuestieDB](https://www.curseforge.com/wow/addons/questiedb)** (required; contract 4, tested
  with 1.1.1). LevelScout reads its quests, NPCs, objects, items, prerequisites, spawns, drop
  sources and rates, zone mapping and quest XP from the installed QuestieDB at runtime, with
  QuestieDB's own corrections for the character you play. The TOC declares
  `## Dependencies: QuestieDB`; without it (or with a QuestieDB of an incompatible contract)
  LevelScout prints one chat message saying what is missing and stays inactive. Questie itself
  is not needed.
- **TomTom** (optional): its arrow is used for the waypoint; without it, the game's map pin.
- ForeverDB's data is baked into LevelScout; the ForeverDB addon is not needed.

## Layout

| Path | Contents |
|---|---|
| `LevelScout/` | The addon folder. Link or copy it into `Interface/AddOns`. |
| `LevelScout/data/` | The baked ForeverDB layer (ForeverDB.net data only). Do not edit; re-run the import |
| `LevelScout/adapters/Merge.lua` | Builds the quest, NPC, object and item records at runtime from QuestieDB (`LibQuestieDB`) and the ForeverDB layer; checks the QuestieDB dependency |
| `LevelScout/adapters/Data.lua` | The only reader of the records: quests, NPCs, items, eligibility, zone index, world tables |
| `LevelScout/adapters/Game.lua` | The only code that touches the game API |
| `LevelScout/adapters/TomTom.lua` | The only code that touches TomTom (optional) |
| `tools/import/` | Build-time import of the ForeverDB layer (Lua 5.1, sandboxed); `questiedb.lua` loads the real QuestieDB for the tests |
| `LevelScout/core/` | Pure Lua 5.1, no WoW API calls: cost model, learning from play, quest model, route planner, zone ranking |
| `LevelScout/Engine.lua`, `Guide.lua` | Keeps the plan current in the background; the waypoint for the current step |
| `LevelScout/AutoQuest.lua` | Talking to an NPC accepts and hands in the plan's quests there (Shift skips; a reward to choose is left to the player; both switchable in the window menu) |
| `LevelScout/Tracker.lua` | Collects pace and drop samples from quest progress and kills |
| `LevelScout/ui/` | The window (`/ls`) |
| `docs/planner.md` | How the planner works, what is not built, in-game checks |
| `tests/` | Standalone Lua 5.1 harness with mocks of the client and the dependencies |
| `docs/findings.md` | Historical log of verified facts about the client and the data sources, and of design decisions |
| `docs/data-format.md` | Record layouts, source priorities, how to run the import |
| `.github/` | CI: tests, releases, the daily data update (see Continuous integration) |

## Running tests

```
./run_tests.sh                       # every test file in its own process, one per core
./run_tests.sh -j 4                  # at most 4 processes at once
./run_tests.sh "planner"             # only tests whose name contains "planner"
TEST_FILES="test_core test_game" ./run_tests.sh   # only these files (tests/run.lua lists them all)
TIMES=1 ./run_tests.sh               # each file also lists its 25 slowest tests and its total
SERIAL=1 ./run_tests.sh              # everything in one process, one file after another
```

The real-data tests load the installed QuestieDB addon through the import tools' sandbox, so
they test what players get: by default from
`/Applications/World of Warcraft/_forever_/Interface/AddOns/QuestieDB`, or from
`QUESTIEDB=<QuestieDB folder> ./run_tests.sh`. Unit tests use a small fake `LibQuestieDB`
(`tests/mocks.lua`).

This uses `.tools/bin/lua5.1`, a local build of Lua 5.1.5. To use a different interpreter,
set `LUA=/path/to/lua5.1 ./run_tests.sh`. The tests use a mocked clock, so running files side
by side changes nothing but the wall time. The long files are split in parts that take about
as long as each other (`test_game.lua` to `test_game_4.lua`, `test_objective.lua` and
`test_objective_2.lua`; their shared setup is in `tests/game_env.lua` and `tests/objective_env.lua`),
and `tests/run.lua` lists the files longest first. A test that filters by name may need the
tests before it in its file: some files plan once and check the plans in several tests.

## Regenerating the data

The usual way is one command, which fetches the current ForeverDB data and rebuilds:

```
tools/update.sh           # update if ForeverDB published something newer
tools/update.sh --check   # only say whether the mod's data is behind (exit 1 when it is)
```

It reads ForeverDB's manifest (`https://foreverdb.net/downloads/addon-manifest.json`), downloads
the addon zip and the changed data files into `local/sources/ForeverDB` (each checked against the
manifest's SHA-256), runs the import, compares the counts with the previous report and
runs the tests (when QuestieDB is installed: the real-data tests need it; the update itself does
not). If a count falls by more than 5% or a test fails, it puts the old source and data
back. `--commit` commits the regenerated files, and
`--force` re-imports even when nothing is newer. It needs `curl`, `jq` and `unzip`.

To run the import by hand (ForeverDB only; QuestieDB is not read at build time):

```
.tools/bin/lua5.1 tools/import/import.lua --foreverdb local/sources/ForeverDB
```

The import prints a short report, also saved to `tools/import/last_report.txt`. At runtime
LevelScout needs the QuestieDB addon (see Requirements); TomTom is optional.

## Licence

GPL-3.0 ([LICENSE](LICENSE)). Data from ForeverDB.net (https://foreverdb.net) and CMaNGOS
classic-db (shipped), and from the QuestieDB addon (read at runtime, not shipped); see
[NOTICE.txt](NOTICE.txt) and [CREDITS.md](CREDITS.md).

## Releasing

Release zips are built with the [BigWigs packager](https://github.com/BigWigsMods/packager)
(`release.sh`), configured by `.pkgmeta`. The zip has one top folder, `LevelScout/`, with
the addon, `LICENSE`, `NOTICE.txt`, `CREDITS.md` and `CHANGELOG.md`; tests, tools, docs and this
README are left out. The version is the git tag: the TOC's `## Version` is the packager's
`@project-version@` keyword (unpackaged, `/ls about` shows `dev`). The release notes are
`CHANGELOG.md`.

To build the zip locally (no upload, no API key needed):

```
mkdir -p .tools/packager
curl -fsSLo .tools/packager/release.sh https://raw.githubusercontent.com/BigWigsMods/packager/v2.7.0/release.sh
.tools/bin/bash .tools/packager/release.sh -d
unzip -l .release/LevelScout-*.zip
```

- `-d` skips every upload. Do not add `-z`: that skips making the zip.
- `release.sh` needs bash 4.3 or newer. macOS ships 3.2; `.tools/bin/bash` is a local build.
- It packs only committed files (untracked files are left out), so commit first.
- It finds the checkout by its `.git` folder, so it does not work inside a git worktree (where
  `.git` is a file). There, build from a plain clone:
  `git clone --branch <branch> <path to this repo> /tmp/ls-build && cd /tmp/ls-build` and run
  `release.sh` from that folder by its full path.
- The zip and the unpacked folder land in `.release/` (git-ignored), named
  `LevelScout-<version>-forever.zip`. On a tagged commit (`git tag -a v0.1.0`) the version is
  the tag; otherwise it is the commit hash and the build counts as an alpha.

Upload ids: the CurseForge project id (1806231) is in `LevelScout/LevelScout.toc` as
`## X-Curse-Project-ID:`. The Wago project id goes there as `## X-Wago-ID:` once the project
exists (a commented placeholder is there to fill in). Both can also be given on the command line
as `-p` and `-a`. Dependencies go in `.pkgmeta` as CurseForge slugs: QuestieDB (`questiedb`)
is set as required; ForeverDB (optional) is a placeholder until its slug is confirmed.
Uploads to CurseForge and GitHub are done by CI (see Continuous integration); nothing here
uploads.

## Continuous integration

GitHub Actions, in `.github/workflows/`:

| Workflow | When | What |
|---|---|---|
| `test.yml` (job `test`) | every pull request; pushes to `main` (not pushes to other branches); by hand | `./run_tests.sh -j <cores>` under Lua 5.1 (Ubuntu's `lua5.1`), with the real QuestieDB for the real-data tests. A newer push to a pull request cancels its older run. |
| `release.yml` | a pushed tag `v*` that is on `main` | the tests, then the BigWigs packager: `LevelScout-<tag>.zip` uploaded to CurseForge (project id from the TOC) and to a GitHub release with `CHANGELOG.md` as the notes. No Wago or WoWInterface upload. |
| `update-data.yml` | daily at 05:17 UTC; by hand | `tools/update.sh`. When ForeverDB published newer data and the update passes (import, count check, tests), it opens or updates a pull request from `data/foreverdb` to `main` with `LevelScout/data/` and `tools/import/last_report.txt`. Never pushes to `main`; a failed update fails the run (GitHub mails the failure). |

QuestieDB in CI is the Forever zip of a pinned QuestieDB release, downloaded from
`https://github.com/Questie/QuestieDB/releases` and checked against its SHA-256 (version and
checksum in `.github/actions/setup/action.yml`; change both to move to a newer QuestieDB). The
release's zip is the same addon CurseForge serves. ForeverDB's downloads are cached between
data-update runs; `update.sh` re-checks them against the manifest.

The data pull request is opened with the workflow's own `GITHUB_TOKEN`, and GitHub does not start
`pull_request` runs for such pull requests. The update itself already ran the full suite on the
new data, and the workflow then starts `test.yml` on `data/foreverdb` by hand
(`workflow_dispatch`), which puts the `test` check on the pull request's commit. To run it again,
push to the branch or close and reopen the pull request.

Set up once on GitHub (Settings of the repository):

1. Secrets and variables, Actions: add the secret `CF_API_KEY`, a CurseForge API token
   (https://authors.curseforge.com/#/settings/api-tokens, from an account that may upload to
   project 1806231).
2. Actions, General, Workflow permissions: tick "Allow GitHub Actions to create and approve pull
   requests" (the data update opens its pull request with `GITHUB_TOKEN`). The default "Read
   repository contents" permission is fine: each workflow asks for what it needs.
3. Optional, once `test` has run: a branch protection rule (or ruleset) for `main` that requires
   the status check `test`.

To cut a release:

1. On `main`, put the new version's notes at the top of `CHANGELOG.md` and commit.
2. Tag that commit and push the tag: `git tag -a v0.1.0 -m "LevelScout 0.1.0"` and
   `git push origin v0.1.0`. A tag with `alpha` or `beta` in it is uploaded as that release
   type.
3. `release.yml` runs the tests, packages and uploads. The CurseForge file is tagged with the
   game version the TOC's `## Interface:` gives (16001: WoW Forever 1.60.1).

## Installing for in-game testing

```
ln -s "$PWD/LevelScout" "/Applications/World of Warcraft/_forever_/Interface/AddOns/LevelScout"
```

`/ls` (or `/levelscout`) shows or hides the window. Debug commands: `/ls status`, `/ls plan`,
`/ls replan [fresh]`, `/ls snapshot [note]`, `/ls play [reset]`, `/ls learn [reset]`, `/ls buffs`, `/ls debug`,
`/ls quest <id>`, `/ls zone [uiMapID]`, `/ls log`, `/ls pos`, `/ls taxi`, `/ls about`. QuestieDB must be installed
and enabled in the same AddOns folder.

`/ls play` prints the play log: what the plan promised for the next 15, 30 and 60 minutes against
what you earned, and where you overruled the plan.

To see what the planner would do for any character without the game:

```
.tools/bin/lua5.1 tests/sim.lua 12 Alliance WARRIOR 1 1436 55.7 47.5
```

(level, faction, class, race id, uiMapID, x, y).

To plan a real situation again: `/ls snapshot` in game, `/reload`, then

```
.tools/bin/lua5.1 tests/replay.lua "<WoW>/_forever_/WTF/Account/<ACCOUNT>/<Realm>/<Character>/SavedVariables/LevelScout.lua"
```

(`--list` shows the saved ones). It prints what differs from what the game showed.
