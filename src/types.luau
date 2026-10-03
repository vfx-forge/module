local Promise = require("@pkg/Promise")
local lifetime = require("@mod/lifetime")
local ObjectCache = require("@obj/ObjectCache")

export type scope = lifetime.effect

export type EmitOptions = {
  priority: number?,
}

export type EmitEnv = {
  Finished: typeof(Promise.resolve()),
  Clear: (self: EmitEnv) -> (),
  SetSpeed: (self: EmitEnv, speed: number) -> (),
  GetSpeed: (self: EmitEnv) -> number,
  Pause: (self: EmitEnv) -> (),
  Resume: (self: EmitEnv) -> (),
  IsPaused: (self: EmitEnv) -> boolean,
  SetPriority: (self: EmitEnv, priority: number) -> (),
  GetPriority: (self: EmitEnv) -> number,
}

export type ApiCaches = {
  shared_part: ObjectCache.ObjectCache,
}

export type EffectsService = {
  init: (api: Api) -> (),
  deinit: () -> (),

  emit: (depth: number, ...any) -> EmitEnv,
  emitNested: (part: Instance, depth: number, parentScope: scope?, join: lifetime.join?) -> (),
  emitFromFolder: (
    folder: Folder?,
    targetParent: Instance,
    depth: number,
    parentScope: scope?,
    join: lifetime.join?
  ) -> (),
  emitOnFinish: (
    emitOnFinish: Folder?,
    targetParent: Instance,
    depth: number,
    parentScope: scope?,
    join: lifetime.join?
  ) -> (),

  prepareEmitFolder: (obj: Instance, folderName: string, scope: scope) -> Folder?,
  prepareEmitOnFinish: (obj: Instance, scope: scope) -> Folder?,
}

export type Api = {
  setup: boolean,

  scope: { unknown },
  caches: ApiCaches,

  init: (params: any?) -> (),
  deinit: () -> (),

  emit: (vfxOrScale: number | Instance, ...any) -> EmitEnv,
  emitWithDepth: (depth: number, ...Instance) -> EmitEnv,
}

return {}
