# LevelScout — Verify-first findings

> **This file is a historical log** of facts verified while LevelScout was designed and of the
> design decisions taken along the way, in the order they were made. Later sections and the box
> below supersede earlier ones where they disagree. The current state is described in
> [../README.md](../README.md), [planner.md](planner.md) and [data-format.md](data-format.md).

Date: 2026-11-12. Client: WoW: Forever **1.60.1.70888** (from `/Applications/World of Warcraft/.build.info`).

Sources read:

| Addon | Version | Where |
|---|---|---|
| Questie | 12.7.0 (commit d9e00cb) | local install, `_forever_/Interface/AddOns/Questie` |
| QuestieDB | 1.0.15, contract 4, baked mode (commit c7ccd23) | local install, `_forever_/Interface/AddOns/QuestieDB` |
| QuestieTrace | 1.10.0 | local install (used as evidence of which APIs exist on this client) |
| TomTom | v4.4.1-release (CurseForge file 9493883, 2026-11-07) | not installed; release zip downloaded |
| QuestDropRates | 1.3.0 (CurseForge file 9547481, 2026-11-10) | not installed; release zip downloaded |

Paths below are relative to each addon's folder.

> **Current architecture (supersedes the dependency plan in sections 1, 2 and 7).**
>
> - **QuestieDB is the one required runtime dependency** (`## Dependencies: QuestieDB`).
>   LevelScout reads its quests, NPCs, objects, items, spawns, drop sources and rates, zone
>   mapping and quest XP from the installed addon through its public `LibQuestieDB` API
>   (contract 4), with QuestieDB's own faction/class corrections for the character played.
>   Without it LevelScout stays inactive and says why.
> - **ForeverDB** is the only source baked into the addon: `tools/import/` writes its data
>   (ForeverDB.net data under GPL-3.0 plus an attribution term) into `LevelScout/data/`. The
>   ForeverDB addon is not needed in game. `LevelScout/adapters/Merge.lua` merges the two at
>   runtime.
> - **Questie** (the addon) is not used. **QuestDropRates** is dropped; ForeverDB's measured
>   drop chances and QuestieDB's drop rates replace it.
> - **TomTom** remains optional.
> - **Licence:** GPL-3.0.
>
> See [data-format.md](data-format.md) and [../CREDITS.md](../CREDITS.md). Sections 1–7 below
> record what was verified on the way; their statements about Questie and QuestDropRates as
> runtime dependencies no longer apply.

> **Design conflicts are collected in section 7.**

---

## 1. Dependency APIs

### 1.1 Questie is now two addons: Questie and QuestieDB

The quest database no longer lives inside Questie. It is a separate addon, **QuestieDB**. That
addon publishes a **documented, versioned public API** as the global `LibQuestieDB`
(`QuestieDB/src/api.lua`). Its header says "Questie is the first consumer, but nothing here
assumes it" (api.lua:6). Questie itself reads all of its data through this API
(`Questie/Database/QuestieDB.lua:220-228`).

**Version check** (api.lua:86-110, config.lua:14-20):

```lua
LibQuestieDB.contractVersion       -- 4
LibQuestieDB.minSupportedContract  -- 1
local ok, msg = LibQuestieDB.RequireContract(4)  -- range check; msg is a ready-made error text
LibQuestieDB.readMode              -- "baked" | "source"
```

**Entity access.** One table exists per type: `LibQuestieDB.Quest`, `.Npc`, `.Item` and
`.Object`. They are also exposed as the globals `QuestDB`, `NpcDB`, `ItemDB` and `ObjectDB`
(api.lua:23-32). Accessors are defined in `src/read/shared.lua:378-445`:

```lua
E.Get(id, key)              -- key = field name or index; table values are fresh copies
E.GetAll(id, {k1, k2, ...}) -- packed {n=...}; nil for unknown id
E.GetAllIds(asHashmap)      -- ascending list, or {[id]=true}; shared table, read-only
E.Exists(id)
E.GetRaw(id, key)           -- uncorrected base data (debug only)
```

Data is stored as CBOR in TOC metadata and decoded on demand through `C_EncodingUtil`
(`src/read/baked.lua`). Each read is cheap, but a field read costs a CBOR decode, so the
planner must cache what it reads.

**Schema.** The schema is published at `LibQuestieDB.Meta.QuestMeta.questKeys` (and the
matching Npc, Item and Object tables), so fields can be read by name.

