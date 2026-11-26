# LevelScout

## Unreleased

- **Delivery and talk quests are planned again**: quests that ForeverDB now records with an objective
  nobody was seen doing (often "speak with" or "deliver to" the turn-in NPC) were left out. They are planned
  as a talk to the turn-in NPC, and the paladin chain starting with A Strange Artifact is offered on the
  Class tab again.
- **Leaving out a slow quest no longer spoils the route**: when dropping slow quests left a quest before the
  level it needs, the shortening that follows could go on from a route that scored nothing and keep moves
  that made it worse. That quest now waits first. Unsearched plans: Goldshire 8,980 to 10,055 XP/h, Westfall
  for a level 12 warrior 9,667 to 10,330 with the same quests. Not benchmarked. (For developers:
  `Planner.TIDY_GATES`, on.)
- **Following the plan no longer re-plans**: accepting or turning in a quest, finishing an objective, using
  the hearthstone or a flight, learning a flight point, a level-up or walking into another zone no longer
  shows "Planning..." and the progress bar, and the next step shows at once. The other zones are still
  ranked from time to time, quietly behind it. The bar shows when the route is really planned again: a
  quest of it can no longer be done, you skip a quest, change an option or click re-plan, you are half a
  level or more ahead of it, it runs out, or you pick another zone.
- **On to a higher zone, when this one is done**: the plan for the next hours now goes on only to a zone of a higher level range (the middle of its range above this one's), and only when little is left here (three quests or fewer still to turn in), you are within a level of this zone's top, or you are at least two levels into the next zone's range by then. Dungeons are not held to it. When no zone qualifies, the plan stays in one zone and is worked out again as you play. When the zone you are in runs out, "Done here. Next:" names a higher zone when one has something to do, else the best one as before. Not benchmarked. (For developers: `Zones.HANDOFF`, off: as before; `Zones.HANDOFF_RISE`, `HANDOFF_QUESTS`, `HANDOFF_NEAR_CAP`, `HANDOFF_FIT`, `HANDOFF_LEVELS`; `Zones.Handoff`, `Zones.Higher`, `Zones.LevelAt`.)
- **The route stays put**: the zone's route on screen is no longer reshuffled as you play. Quests no
  longer come and go between plans, and a slightly better route no longer replaces it. It changes only
  when a quest of it can no longer be done, when you skip or bring back a quest, change an option or
  click re-plan, or when you are half a level or more ahead of what it expected (you did other
  things). A quest you take on your own is added to it; a stop you stand at is still brought forward.
  The way to the current step still follows you: travel far off and it points you to a flight master
  or boat as before.
- **Quests you take are planned**: a quest in your log with work or a turn-in in the zone stays in the
  route whatever it pays. Before, only finished ones were kept, and one you had accepted could vanish and
  show under "left out as slow". This now goes for every quest you take yourself: a red quest, an escort,
  or an elite quest while group quests are listed only is planned once it is in your log (until you take
  it, it stays listed). Taking a quest you had skipped brings it back. A dungeon quest you have taken
  stays in that dungeon's plan, and a finished elite quest is turned in whatever the option says. Still
  left out: a quest whose mobs are too strong for your level (planned once you reach it), one done wholly
  in another zone (that zone's plan has it), and a failed one ("Escort quests" says to abandon it and take
  it again). A turn-in carried from another zone is still weighed as before.
- **A quest you take no longer drops out of the route** when no database knows where it is turned in: the
  turn-in is guessed at its giver, as before you took it.
- **The zone you picked stays**: LevelScout no longer switches zones by itself. When the step the plan
  leaves a zone after is done, the banner says "Done here as planned. Next: <zone>" and chat says so once;
  click it to go, right-click to stay. The zone shown (picked by you or by LevelScout) is kept for 40 minutes of play (or the time its plan
  gives it, if shorter): no banner about a better start in that time. A zone that runs out stays shown,
  with "Nothing left here" and the next zone's steps below it.
- **Fair figures on the Zones tab**: every zone is figured over the same 2 h 30 starting there, and the best
  three others are planned again like the shown zone's path. The other rows show "~" before the figure (a
  rough one) and no percentage. A difference under 5% is not shown, and the banner only names a start that
  was planned again.
- **Hearthstone on the way to the next zone**: the trip between zones may go by hearthstone when it is ready
  and saves 2 minutes or more. In a level 35 snapshot the missed path earned 60,998 XP against 51,296 for
  the one chosen before.
