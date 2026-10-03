# Writing a custom effect (sdk 1)

A custom effect is a ModuleScript tagged `VFXForgeEffect`, anywhere in the place. The game registers every tagged module when ForgeVFX initializes, and one tagged later as it is tagged. The plugin registers the same modules in its own copy, so a custom effect shows in the panel and previews like a built-in, and it reloads the module while you edit it.

`sample.luau` beside this guide is a complete effect. The types are in `ReplicatedStorage.VFXForge.SDK`, which the plugin writes when you create a custom effect.

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
- `display` takes `name` and an optional `icon`.
- `classifier` is a selector. Every alternative in it names a class and a tag of its own, as in `BasePart.MyEffect`, so no instance can be yours and another effect's at once. Tag the instances that play it with that tag. A classifier that shares a tag with another effect, or names a class a built-in plays whole (`Beam`, `Trail`, `ParticleEmitter`, `Sound`, `Model`), is refused.
- Optional fields: `components` (a selector for descendants the effect plays itself), `layout` (the panel's rows), `constant` (an Enabled loop may emit it), `params`, `duration` and `unload`.
- Any other field is refused, so a typo like `clasifier` is caught.

Every method takes `sdk` first. Never require ForgeVFX from a custom effect.

## Params

`params(sdk)` is called once each time the module loads and answers `attributes` and `properties`, tables of knobs by name. A knob declared with `:curve(preset)` is a curve param, edited in the curve editor; its value goes straight into `sdk.curve`. A knob declared with `:mod()` can be animated by modifiers and is read as a Track, which `sdk.speed` takes.

## Time

All time is effect time: scaled by the effect's speed and stopped while it is paused.

- `sdk.wait(ctx, seconds)` waits.
- `sdk.step(ctx, fn)` calls `fn(dt, elapsed)` every frame while the effect runs, and answers a function that stops it.
- `sdk.curve(duration, shape)` is a curve over `duration` seconds. `shape` is a preset (`linear`, `easeIn`, `easeOut`, `easeInOut`), a curve param's value, a chain of vectors or a function of time. `curve:at(t)` answers its value for `t` from 0 to 1.
- `sdk.tween(ctx, curve, fn)` plays a curve, calling `fn(alpha)` once at the start and then once a frame.

An effect lasts until `emit` returns and everything it started has finished: its tweens, its nested emits and every piece of every join. A step does not keep an effect alive; wait for as long as it should run.

## Pieces, nested emits and cleanup

- `sdk.join(ctx)`, `sdk.spawn(join, fn, ...)` and `sdk.await(join)` run pieces on threads of their own.
- `sdk.emit(ctx, instance)` plays an instance as a nested effect of this one.
- `sdk.hold(ctx, thing)` cleans up an instance, connection, function or thread when the effect ends.

`sdk.wait` and `sdk.await` yield, so they cannot run inside a step or a tween's callback.

## Writing to instances

`sdk.getWriter(ctx, obj, property)` and `sdk.getAttributeWriter(ctx, obj, name)` answer a writer with `:set(value)`. Writers hand a target over between overlapping emits by priority and put the authored value back when the last one ends. Write through a writer rather than to the instance.

## Math

`sdk.lerp(a, b, t)` blends any value ForgeVFX blends. `sdk.color` blends colors in Oklab. `sdk.shape.box`, `cylinder`, `sphere` and `disc` answer a random point. `sdk.bezier.new(points)` is a path with `:at(t)`, `:atUniform(u)`, `:length()` and `:tangent(t)`; `:set(points)` moves it, and only the segments that moved are measured again.

Curve and bezier points are a chain: an anchor, its outgoing handle, the next anchor's incoming handle, the next anchor, and so on, 3n + 1 points; two points are a straight line.

## Errors

A module that fails to load, throws in `params` or breaks a rule is refused with every reason named, and in the plugin the version before it stays registered. An `emit`, step, tween callback or piece that throws is warned about once per instance, and its effect ends and lets go of what it held.

## Live reload in Studio

The plugin reloads a custom effect when any ModuleScript inside the tagged module changes, or one is added or removed there. It copies the module into a folder of its own and requires the copy, so:

- Keep helpers inside the tagged module and require them relative to `script`.
- A module required by absolute path from elsewhere, such as `ReplicatedStorage.Shared.Util`, is not reloaded. The plugin tells you when one changes; reload the plugin to pick it up.
- A require that climbs out of the tagged module (`script.Parent.Shared`) does not resolve in the copy.

Do no work when the module loads: no connections, loops or threads at the top level. Everything belongs in `emit`. If the module must start something, stop it in `effect.unload()`, which the plugin calls on the old version before a reload drops it. Effects already playing finish on the version they started with.
