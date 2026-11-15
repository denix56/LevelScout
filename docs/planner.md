# LevelScout planner, guidance and window

Written 2026-11-13. Describes what is built, where it departs from the original design and why,
and what has to be checked in game.

## Design review

The original design was reviewed for speed and for the quality of its results before the core
was written. These are the changes that came out of it.

| Design | Problem | What is built |
|---|---|---|
| Zone score = peak XP/hour over the first N steps | N is arbitrary, and one cheap turn-in can make a zone look great | The best XP/hour reachable by following the route and leaving at the best moment, judged on at least 60 minutes of play. The trip to the zone and a 2-minute switch cost are on the clock |
| Order by cheapest insertion (shortest route) | The goal is XP per hour, not distance; a short route can still be full of poor quests | Quests are added in order of XP per added second, each stop at its cheapest place. Quests that pay less than half of what the rest of the route earns per second are dropped and listed as "left out as slow" |
| Chain bonus: a share of the value of follow-ups | A guess where the real thing is available | Follow-up quests are planned for real: accepted after their prerequisite is turned in, with their own XP and time |
| Re-plan on every quest progress event | A kill quest updates the log on every kill | Events are debounced (0.5 s), plans are at least 2 s apart, and a log update re-plans only when progress really changed. Other zones are re-ranked at most every 45 s |
| Plan 5-8 zones on every change | Too much work for a change that only affects one zone | Only the shown zone is re-planned on progress. All shortlisted zones (6) are re-planned on login, level-up, zone change, and when the ranking is older than 45 s |
| Kill time = kills x cycle time | A camp of 5 mobs cannot be killed 20 times in a row | Kills beyond the camp's size wait for respawns (about 300 s per mob) |
| (not in the design) | Inserting stops one at a time can leave an accept for a later visit to the same NPC | After routing, every accept moves to the first visit of its place (within 40 yards), as far forward as its prerequisites allow. This never lengthens the route |
| (not in the design) | The shortest order is not always the best: batching turn-ins saves walking but pays out later | After routing, runs of up to three consecutive stops are moved together to shorten the route (this is what lets a work-and-turn-in pair move to where the giver is passed anyway). Each such move is kept unless it would cost more than 5% of the route's peak XP per hour: working a camp while you are there beats coming back for it |
| A zone's plan holds the zone's quests | A quest can send you into the next zone, where another quest starts in the very camp you are clearing (a letter on a table); it belongs to that other zone, so it was never considered | Quests that start within 80 yards of a stop the plan makes in another zone are added as candidates. The usual value check decides whether they stay |
| Stability threshold | Not specified | The shown order is rebuilt as it was (minus finished steps). A fresh plan replaces it only when it scores 5% better |
| Move-on with hysteresis | Not specified | Both choices are valued over the same hour: leaving now (an hour of the other zone, trip included) against staying (what is left here, then the other zone for the rest of the hour). Suggested when leaving is worth 20% more; the suggestion stays until that falls under 5%. A short remainder never triggers it by itself. Since stage 3 this rule is the fallback: with an itinerary the banner follows it (see "Itinerary") |

**Speed, measured** on the real data in standalone Lua 5.1 (`tests/sim.lua`): planning all
shortlisted zones takes 30-190 ms of CPU in total, and the longest stretch without a yield point
is 1-4 ms. In game the work is cut into 4 ms slices per frame, so a full re-rank spreads over
roughly 10-50 frames. In-game Lua speed is not measured yet.

**Result quality** has only been judged by reading simulated plans (level 2 Northshire, level 7
Elwynn, level 12 Westfall, level 22 Barrens, levels 34-58). They read like sensible routes: hub
pickups first, shared camps merged, turn-ins batched. It has not been compared against a
leveling guide or against play.

## Search (stage 1 of the better-planner work)

A fresh plan is built in five steps. A kept plan (the order on screen, minus finished steps) skips 2, 4 and 5.

1. **Build**: quests are added one at a time, best XP per added second first, each stop at its cheapest place.
2. **Search** (`Planner.SEARCH_ITERATIONS`, 120 rounds): each round takes 2 to 8 quests out of the route and puts them back.
   - What is taken out: any quests, quests close to each other, the quests that pay least, or everything on one stretch of the route. Follow-ups leave with their prerequisite.
   - Putting back uses **regret insertion**: a quest that would lose much if its best place were taken goes first. Three strengths (none, 1, 2.5) are tried.
   - A quest goes back only if it pays at least half the route's rate (the same bar as the "left out as slow" rule). A quest already finished in the log always goes back.
   - The ways of taking out and putting back are chosen by how well each has worked so far.
   - A round is kept when the route is worth more. Early rounds are also kept when it is worth up to 1.5% less (`SEARCH_TEMPERATURE`); the allowance shrinks to nothing by the last round.
   - "Worth" is the peak XP per hour, plus 15% of the route's surplus: all its XP, less its time valued at half the peak rate.
3. **Drop and tidy**, as before: slow quests are dropped, accepts are batched, runs of up to three stops are moved.
4. **Exact windows** (`Planner.EXACT_WINDOW`, 8 stops): each stretch of 8 stops in a row is put in its best possible order, found by trying every valid order through a table of "stops visited, last stop" states. Two orders are produced (quickest through the stretch; best rate soonest, then quickest finish) and the one that makes the route worth most is kept. The window slides on by 4 stops.

5. **Searched against not searched**: the search maximises "worth" before step 3, and step 3 can undo part of that. So the route as it was before the search goes through steps 3 and 4 as well, and the plan with the higher score (XP per hour leaving at the best moment) is returned. A searched plan is therefore never worse than the same planner without the search. This costs one more tidy-up per zone.

Not searched: dungeon plans (one run with its lead-up). No beam search was built: the sliding window covers routes of any length.

The search uses its own random numbers, seeded from the zone, the level and the number of quests, so the same situation always gives the same plan. Before this work the planner did not have that property: quests were walked in memory order, and plans for identical input differed by up to 9%. Quests are now always walked by id.

### Nearby insertion places

