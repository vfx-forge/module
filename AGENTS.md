# forge-vfx Agent Guide

Instructions for coding agents working in `pkg/forge-vfx`, the emit module behind the [VFX Forge](https://devforum.roblox.com/t/3867553) Roblox plugin.

Follow this whether you are changing code here directly or preparing a PR. Code that does not match the style below will be sent back.

**Before writing any Luau, read `.agents/skills/forge-luau-style/`.** It is the canonical rule set: `SKILL.md` for the rules and procedure, `reference.md` for the full evidence and worked corrections. This file is the summary; that directory is the authority. Both describe this package only. The parent plugin repo has its own conventions and its own guide, and nothing here is a rule for it.

`.agents/` is deliberately tool-agnostic. If your assistant discovers skills from its own directory, symlink to it rather than copying, e.g. `mkdir -p .claude/skills && ln -s ../../.agents/skills/forge-luau-style .claude/skills/forge-luau-style`. Tool-specific directories are gitignored, so a copy will drift and nobody will see it.

## Layout

| Path | Contents |
|---|---|
| `src/effects/` | One module per effect, every effect there is; each declares its rows and `emit(ctx, attrs, props)` |
| `src/mod/` | Plain-table helper namespaces (`tween`, `lerp`, `logger`, `attributes`) |
| `src/mod/lifetime.luau` | Emit and effect records: `hold`, `defer`, `lock`, `run`, `clear`, `await`, `step`, `wait`, `kill`, `join`, `add`, `include`, `spawn`, `awaitJoin`, `speed`. Each emit and each effect carries a `clock` (`src/mod/clock.luau`); `lifetime.speed(scope, row)` makes an authored Speed row the effect's clock, its track stepped on the clock above so it never scales itself. Effects file resources through `lifetime.hold(scope, x)`, never `table.insert(scope, x)`; a Handle the scheduler returns is filed with the connections, and one with no owner is adopted by the effect. `lifetime.step(scope, fn, phase)` is a step held and owned by the effect, at the effect's depth; `lifetime.wait(scope, seconds)` parks whichever thread of the effect calls it on frame time, does not yield for a length of 0, below 0 or not finite, and never resumes once the effect stops; `lifetime.kill` is what a throwing step's owner gets; an effect waits for its own pieces and child emits through a join: `lifetime.join(scope)` makes one, `lifetime.add(join)` counts one thing in and answers a count-out that works once, `lifetime.include(join, emit)` counts a child emit until it is done by any means, `lifetime.spawn(join, fn, ...)` runs a piece on a thread the effect holds (a throw is logged once and counted out), and `lifetime.awaitJoin(join)` parks until the count is 0, or returns at once when its effect is no longer running. The count is live, so anything counted in while the body waits is waited for; the service's `emitNested`, `emitFromFolder` and `emitOnFinish` take the join as their last argument |
| `src/mod/scheduler.luau` | The one frame loop. Phases `undo wait compute` run at `RenderPriority.First` and `shake screen follow` at `Last + 1` in a running game, all six from one `RenderStepped` connection in the editor; `screen` and `follow` run by depth, shallowest first. `scheduler.add(phase, run, depth?, owner?, survives?)` returns a Handle (`Connected`, `Disconnect`); steps run in the order they were added, one added during a pass runs from the next pass of its bucket. A step that throws is dropped and logged once, and its owner, if it has one, is handed to `scheduler.failed`, which `lifetime` sets to kill it; a step with no owner ends alone. `scheduler.adopt(handle, owner)` gives an ownerless step the owner that holds it, and `lifetime.hold` adopts every step it is handed, so a held `tween.fromParams` tween that throws kills its effect and only an unheld one ends alone. Only a service step kept for the session passes `survives` (the debris physics step, camera shake's undo and shake steps): it stays connected after a throw and warns once. Never pass it for a step an effect or a tween owns. `api.init` starts it and `api.deinit` stops it. Outside it only the ConstantVFX tick in `src/services/enabled_effects.luau` and the ObjectCache recycler keep a clock of their own, until the plans that replace them |
| `src/mod/mods.luau` | Modifier queues. `mods.build` turns a lane map into a Track and returns, second, a function handing the same piece-independent lanes to another piece of the same events (nil when some lane draws or schedules per piece); the reader keeps it per row so one read builds its lanes once for every piece. `mods.track` is the read-and-build behind it, and the only caller left is the mesh's decal, a knob authored on an instance the dispatcher reaches on its own. `legacy_mods` reads the old attribute format and owns every quirk of it (`ALIASES`, `CURVES`, `SPANS`, `DRAWN_RANGES`). A row's stored modifiers are a map from lane name to queue: `start` fires at the emit, `end` at `span - reach(end)`, and every other lane is an event a module declares in `module.events` and fires with `piece:fire(name, elapsed, runFor)`; `runFor`, when the firer knows how long the phase it opens runs, is what an entry on that lane naming no duration runs out instead of the effect time left. `track.reach(lane)` is how long a lane's entries run from its trigger, zero for a lane the row does not hold or one that snaps; never shorten it for a lane that moves nothing, since a phase length (lightning's released bolt) reads it. `track.still(lane, at)` is true when the lane, fired at `at`, leaves the row where it stood then for its whole reach (every entry a chained tween to one literal equal to that value, nothing drawn or waited) and no lane starting after it takes the row (every other lane the row holds has already fired, at or before `at`, and not later in the same frame), and true for a lane the row does not hold; an exit stepper uses it to stop sampling a row, never to change how long the exit runs. A lane's entries play one after another, lanes run together; a stored map replaces only the default lanes it names (an empty named lane silences one, an empty map silences none); `delay` is an entry that waits before what follows; an entry naming no duration runs for the effect time left from where it starts (none on the `end` lane). `mods.build` folds the lanes inside the track; there is no arbitration layer and no second stepper |
| `src/mod/knob.luau`, `src/mod/mod.luau` | Row and default-modifier builders an effect module declares its rows with: `knob(x)` chained `min max aliases options label hint curve unit hidden readonly mod`; a knob's unit is one of `seconds perSecond perSecondSquared studs studsPerSecond studsPerSecondSquared`; `mod.from(a)` / `mod.to(b)` chained `duration curve delay lane`, and `:mod(...)` takes one or more specs, one lane each |
| `src/mod/registry.luau`, `src/mod/reader.luau` | The effect registry (`register get list of scan read source`; `scan(root, claimant)` finds every registered effect plus every legacy tween RayValue no module's row already reads, and drops what the root's own module claims; a Track is called as `track(current, span)` for a piece's own state and clock, or `track(current, span, piece)` when its event lanes fire on that piece's clock; a Track answers `at(elapsed, own, since)`, `has(lane)`, `reach(lane)` and `still(lane, at)`) and the reader that resolves a module's rows into one frozen `attrs, props` pair per emit |
| `src/mod/retime.luau`, `src/mod/resize.luau`, `src/mod/recolor.luau` | One walk over a classified instance's rows by `unit`, editing what each row answers to: retime scales spans and rates, resize lengths, recolor the colour rows. `PROPERTY_UNITS` and `RATIOS` are the two tables they keep for engine properties no row names and for the old ratios |
| `src/mod/clock.luau` | The clock tree every step and wait advances on: `clock.global` (the global speed and pause, times every Global controller), each emit's clock (its handle) under it or under the effect that started it, a controller's region clocks, and each effect's clock (its authored Speed). A clock's factor is its parent's times its `speed` and every `scale`, 0 while `paused`, worked out once a frame and pinned before any change, so a change reaches it and everything below it from the next frame; `clock.refresh(c)` is the one way an owner's own later steps see its change on the same frame. While no clock is off 1 (`clock.uniform`), the scheduler hands each step the frame's delta untouched. `clock.watch` calls back once a frame with a factor that moved; `clock.speedChanged` and `clock.pausedChanged` are the API's `SpeedChanged` and `PausedChanged` signals (vendored GoodSignal, `pkg/GoodSignal.luau`), and `api.setSpeed`, `pause`, `resume` and their getters only read and write `clock.global`; `clock.wall` is real time only a global pause stops; `clock.REAL` is what a step with no owner advances on |
| `src/mod/adapters.luau` | What puts an engine-timed piece under its effect's clock: `particle` (TimeScale up to 1, the emitter's time rows retimed above it), `beam` (TextureSpeed), `sound` (PlaybackSpeed, Pause and Resume), `debris` (launch velocity, a VectorForce for gravity, anchored while paused). Each restores what it wrote when its effect ends. `adapters.create` is the seam a spec stands an Instance in through |
| `src/mod/common/` | Pure helpers with no engine access, requirable under lune |
| `src/obj/` | Class modules with metatables (`Bezier`, `ObjectCache`) |
| `src/services/` | Long-lived services (`effects`, `caches`, `texture_loader`) |
| `src/emitters.luau` | The dispatcher: the reader, the applier and the module's emit for a classified instance; the legacy RayValue remnant for the rest |
| `src/services/effects.luau` | Scans a root through the registry and dispatches every hit at its depth; nothing else selects instances. Every root of an emit is scanned before anything runs, so the clocks a controller (`src/effects/controller.luau`) scales around its parent instance stand before the first effect under it starts; each effect is handed the clock of the region it falls in. The env an emit returns answers `SetSpeed`, `GetSpeed`, `Pause`, `Resume` and `IsPaused` through one shared metatable |
| `src/types.luau` | Shared exported types |

