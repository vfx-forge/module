const lifetime = require("@mod/lifetime")

const cores = require("@mod/lightning/cores")

type entry = { visible: boolean, opacity: number }

export type Cover = {
  model: Model,
  highlight: Highlight,
  fill: number,
  outline: number,
  entries: { entry },
  left: number,
  on: boolean,
  opacity: number,
}

const highlight = {}

-- one per emit, so a Count of 3 takes one of the 31 Highlights the engine draws at once, not three
function highlight.make(scope: lifetime.effect, template: Highlight, bolts: number): Cover
  const model = cores.model(scope)
  const made = lifetime.hold(scope, template:Clone())

  for _, tag in made:GetTags() do
    made:RemoveTag(tag)
  end

  made.Archivable = false
  made.Enabled = false
  made.Adornee = model
  made.Parent = model

  return {
    model = model,
    highlight = made,
    fill = template.FillTransparency,
    outline = template.OutlineTransparency,
    entries = {},
    left = bolts,
    on = false,
    opacity = -1,
  }
end

function highlight.join(cover: Cover): entry
  const made = { visible = false, opacity = 0 }

  table.insert(cover.entries, made)

  return made
end

-- the artist's transparencies seen through the most opaque bolt showing, hidden while none shows (a blink); each
-- bolt's frame calls it after writing its own entry, so it never lags a bolt by a frame
function highlight.refresh(cover: Cover)
  local opacity = 0

  for _, made in cover.entries do
    if made.visible then
      opacity = math.max(opacity, made.opacity)
    end
  end

  const on = opacity > 0
  const shown = cover.highlight

  if on and opacity ~= cover.opacity then
    cover.opacity = opacity
    shown.FillTransparency = 1 - (1 - cover.fill) * opacity
    shown.OutlineTransparency = 1 - (1 - cover.outline) * opacity
  end

  if on ~= cover.on then
    cover.on = on
    shown.Enabled = on
  end
end

-- the last bolt to go takes the Highlight and its Model with it
function highlight.leave(cover: Cover, made: entry)
  made.visible = false
  cover.left -= 1

  if cover.left > 0 then
    highlight.refresh(cover)

    return
  end

  cover.model:Destroy()
end

return highlight
