# Writing a custom effect (sdk 1)

A custom effect is a ModuleScript tagged `VFXForgeEffect`, anywhere in the place. The game registers every tagged module when ForgeVFX initializes, and one tagged later as it is tagged. The plugin registers the same modules in its own copy, so a custom effect shows in the panel and previews like a built-in, and it reloads the module while you edit it.

`sample.luau` beside this guide is a complete effect. The types are in `ReplicatedStorage.VFXForge.Effects.SDK`, which the plugin writes when you create a custom effect, and the plugin puts the new effect beside it in `ReplicatedStorage.VFXForge.Effects`. That module holds types only: requiring it answers nil, so an effect requires it for its types (`SDK.V1`, `SDK.Ctx`) and reaches the sdk through the `sdk` argument each function is handed.

## The module

The module returns a plain table:

```luau
local effect = {}

effect.sdk_version = 1
effect.id = "my_effect"
effect.display = { name = "My Effect" }
effect.classifier = "BasePart.MyEffect"

function effect.params(sdk)
  return {
    attributes = {
      FadeTime = sdk.knob(0.5):min(0):unit("seconds"),
      FadeCurve = sdk.knob("easeOut"):curve("easeOut"),
    },
  }
end

function effect.emit(sdk, ctx, attrs, props)
  local transparency = sdk.getWriter(ctx, ctx.ref, "Transparency")

  sdk.tween(ctx, sdk.curve(attrs.FadeTime, attrs.FadeCurve), function(alpha)
    transparency:set(alpha)
  end)
end

return effect
```