Require via the `.luaurc` aliases (`@mod`, `@obj`, `@vfx`, `@srv`, `@root`, `@pkg`). Do not write relative requires; there is exactly one in the whole tree and it is an outlier.

## Setup

```sh
rokit install --no-trust-check
```

`--no-trust-check` is required because `UpliftGames/wally` is untrusted by default and plain `rokit install` aborts on it. This is the same invocation the plugin repo's release workflow uses.

If `stylua` reports `No such file or directory`, you skipped this step: `rokit.toml` pins StyLua 2.4.0 while the parent plugin repo pins 2.5.2, so the shim will not resolve until the pinned build is fetched. Never work around it by calling a binary out of `~/.rokit/tool-storage/`; that silently formats with the wrong version.

`selene.toml` sets `std = "roblox+luau"`, which needs a generated `roblox.yml`. It is 730 KB of generated API surface, so it is gitignored rather than committed:

```sh
selene generate-roblox-std
```

Run that once after cloning. Without it `selene` cannot resolve the standard library. CI does not need it, because selene is not a gate there yet.

## Always run stylua

```sh
stylua --config-path ./stylua.toml src/
```

Required before every commit. stylua is necessary but not sufficient: it will not sort your requires, remove a header comment, or fix a bare `error()`.

Build with `rojo-build-noalias -o output.rbxm`. The TypeScript surface (`index.d.ts`) is separate: `bun run typecheck`, `bun run lint`.

