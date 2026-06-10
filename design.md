# Mobile RTS — Design Document

## Concept

This is a mobile RTS game in the style of StarCraft or Warcraft, built in Godot. The idea is to have two factions to start with, to keep it simple. Key design elements in this game are going to be the World Editor and the mobile controls.

The Warcraft III world editor is one of the greatest pieces of game software ever developed, and while there's no chance we're going to get anywhere close to as good of a product, one of our goals is to get something that works roughly the same way. Players should be able to build custom units, abilities, scripts, etc and build all sorts of different game modes. This is a critical element of the design, and any maps that we publish should be built inside the world editor. It would be cool to allow a more advanced form of level editing where the user can just use actual Godot to build their level, but that opens up security concerns that we need to be careful about.

The mobile controls are going to be the key standout feature of this game, so it's imperative that we get them correct. I'm envisioning something that feels like a player standing on the bridge of a ship giving commands to their armies below.


## Design Pillars

These are the tests every feature has to pass:

1. **You are the commander.** The player can drop to micro when it matters, but the game is built around giving intent ("hold this choke", "max out gas mining") and trusting your army to execute. If a feature requires APM to be viable, it's wrong for this game.
2. **Touch-native, never ported.** Every interaction is designed for fingers on glass first. No feature ships if it only works with a mouse.
3. **The editor is the game.** All official maps and modes are built in the World Editor. If the editor can't express something we want to ship, the editor gets extended, not bypassed.
4. **Asymmetry over content volume.** Two factions that play genuinely differently beat four factions that are reskins.


## Technical Foundations

Decisions locked in here shape everything else, so they go near the top.

- **Engine:** Godot 4.6, standard build (GDScript, no .NET). Performance-critical sim code can move to GDExtension (C++) later if profiling demands it, but we start pure GDScript.
- **Rendering:** 3D world with a fixed-angle perspective camera (WC3/SC2 style), using Godot's Mobile renderer. 3D gives us smooth zoom/rotate, terrain height, and the "standing on the bridge" feel. Asset pipeline is Blender → glTF.
- **Simulation:** Deterministic lockstep. The sim is a pure, headless GDScript module that advances in fixed ticks and is fed only commands. The 3D scene is a *view* of the sim, never the sim itself. This is what makes multiplayer cheap (commands on the wire, not state), makes replays free, and keeps mobile bandwidth tiny.
- **Orientation:** Landscape. The side control buttons and bottom console assume thumbs on both edges of a horizontally-held phone.
- **Dev loop:** Develop and iterate on Linux desktop with mouse-emulated touch. Export to Android once the control scheme is provable on-device. iOS later.
- **Performance budget (initial targets):** 60 fps render on mid-range Android, sim tick at 20 Hz, ~300 active units per game without dropping ticks. These numbers will move, but every system gets designed against *some* number.

### Determinism rules (the sim's constitution)

Lockstep dies the moment two machines disagree, so the sim follows hard rules:

- No floats in the sim. All sim math is fixed-point (scaled int64). The view layer can use floats freely.
- One seeded, deterministic RNG owned by the sim. Nothing in the sim touches `randf()` or any engine randomness.
- No engine physics, no `_process`-time logic, no node-order dependence inside the sim. The sim is plain objects advanced by `tick()`.
- All iteration over game objects happens in a defined, stable order (by entity id).
- Commands are timestamped to a future tick (2–4 ticks of command latency) and executed identically on all peers.
- Periodic state hashing for desync detection: every N ticks each peer hashes its sim state and peers compare.

### Pathfinding and movement

- Grid-based sim world (the 3D terrain is a visualization of the grid, with height).
- Flow fields for group movement — one field per destination shared by the whole ordered group — with grid A* for small/single-unit orders.
- Local avoidance is deterministic and sim-side (boids-lite steering on fixed point), not engine navigation.


## Controls