| Entity | Fields we need |
|---|---|
| Quest (`src/meta/questMeta.lua`) | `name`, `startedBy` `{npcIds, objectIds, itemIds}`, `finishedBy` `{npcIds, objectIds}`, `requiredLevel`, `questLevel`, `requiredRaces`, `requiredClasses`, `objectives` (six groups: creature, object, item, reputation, killCredit, spell; each entry has the ID first), `triggerEnd` `{text, {[zoneId]={{x,y}}}}`, `preQuestGroup`, `preQuestSingle`, `childQuests`, `exclusiveTo`, `nextQuestInChain`, `breadcrumbForQuestId`, `breadcrumbs`, `zoneOrSort`, `questFlags`, `specialFlags`, `extraObjectives`, `requiredMaxLevel` |
| Npc (`src/meta/npcMeta.lua`) | `minLevel`, `maxLevel`, `rank` (cmangos: 0 normal, 1 elite, 2 rare elite, 3 boss, 4 rare), `spawns` `{[areaId]={{x,y,phase?}}}`, `waypoints`, `zoneID`, `friendlyToFaction`, `npcFlags` (vendor, repair, trainer and flight-master bits) |
| Object (`src/meta/objectMeta.lua`) | `spawns`, `zoneID` |
| Item (`src/meta/itemMeta.lua`) | `npcDrops`, `objectDrops`, `itemDrops`, `vendors`, `startQuest`, `class` |

- **There is no quest XP field in the quest schema.**
- Coordinates are in 0–100 percent of the zone map, keyed by **AreaTable ID**, not by uiMapID.

**Support data** is available as whole tables through `LibQuestieDB.Support.Get(name)`
(`src/support/data.lua:80`):

| Call | Contents |
|---|---|
| `Support.Get("QuestXP").db` | `[questId] = {questLevel, baseXP}`, from `support/Forever/QuestXP/xpDB-classic.lua` overlaid with `xpDB-traces.lua`. The traces file was generated 2026-11-11 from 655,837 Forever player sessions. |
| `Support.Get("ZoneDB").private.areaIdToUiMapId` / `uiMapIdToAreaId` / `subZoneToParentZone` | Conversion between Questie zone IDs and the `C_Map` IDs that TomTom uses |
| `Support.Get("ZoneDB")` dungeons table (`support/Forever/Zones/dungeons.lua`) | 129 dungeon AreaIds, with entrance coordinates |
| `Support.Get("QuestieClassicItemDrops").wowheadData` | Drop rates as a **Lua source string** (`[[return {...}]]`), `[itemId][npcId] = percent`. Using it needs `loadstring`. Questie's `DropDB` does this already. |
| `Support.Get("QuestieItemDropCorrections")` | Manual drop-rate overrides |

### 1.2 Questie: what it adds on top of QuestieDB

- **Public API** (`Questie/Public/*.lua`). It is small:
  - `Questie.API.isReady`
  - `Questie.API.RegisterOnReady(fn)`
  - `Questie.API.RegisterForQuestUpdates(fn(questId, objectiveIndex, reason))`, where
    `reason` is a value of `Questie.API.Enums.QuestUpdateTriggerReason`: `ACCEPTED`=1,
    `UPDATED`=2, `TURNED_IN`=3, `ABANDONED`=4.
  - `Questie.API.GetQuestObjectiveIconForUnit(guid)`

  These are the only Questie functions intended for other addons.
- **Internal modules.** Any addon can reach these through the global `QuestieLoader`:
  `QuestieLoader:ImportModule("QuestieDB")`, `("DropDB")`, `("QuestXP")` and
  `("AvailableQuests")`. They are **not** a public API. The useful ones:

| Function | What it does | Ref |
|---|---|---|
| `QuestieDB.IsDoable(questId)` | Full availability check: race, class, reputation, profession, prerequisites, breadcrumbs, exclusive-to, events, level. About 270 lines we would otherwise reimplement. | QuestieDB.lua:695 |
| `QuestieDB.GetItemDroprate(itemId, npcId)` | Returns `{percent, "questie"\|"pserver"\|"wowhead"}`. Priority: manual correction, then private-server data, then Wowhead. | QuestieDB.lua:439, dropDB.lua:126 |
| `QuestXP:GetQuestLogRewardXP(questId)` | Database XP scaled by the cmangos level formula, ×global and buff multipliers | QuestieXP.lua:59-108 |
| `QuestieDB.IsDungeonQuest` / `IsGroupQuest` (elite) / `IsRaidQuest` / `GetQuestTagInfo(questId)` | Quest tags | QuestieDB.lua:515-620 |