`Planner.NEAR_K` (default `nil` = off = today's exact scan). When set, `R:best` does not try every place the order rules allow, only: the range's edges (`lo`, `hi`), the place right after the start, and both sides of each of the stop's K nearest stops that are in the route (the stops are ranked once per stop by straight-line `Geo.Dist`, other continents last, ties by creation number; the list is cached in `r.nbr` and rebuilt when more stops have been made). The "second best" for the regret is the second best among the candidates. `R:improve` uses the same rule for a moved run (neighbours of its first and last stop; `Planner.NEAR_IMPROVE = false` turns that part off). Routes of at most 2K + 2 stops are scanned fully. With K off or huge the plans are byte-identical to before. The work counter counts evaluated places plus list walk steps, so equal-work comparisons give a cheaper trial more rounds.

Measured (8 characters, 3 salts, CPU ms = min of 2 runs, machine shared so about +-10% noise per figure): base 1017 ms/char, mean zone +7.7%, worst 0.0%, itinerary 41193 XP. K=6: 715 ms (-30%), mean +8.8%, worst -1.9%, itin 40626. K=10: 762 ms, +7.5%, worst -1.8%, itin 39300. K=16: 815 ms, +7.6%, worst -4.4%, itin 40971. K=24: 856 ms (-16%), +7.7%, worst 0.0%, itin 40582. Equal work (x0.5 / x1 / x2 of base's work), mean zone (worst): base +6.7 / +7.4 / +8.6 (0.0 each); K=6 +7.3 (-2.6) / +8.3 (-3.5) / +9.0 (-2.3); K=24 +6.7 (-0.5) / +7.3 (-0.3) / +8.7 (0.0). With K applied everywhere it is faster per plan but some zones get a little worse (worst zone below 0, because the greedy route and the unsearched comparison route in `finish` are also built with nearby places only) and itinerary XP drops about 1.5%.

`Planner.NEAR_SCOPE` ("search", the default, or "all" = the behaviour measured above) says where K applies. With "search" the nearby rule is used only for the repair after each removal inside the search's rounds (Search.Run's `sc.fill`; the Planner wrapper sets `r.nearK` for the duration of that call and clears it afterwards, also on an error); `R:nearCandidates` reads `r.nearK`. The initial fill, the warm-start rebuild and its repair, the tidy-up `improve` and everything in `finish` try every place, so the unsearched comparison route equals the plan with K off and "never worse than no search" holds again. With K off the plans are byte-identical to before (step dump of the 8 bench characters).

Measured, scope "search" (8 characters, 3 salts, CPU = min of 3 runs, shared machine, about +-10%): base 983 ms/char, mean zone +7.7%, worst 0.0%, top +9.8%, work 3592k, itinerary 41193 XP. K=6: 728 ms (-26%), +8.1%, 0.0%, +10.2%, 3372k, itin 39975 (-3.0%). K=10: 799 ms (-19%), +8.1%, 0.0%, +11.1%, 3598k, itin 40576 (-1.5%). K=16: 829 ms (-16%), +7.9%, 0.0%, +10.2%, 3833k, itin 40777 (-1.0%). K=6 scope "all": 685 ms, +8.8%, -1.9%, +11.4%, itin 40626. K=6 with `NEAR_IMPROVE = false` (no effect on the plans in "search" scope, since the tidy-up improve is outside the rounds): 688 ms, identical scores. The worst zone is fixed (0.0% for all 8 characters) and the mean zone holds, but itinerary XP still drops 1.0 to 3.0%, more than the 0.5% bar, so `NEAR_K` stays `nil` (off).

### Objective and polish

`core/Objective.lua` and the route object in `core/Planner.lua`.

**Caches (`Planner.VALUE_CACHE`, on).** A pure speed-up: the plans are byte-identical (a step dump of the 8 bench characters matches). Each stop remembers its seconds, XP and kills per level reached (cleared when its reqs change); `R:profile()` is kept for the route's version, with the profile of the route a trial started from held apart, because a taken-back trial leaves the route exactly as it was and gets its version back (versions are never reused for another route); `gateIndex` halves instead of scanning; `R:best` reads the travel memo in place; `Travel:NearestNodes` is remembered per location. Together: about 23% less CPU, 9% less counted work.

**Dinkelbach (`Objective.MODE = "dinkelbach"`, off).** Rounds are judged by the XP a route makes over what rate R would have made in the same time, plus the tail term, reported as R + F/H so the loop's relative margins work unchanged. R is the best true score found, raised every `Objective.EPOCH` rounds. The loop's best route is still chosen by today's worth, and finish() compares today's scores.

**Polish (`Objective.POLISH`, off).** After a repair, short runs of the stops the repair placed (and neighbours) are moved a few places (`R:shift`, `R:runBounds`), each try re-working only the changed stretch (`ev:commit`, `ev:evalFrom`; with Dinkelbach the rest of the route is read from the reference once it is the same stops shifted in time). Draws no random numbers, calls the checkpoint, leaves a route that already has a stop before its level alone.

Measured (5 salts, equal work, mean zone vs the old planner): at x0.5 / x1 / x2 of base's search work, base +6.9 / +7.3 / +8.3; Dinkelbach +6.9 / +7.6 / +8.4 (worst zone -1.2% at x0.5); polish +6.6 / +7.3 / +8.1; both +7.0 / +7.9 / +8.5 (worst -1.5% at x0.5). The standard error of a mean is about 0.15 to 0.25, so none of this clears the noise bar; polish costs about 25% more work per round.

### Search loop: stopping, removals, acceptance

`core/Search.lua` holds the loop: rounds, ways of taking quests out, three regret strengths, adaptive weights, acceptance. Everything below is a setting on `ns.Search`. Only `OUTSIDERS` is on by default; the numbers behind the defaults are under "Defaults chosen" below.

- Early stop: `STALL_ROUNDS` (stop after that many rounds without a new best), not before `MIN_ROUNDS`, or `STALL_FROM` of the rounds; a search that started from an earlier plan uses `STALL_ROUNDS_WARM` / `MIN_ROUNDS_WARM`. The result says `stopped`.
- More removals (`EXTRA_OPS`): "a whole quest chain", "everything at one camp", "the longest detours", and with `"all"` "everything at one place". Weights are saved by operator name, so saved weights stay valid when operators are added or switched off.
- Acceptance (`ACCEPT`): "anneal" (today) or "rrt" (a round is kept when within `RRT_MARGIN` of the best; no schedule, which suits a search that may stop early). `Search.Accept` is the pure rule. `RESTART_AFTER`: go back to the best route after that many rounds without a new best; the debug view says so on that round.
- Saved weights are blended: `w = max(0.05, WEIGHT_CARRY * saved + (1 - WEIGHT_CARRY))`.
- `OUTSIDERS = "once"`: in a search round's repair, quests that were already out before the round's removal are tried only on the first pass of the repair (Planner's `fill` takes the set of quests just taken out as a fourth argument).

### Plan memory: reuse and warm start

(`core/Memory.lua`, `Zones.PlanZone/Rank/Itinerary`, the warm block in `Planner.Plan`.)

Reuse: with a memory (Engine only), Rank hands out another zone's earlier plan while the discrete inputs are equal (level, side, class, race, flight paths, group, XP bonus, capacity, planner settings, start cell, quests the plan read incl. ignored), XP and rested pool moved under 10% of a level, learned figures under 2% (step-model weights 0.02), and the plan is under `Zones.REUSE_MAX_AGE` (300 s) old. The home zone is always planned. `Memory.Reusable` says why not (z.why).

Warm start: a zone's search starts from the route the previous search of it ended on (`plan.searchOrder`), rebuilt, repaired with the usual price floor, kept when worth >= the greedy route, then at most `Planner.WARM_ROUNDS` rounds. Every 5th plan of a zone is cold (`Zones.REFRESH_EVERY`). The itinerary re-plans later zones warm from their ranked plans (`Zones.ITINERARY_WARM`), with 40 rounds (`Zones.ITINERARY_ROUNDS`). A quick re-plan of the shown zone is cold (`Zones.WARM_SHOWN`). Without a memory nothing changes. Sequence bench: `tests/bench_replan.lua`.

Sequence bench (8 characters, re-plans 45 or 120 s of play apart): reuse cut the ranking work by 28% to 42%, but reused zones were 1.1% to 2.7% off a fresh plan on average (up to 31%), and the best-ranked zone differed from a fresh ranking in 14% to 21% of steps. That misses the keep rule (under 1%, 95% agreement), so reuse is off; part of the difference is the search's own noise, which was not measured separately. Zones planned warm in a ranking scored 0.4% to 0.6% above cold ones. A warm quick re-plan of the shown zone scored 0.6% to 1.6% below a cold one (worst case -12%), so the shown zone is re-planned cold. A quest-starting item in the bags is part of the reuse key.

### How a change is judged

One measure decides: the XP actually earned over the next two hours (the itinerary's XP, `Zones.HORIZON`), compared PAIRED against base. `tests/bench.lua` runs every config on the same 8 characters and the same salts (`SALTS`, `Search.SEED_SALT`); for each (character, salt) pair it takes the % difference to base on that character and salt, and reports their mean, its standard error (sd / sqrt(n), n = characters x salts), the worst character (mean over salts of its difference) and how many characters are worse than -0.5%. A second line gives the same for the best-ranked zone's route in its first 120 minutes. The zone-score columns (mean / worst / best-ranked zone %) are secondary: the zone score and the itinerary's XP disagreed, so the zone score does not decide.

Verdict versus base:

- "better": the paired mean is above 2 SE and no character is below -1%.
- "worse": the paired mean is below -2 SE, or a character is below -2%.
- "no clear difference": otherwise.

A change is kept when its verdict is "better" on `SALTS="0 1 2 3 4"`, the planner's guarantees hold (the searched plan is never below the unsearched one), and planning yields cleanly (the yields test). CPU time is indicative only (a shared machine); work units are exact.

### Defaults chosen (all streams merged)

`ONLYSET=1 SALTS="0 1 2" ITIN=1 tests/bench.lua`, mean of three seeds, against the old planner:

| Settings | Mean zone | Worst | Best-ranked | Work per character | CPU per character | Itinerary XP | Itinerary time |
|---|---|---|---|---|---|---|---|
| Before this work (anneal, no outsiders rule, itinerary cold at 120 rounds) | +7.5% | 0.0% | +9.0% | 4038k | 1146 ms | 40,819 | 92 ms |
| Chosen: outsiders once, caches, itinerary warm at 40 rounds | +7.7% | 0.0% | +9.8% | 3592k | 967 ms | 41,193 | 61 ms |
| Chosen + record-to-record (0.5%) | +8.0% | 0.0% | +10.2% | 3630k | 985 ms | 40,044 | 63 ms |
| Chosen + record-to-record + Dinkelbach + polish | +7.4% | 0.0% | +9.5% | 3922k | 1127 ms | 40,209 | 71 ms |

- Kept: the caches (identical plans), "outsiders once", warm itinerary re-plans at 40 rounds (40,044 / 40,084 / 40,116 XP for warm 40 / warm 120 / cold 120 rounds with record-to-record on: the same within 0.2%).
- Record-to-record acceptance is off: it raised the zone scores a little but took 1 to 2% off the itinerary's XP (on its own 1.2%, against 0.4% for "outsiders once").
- Off: Dinkelbach and polish (no gain, and worse combined), early stop (loses 0.5 to 0.9 points), extra removals (worse at equal work), restarts (one zone below the unsearched route at half the work), reuse (see above).
- The standard errors are 0.2 to 0.45 points, so differences under about half a point are not settled.


### Goal: surplus over the next-best option

`Planner.GOAL` ("rate", the default, or "surplus"). Today's goal ("rate") values a zone's route by its best "XP so far / time so far" over leaving points, with time floored at one hour. It has an arbitrary floor, ignores what else the player could do, and disagrees with the 2-hour itinerary (three changes raised zone scores and lowered itinerary XP). "surplus" is the marginal value theorem: stay while the route pays more than the alternative.

- **R**, XP per second to be had elsewhere, times `Planner.ALT_SHARE` (1.0). It is the best zone's today's score (`plan.score / 3600`, one-hour floor). Sources in order: `ctx.altRate` set by the caller (tests, bench); the Engine passes the last full ranking's best score (`Zones.AltScore`, kept as `plan.todayScore` under this goal) as `state.altRate`; otherwise `Zones.Rank` runs `Zones.Bootstrap`: every shortlisted zone planned once under "rate" with no search (memory untouched), best score / 3600, stored in `ctx.altRate` (and `ctx.bootstrapWork`). The itinerary re-plans later zones with the same R. `Planner.Plan` called without any R uses the greedy route's own score.
- **Value** of leaving after stop k: V(k) = XP(k) - R * (overhead + T(k)); leaving before the first stop is V = -R * overhead. `R:surplus` computes the max over the route (level-ups, rested pool and gates as in `R:score`; a stop before its level is broken). `plan.value` is the best of those, `plan.peak` the argmax over the steps, `plan.stay` is set when staying put is better, `plan.bestValue` is the best V over the steps even then, `plan.tailStart` is after the peak. `plan.rate` and `plan.score` are XP per hour up to the peak (no floor): what the window shows. Deviation: when staying put wins, `peak` is still a step (the argmax over steps, usually the first), never 0.
- **Search**: `Objective` mode "surplus" (automatic when the route has a goal R): the round's number is R + V / MIN_HORIZON, so the relative margins work (`ev:scale` = max(|ref|, R)). The best route is kept by the same number; `finish()` compares searched against unsearched by `plan.value`; the warm-start check, the exact windows and the tidy-up's guards use it too (the guard keeps `SCORE_GIVE` of V in XP; guarding R + V/H let the tidy-up throw the whole surplus away). Polish is not built for it (skipped). `Zones.Rank` sorts by value, then best value, then score, then map (zones below staying put tie on value).
- **Under "rate"** nothing changes: a step dump of the 8 bench characters (all zones, steps, times, XP, work, itinerary XP) is byte-identical to main.
- **Cost**: the bootstrap is one unsearched plan per zone: about 0.9M work units and 300 to 550 ms per character (a fifth of a ranking, +25% work).

Measured (`ONLYSET=1 ITIN=1 SALTS="0 1 2" REPEAT=2`, 8 characters, summed over characters, mean of 3 salts; the "mean zone" column of the bench compares `plan.score`, which changes meaning, so it is not a judge; the XP columns follow the best-ranked zone's route for 60 / 120 minutes, stopping mid-step pro rata, and the itinerary):

| Setting | XP 60 min | XP 120 min | Itinerary XP | Worst character (any of the three) | Best zone differs from rate | Work/char | CPU/char |
|---|---|---|---|---|---|---|---|
| rate (main) | 134,012 | 283,605 | 329,540 | - | - | 3592k | 2749 ms |
| surplus, ALT_SHARE 1.0 | 149,074 (+11.2%) | 272,384 (-4.0%) | 305,176 (-7.4%) | -43% | 7 of 24 | 4419k | 3284 ms |
| surplus, 0.9 | 144,357 (+7.7%) | 289,870 (+2.2%) | 323,369 (-1.9%) | -17.5% | 4 of 24 | 4435k | 2445 ms |
| surplus, 1.1 | 126,951 (-5.3%) | 249,054 (-12.2%) | 317,157 (-3.8%) | -28.5% | 10 of 24 | 4413k | 2901 ms |

CPU is noisy (shared machine, the test suite ran during part of it; ms/kwork varied from 0.37 to 0.77 between rows), work is exact. Per-character figures swing by 20% either way (the best zone is often a short dungeon run that ends before 120 minutes, which the 120-minute measure counts as it is).

Decision: the bar (itinerary XP within 0.3%, top-zone 60/120-minute XP not lower, worst character at most 1% lower) is missed by a wide margin, so `Planner.GOAL` stays "rate". Zones below R, which is most of them (R is the best zone's own unsearched score), all read "stay put" and the search gets a flat signal for them; the itinerary then lost 2 to 7% of its XP.

Faster settings retested under "surplus" (against the surplus row: itinerary 305,176 XP, 4419k work): `NEAR_K = 10` (scope "search"): 320,615 XP (+5.1%), 4459k work, 2420 ms; `Search.ACCEPT = "rrt"`, `RRT_MARGIN = 0.005`: 307,585 XP (+0.8%), 4412k work, 1628 ms (-50%, the same machine-load caveat). Against the 0.5% bar both are within or above the goal's own baseline, but the baseline itself is noisy per character (+-20%), so this is not a result to act on; the worst zone is not below the unsearched route for any setting (`finish` compares by value; tested). Neither is turned on.

### Measured (`tests/bench.lua`)

Eight imagined characters (levels 7 to 42, both sides), every shortlisted zone planned from scratch with all flight paths known. Score is XP per hour leaving at the best moment.

| Settings | Mean zone | Worst zone | Best-ranked zone | CPU per character |
|---|---|---|---|---|
| Before (no search) | 0% | 0% | 0% | about 0.25 s |
| Search, 120 rounds, no exact windows | +6.7% | 0.0% | +9.1% | about 1.2 s |
| Search, 120 rounds, exact windows | +7.4% | 0.0% | +9.6% | about 1.2 s |

- Part of the gain is a better order with the same quests, and part is leaving out more slow quests, which shortens the route.
- No zone ends lower than before. Until step 5 was added, one zone ended about 2% lower (the two search rows read +6.6% / -2.3% / +9.1% and +7.3% / -1.8% / +9.4%).
- With exact windows the comparison in step 5 is against the unsearched route with exact windows, not against the "before" row, so "never below before" is measured there, not guaranteed. Without exact windows it is guaranteed.
- The 300-round and 1500-round rows of the earlier table (+9% and +11% mean) were measured before stage 2 and have not been run again.
- CPU times were measured on a busy machine and vary by a factor of two between runs.

Run it with `.tools/bin/lua5.1 tests/bench.lua` (`VERBOSE=1` for a line per zone, `ROUNDS="40 300"` to compare search lengths, `REF=1500` for a reference run). To run only some tests: `./run_tests.sh "planner search"`.

## Level-ups along the route (stage 2)

The route is valued level by level instead of at today's level throughout (`Planner.LEVELS_AHEAD`, 3 level-ups; 0 switches it off).

- **When a level is reached**: the XP still needed comes from the game (`UnitXP`, `UnitXPMax`). Later levels use the classic XP table, scaled by how the game's figure for the current level compares with it. Nothing levels up at the level cap.
- **After a level-up**: kills are valued at the new level (less XP per kill, quicker kills) and a quest that has fallen six or more levels below pays less.
- **Quests for a later level**: a quest that needs a level the route reaches (its own minimum level, a red quest, or mobs that are too strong today) is built as it will be at that level and may be placed only after that level-up. Before, it was only listed under "later".
- **If the level-up moves**: dropping or moving stops can push a level-up back. A quest left before the level it needs is taken out again and listed under "later".
- **In the window**: a heading "Level N from here" after the step that levels you up, and "needs level N" on the accept step of such a quest.

Limits: XP from exploring and from kills on the way is not counted, so level-ups come a little earlier in play than planned. Insertion estimates and the exact windows use the values of the stretch's starting level; the route's score uses the real level at every stop. Dungeon plans do not take quests for a later level.

## Itinerary: the next two hours across zones (stage 3)

`Zones.Itinerary` (in `core/Zones.lua`) answers "which zones, in which order, and when to move on" for the next two hours (`Zones.HORIZON`). It is worked out after each ranking (at most every 45 s), in a job of its own once the zones and the route are on screen, and kept in between. Later zones are re-planned with the full search: a shorter one (40 to 80 rounds instead of 120) cut the time to a quarter or a third, but gave two of six characters a worse itinerary (5% and 11% less XP).

- **What is tried**: every order of up to three of the five best-ranked zones and dungeons. A zone's route may be left at its best moment, at the first turn-in after each quarter of an hour, or at its end. A stay is at least 10 minutes, except in the zone on screen (`opts.shown`): you are in it already, so what is left of it may be finished and left however short it is (`Zones.SHORT_IN_HAND`). The trip to the next zone (2 minutes to switch plus travel from the stop where you leave) is on the clock.
- **What wins**: the itinerary that earns the most XP inside the two hours. A camp being worked when time runs out counts for the share done.
- **Later zones, as you will find them**: the winner's second zone is planned again from where the first is left, at the level reached by then, with the first zone's turned-in quests done. Its moment to leave is then chosen, and the third zone (when there is one) is planned again the same way from where the second is left. A zone with nothing left to do by then is dropped with what follows it. The itinerary is kept only if it still beats the best single zone.
- **Quests carried between zones**: when a zone is left, the quests accepted there and not yet turned in stay in the (imagined) quest log, as the game would show them: complete when all their work is behind you, otherwise with the objectives done so far ticked off (`project` in `core/Zones.lua`). The next zone's plan then
  - turns in or finishes a carried quest when that happens on its map (the existing rule for quests in the log from elsewhere);
  - considers the turn-in of a carried, finished quest wherever it is, a city on the way included (`ctx.carried`, new). The usual value check decides: a turn-in that costs too much travel is left out as slow.
  - XP from such a turn-in counts in the zone where it is turned in (`segments[n].carried`, `carriedXP`; listed in the tooltip).
  - A quest accepted and never turned in inside the two hours earns nothing; the time spent on it is on the clock of the zone where it was spent, so it counts against that moment to leave.
- **Stability**: the shown order of zones is kept unless another earns 5% more. Zones at the front of that order with nothing left by now are finished and passed over: the rest of the order stands.
- **Each zone's route**: every segment carries the plan it is followed by (`segments[n].plan`); for later zones that is the plan made from where the zone before is left. The window shows its first steps.
- **Move-on banner**: with an itinerary for the shown zone, `Zones.MoveOn` follows it. The banner names the itinerary's first zone when that is not the shown zone. The gain is the itinerary's XP against the best itinerary that starts by staying in the shown zone (`itinerary.here`, worked out the same way, later zones planned again), over the two hours. Thresholds are unchanged: shown from 20%, kept until under 5%. If starting in the shown zone turns out at least as good, that becomes the itinerary and there is no banner. The one-hour rule (see the design review table) is used only when there is no itinerary for the shown zone, or nothing is left in the shown zone.
- **In the window**: on the Zones tab, a "Next 2 hours" row (zones with their times, XP per hour over the two hours, the gain against one zone; the tooltip lists each zone, quests brought along, and what starting in the shown zone would earn), shown when it says more than "stay here". On the Route tab, the route goes on past the shown zone: after the step where the itinerary leaves (or after the last step, when the zone is followed to its end or the leave step is not in the route any more) a heading "Then: zone (about N min there)" and the first steps of that zone's route (`UI.AHEAD_STEPS`, 6, up to where it is left in turn), dimmed, and the same for a third zone. Steps of the shown zone the itinerary leaves undone follow under "Left for later here", dimmed. The banner reads "zone: N% more XP over the next 2 hours".
- **When the shown zone runs out**: a quick re-plan that finds the shown zone's route used up ranks the zones in the same job (no wait for the next ranking, which needs an event after 45 s). The zone shown next is the one the itinerary made for the finished zone goes to next (`Zones.NextZone`), if it still has steps; without such an itinerary, the zone you stand in if it has steps, else the best-ranked. It becomes the chosen zone, as if picked by hand. When the finished zone is the one you stand in, the new zone's route is made from where you stand (the ranking judged it as left from the zone's main town). An empty route with nothing to go to does not rank the zones on every re-plan.

Measured on six imagined characters (all flight paths known, `tests/sim.lua`), XP over two hours against the best single zone:

| Character | Itinerary | XP | Best single zone | Gain |
|---|---|---|---|---|
| 22 paladin, Lakeshire | Redridge 58 min, Duskwood 57 min | 43,542 | 40,672 | +7.1% |
| 35 hunter, Southshore | Hillsbrad 59 min, Desolace 46 min | 59,456 | 49,884 | +19.2% |
| 12 shaman, Crossroads | one zone (map 1421) | 24,261 | 24,261 | 0% |
| 42 warrior, Gadgetzan | Stranglethorn 56 min, Badlands 40 min | 70,130 | 61,217 | +14.6% |
| 31 rogue, Darkshire | one dungeon (id 2959) | 53,724 | 53,724 | 0% |
| 15 mage, Sentinel Hill | dungeon (id 3065) 42 min, Loch Modan 66 min | 27,943 | 23,307 | +19.9% |

- No character gets three zones in two hours, and no carried quest is turned in inside the two hours: carried turn-ins are planned (the hunter's second zone has two, in Stormwind and Ironforge) but land after the horizon. So carrying quests changes none of these six numbers.
- With a three- or four-hour horizon (tests only) three zones appear, and carried turn-ins count: the hunter over three hours turns in 4 carried quests for 9,300 XP in the second zone.
- Finding the itinerary takes 2 to 330 ms of CPU here, nearly all of it planning the second zone again. A third zone, and a banner comparison when the itinerary does not start in the shown zone, each add about as much again.

Limits:
- The choice of zones, order and first moment to leave is made from plans for today's level and position. Only the winner (and the "start here" alternative for the banner) is planned again, so a carried turn-in cannot make a different order win.
- A quest that starts in one zone and ends in the next is still planned by the first zone alone. When that zone left it out as slow (the usual fate of a delivery to another zone), the itinerary does not put it back: the route on screen would not show its accept step.
- A carried quest with work left is finished only where that work is on the next zone's map.
- Between re-rankings (45 s) the banner uses the kept itinerary.
- None of this has been tried in the game.

## Not built (by decision or deferred)

- **Learning travel times per zone or per flight**: not built. Own pace, travel speed, drop rates
  and a correction of step times (with one factor for all travel) are learned (see "Learning from
  play").
- **Party handling**: built as a simple model, re-planned whenever the group's size changes.
  - XP from kills is shared by the classic rule (half each for two; a bonus from three members).
  - Time per kill is the solo time x (0.3 + 0.7 / members): an assumption, not a measurement.
  - Kill credit is shared (the kill count does not change).
  - Quest drops are split between the members in turn, so the group needs the count once per
    member on the quest (the round-robin default from findings.md section 5).
  - Not modelled: where the other members are, their levels.
- **Elite quests** are routed (option "Group quests: in the route", on by default; off lists
  them under "Needs a group"). These are assumptions, not measurements:
  - an elite is fought by the group you are in, or by an assumed group of three;
  - an elite takes 2.5 times a normal mob's fight, then the group speed-up applies;
  - elites up to 5 levels above you are allowed (normal mobs: 3);
  - no time is charged for finding a group;
  - the design's single "party block" (all elite quests routed as one unit) is not built: elite
    stops are placed like any other stop.
- **Who is on the quest**: for a quest in your log, the game is asked which party members are on
  it, and drops are split between those only. For quests not yet accepted, every member is
  assumed to take them. Not available in a raid.
- **Hearthstone** as a free return trip.
- **Death risk**: only the cutoff exists (mobs 4+ levels above wait for later).
- **Town trips** (vendor, repair, trainer).
- **Mount speed** as a figure of its own: travel starts from ForeverDB's observed run speed for the
  level band and moves towards the speed this character really travels at, mounted or not (see
  "Learning from play", travel speed). There is still one speed for all walking: the planner does
  not know where you can ride.
- **Weapon upgrade bonus.**

## Learning from play (`core/Learn.lua`, `Tracker.lua`)

The planner starts from database figures and moves them towards what this player sees. Small
online estimators, updated one sample at a time. Pace and drop rates count solo play only: in a
group kills are quicker and drops are shared out. Travel speed and step times are learned in a
group too. `/ls learn` shows what has been learned; `/ls learn reset` forgets all of it.

A plan takes several frames to make, and learning goes on in between. The Engine hands the
planner a copy of what was learned when the plan started (`gather`), so every part of one plan
(each zone, the kept order, the zones of the itinerary planned again from a projected state) uses
the same figures. `Zones.Project` copies the learned tables into the projected state as they are.

**Pace** (per character, `LevelScoutCharDB.pace`): seconds per kill, per collected item and per
object, as a ratio to ForeverDB's median for the level band (`Cost.Pace`).

- A sample is the time between two counts of the same objective in the quest log, when both
  happened within 240 seconds and 250 yards. A kill sample is divided by the usual scaling for the
  mob's level difference (`Cost.KillSeconds`), so it compares like with like. Elites are left out.
- The estimate is the running mean of log(own / typical). The typical pace counts as 3 samples
  (`PACE_PRIOR`); after 20 samples (`PACE_MEMORY`) older ones fade. A sample counts as at most 4
  times faster or slower than typical.
- Because it is a ratio, it carries over to the next level band.
- Events and "other" objectives are not learned.
- The level-aware kill time (`Model.KillAt`, for stops reached after a level-up) starts from the
  same learned pace as the task itself (`task.paceC`).
- A saved value outside the sample limits (a damaged file) is held to them when it is used.

**Travel speed** (per character, in the same table: `LevelScoutCharDB.pace.r`): yards per
second while travelling, as a ratio to ForeverDB's run speed for the level band (`Cost.Pace`'s
`r`, 7 in most bands). It replaces that run speed in `Zones.Context` (`pace.r`, which
`Travel.New` gets as its speed), so it changes every walk in every plan; flights, boats and the
detour factor are untouched.

- The Engine looks at the player's position once a second (`Engine.TrackMove`, from the frame
  timer that also watches the buffs) and passes it to `Tracker.OnMove` with what
  `Game.GetMovement` says: blocked (on a flight path, in combat, dead or a ghost, swimming,
  flying, falling, in a vehicle) and mounted.
- Two positions in a row are one hop. A hop counts as travel when it is at most 3 seconds long
  and makes between 4 and 20 yards per second (`MOVE_MIN`, `MOVE_MAX`): slower is standing,
  walking pace or being stuck; faster is not on the ground (the fastest mount makes 14, a flight
  path about 30, a teleport far more).
- Ten seconds of such hops in a row (`MOVE_STRETCH`) are one sample: the yards covered, hop by
  hop, over the seconds. Anything else ends the stretch and nothing is taken from it: a blocked
  moment, a hop that is not travel, no position (an instance), another continent, mounting or
  dismounting (so the two speeds are never mixed in one sample).
- The estimate is the running mean of log(own / typical), as for pace, with limits of its own:
  the typical speed counts as 12 samples (`SPEED_PRIOR`: two minutes of travel), the last 60
  count most (`SPEED_MEMORY`: ten minutes), and a sample counts as at most 2.5 times faster or
  slower than typical (`SPEED_MAX_RATIO`). One sample moves the planned speed by under 6%.
- What it measures is the speed while really moving, averaged over time: a character who rides
  between camps and walks inside them ends up in between. Stops on the way (a fight, a herb) are
  not travel and are left to the step-time model's travel factor.
- Checks the client does not have count as "not blocked" (`Game.GetMovement`); a flight is then
  still left out by its speed. The path is measured in the planner's own yards (map position
  through `Geo`), the same yards its distances are in.
- Not verified in the game: that `UnitOnTaxi`, `IsMounted`, `IsSwimming`, `IsFlying`,
  `IsFalling`, `UnitIsDeadOrGhost`, `UnitAffectingCombat` and `UnitInVehicle` exist on this
  client; how a boat or zeppelin deck moves the map position (a slow stretch of one could be
  taken as travel; the limits and the slow average bound what it can do); how the position
  behaves at a map border.

**Drop rates** (per account, `LevelScoutDB.drops`): kills and drops per item and mob.

- A kill (`PARTY_KILL`) of a mob that drops an item wanted by an open objective is one try. A count
  of that item within 120 seconds of such a kill is one drop.
- The rate planned with is (database rate x 20 + drops) / (20 + kills): the database rate counts
  as 20 kills (`DROP_PRIOR_KILLS`). With no database rate, nothing changes until 5 kills; then the
  start is 35% worth 4 kills.
- If a kill arrives without a readable mob (the GUID is secret), the next drop is not counted, so
  a hidden kill loses the try and its result together.
- Only drops from mobs are learned, not from objects.

- **One correction per data source.** Before an item's own counts are used, its database rate is
  multiplied by (drops seen + 10) / (drops promised + 10) for its source (ForeverDB, CMaNGOS,
  Wowhead, QuestieDB correction), over all items and mobs of that source we have kills for; within
  1/2 to 2. "Promised" is kills x database rate. An item's own counts are left out of its own
  source correction, so they are not used twice. This is what reaches items never farmed before.

**Step log** (per character, `LevelScoutCharDB.steps`): planned against real time, per
finished step. It measures how far off the plans are, and the step-time model below is fitted on
each line as it is written.

- Timing starts when a step becomes the first step of the shown plan and ends at the first plan
  in which it is no longer first. The planned time is the one from the plan that first showed it
  (travel plus the step).
- A line is written only if the step is finished: an accept when the quest is in the log, a
  turn-in when the quest is completed, work when every objective it was for is finished. A step
  that left the top for another reason (new route, skipped quest, zone change) is dropped, as is
  one that took over two hours, and the one being timed when planning pauses (inside an instance,
  position unknown: `Tracker.Interrupt`).
- A line: `k` kind, `w` action, `p` planned seconds, `pt` its travel part, `a` seconds taken,
  `lv` level, `g` group size, `e` elite step, `n` planned kills, `d` mob level minus own level
  (when the step started). The newest 300 are kept.
- `/ls learn` shows the median of taken / planned, overall and by kind of step.
- Both ends are read when a plan is published, up to about 3 seconds after the fact. Time spent
  on something other than the first step counts towards it. Once pace and travel speed are
  learned, the planned times already include them, so the log then shows what is left over.
- "The first step of the shown plan" is `plan.order[1]` / `plan.steps[1]` of the plan the Engine
  publishes, whichever way it was made (searched, kept order, the plain route that beat the
  searched one).

**Step-time model** (per character, `LevelScoutCharDB.stepModel`): a correction of planned
times by kind of step, used by the search.

- A step is travel, then what is done at the stop. The model predicts
  log(seconds taken / seconds planned) as a weighted sum of nine features (`Learn.StepFeatures`):
  travel's share of the planned time, and, each weighted by the stop's share: the stop itself;
  kill, collect or use work; elite; log of the group size; mob level minus own level (within 4
  either way); log10 of the planned kills. Elite, group, level and kills describe work only.
- So the model is three kinds of factor, each within 1/2 to 2:
  - `Learn.TravelFactor`: one factor for all travel (what `Travel.DETOUR` would be if fitted);
  - `Learn.TalkFactor`: one for accepting and turning in (`INTERACT_SECONDS`);
  - `Learn.WorkFactor`: one per kind of work (what `ELITE_KILL_FACTOR`, the group speed-up and
    the level-difference scaling would be if fitted).
- Fitted by recursive least squares (`Learn.AddStep`), one finished step at a time:
  - weights start at 0 (no correction) with a prior variance of 0.05 each, so the first steps move
    them only a little;
  - older steps fade by 1% with each new one (about 100 remembered);
  - a single step counts as at most 3 times off, and as taking at most 4 times the planned time;
  - what is known about a weight fades only down to a floor (variance 0.2, `STEP_DOUBT`), so a
    feature that goes unseen for a long time (no elites for ten levels) moves by at most about a
    fifth of the error on the first step when it returns. The floor only makes the model
    surer of the weights it has; it does not pull them back towards "no correction".
- **Used inside the search** (`core/Planner.lua`, `newRoute`): travel between stops (`R:tt`) is
  multiplied by the travel factor, accepting and turning in by the talk factor, and the work at a
  stop (`taskTotals`) by its work factor. Every time the search looks at comes from those, so the
  corrected times decide the order of stops, which quests are dropped as slow, the route's XP per
  hour and the zone ranking. A model that has seen no step is not used. In an itinerary, the
  trip from one zone to the next is multiplied by the travel factor as well (`Zones.Itinerary`).
- A stop shared by several quests counts as its most telling kind of work (killing, else
  collecting, else using), whichever quest was put on it first; the step log records the same
  kind (`workAs`).
- The step log and the model are fitted against the uncorrected planned time (`rawTravel`,
  `rawSeconds` on the step), so the model does not chase its own correction.
- `/ls learn` prints the model as factors: "elite x1.40" means the work at an elite stop takes
  1.4 times the planned time, other things equal. They are the fitted weights as they are; the
  planner holds each combined factor within 1/2 to 2.
- Limits:
  - For a step that is part travel and part work, the planner adds the two corrected parts; the
    model was fitted on the product form. The two agree when the step is all travel or all work,
    and differ by a few percent in between unless the travel and work factors are far apart.
  - Not corrected: the zone-switch overhead (`Zones`), and the choice between drop sources of an
    item (`Model`).
  - Travel is corrected twice over by design: the learned speed goes into the planned travel
    time, and the travel factor is fitted on what is left (detours, stops on the way). A step
    logged before the speed changed was planned with the old speed; such lines fade out of the
    model like any other (about 100 steps).
  - Features that occur together (elite and group size) cannot be told apart from few steps; the
    prior splits the effect between them. The prediction is still right for steps like those seen.
  - With a correction in force the search can settle on a different order than without, as with
    any change of its inputs; `Zones.PreferFresh` still keeps the shown order unless a new one is
    5% better.

Limits and unknowns:

- **Not verified in the game.** Whether `PARTY_KILL` fires for solo kills on this client and
  whether its GUID is readable is the open check in findings.md section 6. If it does not, no drop
  rates are learned and the database rates stay in use; pace learning does not depend on it.
- A kill that is never looted counts as a try without a drop.
- The time between two counts includes everything done in between (other mobs, a short break
  under 240 seconds).
- `Cost.KillsForItems` still plans for the 70th percentile of the learned rate; the uncertainty of
  the learned rate itself is not added.
- The sums behind the per-source correction are taken in a fixed order (`Learn.SourceBias` sorts
  its keys), so the same counts always give the same plan.

## XP bonuses

- **Buffs** (sleeping bag, food, event buffs): read from the game out of combat and applied to
  quest XP and kill XP alike. The sleeping-bag buff (spell 429959, 1% per stack) and the classic
  event buffs are known by id. Any other buff counts when its description says it raises
  experience by a percentage (English client only), which is how food is picked up. In combat
  and in instances the client hides buffs, so the last reading is kept. The game's own reward
  figure for a quest in the log is not raised again.
- **Rested XP** (from an inn or city): the pool the game reports is the XP still to be earned at
  double rate, so half of it is bonus. The plan spends that bonus on kills in route order until
  it runs out; quest rewards do not use it. It re-plans when the pool changes by more than 10%
  of a level at once, appears, or runs dry.
- **Reminders**: before an XP buff ends, one message in chat, one on screen and a line in the
  window's footer: 10 minutes ahead for the sleeping bag, 3 minutes for any other XP buff. They
  work from the last buffs read, so they also fire in combat.
- **Missing buffs**: every XP buff a character has had is remembered. When one is not on, the
  footer says so ("No Hearty Stew (+3% XP)"), and its ending is announced once in chat and on
  screen. The options menu has one switch per XP buff ("Remind: <buff> on/off") that turns off all three
  reminders for it; the buff still counts in the plan. A buff the addon has never recognised
  cannot be missed: `/ls buffs` lists every buff with its id and description, to find out why.
- The window's footer shows "Rested" and "+N% XP" when they apply; the XP-per-hour tooltip names
  the buffs.

## Dungeons

A dungeon run is planned like a zone and ranked with the zones (it shows as "Dungeon" in the
Zones tab). This reverses the original design, which left dungeons out.

- **Which dungeons**: 5-player dungeons with a known entrance and at least one quest: 18 on
  2026-11-13. Raids are left out. Sunken Temple, Blackrock Depths and Spire, Scholomance and
  Dire Maul are missing: their quests could not be matched to a dungeon (shared entrances, or no
  quests confirmed in Forever yet).
- **Which quests**: the ones ForeverDB players confirmed in Forever, plus the ones QuestieDB
  files under the dungeon's area. The two sources are matched by where the entrance is.
- **Prerequisites**: every quest that has to be done first to get a dungeon quest is planned too,
  wherever it is, up to 8 links back.
- **The plan**: lead-up quests, then every dungeon quest accepted, then one "Run <dungeon>" step
  at the entrance for all of them, then the turn-ins. A quest given or turned in inside the
  dungeon is placed at the entrance.
- **Shortlist**: up to 3 dungeons whose level range fits: from a quarter of the way into the
  suggested range (`Zones.DUNGEON_FROM`; 29-38 is offered from 31), or from the highest level
  one of its quests still to do asks for when that is more (`Zones.DungeonFrom`), to 2 above
  its top and that still have quests to do, or that have a quest in your log.
- **Assumptions, not measurements**: a run takes 15 minutes plus 6 per boss (30 minutes to 2
  hours); it has 20 kills plus 12 per boss, each paying an elite's XP at the dungeon's middle
  level shared by five. No time is charged for finding the group. Loot is not valued.
- Inside the dungeon the planner is paused, as in any instance.
- Zone plans still never include dungeon quests, with one exception: a dungeon or raid quest
  that is in the log and complete has only its turn-in left, and that is planned like any other
  turn-in (in the zone where it is, or carried along in an itinerary).
- **Class quests done inside** (`Zones.ClassInside`): a class quest of this class with an
  objective that can only be done in the dungeon (every NPC or object for it stands there and
  nowhere else, `Data.InstanceOf`, from QuestieDB's spawn areas; a dungeon whose door was not
  matched is matched by name for this) is planned with that dungeon, whatever dungeon it is
  filed under, with its lead-up. Done wholly inside, it is a dungeon quest like the others.
  Done only partly inside (`keep`), it is accepted before the run ("for the run; the rest is
  done elsewhere") and kept in the log: no turn-in step, no reward counted, never dropped as
  slow; once its part inside is done, it has nothing more to do there. Example: the paladins'
  The Test of Righteousness (1654) needs lumber from the Deadmines and a hammer from Shadowfang
  Keep: either dungeon's plan takes it in.
- A quest filed as a dungeon quest but with no objectives (a talk, like the first Test of
  Righteousness in Ironforge) is planned like any other quest: nothing of it is done inside.
- A dungeon plan also takes such a finished quest when it is not on the dungeon's own list (a
  follow-up started inside, like Return of the Ring): when its turn-in is on the map of the
  dungeon's door or on the map you stand on, or the quest belongs to the door's zone. Where
  in the route it is turned in is the planner's choice, like any turn-in.

## Class quests (`core/Classes.lua`)

A class quest chain that becomes available is suggested: one line in chat, and a row on the
window's Class tab, whose title glows until the tab is opened. Picked, it is the plan shown
until it is done, then the zones take over again.

- **What a chain is**: quests only some classes can take, this class among them (a classes mask
  that names every class does not count). They are found through the index (`Data.ClassQuests`,
  the mask is read in `Data.BuildIndex`) and grouped by what links them: prerequisites, next in
  chain, breadcrumbs, either-or siblings. A group is one chain, under its lowest quest id. Its
  name is its last quest within reach at your level. Repeatables and seasonal quests are left
  out, and so are quests this character can never take (race, side, a sibling taken, the chain
  done further on).
- **Available**: a quest of the chain is in the log, or can be taken now (level reached, the
  quests before it done, seen by Forever players). `sig` is the list of such quests; it changes
  when the chain moves on, and that makes the chain news again (chat once more, the tab glows).
- **Named** after the last quest of the chain its plan turns in, with that quest's level
  ("[12] Dead-tooth Jack"). A chain with a variant per race (the level 10 warrior quests of
  Stormwind, Ironforge and Darnassus are linked as either-or quests) is named after the variant
  planned.
- **Offered**: when something of it can be planned and the zone's route does not already do one
  of its quests (`Classes.InPlan`). Each offered chain is planned once, again when it moves on,
  when the level changes, or after 5 minutes (`Engine.CHAIN_REPLAN_AGE`); that plan gives the
  tooltip its figures. "Lost against leveling" is the chain's time less the time its XP would
  take at the best zone's XP per hour.
- **The plan** (`Classes.Plan`, `Planner.Plan` with `ctx.chain`): like a dungeon plan, from where
  you stand. The chain's quests and every quest that has to be done first (8 links back) are
  must-dos: placed whatever they pay, never dropped as slow. Nothing else is taken, not even a
  quest whose giver stands at one of the chain's stops, nor one in the log (decided 2026-11-15:
  an extra quest taken at a chain stop could lead away from the chain once accepted); the quests
  left out are not listed. No search: the route is built, improved and put in order as usual. A quest of the chain for a
  higher level waits under "Later"; an elite one is routed or listed as any elite quest is.
- **The Class tab**: the chain followed ("Following"; right-click: back to the leveling plan),
  the chains on offer ("Available", lowest level first, the new ones marked "New" while the tab
  stays open; click: plan it, right-click: don't suggest it again; the tooltip gives where it
  starts, its quests and time, the zones, XP, the leveling time it costs and what needs a group
  or a higher level), and the ones turned off ("Not suggested"; click: suggest it again).
  The tab's title glows (a slow gold pulse and "New") while a chain on offer has not been seen
  there; opening the tab marks them all seen (`Engine.ChainsSeen`).
- **Following it**: the window's title is "Class quest: [level] name", the summary counts the chain's
  quests left. The move-on banner and the itinerary are off. The shown order is kept unless a
  new one is 5% better, as for a zone. The chain is planned before the zones are ranked; on
  the first plan of a session (login, /reload) it is shown at once, in the order saved with the
  character (`chainRoute`), and the zones are ranked behind it. The zone chosen before stays chosen and is where leveling
  goes on ("Then: back to leveling in ...", the best-ranked zone when none was chosen). Picking
  a zone on the Zones tab, or "Back to the leveling plan" in the options menu, leaves the chain.
- **The end**: when the chain's plan has no steps. Chat says why: done, the rest opens at level
  N, the next part is a group quest, or nothing more of it can be planned. Leveling goes on in
  the same job. A quest of the chain that leaves the log and is not done 2 seconds later
  (`C_QuestLog.IsQuestFlaggedCompleted`) was dropped: the chain is left, and offered again.
- **Saved with the character**: `chain` (the chain followed), `chainName`, `chainRoute` (its
  order: { chain, order }), and per chain
  `classChains[id]` = { told (chat said so for this `sig`), seen (the Class tab was open with
  this `sig`), never }.

## How a quest is modelled (`core/Model.lua`)

**Quests started by an item.** A quest that only an item starts (a dropped letter, a head, a deed) has no quest giver. The data's start spots for such a quest are where players happened to start it, so they are not used as a place to accept it: without the item it is listed with "starts from an item" and not planned. The addon looks at the bags (`Game.GetBagItems`, on `BAG_UPDATE_DELAYED`): while an item that starts a quest is there (the game names the quest where it can, otherwise the data does, `Data.QuestsStartedByItem`), the quest is planned with a "Start: <quest>" step where you stand, and the usual value check decides whether it stays. The first time such an item turns up, the chat says so once. The waypoint, the way there and the live distance go with the next step, since there is nowhere to walk for the Start step. Items already in the bags when the addon starts are not announced.


- **Pickup and turn-in**: Forever-observed spots first, then the NPC's or object's spawns. A
  quest with no known turn-in is assumed to end at its giver (marked as a guess).
- **Objectives**: for a quest in the log, remaining counts and finished objectives come from the
  game; the reward too when the client reports it. Otherwise counts come from data, then a
  default per kind (marked as a guess).
  - Kill: at the densest camp of the target, preferring camps near the giver. A quest's later
    objectives prefer the camp its earlier ones are in.
  - Item: the cheapest of its sources (drop, object, vendor). Kills needed for drops are the
    70th percentile for the drop rate. Without a rate, players' typical seconds per item.
  - Object: count x players' typical seconds per object.
  - Event and other: only where Forever players saw it done.
- **XP**: quest XP scaled for the level (classic rule), plus XP from the kills (classic formula,
  doubled while rested).
- **Not confirmed in Forever**: a quest that no ForeverDB player has seen and that has no reward
  in Questie's player traces is not planned until it is in the log (438 quests on 2026-11-13).
  Unless a quest that needs it is confirmed (it is all of that quest's prerequisites, or the
  only one): a follow-up seen in Forever shows the quest before it exists too, followed up to 8
  links (`Model.CONFIRM_DEPTH`). The paladin quest A Second Opinion (78090) is confirmed so by
  Earning Your Salt (78091), which lets its chain be planned to the end.
  QuestieDB carries such quests over from other versions of the game, for example Season of
  Discovery's "Duskwood Mission" quests. They are listed under Quests.
- **Red quests**: a quest 5 or more levels above you (red in the quest log) waits under "Later"
  until it is no longer red, also when it is already in your log. Once complete, its turn-in is
  planned. Exception: a red quest is taken along when at least half of its objectives are in
  camps another planned quest visits anyway (the same mobs, or within 80 yards), unless its own
  targets are 4 or more levels above you.
- **Drops from several kinds of mob**: an item is taken from the kind another planned quest
  already has you killing, so both quests share one stop and one set of kills.
- **Left out of zone plans**: dungeon and raid quests (dungeon quests are planned under their
  dungeon, and a finished one gets its turn-in planned, see above), elite quests when the option is off, quests and mobs for a
  higher level, repeatables and seasonal quests, quests that start from an item, quests with an
  objective no database can locate.

## Files

| Path | Contents |
|---|---|
| `LevelScout/adapters/Merge.lua` | Builds the quest, NPC, object and item records at runtime from QuestieDB and the baked ForeverDB layer (docs/data-format.md) |
| `LevelScout/adapters/Data.lua` | The only reader of the records: getters, eligibility, the zone index, world tables |
| `LevelScout/core/Geo.lua` | Map points to world yards (and back, for a harbour), distance, spawn clustering |
| `LevelScout/core/Cost.lua` | XP scaling, mob XP, kill time, kills for drops, pace |
| `LevelScout/core/Learn.lua` | Online estimates: own pace, travel speed, drop rates (with a correction per data source), step-time model |
| `LevelScout/core/Travel.lua` | Walking, known flight paths, boats and zeppelins: the seconds (`Seconds`) and the legs behind them (`Route`) |
| `LevelScout/core/Model.lua` | One quest as stops and tasks |
| `LevelScout/core/Planner.lua` | The route for one zone |
| `LevelScout/core/Objective.lua` | What the search maximises (the evaluator interface) |
| `LevelScout/core/Search.lua` | The search loop over a zone's route |
| `LevelScout/core/Memory.lua` | Plan memory between re-rankings |
| `LevelScout/core/Zones.lua` | Planning context, shortlist, ranking, move-on, order stability |
| `LevelScout/core/Classes.lua` | Class quest chains: which are available, the plan for one |
| `LevelScout/Engine.lua` | Reads game state, runs the planner in the background, publishes the view |
| `LevelScout/Tracker.lua` | Turns quest-log progress, kills, positions and finished steps into samples for `Learn`; keeps the step log |
| `LevelScout/Guide.lua` | The one waypoint (TomTom arrow, else the game's map pin) and the way to the current step from where the player stands |
| `LevelScout/ui/Format.lua` | Step titles, durations, numbers, the way to the current step in words |
| `LevelScout/ui/Window.lua` | The window |
| `LevelScout/ui/Debug.lua` | The search view: the route on the map, frame by frame |
| `tests/sim.lua` | Plans for an imagined character on the real data and prints the result |
| `tests/bench.lua` | Compares planner settings on eight imagined characters: route worth and CPU time |

## The window

**Inside an instance** the game gives no usable position, so nothing is planned and the waypoint is removed. The last route stays on screen, with "Paused inside an instance · the route goes on outside" above it, and its steps are brought up to date from the quest log on every log change: counts on work steps, "ready to turn in" on turn-ins, and on the dungeon's run step one line per quest ("Kobold Camp Cleanup: 3/10", "done", "not in the log"). Leaving the instance plans again as usual.

`/ls` shows or hides it. So does the round button on the minimap's edge (drag it to move it
around the minimap; the options menu can hide it), and the entry in the minimap addon list.

- **Header**: zone name ("Class quest: [level] name" while a class quest chain is followed);
  options, collapse, close. Drag to move (position is saved).
- **Quest levels**: an accept or turn-in step names its quests with their level in front, as
  the quest log does ("Accept: [12] Wolves Across the Border"): on the rows, the waypoint's
  title, the minimap button's tooltip and `/ls plan` (`Format.QuestName`).
- **Summary**: steps, time and XP of the route; XP per hour on the right.
- **Banner** (only when it applies): starting in another zone is at least 20% better over the
  next two hours (see "Itinerary"); click to switch.
- **Route**: the current step on top with a live distance, then the rest. Quests accepted or
  turned in one after another at the same NPC are one row. Click a step to point
  the arrow at it; right-click to skip its quest. Steps after "Low value from here" are the slow
  tail. Where the current step is and how to get there: see "Getting to the current step".
- **Quests whose giver is in another zone or city** are planned like any other: the trip to
  the giver is part of the route, and the usual value checks decide. A quest worth the trip
  gets its accept step in the route; one that is not is left out as slow (Quests tab).
  - A step outside the zone being planned names its zone in a pale mint green ("In Alterac
    Mountains  ·  ..."), on every such row; on the current row the way there starts with it.
    The zone is the one the step's spot lies in (`Zones.ZoneAt`), not the map the spot was
    recorded on: Forever-observed objective spots can be on the continent map, which made
    camps in Stranglethorn read "In Eastern Kingdoms". Zone maps are rectangles and
    neighbours overlap (the north of Stranglethorn lies inside Westfall's rectangle), so the
    zone being planned and the zone you stand in win when their map contains the spot; only
    then the smallest map that does. In the game this is only the fallback: the game is asked
    first (`C_Map.GetMapInfoAtPosition` on the spot's map, up through parent maps to a zone
    of the data), which knows the real borders.
  - There was a "Get before you go" list: these quests named above the route, not weighed.
    Standing at the giver then moved the quest into the route, where it could be weighed out
    and vanish from both (Ansirem's Key). Removed: a quest is either in the route or left out.
- **Zones**: the zone you are working in is always first. The others follow, best first, with
  XP per hour, a bar, and what leaving now would gain or lose over the next hour ("+12%",
  "-8%"). While you are inside your zone, the other zones are judged as if you left from its
  main hub, so walking around in it does not move their figures. Once you leave it, your real
  position counts. Click a zone to plan it.
- **Quests**: what the route leaves out, by reason. Click a quest to point at its giver; click a
  quest you skipped to bring it back.
  - **Search box** on top: type part of a quest's name to find it among the quests you can
    accept now (`Engine.FindQuests`, `Data.FindQuests`): your side, race and class, not done,
    not in the log, prerequisites done, seen in Forever, not repeatable, and your level: its
    required level, or, where the data has none, not 5 or more levels above you. Case,
    punctuation and spaces do not matter, and a few typos per word are forgiven (1 in words of
    4-6 letters, 2 in longer ones; `core/Find.lua`): the name itself first, then the typed text
    inside it, the whole name with typos, then every typed word at the start of a word of the
    name or within its typos. The index keeps every quest's name, required level, side and
    races (read in its one pass at login), so a search decodes only the best 300 matches
    (`Data.FIND_CHECK`); it takes 10-60 ms and runs 0.15 s after the last key. Up to 12 are
    listed, each with its giver, zone and the size of its chain.
  - Click one (Enter: the best): it becomes the plan with its chain (`Engine.PickQuest`,
    `Classes.ChainOf`: the quests linked to it by prerequisites, follow-ups, next in chain,
    breadcrumbs and either-or siblings, up to 40, through quests this character can take),
    followed like a class quest chain (only its quests) until done: the title reads
    "Quest: [level] name", and the Quests tab shows it on top (right-click: back to leveling).
- **Options**: re-plan, let LevelScout pick the zone, lock, size (4, 7 or 12 rows, or "Custom" after dragging the corner grip; picking it again returns to the presets), scale, reset
  position.

**Getting to the current step** (`Travel:Route`, `Guide.lua`, `ui/Format.lua`): the arrow
shows a direction; the window also says which zone the step is in and, when the planned way
uses a flight path, a boat or a zeppelin, where to board and where to get off.

- **How long a walk is** (`Travel:WalkYards`): the straight line times `DETOUR` (1.25), and for
  a walk of 1,000 yards or more in a straight line (`HUB_WALK_MIN`) also what ForeverDB's walk
  table says, when that is more. The table (`world.travel.hubs` and `world.travel.walk`) has
  the yards on foot along the terrain between pairs of nearby hubs: flight masters, quest hubs
  and transport ends, 291 hubs and 1,225 pairs; far hubs are joined by the shortest chain of
  pairs. A walk from a to b is at least the table's walk between the hub nearest a and the hub
  nearest b, less 1.25 times the two straight lines to those hubs. Where an end has a second
  hub within 1,000 yards (`HUB_SECOND_MAX`), the pair that says least is believed, so a hub
  behind a ridge does not make a walk look long.
  - Why: the straight line made a walk over mountains look short. Stormwind to the door of
    Gnomeregan came out as 652 seconds on foot against 693 by flying to Ironforge, so no
    flight was suggested; the real walk goes round through the Burning Steppes. With the
    table it is 1,765 seconds on foot, and the flight is taken.
  - It only ever makes a walk longer, and changes nothing inside one area (Ironforge to that
    door is the straight line as before). The danger tiers in the table are not used.
  - The walk to a flight master is checked against the table whatever its length. From the
    north of Ironforge, Menethil Harbor's flight master is under 1,000 yards away in a
    straight line and a long way on foot: the way to Hillsbrad came out as "fly Menethil
    Harbor to Southshore". Now it is the Ironforge flight master. (Checking every walk from
    300 yards was tried: it moved enough routes to break five real-data tests, for one case.)
  - `Travel.HUB_WALK = false` gives the straight line everywhere, as before.
  - Not done: the tram and the lifts are still not taken (see below), so Stormwind to
    Ironforge is always the flight.
- `Travel:Route(a, b)` gives the legs behind `Travel:Seconds(a, b)`: the same choice (both use
  `Land` and the same search over the links) and the same total.
  `{ seconds, mode, legs = { { kind = "walk"|"fly"|"boat", from, to, seconds, name, transport } } }`;
  `from` and `to` are `{ name, loc, node }` for a flight point or a harbour, `{ loc }` for the
  two ends. `Seconds` builds no legs and costs what it did before.
  - A flight is one leg from the first flight point to the last, however many points the path
    passes: the flight map takes a click on the far end and flies through the points between.
  - Only flight points the character knows are in the travel object, so an unknown flight is
    never suggested; the "Flight paths unknown" tip is unchanged.
  - Links (boats, zeppelins, ferries, lifts, the tram) can follow one another, with a walk or a
    flight between them, and are used inside a continent too when the way without them takes
    `Travel.MIN_FOR_LINK` seconds or more (`Travel.CHAIN`; off: one crossing between continents).
    The times between the links are worked out once per set of flight points (`hops` in Travel.lua).
  - Land masses (`world.travel.comps`, a grid of land-mass ids per continent): there is no walk
    between two land masses that links of our side join, directly or through a third (the
    mainland, Rut'theran Village and Teldrassil; for the Alliance the mainland and Feathermoon's
    island). `Walk` is `math.huge` there and only flights and links make the trip
    (`Travel.LAND_MASSES`, `T:Apart`). An island nothing goes to is still walked (swum) to.
  - Round the water (`Travel.LAND_PATH`): when the straight line of a walk of up to 4,000 yards
    leaves the land on the land-mass grid, the cheapest way over the grid's 400-yard cells is
    found (A*; a cell of water or a step between two masses costs `Travel.SWIM` = 1.5 times its
    length, swimming being two thirds as fast), less one cell for where the ends are in theirs,
    times `DETOUR`; the walk is at least that. Remembered per pair of cells. In 7,200 sample
    walks in eight coastal zones it made 9% of them longer, by up to 50% (walks across open
    sea); none of the walks along a coast or over a lake changed: the grid is too coarse for those.
  - On foot or mounted (`Travel.New`'s `ride`, `Travel.MOUNT_UP`): the speed on a mount is
    learned apart from the speed on foot (`Learn.RIDE_KEY`; the Tracker's samples say which).
    Once the character has been seen riding, a walk takes the shorter of on foot and 3 seconds
    plus the ride. Not known: where mounts cannot be used (caves, buildings), and that a mount
    comes at a level later in the plan.
  - The Deeprun Tram is a setting (`chardb.tram`, the window's menu): on, off, or auto, which
    takes it only while the flight between Stormwind and Ironforge is not known (`Travel.New`'s `tram`).
  - A boat leg's kind and ends come from the link's name ("Boat between Menethil Harbor and
    Theramore Isle"). A link named otherwise ("Freewind Post lift") has no end names.
  - As before, links are only used between continents (the tram and the lifts are in the data
    but `Seconds` never takes them).
- The way is worked out for the current step, from the player's live position, with the
  travel object of the shown plan. It is not stored in the plan.
- **Flight points to unlock** (`Zones.FlightStops`, shown by the window, not part of the plan):
  a flight point of your side that the character does not know and that the route passes
  close to gets a row of its own in the route, "Flight point: Thelsamar". It is listed when
  the smallest detour anywhere in the route (on foot, the 20 seconds with the flight master
  included) is at most 3 minutes (`Zones.FLIGHT_DETOUR`), at the first place within 30
  seconds of that smallest detour (`FLIGHT_SOON`): a route often passes a flight master
  several times, and the sooner it is unlocked the sooner it is used.
  - A stop before the first step is where the waypoint goes ("New flight point: Thelsamar"),
    and its row is the highlighted one. Once the point is learned the route is planned again
    and the row is gone.
  - Click: point the arrow at it. Right-click: leave it out (`LevelScoutCharDB.skippedNodes`).
  - Nothing is listed while no flight point is known at all (the flight map has not been
    read: every point would look new).
  - Limits: it earns no XP and is not weighed by the planner, so the route's times and XP per
    hour do not include the detour. It is worked out when the route is planned, from where
    you stood then.
- **A row clicked in the window** (`Guide.Show`: a later step, a flight point) gets
  the same treatment: the way to it is worked out with the last plan's travel object, the
  waypoint goes to the flight master or harbour first, and to the step once the ride has
  begun. That row is the highlighted one while the arrow is on it (`Guide.Pointed`), not the
  route's first step. It stays so through
  new plans (a flight, a zone change and quest events all plan again) as long as what was
  clicked is still in the plan: the same flight point, a step with the same title or at the
  same spot, on the same map. Once it is gone (the quest
  was accepted) the arrow and the highlight go back to the route's first step.
  - `Guide.Follow(step, title, travel, keepPointed)`: the Engine names the current step on
    every publish, and says whether the step pointed at by hand is still in the plan.
  - `Guide.Tick()`: once a second (the Engine's frame timer, the one that samples the travel
    speed) the way is worked out again. `Guide.Trip()` is the result, for the window.
- **Waypoint**: when the way has a flight or boat leg, the waypoint points at where the first
  one starts, titled "Flight master: Lakeshire, fly to Darkshire" or "Boat: Menethil Harbor,
  ride to Theramore Isle". Once that leg is behind (the way from the new position is a walk), it
  points at the step, with the step's title. A harbour's map point comes from `Geo.OnMap` (the
  smallest map that contains it).
- **No flicker**:
  - the waypoint is set again only when its place or title changes (`Guide`'s key), so a
    changed time moves nothing;
  - a different way (other flight points, another harbour, no flight any more) is taken up
    only when it has come out twice in a row (`Guide.SETTLE`), so about two seconds after it
    first shows; a new current step is taken up at once;
  - once a flight has begun the waypoint goes to the step itself (the flight master is behind
    you), and nothing is worked out in the air, so the flight points passed underneath are
    not offered. A flight is recognised from the game (`UnitOnTaxi`) or, where that is
    missing, from moving faster than 20 yards per second between two looks
    (`Guide.FLIGHT_SPEED`). On landing the way from there is taken at once;
  - a click on a row points the arrow by hand; it stays there until the next plan is
    published, while the way goes on being worked out for the window.
- **Current row**: a line of its own above the step's detail, only when there is something to
  say:
  - another zone, on foot: "In Duskwood";
  - a flight: "In Duskwood  ·  fly Lakeshire to Darkshire  ·  4 min" (the time is the whole way
    from here); without "In ..." when the step is in the zone you are in;
  - a boat: "In Dustwallow Marsh  ·  boat Menethil Harbor to Theramore Isle  ·  9 min";
    several legs are joined with "then";
  - the step is in the zone you are in and the way is a walk: no line.
  The zone is the map name of the step's location (`Game.MapName`; `Zones.Name` first). The
  line coming or going changes the row's height, so the list is drawn again then (`UI.Tick`);
  a change of words is put in place. A long line is given the room it wraps into, from an
  estimate of the small font's character width (`TRIP_CHAR_W`): not checked in the game.
- **Tooltip** of the current step, under "Travel", when the way is more than a walk: "From
  where you are" with the total, then the legs with their times: "Walk to the flight master in
  Lakeshire (Redridge Mountains)", "Fly Lakeshire to Darkshire", "Walk to the boat in Menethil
  Harbor", "Boat Menethil Harbor to Theramore Isle", "Walk to the step".
- **Later rows**: "In Westfall  ·  " in front of the detail of a step whose zone is not the
  zone of the step before it (worked out when the list is drawn; no flights).
- Limits: the live distance on the current row is still the straight line to the step, not to
  the flight master. The row's time is the planned one (from where the plan was made); the
  trip line's time is from where you stand now. The way is a walk again as soon as walking is
  under four minutes (`MIN_WALK_FOR_FLIGHT`), as in the planner. None of this has been tried in
  the game: that `UnitOnTaxi` exists, that the flight master's map point from the data is where
  he stands, how the harbour pin lands, the height of the row.

**Progress while planning**: a 3-pixel gold bar along the footer's top edge, and in the footer
(in place of "Planning...") what the planner is doing: "Ranking zones: Duskwood (3 of 9)",
"Searching for a better route: round 40 of 120", "Putting stops in their best order",
"Checking the shown route", "Planning the next two hours". Collapsed, the bar sits at the
window's bottom edge without text. It lies over the layout and moves nothing.

- The planner reports through an optional callback (`ctx.progress(stage, done, total, what)`,
  set from `state.progress` in `Zones.Context`); the core files know nothing of the window, and
  plans are the same with and without it.
- `Engine.lua` turns the reports into `view.progress = { fraction, text }`. On a full re-plan
  the bar is shared out as: ranking the zones 75% (equal parts per zone; inside a zone a tenth
  for building, most for the search, the rest for tidying), the check of the shown route 5%,
  the itinerary 20% (`Engine.SHARE_RANK`, `SHARE_CHECK`). Measured on six characters, the
  itinerary took 1% to 40% of the ranking's time and the check under 10%, so the bar can jump
  or pause near the end. A quick re-plan: the shown zone's plan 70%, the check 30%. The
  fraction never goes backwards.
- The zones and the route are shown as soon as the ranking and the check are done; the bar stays
  while the itinerary (and the search view's recording) is worked out in a job of its own, and
  the move-on banner uses the itinerary from before until the new one is in. A new plan job
  stops that job, and it is worked out again afterwards from the newest plan.
- `view.progress` is updated on every report, but the window is told at most every 0.15 s
  (`Engine.PROGRESS_EVERY`, by `Game.Now()`), through `Engine.OnProgress`. That call
  (`UI.Progress`) only sets the bar's width and the footer text: no redraw of the rows.
- It is cleared when the job ends, also when it fails. `Engine.PROGRESS = false` switches it off.

The window uses the game's own look: the tooltip border and background, the quest "!" and "?"
icons and the cursor icons for kill, collect and use, the quest-log highlight, gold titles and
the game's close button. These art files are named by path and have not been checked on the
Forever client: a missing one shows as a solid green square.

**Skipping a quest**: the "Skip" button on the current step, or right-click on any step. An
"Undo" row stays on top of the route for two minutes afterwards. Skipped
quests are listed under Quests ("Skipped by you"); click one to bring it back. A skipped quest
that gets completed anyway has its turn-in planned, and it leaves the skipped list when turned in.

## Search view (debug)

`/ls debug`, or "Search view (debug)" in the options menu, opens a second window that shows how the search arrived at the route (`ui/Debug.lua`).

- **Map**: the route drawn over the zone's map, gold at the start to blue at the end. Stops are coloured by kind (accept, work, turn in). Stops on other maps are not drawn and break the line.
- **Frames**: the route as first built, one frame per search round, then the final route. A round's frame says what was taken out (marked red on the map), and whether the result was a new best, better, slightly worse but kept, or undone.
- **Slider, Play, mouse wheel**: step through the frames. The view opens on the final route.
- **Curve**: what each round's route was worth (grey) and the best so far (gold), with a marker at the shown frame.
- While the view is open, the engine plans the shown zone once more from scratch on every re-plan to record the search. Closing it stops that. Recording does not change the plan.
- Dungeon plans are not searched, so there is nothing to show for them.

Not verified in the game: the map art (`C_Map.GetMapArtLayers` / `GetMapArtLayerTextures`; a plain dark background is used when they are missing), line drawing (`CreateLine`; without it only the stops are drawn), and the slider's look.

## In-game checks

None of this has run in the game. The tests drive the engine and the window against mocked game
calls, which proves the code paths run, not that the client behaves as mocked.

1. Log in. Expect a LevelScout window with a route within a few seconds, and no Lua error.
   If there is an error, paste it.
2. `/ls status` — expect `planner: ready` and `waypoint: tomtom` (or `map` without TomTom).
3. `/ls plan` — paste the output; the first step should be something sensible near you.
4. Check the window: text not cut off or overlapping, rows readable, tabs switch, the mouse
   wheel scrolls, dragging the header moves it, the position survives `/reload`.
5. Accept a quest, make progress, turn one in. The route should update within about 2 seconds
   each time, and the arrow should follow the first step.
6. Flight paths. Until a flight map has been seen, the Zones tab shows a "Flight paths unknown"
   tip, the current step's way line ends with "on foot: flight paths not known yet" when the
   step is in another zone (its tooltip says to open a flight master's map), and chat says so
   once per character. Discovering a new flight point records it on the spot when you stand within 150 yards
   of its flight master (chat: "Learned flight point: <name>"); otherwise the tip asks you to
   open the flight map. This relies on the `UI_INFO_MESSAGE` event carrying the game's
   `ERR_NEWTAXIPATH` text, which is not verified on this client.
   Open a flight master's map. While it is open (no `/ls replan` needed) the route should be
   planned again with the flight points it lists, and when the way to the current step starts
   with a flight, its destination should be marked on that same map, not only on the next
   opening. The points are read when the map opens, again every 0.3 s for as long as it is open
   (`Engine.TAXI_LOOKS`: a point just discovered can be listed a moment late) and once more when
   it closes, from the flight map's own map, the zone's map and the maps above it. New points
   re-plan the shown route at once (`Engine.ReplanNow`: no debounce, and only the shown route,
   however old the ranking: the zones are ranked right after), and its
   way to the current step is taken at once (`Guide.Follow`, `fresh`), without the usual settling.
   `/dump LevelScoutCharDB.knownNodes` should list node ids.
7. Enter a dungeon: the window should say it is paused, and the waypoint should go.
8. Watch the frame rate while it plans (`/ls replan`). It should not hitch.
9. Learning. Solo, on a "kill N" quest, kill four mobs in a row, then `/ls learn`: expect
   "time per kill: N% of players' typical (3 samples)" or close. On a "collect N" quest whose item
   drops from mobs, kill and loot a few, then `/ls learn`: expect a line such as "Boar Hide from
   Boar: 1 in 4 kills". If no such line appears, `PARTY_KILL` is not usable here (see findings.md
   section 6) and drop rates are not being learned.
   After a few finished steps, `/ls learn` should also show "plan accuracy: N steps took X% of
   the planned time (median)"; paste it.
   Run for a minute without stopping, then `/ls learn`: expect "travel speed: N% of the typical
   run speed, X yards per second (5 samples)" or close, near 100% on foot. Take a flight path:
   the sample count must not go up during the flight. `/dump UnitOnTaxi("player")` in the air
   and `/dump IsMounted()` on a mount should both print true.
10. Getting to a far step. With flight points known, pick a zone a flight away (Zones tab). The
   current row should gain a line such as "In Duskwood  ·  fly Lakeshire to Darkshire  ·  4 min",
   the arrow should point at the flight master with the title "Flight master: Lakeshire, fly to
   Darkshire", and after landing (within a few seconds) the arrow should point at the step and
   the line should go or shrink to nothing. The arrow must not jump during the flight. Check
   that the row's text is not cut off.
11. The earlier `/dump` list in findings.md section 6 is still open, in particular
   `GetQuestLogRewardXP`.
12. Class quests. At a level where a class quest opens (10 for most classes), expect one chat
   line ("Class quest [level] X is now available") and the Class tab's title glowing with "New".
   Open the tab: the glow should stop, and the chain's row should show "New"; its tooltip should
   name the giver and the zones. Click it: the title should read "Class quest: [level] X" and the
   route should start with the chain. Abandon a quest of the chain: chat should say
   "You dropped ...", and the leveling route should come back. Check that the tab titles fit
   (four tabs now) and that the glow is visible but not distracting. This relies on `QUEST_REMOVED`
   passing the quest id and on `C_QuestLog.IsQuestFlaggedCompleted`, neither checked on this
   client.
13. Quest search. On the Quests tab, click the box and type part of a quest's name with a typo
   ("missng diplomt"): the list should show it within a moment, with its giver and chain. Typing
   should not stall the game. Enter, or a click, makes it the plan ("Quest: [level] name"). Check
   that Escape clears the box and leaves it, and that keys typed there do not also move the
   character (the box must take the keyboard while it has focus).

### QuestieDB as a runtime dependency

LevelScout now reads quests, NPCs, objects and items from the installed QuestieDB (it used to
ship a copy). After `/reload`, with QuestieDB 1.1.1 enabled:

1. **No error, one line of status.** No Lua error at login. `/ls status` should print
   `data: client build 1.60.1.70938, ForeverDB 0.60.4 (data ..., baked ...); QuestieDB 1.1.1
   (contract 4)` and, a few seconds after login, `index built: 5133 quests, N ms of work over
   M frames (X s)`. Paste that line: N is the real cost of reading QuestieDB in the game (the
   offline estimate is 100–150 ms of work, half a second or so of wall time; the old build took
   about 15 ms). The window should go from "Reading quest data" to a route within a few seconds,
   as before.
2. **Frame rate.** Watch the frame rate for the first seconds after login and during `/ls replan
   fresh`: no hitch (the index yields every 4 ms; the one-off parse of QuestieDB's drop tables
   runs inside it).
3. **Zone ranking.** Zones tab: the zones and dungeons ranked for your level should be the same
   list, in about the same order, as the build before this change showed for the same character
   (the records are the same, so only the timing can differ). Dungeons should list their quests.
4. **Route and quest givers.** Pick two or three steps of the route and check in the world:
   the pickup and turn-in NPCs are where the arrow points and are the right faction's NPCs
   (`/ls quest <id>` prints the starters, finishers and objectives with their count sources).
   For a Horde character, try quest 84395 (Undead Potatoes): its turn-in should be Oran
   Snakewrithe in Undercity, not Jennea Cannon in Stormwind (QuestieDB's faction correction).
   For a class quest, check that only your class's quests appear.
5. **Drop rates.** On a "collect N" step, `/ls quest <id>` lists the drop sources with rates and
   their source (ForeverDB, QuestieDB correction, CMaNGOS, Wowhead): they should be non-empty for
   ordinary mob drops, and the step's time in the route should look plausible for the rate.
6. **Memory.** `/run UpdateAddOnMemoryUsage() print(GetAddOnMemoryUsage("LevelScout"),
   GetAddOnMemoryUsage("QuestieDB"))` after the first plan: LevelScout should be close to what the
   build before this change showed (offline: about 10% more); QuestieDB's number now includes
   what it decoded for LevelScout (offline: 2–3 MB). Paste both numbers.
7. **QuestieDB disabled.** Disable QuestieDB in the AddOns list and log in. The game's addon list
   shows LevelScout as missing a dependency and does not load it (that is the TOC's
   `## Dependencies: QuestieDB`); no Lua error. When LevelScout does load without a usable
   QuestieDB (for example a QuestieDB too old for contract 4), it prints one red line saying
   which version it needs, the window says the same, and `/ls quest 7` answers "data not usable".
   The message for a missing QuestieDB reads
   "QuestieDB is missing. LevelScout reads its quest data from the QuestieDB addon: install or
   enable QuestieDB (https://www.curseforge.com/wow/addons/questiedb), then /reload."
   Re-enable QuestieDB and `/reload`: everything is back.
8. **With Questie too.** If Questie is installed as well, check both still work after a
   `/reload` (LevelScout leaves QuestieDB's caches alone when Questie is loaded).
