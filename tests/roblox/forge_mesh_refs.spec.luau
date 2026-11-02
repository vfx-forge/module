const RunService = game:GetService("RunService")

const api = require("@root")
const utility = require("@mod/utility")
const lifetime = require("@mod/lifetime")
const scheduler = require("@mod/scheduler")

const pool = require("@srv/pool")
const effects = require("@srv/effects")
const containers = require("@srv/containers")

const PIECE = "ForgeMeshRefsTemplate"
const INNER = "ForgeMeshRefsInner"
const BARE = "ForgeMeshBareTemplate"
const EMITS = 2
const PIECES = 2
const INNER_PIECES = 2
const SLACK = 0.01

-- the template's own names, so a copy another effect has free in the pool is
-- left out of the count
const OWN = { Ray = true, Stretch = true, Streak = true, Pointer = true, InnerStreak = true }

type Problems = { string }

const function note(problems: Problems, condition: boolean, message: string)
  if condition then
    return
  end

  table.insert(problems, message)
end

const function nameOf(inst: Instance?)
  return if inst == nil then "nil" else inst:GetFullName()
end

const function inside(holder: Instance, inst: Instance?)
  return inst ~= nil and (inst == holder or inst:IsDescendantOf(holder))
end

const function waitFor(seconds: number, done: () -> boolean)
  const started = os.clock()

  while not done() do
    if os.clock() - started > seconds then
      return false
    end

    task.wait()
  end

  return true
end

-- the plugin's runtime when one is running; an Open Cloud task is a server,
-- which never starts one, so the case starts the parts an emit needs itself
const function withRuntime(body: () -> ())
  if api.setup and pool.started() then
    body()
    return
  end

  if api.setup or pool.started() then
    error("the runtime is half started", 0)
  end

  if RunService:IsClient() then
    scheduler.start()
  else
    scheduler.start({
      IsRunning = function()
        return false
      end,
      RenderStepped = RunService.Heartbeat,
    })
  end

  const scope = {}

  -- a nested emit runs only under a set up api
  api.setup = true

  const ok, err = pcall(function()
    pool.init(scope)
    effects.init(api)
    body()
  end)

  effects.deinit()
  lifetime.releasePlain(scope)
  scheduler.stop()

  api.setup = false

  if not ok then
    error(err, 0)
  end
end

const function part(name: string, size: Vector3, cframe: CFrame, parent: Instance)
  const made = Instance.new("Part")
  made.Name = name
  made.Size = size
  made.CFrame = cframe
  made.Anchored = true
  made.CanCollide = false
  made.CanQuery = false
  made.CanTouch = false
  made.Parent = parent

  return made
end

const function attachment(name: string, position: Vector3, parent: Instance)
  const made = Instance.new("Attachment")
  made.Name = name
  made.Position = position
  made.Parent = parent

  return made
end

const function trail(name: string, from: Attachment, to: Attachment, parent: Instance)
  const made = Instance.new("Trail")
  made.Name = name
  made.Enabled = false
  made.Attachment0 = from
  made.Attachment1 = to
  made.Parent = parent

  return made
end

const function pieceRows(inst: Instance)
  inst:AddTag(utility.FORGE_MESH_TAG)
  inst:SetAttribute("Speed", NumberRange.new(0, 0))
  inst:SetAttribute("Lifetime", NumberRange.new(0.6, 0.6))
end

