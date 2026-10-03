# forge-vfx Luau Style: Full Reference

Evidence-backed rule set for `pkg/forge-vfx`. Every count below was measured across the package (52 `.luau` files, ~14k lines). The canonical corpus is `src/` less the drifted and vendored files named in SKILL.md. Where a count below has aged past the tree, the tree wins: re-measure before quoting it back.

## Corpus

**Canonical (read these):** `src/mod/recolor.luau`, `src/effects/*.luau`, `src/obj/*.luau`, `src/services/*.luau`, `src/emitters.luau`, `src/types.luau`, `src/mod/tween.luau`, `src/mod/logger.luau`, `src/mod/attributes.luau`.

**Drifted (do not imitate):** `src/mod/common/path.luau`, `src/mod/modifiers.luau`.

**Vendored, MIT, by Daniel P H Fox (not house style):** `src/mod/color/Oklab.luau`, `src/mod/color/sRGB.luau`. `Oklab.luau` lines 1 to 23 are a verbatim license block.

**Third-party in its entirety (never precedent, never reformatted):** everything under `pkg/`.

**Treat with care (recently modified):** `src/mod/utility.luau`, `src/mod/lerp.luau`, `src/init.luau`.

## 1. Length sorting

**Rule:** within a blank-line-delimited group, sort interchangeable siblings by identifier length, ascending.

Measured across canonical require groups: identifier-length ascending 29/30. Full-line-length ascending only 11/30. The identifier is the key.

Disambiguating case, the local group of `src/effects/shockwave_line.luau`:

```luau
local mod = require("@mod/mod")            -- name 3, line 31
local knob = require("@mod/knob")          -- name 4, line 33
local mods = require("@mod/mods")          -- name 4, line 33
local tween = require("@mod/tween")        -- name 5, line 35
local logger = require("@mod/logger")      -- name 6, line 37
local reader = require("@mod/reader")      -- name 6, line 37
local utility = require("@mod/utility")    -- name 7, line 39
local lifetime = require("@mod/lifetime")  -- name 8, line 41
local registry = require("@mod/registry")  -- name 8, line 41
```

Identifier length alone reproduces the file. Alphabetical predicts `knob` first; line length ties half the block.

Holds for `game:GetService` blocks too (4/4): `RunService` (10) before `CollectionService` (17).

**Applies to string lists**, the class lists at the head of `src/mod/recolor.luau`:

```luau
Color = {
  "Part",             -- 4
  "Union",            -- 5
  "MeshPart",         -- 8

  "SpotLight",        -- 9
  "PointLight",       -- 10
  "SurfaceLight",     -- 12

  "SurfaceAppearance",
},
```

Note the blank lines: sorting restarts per group.

**Does NOT apply generally inside function bodies.** Measured over 23 canonical multi-line local groups: identifier-ascending 15/23, near chance. Semantic pairing overrides length:

```luau
-- src/effects/shockwave_ring.luau, descending by length, and correct: the
-- entry phases stand in the order a piece runs them
local offsetInStart = offsetIn.at(0)
local sizeInStart = sizeIn.at(0)
```

Semantic orders that win over length: Start before End, base/start/end, numbered pairs (`w1`..`w4`), `.Name` first in property blocks, `CanCollide`/`CanQuery`/`CanTouch`, and the order an effect's own phases run.

Where no semantic order exists, length ascending reappears (the row locals at the head of `ring.emit`).

`utility.COPY_PART_PROPERTIES` is alphabetical, not length sorted, and that is correct.

## 2. Blank lines and density

Canonical blank-line density is 23.8%. The two drifted files sit at 15.4%.

**Blank line after every block-closing `end`:** 576 vs 30, about 95%. The 30 exceptions are nearly all `end)` or `end,` closing a call or table argument, a different construct.

```luau
-- src/mod/utility.luau
function utility.lock(ref: Instance)
  if LOCKS[ref] then
    return true
  end

  LOCKS[ref] = coroutine.running()

  return false
end
```

