local pool = require("@srv/pool")

local function check(condition: boolean, message: string)
  if condition then
    return
  end

  error(message, 2)
end

return {
  {
    name = "the engine's list carries a part's size, color and shape and a highlight's look",
    run = function()
      local part = pool.engine.properties("Part") or {}
      local highlight = pool.engine.properties("Highlight") or {}

      for _, name in { "Size", "Color", "Shape", "MaterialVariant" } do
        check(table.find(part, name) ~= nil, `Part lacks {name}`)
      end

      for _, name in { "FillColor", "OutlineColor", "FillTransparency", "Adornee" } do
        check(table.find(highlight, name) ~= nil, `Highlight lacks {name}`)
      end

      -- derived from what is listed, and moving a part is its effect's business
      for _, name in { "Position", "Orientation", "BrickColor" } do
        check(table.find(part, name) == nil, `Part lists {name}`)
      end
    end,
  },
}