## Style summary

- **2-space indent.** Enforced by stylua.
- **No `--!strict`.** Most files carry no mode comment at all. `--!native` / `--!optimize 2` only for genuinely hot numeric code.
- **No header comments.** Never open a file with a prose block explaining it.
- **Comment rarely**, only where the code cannot say it itself. Lowercase fragment, no trailing period, labelling the lines beneath. Many files here have zero comments and that is correct.
- **Blank line after every closing `end`.** Separate logical blocks.
- **Annotate every parameter. Leave return types inferred** unless the return is optional, a tuple, or a named type.
- **Guards are three lines.** No one-line `if x then return end`, ever.
- **Nothing on the pass thread yields.** Step bodies, tween animators, `onFinish`, counters, and any cleanup, defer or onCancel reached from them run on the scheduler's pass thread; a yield there leaves the pass open and every frame is skipped until it resumes. Put blocking work in `task.spawn`. `tween.timer`, `lifetime.wait`, `lifetime.await` and `lifetime.awaitJoin` refuse to run there (`scheduler.inPass()`).
- **Errors go through `@mod/logger`**, not bare `error()`. Per-frame hot paths absorb bad input silently instead.
- **Sort interchangeable siblings by identifier length, ascending, within each blank-line group.** Governs requires and flat lists. It does not override semantic order: `scaleStart` still precedes `scaleEnd`.
- **Naming:** `snake_case` files and object internals, `camelCase` locals and functions and config fields, `PascalCase` class modules and exported types and public API fields, `UPPER_CASE` constants.
- **No em or en dashes anywhere**, in code, comments, or docs. This includes ` -- ` used as a prose dash. Rewrite with a comma or a second sentence.
- **A registered effect module declares every value it needs as a row and reads it through `emit(ctx, attrs, props)`; it never calls `attr.get` on its own instance.** Every effect is registered; there is no unconverted effect. The one `mods.track` left reads a knob authored on a decal the dispatcher reaches separately, and no effect ever reads a `_Start`, `_End` or `_Curve` attribute; the old format is `legacy_mods`' business. A module that the ConstantVFX tick may emit declares `constant = true` and reads `ctx.constant`; `ctx.shared` carries the per-emit maps. A module never reads a `_Start`/`_Duration`/`_Curve` quad to play a ramp: the ramp is a default modifier on the row it changes, and a legacy-only input behind it is a hidden row.
- **Effects never call `task.wait`, `task.delay` or `os.clock`, and never connect to or bind a RunService frame signal.** Wait with `lifetime.wait(scope, seconds)`; step with `tween` or `lifetime.step(scope, fn, phase)`. A step that reads where a parent is follows (`lifetime.step(scope, fn, "follow")`, or a tween's last argument set to `scope.depth`); a screen places itself in `"screen"`; everything else computes.
- **A module never multiplies a delta by a speed.** Every step, tween, timer and `lifetime.wait` already advances on the effect's clock. An authored Speed row is `lifetime.speed(scope, row)` right after `EmitDelay` (a module the EmitDuration ConstantVFX tick may emit calls `utility.speedFrom(scope, ref, row)` there instead), and a timer that should end once that speed rests at or below 0 for good returns `nil` when `scope.clock.halted`. A piece the engine times (a particle emitter, a beam's texture, a sound, debris) goes through `@mod/adapters`. A controller's `Scope` and `TimeScale` reach a module only through its clock; a module never reads them.
- **Effects never build a Promise or read `Finished`.** A body waits for its pieces and child emits through `lifetime.join`: count a piece in with `lifetime.add` (or run it with `lifetime.spawn` when it yields), hand the join to `scope.effects.emitNested`/`emitFromFolder`/`emitOnFinish`, and end with `lifetime.awaitJoin`. Name the local for what it counts (`outstanding`, `children`, `clones`), never `pieces`: `piece` is lane machinery. `pkg/Promise` is required only by `src/services/effects.luau`, which builds the public `Finished` when somebody reads it, and `src/types.luau`, which types it.
- **Row ids carry no underscores; old spellings are aliases.** A value that is a Roblox property is a property row. The vocabulary is fixed: module fields `id display classifier components attributes properties layout duration constant emit selected events`; ctx fields `ref obj scope scale effect duration shared constant piece`; never name a new public thing `select`, `claims`, `rest`, `ramp`, `each`, `ownStart`, `span`, `stamp`, `drive`, `track`, `rand`, `priority`, `hold` or `arbiter`. `walk` is not reserved. `lane`, `lanes`, `piece`, `fire`, `fired`, `runs`, `runFor`, `events`, `draw`, `has`, `reach`, `still`, `own` and `since` name the lane machinery in `src/mod/mods.luau` and nothing else; read one as that machinery wherever it appears, and never give one to anything outside it. `PROPERTY_UNITS` and `RATIOS` are the two tables `retime` and `resize` keep for engine properties and old ratios. The clock's names are `clock`, `factor`, `speed`, `paused`, `scale`, `unscale`, `halted`, `uniform`, `watch` and `refresh`; a local that holds an effect's clock is `timeline`. `clock.scale` is a controller's multiplier on a clock and has nothing to do with `ctx.scale`, the size scale.

