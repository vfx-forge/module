/**
 * Result returned from emitting VFX effects
 */
export interface EmitResult {
  /**
   * Promise that resolves when the effect has finished playing, has been cleared, or its module was deinitialized
   */
  Finished: Promise<void>;

  /**
   * Clear all emitted effects
   */
  Clear(): void;

  /**
   * Set the speed every effect of this emit runs at, from the next frame. It multiplies with
   * the global setSpeed, any controller over the effects and each effect's own Speed.
   * Errors unless it is a finite number of 0 or more. Once the emit has finished this does
   * nothing.
   * @param speed 1 is authored speed, 0.5 half, 2 double
   */
  SetSpeed(speed: number): void;

  /**
   * The speed last set with SetSpeed, 1 by default. Pausing does not change it. Reads 1 once
   * the emit has finished.
   */
  GetSpeed(): number;

  /**
   * Stand every effect of this emit still, from the next frame, until Resume. Once the emit
   * has finished this does nothing.
   */
  Pause(): void;

  /**
   * Pick every effect of this emit up where Pause left it, at the speed it had.
   */
  Resume(): void;

  /**
   * Whether this emit is paused by its own Pause. A global pause does not count. Reads false
   * once the emit has finished.
   */
  IsPaused(): boolean;

  /**
   * Rank every write this emit and the emits it starts make against another emit's, from
   * now: on a property or attribute two emits write at once, the higher priority owns it,
   * and at one priority the newer emit does. Warns and keeps the priority unless it is a
   * finite number. Once the emit has finished this does nothing.
   * @param priority 0 by default; higher wins
   */
  SetPriority(priority: number): void;

  /**
   * The priority set with the emit's options or SetPriority, 0 by default.
   */
  GetPriority(): number;
}

/**
 * Options an emit may end with, after its instances.
 */
export interface EmitOptions {
  /**
   * How this emit's writes rank against another emit's on a property or attribute both
   * write: the higher priority owns it, and at one priority the newer emit does. 0 by
   * default. Anything but a finite number warns and is 0.
   */
  priority?: number;
}

/**
 * A handler connected to one of the module's signals.
 */
export interface Connection {
  /**
   * Stop calling the handler
   */
  Disconnect(): void;
}

/**
 * A signal the module fires. Each handler is spawned on a thread of its own and runs
 * synchronously until it first yields, so a handler that yields cannot stall a frame of
 * effects.
 */
export interface Signal<T extends unknown[]> {
  Connect(handler: (...args: T) => void): Connection;
  Once(handler: (...args: T) => void): Connection;
}

/**
 * Set the global playback speed: every effect emitted from this copy of the module plays at
 * it, live, from the next frame. It multiplies with each emit's SetSpeed, any controller over
 * the effects and each effect's own Speed. Unlike retime, which rewrites an instance's
 * authored values, it leaves every instance as authored and changes only how fast it plays.
 * Errors unless it is a finite number of 0 or more, and the speed stays as it was.
 * @param speed 1 is authored speed, 0.5 half, 2 double
 */
export function setSpeed(speed: number): void;

/**
 * The global speed last set with setSpeed, 1 by default. Pausing does not change it, and
 * Global controllers are not counted in it (see getEffectiveSpeed).
 */
export function getSpeed(): number;

/**
 * Stand every effect emitted from this copy of the module still, from the next frame, until
 * resume. Each emit keeps its own speed and Pause under it. Calling it again does nothing.
 */
export function pause(): void;

/**
 * Pick every effect up where pause left it, at the speed it had. Calling it again does
 * nothing.
 */
export function resume(): void;

/**
 * Whether every effect is held by pause. An emit's own Pause does not count.
 */
export function isPaused(): boolean;

/**
 * The global speed times every Global controller running: the speed every effect plays at
 * before each emit's own. Pausing does not change it; isPaused reports that.
 */
export function getEffectiveSpeed(): number;

/**
 * Fires with getEffectiveSpeed's new value whenever it changes: on setSpeed, and as a Global
 * controller starts, ramps or ends, which can be every frame while one ramps.
 */
export const SpeedChanged: Signal<[effectiveSpeed: number]>;

/**
 * Fires with true on pause and false on resume, only when the global pause really changes.
 */
export const PausedChanged: Signal<[paused: boolean]>;

/**
 * Initialize the Forge VFX system.
 */
/**
 * What ForgeVFX would write to a property or attribute, for game code to read in place of
 * having it written. While any hook on a target is connected ForgeVFX never writes it, not
 * even to put it back at the end. The fields change only when an effect writes, so a read at
 * Camera priority or later sees this frame's value.
 */
export interface WriteHook<T> {
  /** False after Disconnect, or once the instance is destroyed. */
  readonly Connected: boolean;

  /** Whether any emit is writing the target. */
  readonly Active: boolean;

  /** The owning emit's value, frozen while it is paused; undefined when inactive. */
  readonly Value: T | undefined;

  /**
   * Value minus the first value of this active stretch (first:Inverse() * now for a CFrame).
   * The type's identity when inactive. Undefined for a type with no subtraction, such as
   * Color3, booleans, enums and sequences. On the camera's CFrame it is the camera shake,
   * applied with cf * Offset.
   */
  readonly Offset: T | undefined;