### 1.3 QuestDropRates: globals and SavedVariables only

- **No callable API**: no LibStub library, no callbacks and no events.
- There is a **global table `QuestDropRates`** whose internal methods can be called:
  - `QuestDropRates:GetDatabaseDropInfo(itemName, itemID, questID)` (Database.lua:1734).
    Returns `{rate, bestMob, sources={{mob, rate, npcID?}}, sourceType}`.
  - `QuestDropRates:GetPersonalDropInfo(itemName)` (Tracker.lua:776). Returns
    `{rate, kills, drops, mobs={{mob, kills, drops, rate}}}`.
  - Version string: `QuestDropRates.VERSION = "1.3.0"` (Tracker.lua:3).
- **Keying.** Everything is keyed by the **lowercased item name** and the **mob name
  string**. It does not use item IDs or npc IDs, so lookups are locale-dependent. Rates are
  percent (0–100).
- **SavedVariables.** `QuestDropRatesDB`, account-wide. The per-item records are
  `QuestDropRatesDB.items[normName] = {kills, drops, mobs={[mobName]={kills, drops}}}`.
- **Its "kill" means "a looted corpse".** It registers only `LOOT_READY`, `LOOT_OPENED` and
  `LOOT_CLOSED` for counting (Core.lua:127-135). It counts a kill when a loot window opens on
  a corpse that is a known source (Tracker.lua:567-770). A mob with nothing to loot never
  opens a window, so it is never counted. **The personal rate is therefore drops per looted
  corpse, which overstates drops per kill.** See conflict C2.
- Its database rates come from "pfQuest/CMaNGOS loot tables + Forever overrides"
  (Database.lua:28), covering about 1,525 items.

### 1.4 TomTom

- **Detection.** The README says to use `TomTom and TomTom.IsCrazyArrowEmpty`, because other
  addons create fake `TomTom` tables.
- **Version.** Read it with `C_AddOns.GetAddOnMetadata("TomTom","Version")`. In this
  release, `TomTom.version` reads `"SCM"` because of a packaging quirk (AddonCore.lua:77-79).
- **Adding a waypoint:** `uid = TomTom:AddWaypoint(uiMapID, x01, y01, opts)`
  (core/waypoints.lua:415).
  - Coordinates are **0–1**. The map is a **uiMapID**.
  - `opts`: `title`, `from`, `persistent`, `minimap`, `world`, `crazy`, `silent`,
    `cleardistance`, `arrivaldistance`, `callbacks`.
  - **It mutates `opts`**, so pass a fresh table each call.
  - A duplicate (same map, x, y and title) returns the existing uid.
- **Removing a waypoint:** `TomTom:RemoveWaypoint(uid)` raises an error if `uid` is not a
  table. Guard it with `TomTom:IsValidWaypoint(uid)`, which also raises on a non-table.
- **Arrival.** There is no `onclear` callback.
  - Arrival is signalled through `opts.callbacks.distance[yards] = fn(event, uid, range,
    dist, lastdist)`.
  - Passing `callbacks` **replaces** the defaults: you lose auto-clear and the ping. Start
    from `TomTom:DefaultCallbacks(opts)` and add your own entry.
  - CallbackHandler events: `TomTom.RegisterCallback(owner, "WaypointRemoved", fn)`.
- **Our own waypoint IDs.** The uid is a table we own. Keep the uids we create in a set and
  remove only those, as the design requires.
- **Other calls:** `SetCrazyArrow(uid, dist, title)`, `GetDistanceToWaypoint(uid)`.
- **Forever support.** TOC line 1 includes 16001. It uses HereBeDragons 2.18, which has
  Forever map data. **Risk:** a Forever-only uiMapID that HereBeDragons cannot place gets no
  distance callbacks, so auto-advance would silently never fire. We should also run our own
  arrival check on `C_Map.GetPlayerMapPosition`.

---

## 2. Interface number and TOC conventions

- **Interface: `16001`.** Every Forever-aware addon installed uses it (all 35 TOCs were
  checked). Forever is detected by interface range: Questie uses `16000 <= v < 17000`
  (QuestieCompat.lua:22, VersionCheck.lua:60), TomTom uses 16001–19999, and HereBeDragons
  uses `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT`. Note: "Forever shares Retail's project ID"
  (QuestieCompat.lua:20), so do not branch on `WOW_PROJECT_MAINLINE`.