- `sdk_version` is read first. A module without one is refused, and so is one asking for a version newer than the plugin or emit module you run.
- `id` is a name of letters, digits and underscores, unique across every effect. A built-in's id is refused. When two modules claim one id, the first registered keeps it and the other is refused, with both named.
- `display` takes `name`, an optional `icon` and an optional `category`. The category groups the effect with the built-ins of that kind in the plugin's adder: one of `emitters`, `meshes`, `paths`, `shockwaves`, `camera` or `motion`, and any other value is refused. An effect with no category is listed under Custom.
- `display.reflect` is `"all"` or a list of property names, as in `{ "Color", "Texture" }`. The panel mirrors those engine properties of the instance the way it does for a built-in: each is edited on the instance itself, with no row, no stored value and nothing read on an emit, and each can carry modifiers that play from the emit. Your own property rows are always mirrored, whether or not `reflect` names them, and each shows once, as that mirrored row: editing it edits the row's value, and a modifier on a row declared with `:mod()` reaches the row rather than playing on its own. Leave `reflect` out to mirror your property rows alone.
- `classifier` is a selector. Every alternative in it names a class and a tag of its own, as in `BasePart.MyEffect`, so no instance can be yours and another effect's at once. Tag the instances that play it with that tag. An instance carrying it is yours even where a built-in's classifier matches it too, as screen's matches any part with `Enabled` set. A classifier may name a class a built-in plays, as in `ParticleEmitter.MyEffect`: an instance carrying your tag is your effect's alone and the built-in never touches it, so your effect plays it itself (for an emitter, its own `Emit` calls), and modifiers or old tween children a built-in left on it play nothing, save the modifiers on a property it reflects. A classifier that shares a tag with another effect is refused. So is `Instance` or `PVInstance`, which is too broad to tell your instances apart; name a concrete class such as `BasePart`.
- Optional fields: `components` (a selector for descendants the effect plays itself), `layout` (the panel's rows), `constant` (an Enabled loop may emit it), `params`, `duration`, `unload` and `template` (see Templates).
- Any other field is refused, so a typo like `clasifier` is caught.
- The module table, `display`, `layout`, the table `params` answers and its `attributes` and `properties` are read once, when the module loads, and kept as plain copies. Give them no metatable: one on any of them, or on a param's modifier list, is refused. Make every param with `sdk.knob`, and never freeze a knob table yourself. `unload` must be a function of your own, not an engine function such as `print`.

Every method takes `sdk` first. Never require ForgeVFX from a custom effect.

`ctx` is a frozen table of three fields: `ref`, the instance being emitted; `duration`, the effect's length in seconds; and `constant`, true when an Enabled loop emitted it. Hand the sdk the very `ctx` your emit or rule was given. A copy of it, or any other table, is refused.

## Params

`params(sdk)` is called once each time the module loads and answers `attributes` and `properties`, tables of knobs by name. A knob declared with `:curve(preset)` is a curve param, edited in the curve editor; its value goes straight into `sdk.curve`. A knob declared with `:mod()` can be animated by modifiers and is read as a Track: `track.value` is the param's own value, the one the panel holds, which its modifiers run from or to; `track.animated` is false when no modifier moves it, `track.duration` is how long its modifiers run when `animated` is true (ignore it when `animated` is false), and `track:at(t)` is its value `t` seconds in. Call it with a colon; `track.at(t)` is refused. `sdk.speed` takes a Track; `sdk.apply` takes any param. `attrs` and `props` are read only.

Walk `attrs` and `props` with `for name, value in attrs`, never `pairs`, which sees nothing on them. Never copy them: a copy made with `table.clone` refuses every read. In a rule or in `duration`, read a row by name, since a walk there sees only the rows read so far. A param declared with `:mod()` that `duration` reads is not kept, so a walk in `duration` never finds it, and its `:at(t)` there is not the one `emit` sees: read its `value`.

A knob's default is a number, boolean, string, NumberRange, Vector2, Vector3, UDim, UDim2, Color3, NumberSequence or ColorSequence, or a curve (a row may also hold an Instance, declared as below); a knob under `properties` may also default to an EnumItem. A default of any other type is refused, naming the param, since the panel has no editor for it.

A knob declared `sdk.knob():instance(classes?)` holds an instance the artist picks. An Instance is never a default: `sdk.knob(part)` is refused, and so is a rule default on an `:instance()` row. The row has no default, so a row never picked reads as nil. It also reads nil when its target was destroyed or has left the place, when the target is of a class not in `classes`, and while the row's `readonly` rule holds. The value is read once per emit: a target that streams in is seen from the next emit, and an effect that follows its target through an emit checks the target's `Parent` itself. `classes` is an optional list of class names the row takes, matched with `IsA` so `"BasePart"` takes any part; leave it out to take any instance. It is declared under `attributes`, since an instance is held by an attribute; one under `properties` is refused. It takes `:label`, `:hint`, `:hidden` and `:readonly`, and `:min`, `:max`, `:options`, `:slider`, `:seed`, `:unit`, `:curve` and `:mod` on it are refused.

```luau
Target = sdk.knob():instance({ "BasePart", "Attachment" }):label("Follow")
```

A number knob declared with `:slider()` is drawn as a slider dragged between its `:min` and `:max`, or between the two numbers it is handed, as in `:slider(0, 10)`; a typed value still clamps to `:min` and `:max`. A slider on a knob that is not a number, or with no range to drag over, is refused.

A number knob declared with `:seed()` is drawn as a seed: a field and a reroll button beside it that picks another whole number. Any number is a seed, so the field takes whatever is typed, within the knob's `:min` and `:max` when it has them, and the reroll stays inside them too. A seed on a knob that is not a number, or that is also a slider, a curve or animated with `:mod()`, is refused.

A knob's default can be a function instead of a value. It is a rule, and it answers the default from the other params when the module is read.

### Rules

Where a knob method takes a function (`hidden`, `readonly`) and where a modifier's `duration`, `curve` and `delay` do, the function is a rule called as `rule(ctx, attrs, props)`: the emit's `ctx`, then the attributes and properties read so far. A rule that runs while `duration` is still deciding the effect's length sees `ctx.duration` as nil. `hidden(rule)` hides the row in the panel while the rule answers `true`. `readonly(rule)` makes the row read as its default while the rule answers `true`.

### Default modifiers

`:mod(...)` marks a knob as animated and takes zero or more specs, which are the modifiers the row starts with. A spec comes from `sdk.mod.from(value)`, which runs from `value` to the row's own value, or `sdk.mod.to(value)`, which runs from the row's own value to `value`. Chain `:duration(seconds)`, `:curve(shape)` and `:delay(seconds)` on it, each a literal or a rule, and `:lane(name)`, which is `"start"` (the default, at the emit) or `"end"` (so that it finishes with the effect). A knob takes more than one spec when its phases run in different lanes:

```luau
Opacity = sdk.knob(1):mod(
  sdk.mod.from(0):duration(0.2),
  sdk.mod.to(0):lane("end"):duration(0.3)
)
```

A modifier whose end already equals the row's value does nothing, and a row nothing animates reads as a Track with `animated` false.

## Layout, components and constant

`layout` lists what the panel shows, in order. An entry is a row name (a string naming one of your params), or a group, `{ title = "Pulse", entries = { ... } }`, which holds more entries and may take a `hidden` rule. Every name must be a param, or the module is refused. A layout may not use the same table twice or nest more than eight tables deep.

`components` is a selector for descendants of the instance that this effect plays itself. Anything it matches below an instance of this effect is not played as an effect of its own. Leave it out when the effect owns no descendants.

`constant = true` lets an instance play the effect on a loop, which is what the ConstantVFX tag and an `EmitDuration` window do. Such an emit has `ctx.constant` set to `true`, so `emit` can tell a tick of the loop from a single play. A module without `constant` is never looped.

An effect opens an `EmitDuration` window of its own with `sdk.window(ctx, seconds)`: it plays the loop for `seconds` of the effect's time, a tick as it opens and one every `1 / Rate` seconds after (the `Rate` attribute, 5 a second when there is none), each with `ctx.constant` true, and returns once the last tick has ended. Call it from a single emit only, as `if attrs.EmitDuration > 0 and not ctx.constant then sdk.window(ctx, attrs.EmitDuration) return end`, and add `EmitDuration` to `duration`. It refuses a module without `constant = true`, and a call from a tick, which would open a window on every tick after.

`duration(sdk, attrs, props)` answers the effect's length in seconds, which `ctx.duration` carries into `emit`. It is optional and reads as 1 when missing.

## Templates

`template(sdk)` makes a new instance of the effect for VFX Forge's adder, the popup its keybind opens. It answers one new Instance that your classifier finds, built however you like: its class, its tags, its attributes and its children. Leave it unparented. The adder parents it to the first selected instance, or to the workspace when nothing is selected, places it 5 studs in front of the camera and selects it. The game never calls `template`.

```luau
function effect.template(sdk)
  local part = Instance.new("Part")

  part.Anchored = true
  part.Size = Vector3.new(2, 2, 2)
  part:AddTag("MyEffect")

  return part
end
```

When the classifier's first alternative is a class followed by tags, as `BasePart.MyEffect`, and a selected instance is of that class, the adder adds the tags to it instead of making one, whether or not there is a template. Otherwise the adder calls your template. Without one, it makes an instance itself only for such a classifier: a Part for `BasePart`, an instance of the class for any other, carrying every tag. A class Studio cannot make is reported, and nothing is made. A classifier with more than that (a name, an attribute filter, a pseudo class such as `:has(...)`, or a parent in front of the subject) cannot be made that way, so give such an effect a template.

The adder runs the template inside one undo step and gives it five seconds to return. If it throws, runs out of time, or answers anything but an Instance, the step is undone, so whatever it made is gone, and the error is shown. If the instance is not one your classifier finds, the adder keeps it and says so. The instance may not be or hold a script (a Script, LocalScript or ModuleScript): the adder refuses it and makes nothing.

## Time

All time is effect time: scaled by the effect's speed and stopped while it is paused.

- `sdk.wait(ctx, seconds)` waits.
- `sdk.step(ctx, fn, pass)` calls `fn(dt, elapsed)` every frame while the effect runs, and answers a function that stops it. `pass` is `"early"` (the default) or `"late"`. A late step runs after the camera has moved and shaken, so use it for anything placed against the camera. A step is still called while the effect is paused, with `dt` 0.
- `sdk.apply(ctx, row, write)` calls `write` with a param's value at once, and again every frame while its modifiers move it. A param without `:mod()` is written once. While modifiers move the param, the effect runs until they finish, as it does for a tween.
- `sdk.speed(ctx, track)` runs the effect's clock at a `:mod()` param's value, following its modifiers as they move it: at 2 every step, tween, wait, applied param and nested emit of the effect plays twice as fast, and a value below 0 counts as 0. The param's own modifiers run at the speed the effect would have without it, so it never speeds itself up; the global speed and a pause still apply to them. Once it comes to rest at 0, tweens end where they stand and a pending `sdk.wait` ends the effect, so nothing after it runs.
- `sdk.curve(duration, shape)` is a curve over `duration` seconds. `shape` is a preset (`linear`, `easeIn`, `easeOut`, `easeInOut`), a curve param's value, a chain of vectors or a function of time. `curve:at(t)` answers its value for `t` from 0 to 1.
- `sdk.tween(ctx, curve, fn)` plays a curve, calling `fn(alpha)` once at the start and then once a frame.

An effect lasts until `emit` returns and everything it started has finished: its tweens, the params it applies, its nested emits and every piece of every join. A step does not keep an effect alive; wait for as long as it should run.

## Pieces, nested emits and cleanup

- `sdk.join(ctx)`, `sdk.spawn(join, fn, ...)` and `sdk.await(join)` run pieces on threads of their own.
- `sdk.emit(ctx, instance)` plays an instance as a nested effect of this one.
- `sdk.hold(ctx, thing)` cleans up an instance, connection, function or thread when the effect ends.

`sdk.wait` and `sdk.await` yield, so they cannot run inside a step or a tween's callback.

A function you hand the sdk to call later (to `sdk.step`, `sdk.tween`, `sdk.apply`, `sdk.spawn` or `sdk.hold`, or as a curve's shape) must be one you wrote. An engine function such as `print` or a service's method is refused, since the sdk would call it with VFX Forge's rights in Studio; wrap the call in a function of your own.

A descendant of `ctx.ref` that you `sdk.emit` must also be matched by `components`. An emit that reaches your instance scans its descendants and plays every effect instance it finds there except what `components` matches, so a descendant left out of it plays twice: once from that scan and once from your `sdk.emit`. Never `sdk.emit` the instance itself or one of its ancestors: the nested emit finds your instance again and plays this effect inside itself, which calls `sdk.emit` again, without end.

## Writing to instances

`sdk.getWriter(ctx, obj, property)` and `sdk.getAttributeWriter(ctx, obj, name)` answer a writer with `:set(value)`. Writers hand a target over between overlapping emits by priority and put the authored value back when the last one ends. Write through a writer rather than to the instance.

`sdk.lock(ctx)`, called in `emit`, plays this emit alone on `ctx.ref`. An emit that reaches the instance while this one plays ends at its own `sdk.lock`, silently, though the panel's modifiers on a reflected property have already started for it, since they start before `emit` runs. Call it first in `emit`, before anything is read or written; a step, a tween's callback or a piece may not call it, and a second call by the emit that holds the lock does nothing.

`sdk.guiRoot(ctx)` answers the one Folder every GUI an effect makes goes in: under StarterGui in Studio's editor and under the local player's PlayerGui on a client. It is not archivable, it is made on first use, and it is refused on the server. See Where created instances go.

## Math

`sdk.lerp(a, b, t)` blends any value ForgeVFX blends. `sdk.color` blends colors in Oklab. `sdk.shape.box`, `cylinder`, `sphere` and `disc` answer a random point. `sdk.bezier.new(points)` is a path with `:at(t)`, `:atUniform(u)`, `:length()` and `:tangent(t)`; `:set(points)` moves it, and only the segments that moved are measured again.

Curve and bezier points are a chain: an anchor, its outgoing handle, the next anchor's incoming handle, the next anchor, and so on, 3n + 1 points; two points are a straight line.

## Hosts that run their own watcher

The game's discovery starts in `ForgeVFX.init`. A host that registers and reloads custom effects itself, as the plugin does, calls `ForgeVFX.init({ discover = false })` so the two never register one module twice.

## Errors

A module that fails to load, throws in `params` or breaks a rule is refused with every reason named, and in the plugin the version before it stays registered. An `emit`, step, tween callback, `sdk.apply` write or piece that throws is warned about once per instance, and its effect ends and lets go of what it held.

To say an effect cannot play, call `error(text)`: it is reported once per instance and the effect ends. To say something went wrong that the effect recovers from, call `sdk.warn(ctx, text)`: it is logged once per instance and text, and the effect plays on. Give `sdk.warn` a fixed sentence with no changing number in it, since every distinct text is logged and kept.

## Where it runs

`sdk.context()` answers `"edit"` in Studio's editor, and `"client"` or `"server"` in a running game.

## Production rules

A shipped effect follows these.

- **Params.** Put `EmitDelay` in an Emit group. The runtime does not wait `EmitDelay` for a custom effect: wait it yourself with `sdk.wait(ctx, attrs.EmitDelay)` after `sdk.lock` and add it to `duration`, as the sample does. Add no `Speed` row. Let the group title carry the noun and keep a row label to one word with no spaces: a group `Wobble` with rows `Amount` and `Speed`, never a row labelled `Wobble Speed`. Show about twelve rows at most. Give every seconds, studs and rate row a `:unit()`, every duration `:min(0)`, every transparency `:max(1)` and every scale a floor. Use `:mod()` for what an artist animates and plain values for structure. Hide a row that only matters under another behind it. Name no attribute row after a property the instance has. Write hints that say what changes on screen and a useful range, never an engine property path. Keep implementation tuning a local constant, not a row.
- **Row shapes.** Give each choice the row that fits it: one `:options` row for a mode rather than several booleans that change each other, one NumberRange for a minimum and a maximum, `display.reflect` for an engine property rather than a row that copies it, and `:slider()` for a bounded number an artist tunes by feel, such as a strength or an opacity from 0 to 1. Cut a row that repeats another under a different name.
- **Layout.** A layout entry is a row or a group of rows, never a group inside a group, since the panel draws one level of subtitles under the effect's title.
- **The played instance.** Classify the class the effect needs. An effect that animates its own instance, as the sample animates its part, classifies that class. One that only makes instances of its own, or plays on the camera or a GUI, classifies a `RayValue` with its tag, which has no appearance or physics, as the built-in camera shake does. One that needs only a place in the world classifies an `Attachment` and reads `ctx.ref.WorldCFrame`, so it follows the part it sits in; select that part before adding one, since the adder parents what it makes to the selection.
- **Where created instances go.** Put a created instance under `workspace.Terrain` with `Archivable` false, `Locked` true and `CanCollide`, `CanQuery` and `CanTouch` false, held with `sdk.hold` before it is parented:

  ```luau
  local part = sdk.hold(ctx, Instance.new("Part"))

  part.Archivable = false
  part.Locked = true
  part.Anchored = true
  part.CanCollide = false
  part.CanQuery = false
  part.CanTouch = false
  part.Parent = workspace.Terrain
  ```

  Never put one at the `workspace` root, in a folder of your own, or directly in `StarterGui` or `PlayerGui`; a GUI goes in `sdk.guiRoot(ctx)`. A clone you made is yours to write directly; the played instance goes through writers. Never clone from an instance a writer has written: clone first, write second, and expect a second emit while the first plays (or call `sdk.lock`).

  A ViewportFrame does not render in a SurfaceGui parented to a part (measured in Studio's editor on 2026-10-05). Put every GUI an effect makes in `sdk.guiRoot(ctx)`: a SurfaceGui or BillboardGui there with its `Adornee` set to the part, a ScreenGui there with `ResetOnSpawn` false. Hold a GUI made for one emit with `sdk.hold`; a container every emit shares is found by name in the root or made there, and stays for the session. Nothing in the root is saved with the place or copied to players. On the server there is no root: check `sdk.context()` first.
- **components.** Declare `components = "Instance"` when the instance owns descendants the effect plays, hides or copies.
- **Time.** Keep time with `sdk.step`, `sdk.tween`, `sdk.wait` and `sdk.apply` only. Never use `RunService`, `BindToRenderStep`, `Heartbeat`, `RenderStepped`, `task.wait`, `task.delay`, `task.spawn` or `os.clock`. Use the late pass for anything placed against the camera. Expect a step to keep being called while paused, with `dt` 0. Never multiply by a speed or keep a second clock. The effect stops every step when it ends; use the function `sdk.step` answers only to end one early.
- **Errors.** When the effect cannot play, call `error(text)`. When it recovers, call `sdk.warn(ctx, text)`. Put no `pcall` around an sdk call.
- **Context.** Return at once from a render only effect when `sdk.context()` is `"server"`. Read no `Players.LocalPlayer` in an effect that must work in the editor.
- **State.** Keep no module level state but constants and one `Random.new()`; anything else is wrong after a live reload.
- **Performance.** Return early when nothing changed, cull by distance, and make one raycast or spatial query per emit rather than per frame. Pool what is spawned in bursts. Mind the budgets: 31 Highlights at once, EditableMesh memory, and the Load Assets permission for meshes by id.
- **Measure, date, record.** An effect that rests on an engine quirk says in a comment what was measured and when, or it does not ship.
- **Module shape.** Write no header comment and no section dividers. Write comments as lowercase fragments at the line they explain.

## Live reload in Studio

The plugin reloads a custom effect when any ModuleScript inside the tagged module changes, or one is added or removed there. It copies the module into a folder of its own and requires the copy, so:

- Keep helpers inside the tagged module and require them relative to `script`.
- A module required by absolute path from elsewhere, such as `ReplicatedStorage.Shared.Util`, loads only if it is sandboxed itself (see below), and it is not reloaded. The plugin tells you when one changes; reload the plugin to pick it up.
- A require that climbs out of the tagged module (`script.Parent.Shared`) does not resolve in the copy.

Do no work when the module loads: no connections, loops or threads at the top level. Everything belongs in `emit`. If the module must start something, stop it in `effect.unload()`, which is called on the old version once a reload has replaced it, on a removed one, and on a version that is refused. Effects already playing finish on the version they started with.

## Custom effects in Studio

In Studio, VFX Forge runs custom effects in Roblox's script sandbox. A custom effect cannot upload assets, make purchases, use datastores, compile code with loadstring or require modules by asset id. It cannot use the network or load assets by id unless you turn on Network or Load Assets under Custom Effects in VFX Forge's settings.

In Studio a custom effect can only require modules inside itself, or modules that are sandboxed themselves with no more capabilities than custom effects get. Keep helpers inside the effect, or sandbox a shared one yourself by turning on its Sandboxed property; that limits it in your game too, for every script that requires it.

The sandbox does not stop an effect from changing your place, including your other scripts, or from using Studio's own services. In a playtest and in your game, a custom effect runs as ordinary game code with your game's full rights. Treat a custom effect like any script from a free model: add one only from someone you trust, and read it first.

Turning Network or Load Assets on or off restarts every custom effect, and turning one off also ends every custom effect still playing.
