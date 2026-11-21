const lifetime = require("@mod/lifetime")

const cores = require("@mod/lightning/cores")

const nested = {}

const NAMES = { "EmitOnStart", "EmitOnImpact", "EmitAtTip", "EmitAlong", "Bolt", "EmitOnFinish" }

function nested.slots(ref: Instance): { [string]: Folder }
  const found = {}

  for _, name in NAMES do
    const folder = ref:FindFirstChild(name)

    if folder and folder:IsA("Folder") and #folder:GetChildren() > 0 then
      found[name] = folder
    end
  end

  return found
end

-- a nested emit is a child of the effect's, counted into `children`, which the effect waits for once its bolts are
-- done
const function emit(scope: lifetime.effect, children: lifetime.join, host: Attachment)
  scope.effects.emitInstance(host, scope.depth + 1, scope, children)
end

function nested.host(
  scope: lifetime.effect,
  children: lifetime.join,
  copies: { Instance },
  name: string,
  cframe: CFrame
): Attachment
  const host = lifetime.hold(scope, Instance.new("Attachment"))

  host.Name = name
  host.Archivable = false
  host.Parent = cores.container()
  host.WorldCFrame = cframe

  for _, child in copies do
    const copy = child:Clone()

    if copy then
      copy.Parent = host
    end
  end

  -- a nested emit scans the host and its descendants for effects (registry.scan in services/effects.luau), so emitting the host plays the clones
  emit(scope, children, host)

  return host
end

function nested.again(scope: lifetime.effect, children: lifetime.join, host: Attachment, cframe: CFrame)
  host.WorldCFrame = cframe
  emit(scope, children, host)
end

return nested