- **Flavor suffixes.** Both `_Forever` and `_Camelot` appear. QuestieDB's config lists
  `_Forever`, with `_Camelot` as an alias (config.lua:62); Details uses `_Camelot`;
  QuestieTrace uses `-Camelot`. The simplest choice with no ambiguity is a single
  `LevelScout.toc` with `## Interface: 16001`. ForeverCompanion, OpenMap and QuestDropRates
  all do this.
- **Recommended header:**

  ```
  ## Interface: 16001
  ## Title: LevelScout
  ## Version: 0.1.0
  ## Dependencies: QuestieDB            (see conflict C1)
  ## OptionalDeps: Questie, QuestDropRates, TomTom
  ## SavedVariables: LevelScoutDB
  ## SavedVariablesPerCharacter: LevelScoutCharDB
  ## Category: Quests
  ## IconTexture: ...
  ## AddonCompartmentFunc: ...    (supported; OpenMap and ForeverCompanion use it)
  ```

- The client is a **modern-engine client** (12.x-era API surface) running Classic content.
  The legacy quest-log globals are replaced by `C_QuestLog.*`. The language is still Lua
  5.1, so a Lua 5.1 test harness is valid for `core/`.
- Retail's **"secret values"** apply here. Questie, QuestDropRates and RareScanner all guard
  values with `issecretvalue(v)`. Questie skips aura reads in combat and in instances on
  Forever (QuestieXP.lua:42-45, 130-134).

---

## 3. Database coverage of Forever content

I measured this offline by decoding QuestieDB's baked TOC metadata, with a one-off script (not
kept).

- 5,768 quests, 15,561 NPCs, 7,271 objects and 23,858 items in total.
- Quest IDs of 10000 and above are a proxy for new Forever content: 1,413 in 80000–99999
  and 93 in 30000–79999.

| Metric | Classic-range IDs (<10000), n=4262 | Forever-range IDs (≥10000), n=1506 |
|---|---|---|
| Starter has at least one spawn, or is an item | 97.7% | 90.5% |
| Finisher has at least one spawn | 97.9% | 84.9% |
| `questLevel` / `requiredLevel` present | 100% / 100% | 99.1% / 93.5% |
| `zoneOrSort` present | 100% | 90.4% |
| Has objectives | 2601 | 898 |
| …all objective targets have a spawn location* | 71.6% | 63.9% |
| Database XP known | 82.2% | **62.7%** (all from player traces) |
| `zoneOrSort` is a dungeon area | 686 | 50 |
| Objective mob is elite (rank 1–3) | 871 | 100 |

\* This is a strict check. It counts an item objective as "not located" when the item comes
from a vendor, from a container, or from an NPC with no spawn data, so it understates real
coverage.

**Zones with the most Forever-range quests:**

| Zone | AreaId / sort | Quests |
|---|---|---|
| Riverglades | 16591 | 150 |
| Crafting writs (no map) | 16941 | 150 |
| Zephras Isle | 16593 | 111 |
| "Camping" category (new in Forever) | −666 | 101 |
| Shen'dralas | 16651 | 19 |
| Darkspear Islands | 16606 | 18 |
| Excavation Site: Wetlands | 16732 | 14 |
| Ruins of Lordaeron | 16611 | 13 |

**Caveats:**

- These numbers measure **how complete the entries are**, not how many in-game quests are
  missing. The total number of Forever quests is not known from any source available to me.
  QuestieTrace exists to crowd-source the gaps, and the trace data is about one day old, so
  coverage is improving quickly.
- **Implication for the planner:** about a third of new-content quests lack XP or objective
  locations. They need a fallback XP estimate (for example, the median of same-level quests),
  and an "unlocated" objective must be either estimated near the giver or excluded with a
  visible reason.
- Forever **moved some zone geometry**. dungeons.lua notes that some coordinates are stored in
  "Forever percentages" and cites `docs/forever-coordinate-audit.md`. Database coordinates are
  already in the Forever frame, so we should not convert them again.

### How dungeon and elite quests are flagged

**This information is not in the database.** Questie determines quest tags at runtime from
the **game API** `C_QuestLog.GetQuestTagInfo(questId)`: `tagID` 81 = dungeon, 1 = elite
(group), 62/88/89 = raid. Two details matter:

- It caches the result, and retries after 1 s when the client has not yet loaded data for
  that quest (QuestieDB.lua:559-620).
