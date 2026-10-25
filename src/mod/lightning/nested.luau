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

function nested.host(sdk: any, ctx: any, children: { Instance }, name: string, cframe: CFrame): Attachment
  const host = sdk.hold(ctx, Instance.new("Attachment"))

  host.Name = name
  host.Archivable = false
  host.Parent = sdk.container(ctx)
  host.WorldCFrame = cframe

  for _, child in children do
    const copy = child:Clone()

    if copy then
      copy.Parent = host
    end
  end

  -- a nested emit scans the host and its descendants for effects (registry.scan in services/effects.luau), so emitting the host plays the clones
  sdk.emit(ctx, host)

  return host
end

function nested.again(sdk: any, ctx: any, host: Attachment, cframe: CFrame)
  host.WorldCFrame = cframe
  sdk.emit(ctx, host)
end

return nested