- **For developers**: `Model.Build` marks a quest in the log that has not failed `taken`. `held` is set
  from it, and in a dungeon's plan for that dungeon's own quests. The Engine's log signature includes the
  failed flag, and `QUEST_ACCEPTED` clears `chardb.ignored` for the quest. `Engine.FOLLOW_PATH` and
  `Engine.BACK_WITHIN` are gone. New: `Zones.Commit`,
  `Zones.CommitPath`, `Zones.Waited`, `Zones.COMMIT_STAY`, `Zones.COMPARE_TOP`, `Zones.STONE_TRIPS`,
  `Engine.StayHere`, `Engine.Commit`, `UI.GAIN_MIN`, the play event `stay`, `starts[].rough`,
  `moveOn.reached`, and `commitWas` in snapshots. `Zones.MoveOn` takes the commitment as a fifth argument.
  The itinerary takes about 1 to 1.5 s more CPU.
- **Escort quests are listed, not routed**: quests where you walk an NPC somewhere or keep it alive
  through an attack (Missing In Action, Protecting the Shipment, the Gizelton Caravan) take minutes
  and fail when the NPC dies. They now show under "Escort quests" on the Quests tab. "Escort quests:
  in the route" in the options plans them again; the choice is saved with the character. When
  planned, an escort counts 5 minutes (it was 2), and the two Gizelton Caravan quests half an hour
  more: the caravan sets out about once an hour. Quests that follow an escort wait until it is done.
- **The next zone stays put**: the zone the path goes on to no longer flips between rankings. The order
  on screen, and the step its first zone is left after, stays unless another earns 5% more. Both are
  planned again as you will find them, also when the path starts in the zone you chose.
- **A better next zone**: the three best choices by today's plans are planned again before one is picked
  (a level 34 snapshot: +18% XP over the next 2 h 30).
- **The banner agrees with the Zones list**: it names the zone the list puts first and says how much more
  XP per hour it earns, with the list's figures. The "Next" row shows the path's XP and its XP per hour.
- **For developers**: snapshots record the step each zone was left after (`itineraryWasKeys`).
  `Zones.Choose`, `Zones.StartOrder` and `Zones.REFINE_TOP` are new.
- **For developers: the hearthstone in the plan** (`Planner.HEARTH`, on): a route uses the
  hearthstone on the first trip it shortens by 2 minutes or more, once the stone is ready, and the
  next hours carry its cooldown from zone to zone. The route's order does not change; its times, the
  zone ranking and the next hours see the time saved. The bench binds each character in its town
  (`SET="hearth:Planner.HEARTH=true"`, `BIND=capital`, `HEARTH_READY=`). With the flag off plans
  are unchanged.
- **Hearthstone**: LevelScout reads where your hearthstone is bound and when it is ready. When it saves at
  least 2 minutes, the route uses it: the current step says "hearth to Lakeshire", and so do later steps. When it
  is not ready yet, the step says when it will be. In the benchmark this earned about 1% more XP over the next
  2.5 hours. Not tried in the game yet: `/run LevelScout.Planner.HEARTH = false` turns it off until `/reload`.

## 0.2.0

- **Quests that end in the next zone are taken along**: when the next hours go on to another
  zone, quests that are accepted on the way and finished there (a letter for that zone's town,
  "report to" someone there, work over the border) are accepted in the first zone's route and
  turned in in the next, instead of being left out as slow. The accept says where the quest is
  finished, and the turn-in shows under "Then:". The tooltip of the "Next 2 hours" row says how
  many are taken along and what they add.
- **More zones compared**: up to nine zones are planned and ranked at a time (it was six).
- **Zones one level early**: a zone is offered from one level before its suggested range (it was:
  only from the bottom of the range). Leveling guides enter many zones a level early. Such a
  zone is listed in addition to the usual ones, never in place of one. Dungeons are unchanged.
- **Better routes where quests wait for your next level**: the route search tries taking a few quests out of
  the route and putting them back. When that made you reach a level later than a quest left in the route
  needs it, the try was thrown away, about one try in six. Such a quest now goes out with them and comes back
  after the level-up, and the route the search starts from no longer has one before its level either. Zones
  with such quests get better routes more often; zones without them are planned exactly as before. In the
  search view, a round says how many quests went out for a level.