- It applies a static table of about 2,600 corrections
  (`Questie/Database/Corrections/questTagInfoCorrections.lua`). Forever uses the **Era**
  branch of that table, because `Expansions.Current = Era` on Forever (Expansions.lua).

For a quest not in the log, the API may return nil until quest data is cached. The adapter
therefore needs an **asynchronous tag lookup** (`C_QuestLog.RequestLoadQuestByID`, then the
`QUEST_DATA_LOAD_RESULT` event; to be verified in game). Until the tag is known, it falls
back to these heuristics:

1. Dungeon if `zoneOrSort` is one of the 129 dungeon AreaIds, or if all objective spawns lie
   in a dungeon area.
2. Elite if any objective mob has `rank` 1–3.

---

## 4. Game API on this client

The evidence below comes from code that ships for this exact client: Questie's `QuestieCompat`
Forever branches and QuestieTrace's trackers, which record these calls live on Forever. I have
**not** run any of it myself. In-game checks are listed in section 6.

| Need | API on Forever | Evidence |
|---|---|---|
| Quest log entries | `C_QuestLog.GetNumQuestLogEntries()`, `C_QuestLog.GetInfo(index)` → `{title, questID, level, isHeader, frequency, ...}`, `C_QuestLog.GetLogIndexForQuestID` | QuestieCompat.lua:452-497; QuestieTrace QuestLog.lua:17-52 |
| Objectives in log | `C_QuestLog.GetQuestObjectives(questID)` → `{text, type, finished, numFulfilled, numRequired}`; `C_QuestLog.IsComplete` / `IsFailed` / `IsOnQuest` | QuestieTrace QuestLog.lua:40-52, 429-436 |
| Log capacity | `C_QuestLog.GetMaxNumQuestsCanAccept()` (read it rather than hard-coding 40) | QuestieTrace QuestLog.lua:41, 743 |
| Completed quests | `C_QuestLog.GetAllCompletedQuestIDs()`, `C_QuestLog.IsQuestFlaggedCompleted(id)` | QuestieCompat.lua:605, 974 |
| Quest tags | `C_QuestLog.GetQuestTagInfo(id)` → `{tagID, tagName, isElite}` | QuestieCompat.lua:991 |
| Quest difficulty color | `C_PlayerInfo.GetContentDifficultyQuestForPlayer(id)` (needs `HaveQuestData`); `C_QuestLog.GetTrivialRange()` | QuestieCompat.lua:685-713 |
| Quest reward XP | `GetRewardXP()` in the quest dialog (used by Questie and QuestieTrace). `GetQuestLogRewardXP(questID)` for log quests is **not referenced by any installed addon**, so it must be checked in game. | QuestieDebugOffer.lua:511; QuestieTrace QuestDialog.lua:295 |
| XP gain | `UnitXP`, `UnitXPMax`, `GetXPExhaustion()` and the `PLAYER_XP_UPDATE` event; `CHAT_MSG_COMBAT_XP_GAIN` is registered by QuestieTrace | QuestieTrace PlayerProgress.lua:7-61, QuestieTrace.lua:155 |
| Kill signal (no combat log) | `PARTY_KILL(attackerGUID, targetGUID)` and `UNIT_DIED(guid)` events, used by RareScanner on Forever. The GUIDs **can be secret** and are guarded with `issecretvalue`. | RareScanner RSEventHandler.lua:196-230 |
| Loot | `GetNumLootItems`, `GetLootSlotInfo(slot)` (→ `..., isQuestItem, questID`), `GetLootSourceInfo(slot)` (→ corpse GUID; may be secret), `GetLootSlotLink`, and the `LOOT_READY`/`LOOT_OPENED`/`CHAT_MSG_LOOT` events | QuestieTrace Loot.lua:11-28; QuestDropRates Tracker.lua:584-586 |
| Position | `C_Map.GetBestMapForUnit("player")`, `C_Map.GetPlayerMapPosition(mapID,"player")` (0–1), and the `PLAYER_STARTED_MOVING`/`PLAYER_STOPPED_MOVING` events. For world coordinates and cross-zone distance, use HereBeDragons, which is embedded in Questie and TomTom. | QuestieTrace Position.lua:19-44, 206; TomTom core/position.lua |
| Map waypoint without TomTom | `C_Map.SetUserWaypoint` / `C_SuperTrack.SetSuperTrackedUserWaypoint`. Questie's super-tracking support is behind `QuestieCompat.IsSuperTrackingSupported()`. **To verify in game.** | QuestieCompat.lua:860-885 |
| Rested XP | `GetXPExhaustion()`. Forever also has a **sleeping-bag "Well-Rested" buff** worth +1% XP per stack. Auras are secret in combat and in instances, so read them only out of combat. | QuestieXP.lua:130-154 |
| Flight paths | **Not verified.** Known nodes are only exposed at a flight master (`C_TaxiMap.GetAllTaxiNodes`), so we must record them when the taxi map opens. OpenMap ships `Data/Forever/FlightData.lua` with node positions. | — |
| Hearthstone | `GetBindLocation()`, `C_Item.GetItemCount(6948)`, `C_Container.GetItemCooldown(6948)` (start, duration; 1.5 s or less is the global cooldown), `C_Spell.GetSpellInfo(8690).castTime`, events `HEARTHSTONE_BOUND` and `UNIT_SPELLCAST_SUCCEEDED` (8690). **Not verified.** | ForeverDB 0.60.4 PlannerCalib.lua:316-450 (not run) |