**Group locals into 1 to 3 line semantic clusters.** The row table of `src/effects/shockwave_ring.luau` is the archetype: one cluster per phase, each led by the comment that says why the phase exists.

**Exactly one blank line between top-level functions.** No canonical file uses two consecutive blank lines.

**Blank line before a trailing `return`.** `return <module>` is always the last line.

**Never start a block with a blank line.**

## 3. Requires and imports

Order: `game:GetService` locals, then lowercase local modules, then PascalCase modules. Each group blank-line separated, each internally length-ascending by identifier.

```luau
-- src/effects/shockwave_ring.luau, the head of the file
local CollectionService = game:GetService("CollectionService")

local mod = require("@mod/mod")
local knob = require("@mod/knob")
local mods = require("@mod/mods")
local tween = require("@mod/tween")
local reader = require("@mod/reader")
local utility = require("@mod/utility")
local lifetime = require("@mod/lifetime")
local registry = require("@mod/registry")

local Shockwave = require("@vfx/shockwave")

local Promise = require("@pkg/Promise")
local ObjectCache = require("@obj/ObjectCache")
```

A sibling effect module (`@vfx`) is a group of its own between the two, since it is neither a helper namespace nor a class.

- Group 2: leaf modules returning a plain namespace table (`@mod`, `@root`, `@srv`), lowercase local.
- Group 3: modules returning a class or a third-party package (`@obj`, `@pkg`), PascalCase local matching the file name.
- The local name mirrors the module filename. `@mod/common/flipbook` becomes `flipbook_common`, the `_common` suffix disambiguating against `@obj/Bezier`.
- Aliases are mandatory: 83 `@mod`, 21 `@vfx`, 21 `@root`, 15 `@obj`, 13 `@pkg`, 4 `@srv`, versus exactly one relative require in the whole tree (the `./logger` at the head of `src/mod/attributes.luau`), which is an outlier.
- Mode comments, when present, precede everything.

Known counter-examples: `src/effects/sound.luau` and `src/services/texture_loader.luau` invert the group order. Do not copy them.

## 4. Naming

| Tier | Used for | Examples |
|---|---|---|
| snake_case | file names, module identity, persistent object internals, args carrying module identity | `camera_shake.luau`, `excess_lifetime`, `item_map`, `shared_part_cache`, `part_cache` |
| camelCase | locals, params, functions, transient config fields | `multiplyChannel`, `collisionGroup`, `spreadAngle`, `effectDuration` |
| PascalCase | class modules with metatables, exported types, public API fields, module-level mutable state | `ObjectCache.luau`, `Bezier.luau`, `HitboxConfig`, `Finished`, `Clear`, `local Cache = {}` |
| UPPER_CASE | constants | `RECYCLE_INTERVAL`, `EASE_LUT_SIZE`, `IS_SERVER`, `LOCKS` |

**Corrections to older prose docs:**