- **For developers**: a sharper bench (`tests/bench.lua`): the verdict is now made per character.
  The standard error comes from the characters' means with a Student t bar, and a character counts
  as harmed only beyond its own noise. It prints the variance split, the salt-to-salt correlation,
  and the salts or characters needed to detect a difference. New options: `CRN=1` (common random
  numbers, `Search.STREAM = "rounds"`; the game keeps its stream and its plans), `SEQ=1` (salts
  added until settled), `CHARS=2` / `CHARS=all`, `RAW=file`, and `RACE_DRY=1` (what skipping
  hopeless zones' searches would save).
- **For developers**: three experimental ways for the route search to learn as it goes, all off by
  default: a removal that prefers quests whose removal has paid before
  (`Search.EXTRA_OPS=credit`), quests the search keeps taking in getting a full chance to come back
  (`Search.OUTSIDERS=contested`), and a Bayesian choice of removal and regret strength
  (`Search.BANDIT=beta`, with `uniform` as a control). `tests/bench.lua` switches them with `SET=`
  and prints what each removal and strength achieved with `ARMS=1`. Plans are unchanged.
- **Search view (debug)**: the window can be resized from its corner and keeps its size and place
  across `/reload`. The map numbers the route's stops in order (steps at one place share a marker:
  "3-5"), a list of the route's steps sits to the right of the map and follows the slider, and
  hovering a step lights up its marker, and hovering a marker its steps.
- **Play log (`/ls play`)**: LevelScout now keeps, with your character, what the plan promised
  for the next 15, 30 and 60 minutes and what you really earned, and where you did something
  else than the plan: a zone chosen by hand, a skipped quest, quests turned in out of the
  route's order. Only time you are playing counts. When you overrule the plan, a snapshot is
  taken quietly (at most one every 15 minutes), so the moment can be looked into later.
  `/ls play reset` empties the log.
- **`/ls snapshot [note]`**: saves what LevelScout planned from and what it showed (the zones, the
  route, the next hours) with your character, so a surprising suggestion can be looked into
  later. It plans once more to record this; chat says when it is saved. The last 5 are kept and
  written to disk at logout or `/reload`. (For developers: `tests/replay.lua` plans a saved
  snapshot again outside the game and shows what differs.)
- **Flights from a flight master you have not unlocked yet**: when the fastest way is to walk to
  a flight master of your side that you do not know, unlock the point there and fly on to one you
  know, the route and the waypoint take it: "unlock Lakeshire and fly to Darkshire". Flights
  still end only at points you know.

## 0.1.1

- **One path across zones**: the route no longer stops at the zone's edge. When you finish the
  step after which the plan leaves the zone, the next zone's steps follow by themselves (chat
  says "On to ..."), in the order shown under "Then:", and what is left behind stays for later.
  The plan always looks two and a half hours ahead from where you are. A dungeon is never
  started for you.
- **Your current step stays**: when a clearly better route is found, it is taken with the step
  you are on still first. If that cannot be done, the route changes only after you finish it.
- **The plan starts where you are**: the plan across zones always starts with the zone you chose.
  If another start would earn more, the banner and the plan row say so, and a click takes it.
- **No more shying away from long quests late in the plan**: quests that would be turned in just
  after the two and a half hours count for the part already done.
- **Zones tab**: a zone's XP per hour is for that plan when you start with that zone and take
  the best way on after it ("then Westfall"), and the zones are listed by that. The tooltip
  still has the zone's own first-hour figure.
- **Class quests**: when a class quest chain becomes available (and the leveling route does not
  already do it), chat says so once and the new Class tab's title glows until you open it (the tab is there
  only while it has something). Pick a
  chain there to make it the plan; its tooltip says where it starts, how long it takes, what it
  pays and what it costs against leveling. While you follow a chain, only its quests are
  planned. When the chain is done (or its rest waits for a level or a group), LevelScout goes back
  to leveling. Right-click a chain: don't suggest it again. The options menu has "Back to the
  leveling plan".
- **Class quests in dungeons**: a dungeon's plan takes your class quests that need something
  from inside it, with their lead-up, so you have them when you go in. One that is only partly
  done there (The Test of Righteousness: lumber in the Deadmines, a hammer in Shadowfang Keep)
  is accepted before the run and kept for the rest.
- **Quest search**: a box on the Quests tab finds any quest you can accept now by name, even
  with typos or in any case. Pick one (or press Enter) and it becomes the plan, with its whole
  chain.
- **Learning from play counts active time only**: standing still for more than 15 seconds (away,
  tabbed out) no longer counts towards kill pace or step times. Each step's time is split into
  getting there and the work at the place, and each part corrects its own estimate (travel,
  or the kind of work). `/ls learn` shows both.
- **Quest levels**: accept and turn-in steps show each quest's level, "[12] Name", in the window,
  the waypoint's title and the minimap button's tooltip.
- A quest that needs one of several quests first is planned after whichever of them the route
  does (it waited for all of them before).
- While LevelScout knows none of your flight paths, a step in another zone says it is planned on
  foot for that reason ("on foot: flight paths not known yet"), and chat says once to open a
  flight master's map.
- Opening a flight master's map re-plans with its flight points at once, while the map is open,
  and the flight to take is marked on that same opening (before: after closing it, and on the
  next opening).
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
