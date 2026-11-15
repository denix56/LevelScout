# LevelScout data format

LevelScout's records come from two sources, merged **at runtime** in the addon:

- **QuestieDB**, the installed addon (a required dependency, `## Dependencies: QuestieDB`). It is
  read only through its public `LibQuestieDB` API (contract 4; see findings.md section 1.1).
  QuestieDB applies its own corrections for the logged-in character's faction and class when it
  loads, so every read is already right for that character.
- **The ForeverDB layer**, baked into `LevelScout/data/` by `tools/import/import.lua` from
  ForeverDB alone (ForeverDB.net data, including CMaNGOS classic-db data). Do not edit these
  files by hand.

`LevelScout/adapters/Merge.lua` builds each quest, NPC, object and item record from the two;
`LevelScout/adapters/Data.lua` is the only reader of the records (its interface did not change
when the merge moved from build time into the addon).

## Design: why the merge runs in the addon

The build-time importer already read QuestieDB only through the same `LibQuestieDB` API that
exists in the game, so its per-record builders were moved into the addon unchanged
(`adapters/Merge.lua`) and now run against the real `LibQuestieDB` plus the baked ForeverDB
layer. This means:

- QuestieDB data is always the installed version, and QuestieDB's faction/class corrections are
  its own, for the character being played. The 18 faction × class "variant" passes and
  `ns.data.variants` are gone.
- The records are byte-for-byte what the importer used to write (checked for all 18 faction ×
  class combinations against the last build-time data; `tests/test_realdata.lua` keeps a
  sample).
- No ForeverDB-to-QuestieDB join happens at build time. The few tables that need every quest
  (the XP estimates, the dungeons' quest lists) are computed by the index pass at runtime.

**When records are built.** Lazily: a record is built the first time `Data.GetQuest`,
`GetNpc`, `GetObject` or `GetItem` (or the index) needs it, and its packed string is kept for
the session. Decoded records are cached on top, as before. QuestieDB's reads each cost a CBOR
decode (native in the game), so nothing is read twice.

**The index** (`Data.BuildIndex`, run at login as the existing async job, yielding every few
milliseconds) reads only what it needs of each quest through `Merge.QuestIndex`: zone, starters,
prerequisites, start spots, and what the XP estimates and dungeon lists need (level, XP, kind,
area). It builds no quest record. It does build the records of the NPCs and objects that start
quests (to know where they stand). At its end it computes `world.xpEstimate` and
`world.dungeons`, parses QuestieDB's drop-rate tables once, and hands back QuestieDB's cache of
the quest fields it read (`LibQuestieDB.InvalidateCache("Quest")`; not when Questie itself is
loaded, which reads those quests all session). Reading `world.xpEstimate` or `world.dungeons`
before the index exists builds the index on the spot.

**Startup.** `Data.Init` checks that `LibQuestieDB` exists, that `RequireContract(4)` passes
and that the entity and support API is there (`Merge.Check`). If not, `Data.status` says what is
missing (states `questiedb-missing`, `questiedb-version`, `questiedb-broken`), one chat message
is printed at login, and the addon stays inert.

**Tests.** Unit tests give Data ready-made records in `ns.data.quests`, `npcs`, `objects`,
`items`, `questText`, `questSpots` ("records mode": no merge), or a ForeverDB layer plus a small
fake `LibQuestieDB` (`tests/mocks.lua`). The real-data tests load the real QuestieDB through the
import tools' sandbox (`tools/import/questiedb.lua`, folder from `QUESTIEDB`).

## Running the import

```
.tools/bin/lua5.1 tools/import/import.lua --foreverdb local/sources/ForeverDB --out LevelScout/data
```

Only ForeverDB is needed. ForeverDB is not installed in the game folder; a copy is kept in
`local/sources/ForeverDB` (git-ignored) and refreshed by `tools/update.sh`. The import stops with
a specific message if ForeverDB has changed format.

**How ForeverDB is read.** Its `Data/*.lua` files are run in a sandbox (`tools/import/sandbox.lua`:
no io, os or module loading); its code files are not run. `tools/import/layer.lua` keeps the
tables the runtime merge reads, in ForeverDB's own record layouts (the legend at the top of each
ForeverDB data file), trimmed to what is used. A short report is written to
`tools/import/last_report.txt`.

## Common encodings

- **Spot:** base-36 of `uiMapID * 1e6 + round(x*10) * 1e3 + round(y*10)`, where x and y are
  0–100 on that map. This is the same packing ForeverDB uses. Spots are space-separated.
- **Record:** fields separated by `|`. Free text is kept in separate tables, so a record never
  contains free text.

## The baked ForeverDB layer (`LevelScout/data/`)