Where this package and the [Roblox Lua style guide](https://roblox.github.io/lua-style-guide/) disagree, this package wins. The guide is a gap-filler only.

## Files that are not examples

Two files have drifted and are **not** precedent. Do not copy their conventions, however recent they are. Recency is not authority:

- `src/mod/common/path.luau`
- `src/mod/modifiers.luau`

Two more are vendored MIT code by Daniel P H Fox and were never house style:

- `src/mod/color/Oklab.luau`
- `src/mod/color/sRGB.luau`

Those two vendored files are the only ones left carrying `--!strict`, and only because editing vendored code to match house style would fork it from upstream for nothing. Everything else in `src/` and `tests/` has no mode comment at all.

**Everything under `pkg/` is third-party** (`Z`, `tiniest`, `Promise.luau`, `Shake.luau`, `GoodSignal.luau`), some vendored and some a submodule. It is not house style, it is not precedent, and it is not yours to reformat. Never run stylua over `pkg/`, never cite it, and keep local changes out of it so upstream updates stay clean.

**Imitate these instead:** `src/mod/recolor.luau`, `src/effects/shockwave_ring.luau`, `src/obj/ObjectCache.luau`, `src/types.luau`.

## Before you finish

1. `stylua --config-path ./stylua.toml src/`
2. Confirm you added no `--!strict`, no header comment, and no one-line guards.
3. Confirm no em or en dashes, including ` -- ` in prose.
4. Keep the diff focused. Unrelated reformatting makes review harder.
