# What the lightning costs in Studio

Measured 2026-10-24 in Studio 0.744.0.7441077 (`version()`), Edit mode, on the owner's laptop, through the Roblox Studio MCP's `execute_luau`, on the revised build (Tube, Rim and Segments styles, no glow ribbon). Studio drew at about 360 frames a second (2.78 ms a frame), so every per frame figure below is per 2.78 ms frame. A Jitter driven cost is paid a set number of times a second, not every frame, so at 60 frames a second its share of each frame is six times what these figures show; a Flow or Fade cost is paid every frame whatever the rate.

The first build's figures (2026-10-23, with its camera-facing glow ribbon) are replaced here: the ribbon and its re-aim are gone.

## How

- Render figures are `Stats.RenderCPUFrameTime` and `RenderGPUFrameTime` averaged over every `RenderStepped` of a 2 s window, as `pack-tools/advice/lightning/probe2.luau` did. The camera looked at the bolt from 30 studs, against the sky, and was put back afterwards.
- Lua figures time the effect's own frame step: a probe copy of `init` (never committed) wrapped `frame` in `os.clock()` and added the seconds to an attribute on the played attachment. They are the effect's whole step for every bolt, divided by the frames in the window.
- Setup times the bolt from its start to its first frame (shape, the strike's rays, the plan, the meshes or parts, the riders, the hosts), with the same probe.
- Every bolt held for 3 s (`Hold` 3 to 3) so it was drawn through the whole window, the window opening 0.4 s after the emit; every other row was at its default unless named (Style Rim, Jitter 15, one restrike). A Fade case held 0.1 s and faded over 3 s (linear), so the window sat inside the fade. Idle readings moved between 1.15 and 1.17 ms of render CPU across the session, so a difference smaller than about 0.03 ms is noise.

## Size of one bolt (the defaults: Detail 16, 3 forks)

Read back from the meshes with `EditableMesh:GetVertices` and `GetFaces`. Each chain has a cap at both ends (a point each, 2 vertices a chain).

| | joints | vertices | triangles |
|---|---|---|---|
| core (5 sides) | 44 | 228 | 440 |
| rim (6 sides) | 44 | 272 | 528 |
| default bolt (Rim style, core and rim) | | 500 | 968 |
| Tube style (core only) | | 228 | 440 |
| Detail 32, 8 forks, core and rim | 169 | 1895 | 3718 |

The Detail 32 line is worked out from the same layout (rings times sides plus 2 cap points a chain; a chain of n joints has (n minus 1) times sides times 2 triangles and sides times 2 at its caps), not read back.

Segments draws 40 segments a bolt at the defaults: 40 core parts, and 40 rim parts more when Rim is above 0 (the default).

## Frame cost

| case | render CPU | render GPU | effect Lua per frame |
|---|---|---|---|
| idle, nothing drawn | 1.15 to 1.17 ms | 1.02 ms | |
| default template, 1 bolt (Rim, Jitter 15) | 1.20 ms | 1.03 ms | 0.008 ms |
| 10 bolts at once (Count 10) | 1.28 ms | 1.05 ms | 0.042 ms |
| Tube, 10 bolts | 1.21 ms | 1.04 ms | 0.033 ms |
| 10 bolts, Jitter 0 | 1.17 ms | 1.04 ms | 0.020 ms |
| no bolt, camera orbiting | 1.24 ms | 1.07 ms | |
| 1 bolt, Jitter 0, camera orbiting | 1.24 ms | 1.08 ms | 0.005 ms |
| 10 bolts, Jitter 0, camera orbiting | 1.25 ms | 1.10 ms | 0.020 ms |
| Segments, 1 bolt | 1.17 ms | 1.03 ms | 0.018 ms |
| Segments, 10 bolts | 1.26 ms | 1.04 ms | 0.140 ms |
| Flow, 1 bolt | 1.41 ms | 1.09 ms | 0.065 ms |
| Flow, 10 bolts | 3.00 ms (263 frames a second) | 1.12 ms | 0.556 ms |
| Highlight in Bolt, 1 bolt | 1.18 ms | 1.07 ms | 0.008 ms |
| Highlight in Bolt, 10 bolts (one Highlight) | 1.27 ms | 1.12 ms | 0.045 ms |
| ParticleEmitter in Bolt (Rate 50), 1 bolt | 1.20 ms | 1.06 ms | 0.009 ms |
| ParticleEmitter in Bolt, 10 bolts | 1.38 ms | 1.08 ms | 0.052 ms |
| Beam in Bolt, 1 bolt (40 beams) | 1.21 ms | 1.03 ms | 0.014 ms |
| Beam in Bolt, 10 bolts | 1.57 ms | 1.06 ms | 0.100 ms |
| EmitAlong ParticleEmitter (EmitCount 5), 1 bolt | 1.19 ms | 1.04 ms | 0.011 ms |
| EmitAlong ParticleEmitter, 10 bolts | 1.36 ms | 1.10 ms | 0.065 ms |
| Fade, 1 bolt | 1.34 ms | 1.08 ms | 0.049 ms |
| Fade, 10 bolts | 2.27 ms (340 frames a second) | 1.12 ms | 0.402 ms |
| Fade, Segments, 1 bolt | 1.36 ms | 1.08 ms | 0.076 ms |
| Fade, Segments, 10 bolts | 7.50 ms (114 frames a second) | 1.13 ms | 0.923 ms |
| Fade, Beam in Bolt, 10 bolts | 2.93 ms (252 frames a second) | 1.14 ms | 0.743 ms |
| Fade, Highlight in Bolt, 10 bolts | 1.61 ms | 1.10 ms | 0.170 ms |

What this says:

- A held bolt at the default Jitter costs almost nothing per frame: on the frames between reshapes the step only compares the state it drew. Ten of them add about 0.1 ms of render CPU and 0.04 ms of Lua. With no ribbon there is nothing to re-aim: with the camera orbiting the bolts at 30 studs, ten Jitter 0 bolts added 0.017 ms of render CPU over the orbit alone (0.011 ms with the camera still) and the same 0.02 ms of Lua, where the first build's ten re-aimed glows added 0.7 ms.
- The rim costs little: ten Tube bolts and ten Rim bolts are within 0.07 ms of render CPU and 0.01 ms of Lua.
- Flow writes every vertex of every bolt every frame: about 0.05 ms of Lua and 0.17 ms of render CPU a bolt. Ten Flow bolts took Studio from 360 to 263 frames a second. That is the price of a smooth bolt the spec names; keep Flow to a few bolts at once.
- A Fade is paid every frame it runs, with the bolt still reshaping at its Jitter rate through it (the Fade rows were timed again on that build, idle 1.20 ms): the core's part Transparency and the rim's vertex alpha (one `BatchSetValues` a frame) for a mesh bolt, about 0.04 ms of Lua and 0.1 ms of render CPU a bolt. Segments is far dearer under Fade, and worse than linearly: one fading Segments bolt costs about 0.16 ms of render CPU over idle, close to a plain Fade's 0.14 ms, but ten cost 6.3 ms (about 0.62 ms each, the ten bolt figure over ten) and about 0.08 ms of Lua each, and dropped Studio to 114 frames a second. A fading Segments bolt used to place all its parts again every frame as well (a `CFrame.lookAt` and a `BulkMoveTo` of 80 parts); with that gone, Lua for ten fell from 1.04 to 0.89 ms a frame (0.92 once the disappear reshapes again) and render CPU stayed at 7.5 ms. So the render cost is the engine's response to 80 part Transparency changes a bolt a frame, found by taking the moves away rather than timed on its own.
- The Beam relift under Fade (a new NumberSequence for the Beam's Transparency and a write to each of its 40 clones, every frame) adds about 0.034 ms of Lua and 0.067 ms of render CPU a bolt over a plain Fade, of which about 0.03 ms of render CPU is the beams' own draw.
- A Highlight in Bolt costs about 0.01 ms of GPU a bolt and no Lua to speak of. Under Fade its row is not one cost but a blend: a covered core stays opaque and writes nothing while the Highlight lifts away over the first half of the fade, then fades as a plain bolt does over the second, and this 2 s window caught 1.2 s of the first half and 0.8 s of the second. A whole such fade costs somewhat less than a plain one; the halves were not timed apart.
- Riders: a Bolt ParticleEmitter (5 points a bolt) adds about 0.01 ms of render CPU a bolt, a Bolt Beam about 0.03 ms of render CPU and 0.006 ms of Lua, and an EmitAlong ParticleEmitter (re-emitted at every reshape, 15 a second here) about 0.01 ms of render CPU and 0.002 ms of Lua.
- Flow re-emits an EmitAlong ParticleEmitter 15 times a second: counted in Studio, 19 emits over a 1.25 s Flow bolt, 15.0 a second.

## Setup per bolt

| case | setup, median of 4 |
|---|---|
| Rim, 1 bolt | 1.06 ms |
| Tube, 1 bolt | 0.62 ms |
| Segments, 1 bolt | 1.08 ms |
| Rim, 10 bolts in one emit | 9.76 ms |
| Segments, 10 bolts in one emit | 11.45 ms |

A Beam in Bolt makes 40 clones a bolt and raised the setup of 10 bolts to 16.7 ms (one reading). The 10 bolt figures are the sum over the bolts of one emit. They all start as the emit starts, so a Count of 10 likely spends those 10 ms in one frame; that was not checked frame by frame.