  /** The owning emit's priority; undefined when inactive. */
  readonly Priority: number | undefined;

  /**
   * Give the target back: if an emit is still writing it, what the game wrote meanwhile goes
   * back once that emit ends, and ForgeVFX writes it again from its next step.
   */
  Disconnect(): void;
}

/**
 * Read what ForgeVFX would write to a property instead of having it written.
 * hookProperty(workspace.CurrentCamera, "CFrame") hooks the camera shake: its Offset is the
 * shake, and the camera is left alone.
 */
export function hookProperty<T = unknown>(
  instance: Instance,
  property: string,
): WriteHook<T>;

/**
 * Read what ForgeVFX would write to an attribute instead of having it written.
 */
export function hookAttribute<T = unknown>(
  instance: Instance,
  name: string,
): WriteHook<T>;

export function init(): void;

/**
 * Clean up and shut down the Forge VFX system.
 * Destroys all caches and disconnects event handlers. The global speed goes
 * back to 1 and a global pause is lifted, firing SpeedChanged and
 * PausedChanged if either moved, so a later init starts at full speed.
 */
export function deinit(): void;

/**
 * Emit VFX effects from the provided instances.
 * Supports ParticleEmitters, Beams, Trails, Models, and tagged effects.
 * @param instances One or more Roblox instances to emit effects from
 * @returns Result object with a Finished promise
 */
export function emit(...instances: Instance[]): EmitResult;

/**
 * Emit VFX effects from the provided instances, with options after them.
 * @param args One or more Roblox instances, then an EmitOptions table
 * @returns Result object with a Finished promise
 */
export function emit(...args: [...instances: Instance[], options: EmitOptions]): EmitResult;

/**
 * Emit VFX effects with a scale multiplier.
 * @param scale Scale multiplier for the effect
 * @param instances One or more Roblox instances to emit effects from
 * @returns Result object with a Finished promise
 */
export function emit(scale: number, ...instances: Instance[]): EmitResult;

/**
 * Emit VFX effects with a scale multiplier, with options after the instances.
 * @param scale Scale multiplier for the effect
 * @param args One or more Roblox instances, then an EmitOptions table
 * @returns Result object with a Finished promise
 */
export function emit(scale: number, ...args: [...instances: Instance[], options: EmitOptions]): EmitResult;

/**
 * Emit VFX effects with a specific render depth.
 * @param depth Render priority depth for the effect
 * @param instances One or more Roblox instances to emit effects from
 * @returns Result object with a Finished promise
 */
export function emitWithDepth(
  depth: number,
  ...instances: Instance[]
): EmitResult;

/**
 * Enable a VFX instance and all its descendants.
 * For ParticleEmitters and Beams, sets the Enabled property directly.
 * For other instances, sets the "Enabled" attribute.
 * @param obj The instance to enable (propagates to descendants)
 */
export function enable(obj: Instance): void;

/**
 * Disable a VFX instance and all its descendants.
 * For ParticleEmitters and Beams, sets the Enabled property directly.
 * For other instances, sets the "Enabled" attribute.
 * @param obj The instance to disable (propagates to descendants)
 */
export function disable(obj: Instance): void;

/**
 * Scale the timing of VFX instances by a factor.
 * Adjusts speeds, lifetimes, durations, and rates across all effect types.
 * @param factor The time scale factor (>1 speeds up, <1 slows down)
 * @param instances One or more instances to retime (includes descendants)
 */
export function retime(factor: number, ...instances: Instance[]): void;

/**
 * Scale the size of VFX instances by a factor.
 * Adjusts particle sizes, beam widths, attachment distances, and more.
 * @param factor The size scale factor
 * @param instances One or more instances to resize (includes descendants)
 */
export function resize(factor: number, ...instances: Instance[]): void;

/**
 * Recolor VFX instances.
 * In "replace" mode, sets all colors to the given color (preserving HDR factor).
 * In "multiply" mode, blends the color with existing colors via HSV multiplication.
 * Skips BasePart descendants (only applies to directly passed BaseParts).
 * @param color The target color
 * @param mode "replace" to set colors directly, "multiply" to blend with existing
 * @param instances One or more instances to recolor (includes descendants)
 */
export function recolor(
  color: Color3,
  mode: "replace" | "multiply",
  ...instances: Instance[]
): void;

/**
 * Cache attributes for a VFX instance and optionally its descendants.
 * Strips attributes from instances and stores them in memory for faster access.
 * Only works on the client and for instances inside ReplicatedStorage.
 * @param obj The instance whose attributes to cache
 * @param shallow If true, only cache the instance itself (skip descendants)
 */
export function cacheAttributes(obj: Instance, shallow: boolean): void;

/**
 * Restore previously cached attributes back onto instances.
 * Only works on the client.
 * @param obj The instance whose attributes to restore
 * @param shallow If true, only restore the instance itself (skip descendants)
 */
export function restoreAttributes(obj: Instance, shallow?: boolean): void;