- "Table fields: snake_case" is **contradicted**. camelCase leads 23 to 11. snake_case is reserved for long-lived object internals (`ObjectCache.luau`'s `item_map`, `excess_lifetime`); public API fields are PascalCase (`types.luau`).
- "PascalCase.luau for UI components" is **mis-stated**. This package has no UI. PascalCase means a class module with an `__index` metatable.
- "Types: PascalCase for objects, snake_case for other types" **half-holds**. Exported types and named record/config shapes are PascalCase regardless of being plain data (`AttrCache`, `EnabledEffectConfig`). Only tiny private aliases and `scope` stay lowercase.
- "Table functions: camelCase" holds, with one survivor of the old dispatch table: `emitters.legacy_child`, named for the thing it drives rather than for an action. `emitters.applyMods` and `emitters.dispatch` are the rule.

## 5. Control flow

**Lead with early returns.** Never wrap a body in the positive branch.

```luau
-- src/effects/spin.luau
function spin.emit(ctx: reader.Ctx, attrs: any)
  local ref = ctx.ref :: Model
  local scope = ctx.scope

  if lifetime.lock(scope, ref) or spin.static(attrs) then
    return
  end
```

**Guards are always three lines.** `grep -rE 'if .* then .* end$'` over `src/` returns zero hits, and must keep returning zero.

**Guards return bare `return`, or a shared sentinel** for typed returns: `return EMPTY_ENV` (four of them in `src/services/effects.luau`), never a fresh literal.

**Prefer `continue` over nesting** in loops. 17 uses.

**`elseif` chains for type or class dispatch, no `else` fallback.** `resize.luau`'s file local `scaleShape` branches on the module's id and falls through; `retime.luau`'s file local `scaleProperty` branches on `typeof(v)` the same way. Neither has an `else`.

## 6. Error handling

Route through `@mod/logger`. `logger.error` and `logger.warn` account for 11 of 13 raised diagnostics. The only bare `error(` in canonical code is the segment guard in `src/obj/Bezier.luau`, a hot low-level class deliberately kept dependency-free.

Recoverable per-effect failures use `utility.try`, which wraps `xpcall` and warns with a `%s` template:

```luau
-- src/emitters.luau
utility.try(`failed to emit {effect.id} with error: %s`, effect.emit, ctx, attrs, props)
```

**Per-frame hot paths are the exception.** Silently clamping or absorbing bad input is correct there; a `logger.warn` at 240Hz is a log flood. See `tween.luau`'s `math.max(duration, 0.001)`.

## 7. Type annotations

**Annotate every parameter, leave the return inferred.** Measured over 128 canonical single-line function definitions: params annotated 240/251 (96%), explicit return types only 19/128 (15%).

The 15% are exactly the non-obvious cases: optional, tuple, or named type.

```luau
src/effects/sound.luau        local function selectRandomSound(ref: Sound, poolTag: string): Sound?
src/effects/sound.luau        local function createSoundClone(...): (Sound, Part?)
src/mod/common/bezier.luau    function common.findEndAttachments(ref: Attachment): (Attachment?, Attachment?)
src/services/effects.luau     function effects.prepareEmitFolder(...): Folder?
```

Plain-value returns are left inferred (`recolor.luau`'s color math, all of `logger.luau`).

Other habits: generics on attribute accessors (`attr.get<T>`); `typeof(cache)` intersection for class types; casts via `:: any`; `any` accepted at boundaries with a comment.

## 8. Mode comments

Canonical files use exactly four, and most files use none:

- `--!nolint LocalShadow` (5 files, always line 1)
- `--!native` (`shape.luau`, `Bezier.luau`)
- `--!optimize 2` (`shape.luau`, `Bezier.luau`)
- `--!nocheck` (`Bezier.luau`)

**No canonical file uses `--!strict`.** The only occurrences in the tree are the two vendored color files. The drifted files carried it once, which is what marked them; the marker is still the sharpest canonical/drift tell.

## 9. Comments

**Comment rarely.** Five canonical files carry none at all: `types.luau`, `logger.luau`, `ObjectCache.luau` (289 lines), `texture_loader.luau` (175) and `common/flipbook.luau`. The rest run from about 1% to 11%, and the densest are the dispatcher and the shockwave pieces, where every comment says why a phase runs at all rather than what a line does. A comment earns its place by saying what the code cannot.

**No canonical file has a header or module doc comment.**

**Form:** lowercase fragment, no terminal period, labelling the following block.

```luau
src/effects/beam.luau      -- scale the half-offsets and apply from center
src/effects/mesh.luau      -- the oldest assets' inputs, read and never renamed
src/effects/particle.luau  -- the emitter's own property: a stored attribute of the same name shadows it
```

Comments most often act as section labels inside long literals, not as explanations.

Honest caveats: casing is not perfectly consistent (about 10 capitalized instances), and the voice is informal (the asides about engine quirks in `camera_shake.luau` and `screen.luau`). Do not imitate the caps; the informal voice is fine.

## 10. Other checkable habits

1. `-- stylua: ignore` to protect hand-formatted math (`Bezier.luau`, `shape.luau`, `lerp.luau`, `attributes.luau`).
2. Fixed module skeleton: modes, GetService, requires, constants, `local <name> = {}`, module state, functions, `return <name>`. **Exception: modules under `src/mod/common/` name the table `local common = {}`** (`common/bezier.luau`, `common/flipbook.luau`), and callers alias them `<file>_common` (`local flipbook_common = require("@mod/common/flipbook")`). `path.luau` uses `local path = {}` and is aliased plain `path`; that is part of its drift, not the convention.
3. `local rng = Random.new()` sits immediately before the module table (9 files).
4. Module state declared immediately after the module table, never mid-file.
5. Paired `init`/`deinit` on cache-owning effect modules, adjacent, in that order; `deinit` nils the state.
6. Cleanup via `lifetime.hold(scope, <fn|Instance|Connection>)`, never `table.insert(scope, x)`.
7. Backtick interpolation for dynamic strings. `..` concatenation appears once in canonical code.
8. Generalized iteration (`for _, v in t`), never `ipairs`/`pairs`.
9. `vector.create`/`vector.zero`/`vector.one` for defaults; `Vector3.new` for engine writes.
10. `if/then/else` expressions for simple ternaries.
11. Numeric separators in large literals: `table.create(10_000)`.

## 11. Worked corrections

### Blank lines after `end`, and return-type noise

```luau
-- BEFORE (a former schema module, isArray)
local function isArray(t: { [any]: any }): boolean
  local n = 0
  for _ in t do
    n += 1
  end
  return n == #t
end

-- AFTER
local function isArray(t: { [any]: any })
  local n = 0

  for _ in t do
    n += 1
  end

  return n == #t
end
```

### Bare `error`, missing blank lines, single-letter param

```luau
-- BEFORE (a former schema module, Schema.define)
function Schema.define(d: any): Schema
  local ok, why = Schema.validate(d)
  if not ok then
    error(`invalid schema: {why}`, 2)
  end
  return d :: Schema
end

-- AFTER (needs `local logger = require("@mod/logger")`)
function Schema.define(descriptor: any): Schema
  local ok, why = Schema.validate(descriptor)

  if not ok then
    logger.error(`invalid schema: {why}`)
  end

  return descriptor :: Schema
end
```

### Header comment and the ASCII dash surrogate

```luau
-- BEFORE (the head of src/mod/common/path.luau)
--!strict
-- Pure Path2D control-point (de)serialization + curve sampling. No engine
-- access (no `game`/`script`) so this is requirable under lune as well as in
-- Studio -- unlike `@mod/utility`, which does top-level `game:GetService`.
-- ... 8 more lines
local Bezier = require("@obj/Bezier")

-- AFTER
local Bezier = require("@obj/Bezier")
```

The one genuinely non-inferable fact belongs at its use site, not in a header:

```luau
  -- curves are authored in UI space, where Y increases downward
  return 1 - y
```

### Misplaced module state

```luau
-- BEFORE: a cache declared mid-file, after the functions that read it
-- AFTER: immediately after the module table, as src/mod/curve.luau keeps its
-- shape caches
local curve = {}

-- the four presets, decoded once per runtime and never let go
local Presets: { [string]: Shape } = {}

local function solve(shape: Shape, t: number): number
```

## 12. Roblox guide deltas

<https://roblox.github.io/lua-style-guide/> fills gaps. This package wins conflicts.

**Adopt:** one statement per line, no single-line blocks; no semicolons; double-quoted strings; trailing commas in multi-line tables; space after commas and around operators; no trailing whitespace; newline at EOF; no vertical alignment; comments explain why, not what; long `if` conditions get the condition indented with `then` on its own line.

**Reject where conflicting:**

| Roblox | forge-vfx |
|---|---|
| Indent with tabs | 2 spaces (`stylua.toml`) |
| Requires sorted alphabetically | Length-ascending by identifier |
| `ipairs` for lists, `pairs` for dicts | Generalized `for _, v in t` |
| Block-comment module headers | No header comments |
| Private members `_camelCase` | Not used |
| Avoid section divider comments | Used as labels in long literals |
| Lines under 100 columns, comments at 80 | Not enforced; stylua governs |
