local attr = require("@mod/attributes")
local value = require("@mod/value")
local curves = require("@mod/curves")
local harness = require("@tests/harness")
local legacy_mods = require("@mod/legacy_mods")
local test, expect = harness.test, harness.expect
local Vector3 = harness.datatypes.Vector3
local Instance = harness.datatypes.Instance
local NumberRange = harness.datatypes.NumberRange

harness.suite(function()
  test("a half quad names the half it lacks", function()
    local obj = Instance.new("Attachment")
    obj:SetAttribute("Width_End", 3)

    local queue = legacy_mods.readQuad(obj, "attribute", "Width")

    expect(queue[1].partial).toBe("start")
    expect(queue[1].start.v).toBe(3)
  end)

  test("a whole quad is not partial", function()
    local obj = Instance.new("Attachment")
    obj:SetAttribute("Width_Start", 1)
    obj:SetAttribute("Width_End", 3)

    local queue = legacy_mods.readQuad(obj, "attribute", "Width")

    expect(queue[1].partial).toBe(nil)
  end)

  test("complete fills the missing half and clears the mark", function()
    local queue = { { kind = "tween", chain = false, start = value.lit(3), finish = value.lit(3), partial = "start" } }
    local filled = legacy_mods.complete(queue, value.lit(1), value.lit(9))

    expect(filled[1].start.v).toBe(1)
    expect(filled[1].finish.v).toBe(3)
    expect(filled[1].partial).toBe(nil)
    expect(queue[1].partial).toBe("start")
  end)

  test("an endpoint on a drawn range is a rand", function()
    local ep = legacy_mods.endpoint("attribute", "RotSpeed", NumberRange.new(1, 2))

    expect(ep.t).toBe("rand")
    expect(ep.min).toBe(1)
    expect(ep.max).toBe(2)
  end)

  test("an endpoint elsewhere is a lit", function()
    local ep = legacy_mods.endpoint("attribute", "Width", NumberRange.new(1, 2))

    expect(ep.t).toBe("lit")
  end)

  test("an alias reads the old spelling when the new one is absent", function()
    local obj = Instance.new("Part")
    obj:SetAttribute("PartOffset", Vector3.new(1, 2, 3))

    expect(legacy_mods.alias(obj, "OffsetIn_Start", Vector3.zero)).toEqual(Vector3.new(1, 2, 3))
    expect(legacy_mods.alias(obj, "OffsetIn_End", Vector3.zero)).toEqual(Vector3.new(1, 2, 3))
  end)

  test("the newest spelling wins and nothing is written", function()
    local obj = Instance.new("Part")
    obj:SetAttribute("PartOffset", Vector3.new(1, 2, 3))
    obj:SetAttribute("Offset_Start", Vector3.new(4, 5, 6))
    obj:SetAttribute("OffsetIn_Start", Vector3.new(7, 8, 9))

    expect(legacy_mods.alias(obj, "OffsetIn_Start", Vector3.zero)).toEqual(Vector3.new(7, 8, 9))
    expect(obj:GetAttribute("OffsetIn_End")).toBe(nil)
  end)

  test("an alias with nothing authored is the default", function()
    local obj = Instance.new("Part")

    expect(legacy_mods.alias(obj, "SizeScaleOut_Duration", 0.5)).toBe(0.5)
  end)

  test("a quad reads its halves through the aliases", function()
    local obj = Instance.new("Part")
    obj:SetAttribute("Offset_Start", Vector3.new(1, 0, 0))
    obj:SetAttribute("BaseOffset", Vector3.new(2, 0, 0))
    obj:SetAttribute("Offset_Start_Duration", 0.25)

    local queue = legacy_mods.readQuad(obj, "attribute", "OffsetIn")

    expect(queue[1].start.v).toEqual(Vector3.new(1, 0, 0))
    expect(queue[1].finish.v).toEqual(Vector3.new(2, 0, 0))
    expect(queue[1].duration).toBe(0.25)
  end)

  test("a curve key defaults linear only when the table says so", function()
    expect(legacy_mods.defaultCurve("Color_Curve")).toBe(curves.linear())
    expect(legacy_mods.defaultCurve("Easing_Curve")).toBe(curves.linear())
    expect(legacy_mods.defaultCurve("Width_Curve")).toBe(curves.default())
  end)

  test("a quad with no curve takes the default for its key", function()
    local obj = Instance.new("Attachment")
    obj:SetAttribute("Color_Start", 0)
    obj:SetAttribute("Color_End", 1)

    local queue = legacy_mods.readQuad(obj, "attribute", "Color")

    expect(queue[1].curve).toBe(curves.linear())
  end)

  -- a curve is a binary string, which an instance under this harness cannot hold
  -- as an attribute. the cache carries raw values and every reader looks there
  -- first, so it is the one place a spec can author one
  local function setCurve(obj: Instance, name: string, curve: string)
    obj:SetAttribute(name, "")
    attr.cache(obj)
    attr.set(obj, name, curve)
  end

  local function tweenChild(name: string)
    local child = Instance.new("RayValue")
    child.Name = name
    child:SetAttribute("_START_VALUE", 0)
    child:SetAttribute("_END_VALUE", 10)
    child:SetAttribute("Duration", NumberRange.new(2, 2))

    return child
  end

  test("a tween child with a delay leads with one", function()
    local obj = Instance.new("Part")
    local child = tweenChild("Transparency")
    child:SetAttribute("EmitDelay", 0.5)
    child.Parent = obj

    local queue = legacy_mods.readChildren(obj, "property", "Transparency")

    expect(#queue).toBe(2)
    expect(queue[1].kind).toBe("delay")
    expect(queue[1].wait.v).toBe(0.5)
    expect(queue[2].kind).toBe("tween")
    expect(queue[2].duration).toBe(2)
  end)

  test("a tween child with no delay has none", function()
    local obj = Instance.new("Part")
    tweenChild("Transparency").Parent = obj

    local queue = legacy_mods.readChildren(obj, "property", "Transparency")

    expect(#queue).toBe(1)
    expect(queue[1].curve).toBe(curves.linear())
  end)

  test("a tween child carries its speed ramp", function()
    local obj = Instance.new("Part")
    local child = tweenChild("Transparency")
    child:SetAttribute("Speed_Start", 1)
    child:SetAttribute("Speed_End", 2)
    child:SetAttribute("Speed_Duration", 0.3)
    child.Parent = obj

    local queue = legacy_mods.readChildren(obj, "property", "Transparency")

    expect(queue[1].speed.start).toBe(1)
    expect(queue[1].speed.finish).toBe(2)
    expect(queue[1].speed.duration).toBe(0.3)
    expect(queue[1].speed.curve).toBe(curves.default())
  end)

  test("a speed ramp that rests at one is not carried", function()
    local obj = Instance.new("Part")
    tweenChild("Transparency").Parent = obj

    local queue = legacy_mods.readChildren(obj, "property", "Transparency")

    expect(queue[1].speed).toBe(nil)
  end)

  test("readChild reads one RayValue on its own", function()
    local child = tweenChild("Transparency")
    child:AddTag("AttributeTweener")

    local read = legacy_mods.readChild(child)

    expect(read.source).toBe("attribute")
    expect(read.name).toBe("Transparency")
    expect(read.random).toBe(false)
    expect(read.queue[1].kind).toBe("tween")
  end)

  test("readChild sees a randomizer", function()
    local child = Instance.new("RayValue")
    child.Name = "Size"
    child:SetAttribute("_START_VALUE", Vector3.new(1, 1, 1))
    child:SetAttribute("_END_VALUE", Vector3.new(2, 2, 2))
    child:AddTag("PropertyRandomizer")

    local read = legacy_mods.readChild(child)

    expect(read.source).toBe("property")
    expect(read.random).toBe(true)
    expect(read.queue[1].kind).toBe("randomizer")
    expect(read.queue[1].weight).toBe(curves.linear())
  end)

  test("readChild refuses anything but a RayValue", function()
    expect(legacy_mods.readChild(Instance.new("Part") :: any)).toBe(nil)
  end)

  test("a cached RayValue child still reads as a queue", function()
    local child = tweenChild("Transparency")
    child:AddTag("AttributeTweener")
    attr.cache(child)

    expect(child:GetAttribute("_START_VALUE")).toBe(nil)

    local read = legacy_mods.readChild(child)

    expect(read.source).toBe("attribute")
    expect(read.name).toBe("Transparency")
    expect(read.random).toBe(false)
    expect(read.queue[1].kind).toBe("tween")
    expect(read.queue[1].duration).toBe(2)
    expect(read.queue[1].start.v).toBe(0)
    expect(read.queue[1].finish.v).toBe(10)
  end)

  test("a curve alone is a quad with both halves missing", function()
    local obj = Instance.new("Attachment")
    setCurve(obj, "Width_Curve", curves.linear())

    local queue = legacy_mods.read(obj, "attribute", "Width")

    expect(#queue).toBe(1)
    expect(queue[1].partial).toBe("both")
    expect(queue[1].curve).toBe(curves.linear())

    local done = legacy_mods.complete(queue, value.lit(1), value.lit(2))

    expect(done[1].partial).toBe(nil)
    expect(done[1].start.v).toBe(1)
    expect(done[1].finish.v).toBe(2)
  end)

  test("a curve alone never shadows a RayValue child", function()
    local obj = Instance.new("Part")
    setCurve(obj, "Width_Curve", curves.linear())
    tweenChild("Width").Parent = obj

    local queue = legacy_mods.read(obj, "property", "Width")

    expect(#queue).toBe(1)
    expect(queue[1].kind).toBe("tween")
    expect(queue[1].partial).toBe(nil)
  end)
end)
