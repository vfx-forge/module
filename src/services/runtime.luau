local lazy = require("@mod/lazy")

-- what every emit runs on, as one unit: the dispatch, the pool and what an
-- instance's loops and frame sets are kept in
return lazy.unit("runtime", function()
  return {
    pool = require("@srv/pool"),
    mover = require("@srv/mover"),
    effects = require("@srv/effects"),
    frame_store = require("@srv/frame_store"),
    texture_loader = require("@srv/texture_loader"),
    enabled_effects = require("@srv/enabled_effects"),
  }
end)