The game functions like a computer interface. By default most of it is a viewport of an area of the map, with a few buttons along the side for different actions. Players can select a unit by clicking on it, or grab multiple units by drawing a circle around them. Context-sensitive clicks allow for simple controls:

- Clicking a location on the ground while having a unit selected will give a move order for that unit to that location, and deselect the unit
- Clicking an enemy will make your units attack, and deselect your units
- Clicking a resource will make your units mine that resource, and deselect your units

Notice that in all cases, we work in a clean flow where the player selects with their first action, and orders with their second action. We'll have a reselect button in a corner where the player can hit it to grab the last group of selected units, or a long press will disable the auto-deselect feature.

Two fingers can be used to pan, zoom, and rotate the map. Rotation is tentative. If we allow rotation, I think we need a three-finger click to reset the rotation to default. We might need the three-finger click for something else, so rotation might be cut due to lack of control options.

### Gesture vocabulary

The full gesture set, in one place. Anything not listed here doesn't exist until this table is updated.

| Gesture | Effect |
|---|---|
| Tap unit | Select it (replaces selection) |
| Tap ground / enemy / resource (with selection) | Context order: move / attack / mine, then auto-deselect |
| Draw a circle (lasso) | Select all own units inside |
| Tap empty ground (no selection) | Nothing (prevents misclick orders) |
| Double-tap own unit | Select all units of that type on screen (tentative) |
| Two-finger drag | Pan camera |
| Two-finger pinch | Zoom |
| Two-finger twist | Rotate (tentative, see above) |
| Three-finger tap | Reset rotation to default (tentative / reserved) |
| Long-press reselect button | Toggle auto-deselect off |

Touch ergonomics rules: every tappable button is at least 9mm physical; unit tap targets get a generous radius that scales inversely with zoom (when zoomed way out, taps select the *group* under the finger, not one unit); haptic tick on selection and order confirmation so the player gets feedback without looking at the unit.

### Side buttons

Along the right side of the screen will be control buttons, like move, patrol, attack-move, and stop. We'll place these in a context button where if you just tap it, it will give a move command, but when you hold it, your other movement options pop up in the 4 cardinal directions and you swipe to that button to give that command. Holding either the neutral move or any of the other movement options while giving a command to a group of units will override the context-sensitive click behavior. So for example, I can hold attack-move while clicking on a resource and my units will attack-move to that resource instead of going to it to mine it.

Also along the right side of the screen is a second control button that has unit abilities. Default is attack, then the four cardinal directions can be whatever else. The four slots are populated from the current selection; mixed selections show the abilities of the majority type, with a swipe-down-on-button gesture to cycle subgroups (tentative).

This hold-and-swipe radial pattern (tap = default, hold = 4 options on cardinal directions) is our core button idiom. It gives us 5 commands per thumb-position at the cost of one button of screen space, and it's the same muscle motion everywhere: movement button, ability button, designation button.

### The designation button

The last button along the right side is the designation button. This is how we handle control groups, points of interest, and named targets — and it's critical because of the way it interfaces with the command console below.

A **designation** is a player-created handle on something: a group of units, a map location, or (tentatively) an enemy target. Where a desktop RTS has ctrl+1..9, we have designations, but they're broader — the same system names your control groups, your rally points, your "expansion site Bravo", and your "defend HERE" pin. Designations are what the strategy, tactics, and economy consoles refer to, so the player can say things like "Strike Group A attacks point Bravo" without touching a single unit.

Proposed mechanics (first draft, will iterate in playtesting):

- Tap designation button (with units selected): assign selection to the next free group slot, with a quick flick to choose a slot instead.
- Tap designation button (with nothing selected): hold-and-swipe radial of your designations — swipe to one to select that group or jump the camera to that point.
- Designations appear as labeled chips along the top edge of the screen; tapping a chip selects/centers it. Chips are how the console menus reference them too.
- Creating a *location* designation: long-press on the ground or minimap, choose "designate" from the popup.