-- a template holding every kind of reference a nested effect leans on: a weld
-- inside it, a weld constraint out of it, a beam, a stretched beam and a trail
-- between its own attachments, an object value and a nested template
const function build(root: Folder)
  const origin = CFrame.new(0, 1000, 2000)
  const outside = part("Outside", Vector3.one, origin * CFrame.new(0, 0, 20), root)
  const base = part("Base", Vector3.new(8, 1, 8), origin, root)
  const template = part(PIECE, Vector3.one, origin, base)

  template.Transparency = 1
  pieceRows(template)
  template:SetAttribute("EmitCount", PIECES)

  const child = part("Child", Vector3.one * 0.5, origin * CFrame.new(0, 1, 0), template)
  child.Anchored = false

  const weld = Instance.new("Weld")
  weld.Name = "Weld"
  weld.Part0 = template
  weld.Part1 = child
  weld.C0 = CFrame.new(0, 1, 0)
  weld.Parent = template

  const tie = Instance.new("WeldConstraint")
  tie.Name = "Tie"
  tie.Part0 = template
  tie.Part1 = outside
  tie.Parent = template

  const from = attachment("A0", Vector3.new(-1, 0, 0), template)
  const to = attachment("A1", Vector3.new(1, 0, 0), template)

  for _, name in { "Ray", "Stretch" } do
    const beam = Instance.new("Beam")
    beam.Name = name
    beam.Enabled = false
    beam.Attachment0 = from
    beam.Attachment1 = to
    beam:SetAttribute("EffectDuration", NumberRange.new(0.5, 0.5))
    beam.Parent = template
  end

  -- the stretched beam plays on throwaway attachments of its own
  template.Stretch:SetAttribute("LengthScale", 2)

  trail("Streak", from, to, template)

  const pointer = Instance.new("ObjectValue")
  pointer.Name = "Pointer"
  pointer.Value = child
  pointer.Parent = template

  -- its own children make every take a whole clone, which pool.templateOf
  -- traces back to the outer piece's copy it was taken from
  const inner = part(INNER, Vector3.one * 0.2, origin, template)

  pieceRows(inner)
  inner:SetAttribute("EmitCount", INNER_PIECES)

  trail(
    "InnerStreak",
    attachment("B0", Vector3.new(0, -0.1, 0), inner),
    attachment("B1", Vector3.new(0, 0.1, 0), inner),
    inner
  )

  return template, outside
end

const function named(folder: Instance, name: string, class: string)
  const found = {}

  for _, child in folder:GetChildren() do
    if child.Name == name and child:IsA(class) then
      table.insert(found, child)
    end
  end

  return found
end

-- the piece among `pieces` that holds both ends of a beam or trail
const function holderOf(pieces: { Instance }, link: any)
  for _, piece in pieces do
    if inside(piece, link.Attachment0) and inside(piece, link.Attachment1) then
      return piece
    end
  end

  return nil
end

const function checkTemplate(problems: Problems, template: any, outside: BasePart, label: string)
  note(problems, template:HasTag(utility.FORGE_MESH_TAG), `{label}: the template lost its tag`)
  note(problems, template.Weld.Part0 == template, `{label}: template Weld.Part0 is {nameOf(template.Weld.Part0)}`)
  note(problems, template.Tie.Part1 == outside, `{label}: template Tie.Part1 is {nameOf(template.Tie.Part1)}`)
  note(
    problems,
    template.Ray.Attachment0 == template.A0,
    `{label}: template Ray.Attachment0 is {nameOf(template.Ray.Attachment0)}`
  )
  note(
    problems,
    template.Pointer.Value == template.Child,
    `{label}: template Pointer.Value is {nameOf(template.Pointer.Value)}`
  )
  note(problems, not template.Streak.Enabled, `{label}: the template's own trail was switched on`)
end