| Table | Contents (ForeverDB's layout unless noted) |
|---|---|
| `ns.data.meta` | `{ build, generated, sources = { ForeverDB, ForeverDBData }, requires = { QuestieDBContract }, counts }` |
| `fdb.qcQuests[id]` | CMaNGOS classic quests in the Forever client: `title\|level\|min\|side\|classes\|races\|needsAll\|needsOne\|excl\|starts\|ends\|objectives\|skill\|flags` (quests players were never offered are left out) |
| `fdb.qcGone[id]` | classic quests players have never been offered in Forever |
| `fdb.qcExcl[group]` | CMaNGOS exclusive groups |
| `fdb.qfQuests[id]` | Forever quests: `title\|level\|min\|text\|starts\|ends\|seen\|new\|prev\|lowest\|side` |
| `fdb.questXP[id]` | XP captured by ForeverDB players (ForeverDB `qxp.q`) |
| `fdb.qobj[id]` | captured objective counts (`c:8,i:5`) |
| `fdb.groupSize[id]` | group size (field 16 of ForeverDB's quest guide; import-made) |
| `fdb.startMap[id]` | the uiMap where ForeverDB saw the quest start (from `qcByMap`/`qfByMap`; import-made) |
| `fdb.qfPoi`, `fdb.qfSeen`, `fdb.qfArea` | client quest POI points, players' observations (`{ s, e, o = {...} }`), area-trigger spots |
| `fdb.qcNpc`, `fdb.qfNpcNames`, `fdb.qfNpcSpots`, `fdb.npcLv` | NPC names and spots (CMaNGOS, Forever), observed levels |
| `fdb.npcSpot[id]` | an NPC's own spot from ForeverDB's NPC table (import-made; last fallback) |
| `fdb.qcObj[id]` | CMaNGOS object names and spots |
| `fdb.qfItems`, `fdb.qdrop`, `fdb.qcItem` | Forever item names, drop rates measured in Forever, CMaNGOS drop rates |
| `fdb.dungeons[instanceId]` | 5-player dungeons with an entrance: `{ n, lo, hi, min, ent, bosses, q }` (import-made from ForeverDB's dungeon table) |
| `ns.data.world` | see below |

Every data file starts with the line `-- Data: ForeverDB.net (https://foreverdb.net), build ...`
(a test enforces it).

## Records (built at runtime by `adapters/Merge.lua`)

### Quest record: 30 fields

| # | field | source priority |
|---|---|---|
| 1 | name | ForeverDB (Forever client) > QuestieDB > CMaNGOS |
| 2 | quest level | ForeverDB > QuestieDB > CMaNGOS |
| 3 | minimum level | ForeverDB > QuestieDB > CMaNGOS |
| 4 | maximum level (0 = none) | QuestieDB |
| 5 | side: `a`, `h` or empty for both | from the race mask, else ForeverDB/CMaNGOS side |
| 6 | race mask (QuestieDB PlayableRaceBit masks; bit 32 Skyborne Alliance, bit 33 Skyborne Horde) | QuestieDB > CMaNGOS |
| 7 | class mask | QuestieDB > CMaNGOS |
| 8 | uiMapID of the quest's zone (0 = none) | QuestieDB zoneOrSort mapped to uiMap, else the map where ForeverDB saw it start |
| 9 | quest sort (negative category, e.g. -666 Camping) | QuestieDB |
| 10 | flags | see below |
| 11 | base XP (empty = unknown) | ForeverDB player captures > QuestieDB trace table |
| 12 | XP source: `f` ForeverDB, `q` QuestieDB | |
| 13 | starters: `n<npc> o<object> i<item>` | QuestieDB > CMaNGOS > ForeverDB |
| 14 | finishers | same |
| 15 | objectives | see below |
| 16 | prerequisites, all of (comma list) | QuestieDB; CMaNGOS only for quests QuestieDB lacks |
| 17 | prerequisites, one of | same |
| 18 | mutually exclusive quests | QuestieDB exclusiveTo ∪ CMaNGOS exclusive group |
| 19 | breadcrumb for quest | QuestieDB |
| 20 | next quest in chain (blocks this one when active or done) | QuestieDB |
| 21 | parent quest (must be active) | QuestieDB |
| 22 | minimum reputation `faction:value` | QuestieDB |
| 23 | maximum reputation | QuestieDB |
| 24 | skill `skill:value` | QuestieDB > CMaNGOS |
| 25 | item provided by the quest giver | QuestieDB |
| 26 | group size | ForeverDB quest guide |
| 27 | number of ForeverDB players who saw it | ForeverDB |
| 28 | previous quest players saw (soft hint, not a requirement) | ForeverDB |
| 29 | lowest player level seen completing it | ForeverDB |
| 30 | QuestieDB AreaTable zone id (raw) | QuestieDB |

**Flags (field 10):**

| Letter | Meaning |
|---|---|
| `d` | dungeon (QuestieDB dungeon zone or CMaNGOS flag) |
| `r` | raid |
| `g` | group/elite (CMaNGOS) |
| `p` | repeatable |
| `y` | daily |
| `w` | weekly |
| `n` | new in Forever |
| `u` | unseen by ForeverDB players (QuestieDB only) |
| `v` | seasonal/event category |

**Objectives (field 15):** entries separated by `;`, in quest-log order (Questie's order,
including its "objective first" hints). Each entry is `<kind><ids>:<count>:<countSource>`.

| Part | Values |
|---|---|
| kind | `c` kill (ids = every NPC that gives credit), `o` object, `i` item, `e` event/area, `r` reputation (id = faction, count = value), `x` other |
| countSource | `C` CMaNGOS (via ForeverDB), `F` ForeverDB player capture, `Q` QuestieDB (events, reputation), empty = unknown |


### Quest text

The objective text (QuestieDB's, else ForeverDB's), used for display and as a last-resort count
parse.

### Quest spots

`{ s = spots, e = spots, [objectiveIndex] = spots }`. These are Forever-observed locations: the
client's quest POI points and ForeverDB players' observations. Event objectives fall back to
QuestieDB's trigger area and ForeverDB's area triggers.

### NPC record

`name|minLevel|maxLevel|rank|npcFlags|friendly|spots`

| Field | Values and sources |
|---|---|
| levels | ForeverDB observed levels > QuestieDB |
| rank | 0 normal, 1 elite, 2 rare elite, 3 boss, 4 rare (QuestieDB) |
| npcFlags | QuestieDB, with values from `world.enum.npcFlags` |
| friendly | `A`, `H`, `AH` or empty |
| spots | QuestieDB spawns ∪ ForeverDB Forever-observed spots; CMaNGOS spots only when neither has any |

Any NPC either source knows is built on request (the importer used to keep only those quests
referenced, plus service NPCs).

### Object record

`name|spots` (QuestieDB spawns ∪ CMaNGOS spots).

### Item record

`name|drops|objects|vendors`

- **drops:** `npc:percent:source` entries, space-separated. Rate priority:

  | Priority | Source | Code |
  |---|---|---|
  | 1 | ForeverDB (Forever-measured, else CMaNGOS) | `f` |
  | 2 | QuestieDB manual correction | `c` |
  | 3 | CMaNGOS via QuestieDB | `m` |
  | 4 | Wowhead via QuestieDB | `w` |
  | 5 | CMaNGOS via ForeverDB | `k` |

  Rates are capped at 100%. An empty rate means the NPC drops the item at an unknown rate.
- **objects:** `object:percent:source` entries.
- **vendors:** comma list of NPC ids.

### `ns.data.world` (from ForeverDB unless noted)

| Table | Contents |
|---|---|
| `pace[floor(level/5)]` | `{ c, i, o, e, x = seconds per kill / item / object / event / other, r = run speed }`: the median of ForeverDB installs' observations |
| `xpCurve[level]` | typical full XP of a quest at that level |
| `xpDungeonMultiplier` | Forever dungeon/raid quest XP ÷ classic |
| `xpEstimate[kind][level]` | `{ median, lower quartile, upper quartile }` of recorded quest XP, computed at runtime by the index from every quest. Kinds: `d` dungeon/raid, `o` has objectives, `t` no objectives. A level with fewer than 5 recorded quests borrows from levels up to 5 away. `Data.GetQuestXP` uses it for quests with no recorded XP and falls back to `xpCurve` |
| `zones[uiMap]` | ForeverDB zone levels, hubs and flight nodes (`continent\|side\|src\|lo-hi\|...`) |
| `travel` | flight nodes, paths (yards, copper), measured flight times, hubs, a hub-to-hub walk matrix with danger tiers per faction, and land masses |
| `enum` | QuestieDB's `raceMaskById`, `classKeys`, `factionRaceMasks`, `npcFlags` (QuestieDB's own tables, set at Init) |
| `dungeons[instanceId]` | `{ name, lo, hi, min (levels), ent (entrance spots), bosses, quests, confirmed (comma lists) }` from ForeverDB's dungeon table; `quests` also has the quests QuestieDB files under the dungeon's area (matched by entrance position; computed at runtime by the index) |
| `maps[uiMap]` | `{ c = continent, t, l = world X/Y of the top-left corner, h, w = yards }` from the client's map table (ForeverDB `routeMaps`); turns map points into yards |
| `links` | boats, zeppelins and the tram: `{ name, side, a = {continent, X, Y}, b, wait, ride }` (ForeverDB `routeLinks`) |

## Known gaps (from the 2026-11-12 import; the merge is the same at runtime)

- Some item objectives have no known source in either database: crafted, gathered, PvP marks,
  or items the quest gives you. They cannot be routed by location.
- Objective counts are complete for 97% of classic-range quests with objectives (2,543 of 2,628),
  but only 41% of Forever-range quests (408 of 1,005). Most of the gap is quests no ForeverDB
  player has captured yet, for example Riverglades. Those fall back to the in-game quest log,
  remembered counts, the objective text, then a default per kind.
- Questie's own hidden-quest list and quest-tag corrections are not read, since they live in
  Questie rather than QuestieDB. Classic quests not in the Forever client are excluded using
  ForeverDB's client-filtered list instead. Tags come from the game API at runtime, with data
  flags and an elite-mob heuristic as fallback.
- NPC patrol paths (QuestieDB waypoints) are not read. Spawn points only.
- QuestieDB names follow the client's locale (its l10n overlay); ForeverDB titles are English and
  win for quests ForeverDB knows.