Open question: how many designations before the UI drowns? Starting hypothesis: 8 visible chips, unlimited in the organize menu.


## The Command Console

The main UI feature that makes this game work is a menu console that can be slid up from the bottom of the screen, with all the options the player needs. The console is the macro layer: where the viewport is for *doing*, the console is for *commanding*.

One example is the build menu. The player can click on that, and it brings up build options. Clicking on a structure to build will open up the minimap with a list of player-designated locations. The player can select a location to give an order to build there, or can swipe the menu down to return to the main viewport and place their building that way. They can also select a minimap location to close the menu and bring up the viewport while jumping the viewport to that location.

The console tabs (names tentative):

- **Build** — as above. Structures are ordered at designations or hand-placed in the viewport.
- **Strategy** — large-scale orders to designated groups: attack the enemy base, retreat and defend, raid along a path, escort. These compile down to standing orders the units' AI executes and maintains (a "defend Bravo" group re-engages threats near Bravo without re-prompting).
- **Tactics** — adjust your units' AI. Stances (defensive, reckless, skirmish), priorities (focus healing, coordinate fire on one target, kite), and per-type rules within a group — e.g., telling the healer units in Strike Group A to prioritize healing a specific other unit type. Tactics settings persist on the designation, not the individual units, so reinforcements inherit them.
- **Economy** — reallocate resource mining quickly. For the Hive this is literally sliders (nanomachine allocation per stronghold); for the Rebels it's assigning worker counts per resource and approving auto-replacement of lost workers.
- **Organize** — modify how your army and map information are structured: delete a designated point of interest, change the location of your home base, swap units between control groups, rename designations.
- **World** — loads a larger version of the minimap with information and heatmaps overlaid: where our army is losing or winning battles, where resources are almost drained, recent enemy sightings, area control over time.

The idea is that the player should be able to control individual units if they need to, but there should always be a focus on the macro as well as the micro. It should *feel* like you are the commander of an army. You can give specific commands like sending a specific unit to defend a specific location if that's what you have to do, but you can also just give commands like maximizing mining a specific resource and your units should take care of that. This is what allows us to turn the mobile phone into an effective method of control for an RTS game, so this needs to feel right.

Console interaction details:

- The console slides to two detents: half-height (viewport still visible and orderable above it) and full-height (for the World tab and complex menus).
- Console state is preserved per tab — flicking it down and back up returns where you were.
- Anything the console can target (groups, locations) can be expressed through designations, which is why the designation button is load-bearing.


## Economy & Resources

(Names are working names.)

Two map resources, plus a per-faction supply mechanic:

- **Alloy** — the common resource, mined from surface deposits scattered around the map. Plentiful near start locations, contested at expansions.
- **Flux** — the rare resource, extracted from vents that require a structure built on top (refinery/siphon). Gates higher-tier units and abilities, drives expansion pressure.
- Supply is asymmetric: the Hive runs on **Bandwidth** (hivemind control capacity, produced by strongholds and a cheap relay structure), the Rebels on **Crew** (housing structures; their units cost more crew but are individually stronger).

Resource deposits are finite. The World tab's depletion heatmap plus the Economy tab's quick reallocation exist precisely because expanding and re-tasking your economy is meant to be a constant, low-friction decision rather than a chore.


## Factions

### The Hive (working name)

The Hive is a mechanical race of insect-like creatures that evolved as a result of an experiment in a Supreme AI gone wrong on one of the inner planets. Their playstyle will share some notable similarities with the Zerg, but with some key distinctions:

- The Hive can build anywhere on the map, regardless of fog of war conditions, without needing a "worker" unit. When the player commands to build something, a small capsule is dropped that lands at that location and spawns a nest that eventually grows into the building.
- Similarly, the Hive doesn't use workers for resource extraction. They simply have no worker unit. Instead, each stronghold has an amount of nanomachines it controls. Players can allocate them to gather different resources, or dedicate nanomachines to assisting in building structures within their area of control. Similar to the blight in Warcraft 3 used by the undead, the Hive stronghold designates an area under its control. It then mines resources, repairs structures, and speeds construction in that area.
- Structures built outside the area of influence of a stronghold have significantly weakened defenses and do not regenerate health. Building a structure outside the stronghold area also requires sending a nest capsule, which costs resources up-front. Building inside the influence of a stronghold doesn't require the nest capsule, and therefore doesn't have the initial resource cost.
- Players start with one stronghold and nothing else. The stronghold has its own attack.

Faction identity in one line: *be everywhere, trade quality for reach, win by metastasizing faster than the enemy can excise you.*

Sketch of an initial roster (all names/numbers placeholder, to be built in the editor as the editor's first real test):

- **Stronghold** — central structure; control area, nanomachine pool, basic attack.
- **Relay** — cheap structure extending Bandwidth and (slightly) control area.
- **Mite** — cheap, fast melee swarmer; the early-game mass unit.
- **Spitter** — fragile ranged acid unit; good vs structures under construction? No — that's the Rebel niche; good vs armor instead.
- **Lancer** — mid-tier shock unit; burrows toward designated points (synergy with capsule play).
- **Carapace** — slow tank/area-denial unit that can root into a turret.
- **Sovereign node** — late-game structure or unit enabling a second simultaneous capsule drop / global ability. TBD.

### The Rebels (working name)

The Rebels are a hodgepodge bunch of smugglers, crime families, freedom fighters, and pirates that have united under a single banner to fight against the Hive. They fight with a variety of weapons and defenses that are specifically designed to deal with the Hive.

- Generally extended vision around structures and units. Information is the best defense against the Hive's ability to be anywhere.
- They start with one stronghold and a few workers. Workers set up buildings and mine resources by hand. They always start with one offensive unit wielding a gun as well.
- Rebel units are generally stronger than Hive units, although they cost more and require more training/building time.
- Rebel units are especially effective at destroying structures while they are being built. This makes them more effective at taking care of Hive capsules and other base-rush strategies.

Faction identity in one line: *see everything, hit hard, punish the Hive for every inch it tries to take.*

Sketch of an initial roster (placeholder):

- **Headquarters** — main structure; trains workers.
- **Worker** — builds, mines, repairs. Can garrison to defend.
- **Gunner** — the starting infantry; solid all-rounder with bonus damage vs unfinished structures.
- **Watcher** — cheap sensor unit/structure; long sight range, detects capsules in flight (mini-warning ping).
- **Demolisher** — anti-structure specialist; the capsule/expansion killer.
- **Marauder bike** — fast harasser for hunting Hive relays and outlying nests.
- **Broker** — support caster (working theme: dirty tricks — bribes, jamming, smoke). TBD.

Balance philosophy: the Hive applies map-wide pressure and forces the Rebels to spend attention; the Rebels convert vision into efficient defense and punish overextension. The asymmetry mirrors the controls thesis — both factions should be *more* playable with macro commands than with micro.


## Unit AI & Tactics

Because the game promises "give intent, army executes," unit AI is a first-class feature, not a polish item.

- Every unit runs a behavior profile: a stance (defensive / balanced / reckless / skirmish) plus priority rules (focus fire, prefer healing X, avoid melee, hold position).
- Profiles attach to designations. Set Strike Group A to "skirmish, focus fire" once; every unit added to A inherits it.
- Standing orders from the Strategy tab (defend, raid, escort) are maintained by the group: a defending group re-engages, re-positions, and retreats per its stance without re-prompting.
- The bot opponents are built from the same primitives the player's units use — the bot is effectively a player issuing console commands, which keeps bot work and player-AI work the same system.


## Game Modes

- **Quick Match:** each player picks a faction, and you play a game on one of the game's maps. Slots can be filled in with bots or played against other players online.
- **Custom:** play a custom game on a community-built map.

(Future: ranked ladder, co-op vs bots, campaign — see Future Expansion.)


## World Editor

The editor is the second product we're shipping, and the harder one. Architecture decisions here leak into the whole game, so the rule is: **the game's own content is data, and the editor edits that data.** If official maps need code the editor can't produce, we've failed the pillar.

### What a map is

A map is a self-contained bundle (folder, zipped for distribution) containing:

- **Terrain** — heightmap, texture/biome painting, cliffs, water, pathing blockers.
- **Objects** — placed units, structures, resources, doodads, regions, and start locations.
- **Catalog overrides** — the WC3-style object editor: every unit/ability/structure in the game is defined in a data catalog (stats, costs, ability lists, model references). Maps can override any field and define new entries derived from existing ones. This is how custom units and abilities work — data, not code.
- **Triggers** — event / condition / action scripts (see below).
- **Custom assets** — models, textures, sounds, with format and size constraints.
- **Manifest** — name, author, version, player slots, game-mode metadata, content hash.

The sim consumes catalogs + triggers; nothing in a map bundle is engine-executable code. That's the security model.

### Triggers and scripting

WC3's GUI trigger editor (events, conditions, actions) is the model:

- Triggers are stored as data (a tree of typed nodes), edited in a touch/desktop-friendly GUI.
- They execute on a small interpreter that lives *inside the sim* (so triggers are deterministic and lockstep-safe) and can only call the sim's command API — spawn unit, modify catalog value, move region, display text, etc. No filesystem, no network, no engine access.
- A text form of the same language for power users ("custom script" blocks), which compiles to the same node tree. This is our JASS analog, and it stays small.
- Letting users build levels in actual Godot remains an idea for a trusted/advanced tier, but it's explicitly out of scope until we have an answer to "how do we run someone else's GDScript safely" (we may never).

### Editor product notes

- The editor is built in Godot as part of this project and ships with the game; desktop and mobile should both be viable methods of editing maps. In-progress maps are saved in the cloud, so a player can pull up a map on any device at any time to pick up where they left off.
- All official maps are made in it (pillar #3), which forces us to feel its pain immediately.
- Map sharing: start with file export/import; an in-game browser with moderation comes later and is its own project.


## Multiplayer & Netcode

Deterministic lockstep, as established in Technical Foundations. Specifics:

- **Topology:** peer-to-peer with a lightweight relay for NAT traversal, or a thin dedicated relay server — either way the server never simulates, it just orders and forwards command packets.
- **Tick model:** sim at 20 Hz; player commands are scheduled 2–4 ticks ahead. Render interpolates between sim states so the view stays smooth regardless.
- **Mobile realities:** connections drop constantly on phones. Design for it from day one: aggressive reconnect with command replay, a pause-and-wait window, and bot takeover for abandoned slots.
- **Desync handling:** periodic state hashes; on mismatch, dump divergence diagnostics (this is a dev tool first, a shipping feature second).
- **Replays:** free with lockstep — a replay is the seed plus the command stream. Save them always; they're also our bug-report format.
- **Cheating:** lockstep exposes full state to clients, so maphacks are possible in theory. Accepted risk at our scale; fog-of-war stays sim-enforced so casual cheating isn't trivial.

Single-player vs bots uses the identical command pipeline (a bot is a command source, the local human is another), so netcode and game logic never fork.


## Plot and Setting

I think I should borrow the setting from my project redline game. To give a short recap here, there is a solar system where the ruling power is a borg-style hivemind, aesthetically modeled to look like bugs. Many planetary systems have formed an arrangement where the inhabitants live and fight for this hivemind empire in exchange for not being assimilated. Some of these societies are extremely loyal to the hive, while others have more complicated feelings about the agreement. The hivemind is the first playable faction in the game. TBD on the official name for them, for now we'll call them the Hive.

A few of the outer planets remain independent, and rebel guerrilla organizations exist in many of the interior planets as well. The largest of these organizations will be the second major faction in the game. They are a ragtag mix of freedom fighters, crime families, and general miscreants. Again, no name for them yet. I guess they are just the Rebels for now.

Some ideas for future factions that could be added:

- Any of the outer planetary systems could be a unified society and viable faction
- Similarly, we could use an inner planetary system that has a very close relationship with the hive but is technically a free society
- An idea I kinda like is if a huge spaceship is parked just outside of the solar system, carrying an alien society. Their technology is strange, their motives are mysterious, and they are interested in establishing themselves in this system.


## Art & Audio Direction

Early, but the constraints are known:

- **Readability beats fidelity.** Units are viewed at thumbnail size on a phone. Strong silhouettes, saturated faction colors (Hive: iridescent black/green; Rebels: rust, canvas, mismatched salvage), minimal visual noise on the ground plane.
- Stylized low-poly 3D out of Blender (already in the toolchain); flat or simply-ramped shading keeps the Mobile renderer happy and the art achievable by a tiny team.
- Animation budget is small: favor designs that read with few frames — Hive units skitter and pulse, Rebel units are chunky and mechanical.
- Audio: orders and events need distinct, short confirmations (you're often not looking where the sound happened). Commander-on-the-bridge fantasy says radio-chatter acknowledgments for the Rebels and unsettling synthetic chitters for the Hive.


## Roadmap

Build order chosen so the riskiest theses (controls, deterministic sim) get proven first:

- **M0 — Scaffold.** Godot project, repo conventions, sim/view split skeleton, camera rig, CI sanity. *(in progress)*
- **M1 — Control prototype.** Selection (tap + lasso), context orders, hold-and-swipe radial buttons, reselect, camera gestures — against dumb stationary units on a flat plane. Goal: the controls demo feels good in the hand. **This milestone is the go/no-go for the whole concept.**
- **M2 — Sim core.** Fixed-point math, deterministic RNG, entities, grid, flow-field movement, combat resolution, command queue, state hashing, headless determinism tests (same seed + commands twice → identical hashes).
- **M3 — One faction playable.** Hive vs target dummies: strongholds, capsules, nanomachine economy, 4–5 units, the Build and Economy console tabs.
- **M4 — Two factions + bots.** Rebel roster, supply, a competent scripted bot, win/loss. First full game loop.
- **M5 — Editor MVP.** Terrain editing, object placement, catalog overrides, trigger GUI v1. Rebuild our own test map in it (pillar #3 check).
- **M6 — Multiplayer.** Lockstep over the network, reconnect, replays. Android export hardening.
- **M7 — Polish & content.** 3–4 real maps (made in the editor), tactics/strategy tabs full version, art pass, sound pass.

Each milestone ends with something playable on a phone, even if ugly.


## Future Expansion Ideas

- Generals (like Warcraft III heroes)
- Added factions
- Campaign: one full campaign per faction
- Ranked ladder and matchmaking
- In-game map browser with ratings/moderation
- Co-op vs AI modes (editor-built, naturally)


## Open Questions

Tracked here so they don't silently become decisions:

1. **Map rotation** — keep two-finger twist, or cut it and free up the three-finger gesture? Decide during M1 playtesting.
2. **Faction names** — "Hive" and "Rebels" are placeholders; naming pass once the setting doc from project redline is consolidated.
3. **Designation count/UX** — does 8 chips survive contact with a real game?
4. **Resource names** — "Alloy"/"Flux" are working names.
5. **Mixed-selection ability button** — majority type vs subgroup cycling needs prototyping.
6. **Trigger script surface** — how big does the custom-script language need to be before the editor can build a tower defense? (Good litmus test for editor completeness.)
7. **Trusted Godot-native maps** — viable tier or permanently out of scope?
8. **Monetization/distribution** — undecided, but money can never be used to buy an in-game advantage.