---

## 5. Party quest-item drops

Forever **does not drop one copy per player** for most collection items. According to developer
statements reported in late September 2026:

- Grouped players get quest items **distributed round-robin**: the team added functionality
  to "more predictably round-robin quest items to people who are grouped", so that "everyone
  in the group will get drops evenly" (Josh Greenfield, via Warcraft Tavern).
- The drop **rate is unchanged**: "The short answer is no; however we did do something cool."
- "There is still some amount of randomness involved", and "We are still dialing in this
  system."
- A beta guide says **some** quest items have been shared by the whole party since the
  October 26 build, for example dungeon starters such as An Unsent Letter. It does not list
  which items.

**I cannot determine this per item, so it becomes a setting.** The proposed default is
"round-robin": each kill drops one item at the normal rate, shared across the k party members
on the quest. My expected items per kill is then about rate / k. The alternative is
"per-player", where each member rolls separately. Our loot counter can later learn which mode
applies to each item, by comparing my drops per party kill with the solo rate.

Sources: [Warcraft Tavern](https://www.warcrafttavern.com/forever/news/quest-drops-distribute-more-evenly-in-wow-forever/),
[Icy Veins](https://www.icy-veins.com/wow-forever/news/players-have-felt-a-change-to-group-quest-drops-in-wow-forever/),
[Conquest Capped](https://conquestcapped.com/guides/wow-forever/wow-forever-quest-items/),
[Method](https://www.method.gg/wow-forever/leveling-as-a-party-in-wow-forever-whats-changed-and-what-you-need-to-know).

---

## 6. In-game checks (proposed 2026-11-12)

The checks that would confirm the API table in section 4, to be run in the open world, outside
combat, with Questie loaded. The checks still to be run against the current addon are listed in
planner.md, "In-game checks".

```
/dump GetBuildInfo()
/dump LibQuestieDB.contractVersion, LibQuestieDB.readMode, LibQuestieDB.RequireContract(4)
/dump LibQuestieDB.Quest.Get(7, "objectives"), LibQuestieDB.Npc.Get(6, "rank")
/dump C_QuestLog.GetMaxNumQuestsCanAccept()
/dump GetQuestLogRewardXP and GetQuestLogRewardXP(C_QuestLog.GetInfo(2).questID)
/dump C_QuestLog.GetQuestTagInfo(166)
/dump C_QuestLog.RequestLoadQuestByID ~= nil, HaveQuestData(166)
/dump C_Map.GetBestMapForUnit("player"), C_Map.GetPlayerMapPosition(C_Map.GetBestMapForUnit("player"), "player")
/dump UnitPosition("player")
/dump C_Map.SetUserWaypoint ~= nil, C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint ~= nil
/dump GetXPExhaustion(), UnitXP("player"), UnitXPMax("player")
```

- For `GetQuestLogRewardXP`: if log index 2 is a header, use 1 or 3. `C_QuestLog.GetQuestTagInfo(166)`
  checks the Deadmines tag for a quest that is not in the log.

**Kill and loot signals.** This prints the events while three mobs are killed and looted:

```
/run local f=CreateFrame("Frame") for _,e in ipairs({"PARTY_KILL","UNIT_DIED","CHAT_MSG_COMBAT_XP_GAIN","PLAYER_XP_UPDATE","LOOT_READY"}) do f:RegisterEvent(e) end f:SetScript("OnEvent",function(_,e,...) local t={} for i=1,select("#",...) do local v=select(i,...) t[i]=(issecretvalue and issecretvalue(v)) and "<secret>" or tostring(v) end print(GetTime(), e, table.concat(t," | ")) end)
```

What it answers:

- Whether `PARTY_KILL` fires for the player's own kills, and whether `targetGUID` is readable
  outside instances. If so, it gives exact kill timestamps and the npcId, which are needed for
  cycle time.
- Whether `GetLootSourceInfo(1)` is readable on `LOOT_READY`.

---

## 7. Findings that conflict with the design

**Decisions (2026-11-12):**

| | Decision |
|---|---|
| C1 | Require both **Questie and QuestieDB**. |
| C2 | Use QuestDropRates' **database** rate only. Our own counter supplies personal rates. |
| C3 | Dungeon and elite tags come from the API, with the zone and elite-mob heuristic as fallback. |
| C4 | Party drops default to **round-robin**: about rate ÷ k items per kill. |

The plan put these in a separate dependency adapter, which was never built as a file of its
own. C1 and C2 are superseded by the architecture at the top of this file; the QuestieDB check
is `Merge.Check` in `LevelScout/adapters/Merge.lua`. C3 lives in `LevelScout/adapters/Game.lua`
(the game's tag) and `LevelScout/adapters/Data.lua` (the fallback), C4 in
`LevelScout/core/Model.lua`. C5 below was still open at this point; its later status is in
section 8.

**C5 (open). Objective counts are not in the database.**

- QuestieDB objective tuples are `{id, text, icon}`. The third value is an icon, not a count
  (Questie QuestieDB.lua:1614-1622).
- "Kill 10" or "collect 8" is known only:
  - from the game, once the quest is in the log (`C_QuestLog.GetQuestObjectives` →
    `numRequired`);
  - from the objective text ("Kill 10 Kobold Vermin…"), which is localized and may contain
    several numbers.
- The cost model needs counts for quests not yet accepted. Proposed order:
  1. In-log count.
  2. Count learned from an earlier accept, saved account-wide (counts are static per quest).
  3. Number parsed from the objective text.
  4. A default per objective type.

  Each count carries a `countSource`, so the planner can widen the time spread for guessed
  counts.
- In-game check: `C_QuestLog.GetQuestObjectives` may also work for quests **not** in the log
  once their data is loaded. If so, step 3 is rarely needed.

**Original analysis** (the options considered before the decisions above):

**C1. "Questie (required)" should be "QuestieDB (required)".**

- Quests, NPCs, spawns, levels, prerequisites, quest XP and raw drop tables are all in
  QuestieDB, behind a public, versioned contract with a `RequireContract` check. That is the
  stable adapter target the design asked for.
- Questie adds only logic we may want to borrow, all of it internal: `IsDoable` for full
  availability, the `DropDB` rate priority and the tag corrections.
- Proposal:
  - Hard-depend on QuestieDB.
  - Use Questie's internals when it is loaded and its version is known. Its `IsDoable` would
    give exact availability.
  - Otherwise fall back to our own simpler availability check: level, race, class,
    prerequisites, exclusive-to and completed quests.
- Open question at the time: require Questie anyway (simpler, exact availability), or require
  only QuestieDB. Decided: QuestieDB only (see the top of this file).

**C2. QuestDropRates cannot supply "my personal drops-per-kill".**

- Its personal counter divides drops by **looted corpses**, so kills without loot are
  missing and the rate is overstated.
- It is keyed by item name and mob name, and it has no API, only internal methods.
- Proposal:
  - Use QuestDropRates only as an extra **database prior**, through
    `GetDatabaseDropInfo(itemName, itemID)`, guarded with pcall and a version check.
  - Ignore its personal rate.
  - Always run our own kill and loot counter, with kills taken from `PARTY_KILL` if the
    in-game check shows it is usable, and otherwise from XP gains.
- Open question at the time: whether its personal data should be used with a correction.
  Decided: no; QuestDropRates was later dropped altogether (see the top of this file).

**C3. Dungeon and elite flags are not database data.**

- They come from a client API that may need quest data loaded first, plus Questie's
  correction table.
- This is not a contradiction, but it means the adapter's tag lookup is asynchronous and has
  heuristic fallbacks (section 3).
- A quest whose tag is still unknown would be treated as "probably not a dungeon" using the
  `zoneOrSort` and spawn-area test. Decided as C3 above.

**C4. Party drops are round-robin, neither strictly per-player nor strictly one per kill.**

- This is handled as a setting (section 5).
- It affects the party block: k members on a collection quest need about k times the kills.
- Default decided as C4 above: round-robin.

**Not conflicts, but they change the cost model:**

- About 37% of new-content quests have no database XP. These need a fallback estimate until
  we see the reward in game.
- The quest-log cap should come from `C_QuestLog.GetMaxNumQuestsCanAccept()` rather than a
  constant 40.
- Known flight paths can only be learned when a flight-master map is open.

---

## 8. ForeverDB as a second data source (2026-11-12)

**Source:** ForeverDB 0.58.2 (Wago `kGr9ReKy`, CurseForge 1725334), built for client 1.60.1.70888.
It is GPL-3.0 with an attribution term, and its classic data comes from CMaNGOS classic-db
(GPL-3.0).

- **No runtime access.** ForeverDB keeps all data in its private addon table; no globals. The
  data can only be used by importing it at build time.
- **What it adds over QuestieDB:**
  - objective counts (CMaNGOS for classic quests, player captures for Forever quests);
  - Forever-observed quest, objective and turn-in spots (client POI and players);
  - Forever-measured drop chances;
  - player-captured quest XP and an XP-by-level curve;
  - pace (seconds per kill, item and object by level band);
  - travel data (flight paths and measured times, hubs, walk matrix with danger tiers);
  - zone levels;
  - the list of classic quests that exist in the Forever client.
- **Where QuestieDB is stronger:**
  - NPC spawn coverage. On 3,073 shared quests with objectives, QuestieDB locates every
    objective for 2,002 and ForeverDB for 1,402.
  - 940 Forever-range quests ForeverDB players have not recorded yet. Riverglades is live, so
    these are real.
- **Decision:** import both, with field-level priorities. See data-format.md. (Later changed:
  QuestieDB is now read at runtime and only ForeverDB is imported, with the same field-level
  priorities applied by `LevelScout/adapters/Merge.lua`; see the top of this file. The import
  result below is from the build-time import of both.)

### Import result (2026-11-12)

**Overall:**
- 4,997 quests, 7,938 NPCs, 1,030 objects, 3,395 items, 2.9 MB of data.
- 782 quests excluded:
  - 745 classic quests that are not in the Forever client (ForeverDB's client-filtered list);
  - 37 that ForeverDB players have never been offered.
- Faction/class variants: 77 quests, 9 NPCs, 9 objects, 5 items.

| | Classic-range (<10000) | Forever-range (≥10000) |
|---|---|---|
| Quests | 3,480 | 1,517 |
| Giver located | 3,403 | 1,377 |
| With objectives | 2,628 | 1,005 |
| All counts known | 2,543 | 408 |
| All objectives located | 1,515 | 593 |
| XP known | 3,228 | 998 |

**The remaining "not located" objectives are mostly items no database can locate:**

| Unlocated objectives | Kind |
|---|---|
| 805 | items with no known source (crafted, gathered, PvP marks) |
| 223 | items dropped only by mobs without spawn data (mostly dungeon mobs) |
| 118 | NPCs without spawns |
| 91 | reputation objectives |

### C5 status: objective counts

Counts now come from data for most classic quests. For Forever quests, the planned order still
applies:
1. in-log count;
2. ForeverDB/CMaNGOS count from data;
3. remembered count from an earlier accept (account-wide, step 7);
4. text parse;
5. a default per kind.

The in-game check of `C_QuestLog.GetQuestObjectives` for quests not in the log (section 6) is
still worth running. If it works, it closes the Forever-range gap.

### XP for quests with no record (2026-11-13)

The old fallback was ForeverDB's curve by level. Checked against the quests whose XP is known, it
was off by 33% at the median and about 3x too high for quests without objectives (talk-to and
delivery quests). LevelScout now uses the median recorded XP by level and kind
(`world.xpEstimate`, computed at runtime by the index from every quest; ForeverDB's curve is the
fallback when a level has no estimate). On the same check (each quest left out of its own group)
the median error is 21%, and the 90th-percentile error drops from about 7x to about 3x.
`Data.GetQuestXP` returns the estimate with its quartile range, so the planner can treat it as
uncertain.

---

## 9. Wowhead

An earlier local-only experiment used Wowhead data; it was removed before the first release and
nothing of it ships. The only Wowhead figures in LevelScout are the drop rates QuestieDB ships,
which LevelScout reads from QuestieDB at runtime.
