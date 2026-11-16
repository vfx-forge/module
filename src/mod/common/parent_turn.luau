local common = {}

common.ATTRIBUTE = "ParentTurn"

-- an attribute keeps a CFrame in float32 (an ulp of 1.2e-7 at 1), and a turn
-- read back and carried through the parent's frame lands a few dozen ulps from
-- the template's own; this clears that and stays under a thousandth of a degree
common.TOLERANCE = 1e-5

-- whether two turns agree to within the tolerance, axis by axis
function common.near(a: CFrame, b: CFrame): boolean
  const right = a.RightVector - b.RightVector
  const up = a.UpVector - b.UpVector
  const tolerance = common.TOLERANCE

  return math.abs(right.X) <= tolerance
    and math.abs(right.Y) <= tolerance
    and math.abs(right.Z) <= tolerance
    and math.abs(up.X) <= tolerance
    and math.abs(up.Y) <= tolerance
    and math.abs(up.Z) <= tolerance
end

-- the template's turn in the frame its pieces spawn in, what the plugin stores
-- whenever the template is placed
function common.measure(frame: CFrame, template: CFrame): CFrame
  return frame.Rotation:Inverse() * template.Rotation
end

-- where a template under an attachment or a part is kept: on the point its
-- pieces spawn from, in its own turn. The runtime never reads the position of
-- such a template (forge_mesh.originOf spawns from the parent), so one left
-- behind when its parent moved only put the effect's gizmo away from what
-- plays; the turn is kept, since it is what the pieces play at
function common.pinned(frame: CFrame, template: CFrame): CFrame
  return CFrame.new(frame.Position) * template.Rotation
end

-- whether a template sits off the point it is kept on, past a thousandth of a
-- stud (a CFrame keeps float32)
function common.offPoint(frame: CFrame, template: CFrame): boolean
  return (template.Position - frame.Position).Magnitude > 1e-3
end

-- the turn a template's pieces play at: the stored turn carried by the frame
-- as it stands now, or the template's own while the two agree (the frame has
-- not turned since the template was placed, or the template turned with it),
-- with no frame, or with nothing stored
function common.turned(template: CFrame, frame: CFrame?, stored: any): CFrame
  const own = template.Rotation

  if frame == nil or typeof(stored) ~= "CFrame" then
    return own
  end

  const played = frame.Rotation * stored.Rotation

  return if common.near(played, own) then own else played
end

return common