const function checkPiece(problems: Problems, piece: any, outside: BasePart, label: string)
  const child = piece:FindFirstChild("Child")
  const links = {
    { "Weld.Part0", piece.Weld.Part0, piece },
    { "Weld.Part1", piece.Weld.Part1, child },
    { "Tie.Part0", piece.Tie.Part0, piece },
    { "Tie.Part1", piece.Tie.Part1, outside },
    { "Ray.Attachment0", piece.Ray.Attachment0, piece.A0 },
    { "Ray.Attachment1", piece.Ray.Attachment1, piece.A1 },
    { "Stretch.Attachment0", piece.Stretch.Attachment0, piece.A0 },
    { "Stretch.Attachment1", piece.Stretch.Attachment1, piece.A1 },
    { "Streak.Attachment0", piece.Streak.Attachment0, piece.A0 },
    { "Streak.Attachment1", piece.Streak.Attachment1, piece.A1 },
    { "Pointer.Value", piece.Pointer.Value, child },
  }

  for _, pair in links do
    const name, found, wanted = pair[1], pair[2], pair[3]

    note(problems, found == wanted, `{label}: {name} is {nameOf(found)}, not {nameOf(wanted)}`)
  end

  note(problems, #piece:GetTags() == 0, `{label}: carries the tags {table.concat(piece:GetTags(), ", ")}`)
  note(problems, piece.Streak.Enabled, `{label}: its trail is not playing`)
  note(problems, piece[INNER]:HasTag(utility.FORGE_MESH_TAG), `{label}: its nested template lost its tag`)

  -- the weld holds the child where it was authored as the piece is placed
  const offset = piece.CFrame:ToObjectSpace(child.CFrame).Position - Vector3.new(0, 1, 0)

  note(problems, offset.Magnitude < SLACK, `{label}: the welded child is {offset} off its weld`)
end

-- every beam the beam effect plays is a pooled copy outside the piece, so each
-- must hold both ends in one piece, one per piece
const function checkBeams(problems: Problems, folder: Instance, pieces: { Instance }, name: string, label: string)
  const playing = {}
  const covered: { [Instance]: number } = {}

  for _, beam in named(folder, name, "Beam") do
    if not (beam :: Beam).Enabled then
      continue
    end

    table.insert(playing, beam)

    const piece = holderOf(pieces, beam)

    note(
      problems,
      piece ~= nil,
      `{label}: a playing {name} runs from {nameOf((beam :: Beam).Attachment0)} to {nameOf((beam :: Beam).Attachment1)}`
    )

    if piece ~= nil then
      covered[piece] = (covered[piece] or 0) + 1
    end
  end

  note(problems, #playing == #pieces, `{label}: {#playing} {name} beams play for {#pieces} pieces`)

  for _, piece in pieces do
    note(problems, covered[piece] == 1, `{label}: {covered[piece] or 0} {name} beams play on {piece:GetFullName()}`)
  end

  return playing
end

const function checkNested(problems: Problems, folder: Instance, pieces: { any }, label: string)
  const nested = named(folder, INNER, "BasePart")
  const counted: { [Instance]: number } = {}

  note(problems, #nested == #pieces * INNER_PIECES, `{label}: {#nested} nested pieces for {#pieces} pieces`)

  for _, inner: any in nested do
    const from = pool.templateOf(inner)
    local owner = nil

    for _, piece in pieces do
      if from == piece[INNER] then
        owner = piece
      end
    end

    note(
      problems,
      #inner:GetTags() == 0,
      `{label}: a nested piece carries the tags {table.concat(inner:GetTags(), ", ")}`
    )
    note(problems, owner ~= nil, `{label}: a nested piece was taken from {nameOf(from)}`)
    note(
      problems,
      inner.InnerStreak.Attachment0 == inner.B0,
      `{label}: a nested trail starts at {nameOf(inner.InnerStreak.Attachment0)}`
    )
    note(
      problems,
      inner.InnerStreak.Attachment1 == inner.B1,
      `{label}: a nested trail ends at {nameOf(inner.InnerStreak.Attachment1)}`
    )
    note(problems, inner.InnerStreak.Enabled, `{label}: a nested trail is not playing`)

    if owner == nil then
      continue
    end

    counted[owner] = (counted[owner] or 0) + 1

    -- spawned in the box of the piece it was emitted from
    const at = owner.CFrame:PointToObjectSpace(inner.Position)
    const half = owner.Size / 2 + Vector3.one * SLACK

    note(
      problems,
      math.abs(at.X) <= half.X and math.abs(at.Y) <= half.Y and math.abs(at.Z) <= half.Z,
      `{label}: a nested piece sits {at} from its piece`
    )
  end

  for _, piece in pieces do
    note(problems, counted[piece] == INNER_PIECES, `{label}: {counted[piece] or 0} nested pieces came from one piece`)
  end
end

-- what the pool keeps once every piece is let go: no piece, no nested piece,
-- and no free copy still naming an instance of a use that ended
const function checkLeft(problems: Problems, folder: Instance, outside: BasePart, label: string)
  note(problems, #named(folder, PIECE, "BasePart") == 0, `{label}: a piece is left in the pool`)
  note(problems, #named(folder, INNER, "BasePart") == 0, `{label}: a nested piece is left in the pool`)
  note(problems, #outside:GetJoints() == 1, `{label}: the outside part holds {#outside:GetJoints()} joints`)

  for _, child in folder:GetDescendants() do
    if not OWN[child.Name] then
      continue
    end

    if child:IsA("Beam") or child:IsA("Trail") then
      const link = child :: any

      note(
        problems,
        link.Attachment0 == nil and link.Attachment1 == nil,
        `{label}: a free {child.Name} still names {nameOf(link.Attachment0)} and {nameOf(link.Attachment1)}`
      )
    elseif child:IsA("ObjectValue") then
      note(
        problems,
        (child :: ObjectValue).Value == nil,
        `{label}: a free {child.Name} still names {nameOf((child :: ObjectValue).Value)}`
      )
    end
  end
end

return {
  {
    name = "a forge mesh piece's references point at its own copies across two emits from the pool",
    run = function()
      const root = Instance.new("Folder")
      root.Name = "ForgeMeshRefsSpec"
      root.Parent = workspace

      const ok, err = pcall(withRuntime, function()
        const problems: Problems = {}
        const template, outside = build(root)
        const rest = outside.CFrame
        const folder = containers.root():FindFirstChild("Pool") :: Instance
        local earlier: { [Instance]: true } = {}

        for emit = 1, EMITS do
          const label = `emit {emit}`

          effects.emit(0, template)

          -- every nested effect has started by now, and none has ended
          task.wait(0.25)

          const pieces = named(folder, PIECE, "BasePart")

          note(problems, #pieces == PIECES, `{label}: {#pieces} pieces in the pool for {PIECES}`)

          for i, piece in pieces do
            checkPiece(problems, piece, outside, `{label} piece {i}`)
          end

          checkTemplate(problems, template, outside, label)
          checkNested(problems, folder, pieces, label)

          const rays = checkBeams(problems, folder, pieces, "Ray", label)
          const stretched = checkBeams(problems, folder, pieces, "Stretch", label)
          local reused = false

          -- a beam's copies come from one stack for the class, so either
          -- name may take a copy the last emit's other beam let go
          for _, list in { rays, stretched } do
            for _, beam in list do
              reused = reused or earlier[beam] == true
            end
          end

          for _, beam in stretched do
            for _, link in { beam.Attachment0, beam.Attachment1 } do
              note(
                problems,
                link ~= nil and link.Name == "_ForgeTempAttachment",
                `{label}: a stretched beam runs on {nameOf(link)}, not a throwaway attachment`
              )
            end
          end

          if emit > 1 then
            note(problems, reused, `{label}: no beam came from the pool, so the reuse went unchecked`)
          end

          earlier = {}

          for _, list in { rays, stretched } do
            for _, beam in list do
              earlier[beam] = true
            end
          end

          note(problems, outside.CFrame == rest, `{label}: the outside part moved to {outside.CFrame.Position}`)

          const ended = waitFor(5, function()
            return #named(folder, PIECE, "BasePart") == 0 and #named(folder, INNER, "BasePart") == 0
          end)

          note(problems, ended, `{label}: the pieces outlived their emit`)

          -- the frame the last piece is let go in
          task.wait()

          checkLeft(problems, folder, outside, `after {label}`)
        end

        if #problems > 0 then
          error(table.concat(problems, "\n       "), 0)
        end
      end)

      root:Destroy()

      if not ok then
        error(err, 0)
      end
    end,
  },
  {
    name = "a bare piece never writes to its template",
    run = function()
      const root = Instance.new("Folder")
      root.Name = "ForgeMeshBareSpec"
      root.Parent = workspace

      const conns = {}

      const ok, err = pcall(withRuntime, function()
        const problems: Problems = {}
        const origin = CFrame.new(0, 1000, 2040)
        const base = part("Base", Vector3.new(8, 1, 8), origin, root)
        const template = part(BARE, Vector3.one, origin, base)

        template.Transparency = 1
        pieceRows(template)
        template:SetAttribute("EmitCount", PIECES)

        const decal = Instance.new("Decal")
        decal.Name = "Front"
        decal.Texture = "rbxassetid://1"
        decal.Parent = template

        -- references across the template's own children and to its root, which
        -- a copy built child by child must point at its own
        const child = part("Child", Vector3.one * 0.5, origin, template)
        const pointer = Instance.new("ObjectValue")
        pointer.Name = "Pointer"
        pointer.Value = child
        pointer.Parent = template

        const tie = Instance.new("WeldConstraint")
        tie.Name = "Tie"
        tie.Part0 = template
        tie.Parent = template

        -- a frame set and a texture set, each kept out of every emit
        const sets = {}

        for name, key in { Frames = "FrameSet", Textures = "TextureSet" } do
          const set = Instance.new("Folder")
          set.Name = name
          set:SetAttribute(key, "Probe")
          set:AddTag(utility.EMIT_EXCLUDE_TAG)
          set.Parent = template

          part("1", Vector3.one, origin, set)
          table.insert(sets, set)
        end

        local writes = 0

        for _, inst in { template, sets[1], sets[2], sets[1]["1"], sets[2]["1"] } :: { Instance } do
          for _, signal in { inst.Changed, inst.AttributeChanged } :: { any } do
            table.insert(
              conns,
              signal:Connect(function(name: string)
                writes += 1
                table.insert(problems, `{inst:GetFullName()} changed {name}`)
              end)
            )
          end
        end

        const folder = containers.root():FindFirstChild("Pool") :: Instance

        for emit = 1, EMITS do
          const label = `emit {emit}`
          const texture = `rbxassetid://{emit}`

          effects.emit(0, template)
          task.wait(0.1)

          const pieces = named(folder, BARE, "BasePart")

          note(problems, #pieces == PIECES, `{label}: {#pieces} pieces in the pool for {PIECES}`)

          for i, piece in pieces do
            const front = piece:FindFirstChild("Front") :: Decal?
            const found = if front ~= nil then front.Texture else "nil"

            note(problems, piece:FindFirstChild("Frames") == nil, `{label} piece {i}: carries the frame set`)
            note(problems, piece:FindFirstChild("Textures") == nil, `{label} piece {i}: carries the texture set`)
            note(problems, found == texture, `{label} piece {i}: its decal shows {found}, not {texture}`)

            const own = piece:FindFirstChild("Child")
            const held = piece:FindFirstChild("Pointer") :: ObjectValue?
            const joint = piece:FindFirstChild("Tie") :: WeldConstraint?

            note(
              problems,
              held ~= nil and own ~= nil and held.Value == own,
              `{label} piece {i}: Pointer names {if held then nameOf(held.Value) else "nothing"}`
            )
            note(
              problems,
              joint ~= nil and joint.Part0 == piece,
              `{label} piece {i}: Tie.Part0 is {if joint then nameOf(joint.Part0) else "nothing"}`
            )
          end

          const ended = waitFor(5, function()
            return #named(folder, BARE, "BasePart") == 0
          end)

          note(problems, ended, `{label}: the pieces outlived their emit`)

          -- an edit between emits reaches the next emit's pieces
          if emit < EMITS then
            decal.Texture = `rbxassetid://{emit + 1}`
            task.wait()
          end
        end

        note(problems, writes == 0, `{writes} writes reached the template or its sets`)

        if #problems > 0 then
          error(table.concat(problems, "\n       "), 0)
        end
      end)

      for _, conn in conns do
        conn:Disconnect()
      end

      root:Destroy()

      if not ok then
        error(err, 0)
      end
    end,
  },
}
