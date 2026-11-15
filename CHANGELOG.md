# LevelScout

## Unreleased

- **Class quests**: when a class quest chain becomes available (and the leveling route does not
  already do it), chat says so once and the new Class tab's title glows until you open it. Pick a
  chain there to make it the plan; its tooltip says where it starts, how long it takes, what it
  pays and what it costs against leveling. Quests on the way come along when they add little
  time. When the chain is done (or its rest waits for a level or a group), LevelScout goes back
  to leveling. Right-click a chain: don't suggest it again. The options menu has "Back to the
  leveling plan".
- **Quest levels**: accept and turn-in steps show each quest's level, "[12] Name", in the window,
  the waypoint's title and the minimap button's tooltip.
- A quest that needs one of several quests first is planned after whichever of them the route
  does (it waited for all of them before).
- While LevelScout knows none of your flight paths, a step in another zone says it is planned on
  foot for that reason ("on foot: flight paths not known yet"), and chat says once to open a
  flight master's map.
- A quest no Forever player has seen counts as existing when a quest that needs it has been
  seen, so chains with such a gap are planned through it.

## 0.1.0

First release. A leveling planner for WoW: Forever (client 1.60.1).

- **Zone ranking**: zones and 5-player dungeons that fit your level are ranked by the XP per hour
  you would make there, the trip to them included.
- **Quest route**: the quests of the chosen zone in the order that earns the most XP per hour:
  pickups batched at hubs, shared camps worked together, turn-ins grouped, slow quests left out
  and listed. Follow-ups, quests for a level the route reaches, and quests carried from other
  zones are planned too.
- **When to move on**: an itinerary for the next two hours across up to three zones, and a banner
  when starting somewhere else earns at least 20% more.
- **Guidance**: a waypoint for the current step (TomTom optional), a live distance, and the
  flight map's useful flight paths highlighted.
- **Learns from play**: your pace, travel speed and drop rates move the plan towards what you
  really see. XP buffs and rested XP are counted, with reminders before a buff ends.
- **Groups and elites**: party XP and drop sharing, elite quests routed for a group.
- `/ls` (or `/levelscout`) shows or hides the window; `/ls about` shows the credits.
- **Requires [QuestieDB](https://www.curseforge.com/wow/addons/questiedb)** (contract 4). Quests,
  NPCs, objects, items, prerequisites, spawns and drop rates are read from your installed
  QuestieDB, with its corrections for your character, so they are as current as QuestieDB. Without
  it LevelScout says so in chat and stays inactive. TomTom is optional.

Data from ForeverDB.net (https://foreverdb.net) and CMaNGOS classic-db (shipped), and from the
QuestieDB addon (read at runtime); see NOTICE.txt.
