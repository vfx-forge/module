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

/**
 * Options for init.
 */
export interface InitOptions {
	/**
	 * Whether ModuleScripts tagged VFXForgeEffect are found and registered as custom effects.
	 * True when left out.
	 */
	discover?: boolean;
}

/**
 * Initialize the Forge VFX system, registering every custom effect tagged VFXForgeEffect.
 */
export function init(options?: InitOptions): void;

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
 * For other instances, sets the "Enabled" attribute, in the attribute cache
 * when the instance's attributes are cached.
 * A lightning, bezier or mesh instance starts emitting at its Rate at once,
 * with or without the ConstantVFX tag; in Studio edit mode it also gets the
 * tag, so the place saves with it.
 * @param obj The instance to enable (propagates to descendants)
 */
export function enable(obj: Instance): void;

/**
 * Disable a VFX instance and all its descendants.
 * For ParticleEmitters and Beams, sets the Enabled property directly.
 * For other instances, sets the "Enabled" attribute, in the attribute cache
 * when the instance's attributes are cached.
 * A lightning, bezier or mesh instance stops emitting at its Rate. An emit
 * with an EmitDuration still running keeps going. In Studio edit mode the
 * ConstantVFX tag is removed; in a running game it stays.
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

/**
 * A registered effect, built-in or custom, as the runtime holds it.
 */
export interface RegisteredEffect {
	readonly id: string;
	readonly display: {
		readonly name: string;
		readonly icon?: string;
		readonly order?: number;
		readonly category?: SDK.Category;
	};
	readonly classifier: string;
}

/**
 * Every registered effect, built-in and custom, to read and never to change.
 */
export const effects: {
	/** Every registered effect, in the order the panel shows them. */
	list(): ReadonlyArray<RegisteredEffect>;
	/** The effect registered under an id. */
	get(id: string): RegisteredEffect | undefined;
};

/**
 * The custom effect SDK, version 1. A custom effect is a ModuleScript tagged VFXForgeEffect
 * whose module is an SDK.Effect; every method of it is handed the facade, SDK.V1, first.
 */
export namespace SDK {
	/** A param's rule, run with the read's ctx and the other params. */
	export type Rule = (
		ctx: Ctx,
		attrs: Record<string, unknown>,
		props: Record<string, unknown>,
	) => unknown;

	/** What a number param measures. */
	export type Unit =
		| "seconds"
		| "perSecond"
		| "perSecondSquared"
		| "studs"
		| "studsPerSecond"
		| "studsPerSecondSquared";

	/** The built-ins an effect is grouped with in the adder. */
	export type Category =
		| "emitters"
		| "meshes"
		| "paths"
		| "shockwaves"
		| "camera"
		| "motion";

	/** A param: one row in the panel and one value in attrs or props. */
	export interface Knob {
		/** The lowest value, a number or one of the value's own type. */
		min(value: unknown): Knob;
		/** The highest value, a number or one of the value's own type. */
		max(value: unknown): Knob;
		/** Older names the value is still read under. */
		aliases(...names: string[]): Knob;
		/** The strings a text param may hold, shown as a dropdown. */
		options(list: string[]): Knob;
		/** The row's name in the panel. */
		label(text: string): Knob;
		/** The row's tooltip. */
		hint(text: string): Knob;
		/** A curve param edited in the curve editor, starting as this preset. */
		curve(preset: string): Knob;
		/** What the number measures. */
		unit(unit: Unit): Knob;
		/** Hides the row while the rule answers true. */
		hidden(rule: Rule): Knob;
		/** Locks the row to its default while the rule answers true. */
		readonly(rule: Rule): Knob;
		/** A value modifiers can animate, read as a Track, with default modifiers. */
		mod(...mods: Mod[]): Knob;
	}

	/** A default modifier on an animated param. */
	export interface Mod {
		/** Seconds it runs, or a rule answering them. */
		duration(seconds: number | Rule): Mod;
		/** The preset or curve param value it eases with. */
		curve(shape: string | Rule): Mod;
		/** Seconds it waits before it starts. */
		delay(seconds: number | Rule): Mod;
		/** The moment of the effect it runs from. */
		lane(name: "start" | "end"): Mod;
	}

	/** What params answers. */
	export interface Params {
		/** Params stored as attributes, by name. */
		attributes?: Record<string, Knob>;
		/** Params that are properties of the emitted instance, by property name. */
		properties?: Record<string, Knob>;
	}

	/** An animated param's value. */
	export interface Track<T = unknown> {
		/** The value at the start. */
		readonly value: T;
		/** False when no modifier moves it. */
		readonly animated: boolean;
		/** Seconds the modifiers run. */
		readonly duration: number;
		/** The value at a time in seconds. */
		at(elapsed: number): T;
	}

	/** What emit is handed about the instance it plays. */
	export interface Ctx {
		/** The instance being emitted. */
		readonly ref: Instance;
		/** The effect's length in seconds, from duration, else 1. */
		readonly duration: number;
		/** True when an Enabled loop emitted it. */
		readonly constant?: boolean;
	}

	/** A value over time. */
	export interface Curve {
		/** Seconds it runs. */
		readonly duration: number;
		/** The value at t, 0 to 1 over the curve. */
		at(t: number): number;
	}

	/** A preset's name, a curve param's value, a chain of points, or a function of t from 0 to 1. */
	export type CurveShape =
		| string
		| buffer
		| Vector3[]
		| ((t: number) => number);

	/** One property or attribute this effect writes, handed over between overlapping emits and put back at the end. */
	export interface Writer<T = unknown> {
		/** Writes the value now. */
		set(value: T): void;
	}

	/** A group of pieces the effect waits for. */
	export interface Join {
		readonly _nominal_Join: never;
	}

	/** A 3D path through a chain of points. */
	export interface Bezier {
		/** New points, in the same format. */
		set(points: Vector3[]): void;
		/** The point at t, 0 to 1 with each segment an equal share. */
		at(t: number): Vector3;
		/** The point u of the way along by distance, 0 to 1. */
		atUniform(u: number): Vector3;
		/** The length in studs. */
		length(): number;
		/** The unit direction of travel at t, zero where the path stands still. */
		tangent(t: number): Vector3;
	}

	/** Where a shape draws its point. */
	export interface ShapeOptions {
		/** On the surface rather than inside. */
		surface?: boolean;
		/** How much of the shape it draws from, 0 to 1. */
		partial?: number;
		/** The way the shape faces, Top when none is given. */
		normal?: Enum.NormalId;
		/** The same seed draws the same point. */
		seed?: number;
	}

	/** A random point in a shape at cframe with size, in world space. */
	export type ShapeFunction = (
		cframe: CFrame,
		size: Vector3,
		options?: ShapeOptions,
	) => Vector3;

	/** What every method of a custom effect is handed first. */
	export interface V1 {
		/** A param with its default value, or a rule answering it. */
		knob(defaultValue?: unknown): Knob;
		/** Default modifiers for an animated param. */
		readonly mod: {
			/** Runs from value to the param's own value. */
			from(value: unknown): Mod;
			/** Runs from the param's own value to value. */
			to(value: unknown): Mod;
		};
		/** Waits seconds of effect time, and answers the seconds waited. */
		wait(ctx: Ctx, seconds: number): number;
		/** Calls fn every frame, and answers a function that stops it. */
		step(ctx: Ctx, fn: (dt: number, elapsed: number) => void): () => void;
		/** A curve running for duration seconds. */
		curve(
			duration: number,
			shape: CurveShape,
			options?: Record<string, never>,
		): Curve;
		/** Plays the curve on effect time, calling fn with each value; the effect waits for it. */
		tween(ctx: Ctx, curve: Curve, fn: (alpha: number) => void): void;
		/** Cleans thing up when the effect ends. */
		hold<T extends Instance | RBXScriptConnection | Callback | thread>(
			ctx: Ctx,
			thing: T,
		): T;
		/** A group of pieces the effect waits for. */
		join(ctx: Ctx): Join;
		/** Runs fn on a thread of its own, counted into join. */
		spawn<A extends unknown[]>(
			join: Join,
			fn: (...args: A) => void,
			...args: A
		): void;
		/** Waits until every piece of join is done. */
		await(join: Join): void;
		/** Emits instance as a nested effect the effect waits for. */
		emit(ctx: Ctx, instance: Instance): void;
		/** A writer for a property of obj. */
		getWriter<T = unknown>(
			ctx: Ctx,
			obj: Instance,
			property: string,
		): Writer<T>;
		/** A writer for an attribute of obj. */
		getAttributeWriter<T = unknown>(
			ctx: Ctx,
			obj: Instance,
			name: string,
		): Writer<T>;
		/** Runs the effect's time at an animated param's value. */
		speed(ctx: Ctx, track: Track<number>): void;
		/** t of the way from a to b, for any value that blends. */
		lerp<T>(a: T, b: T, t: number): T;
		/** Colors blended the way eyes see them. */
		readonly color: {
			/** t of the way from a to b, in Oklab. */
			blend(a: Color3, b: Color3, t: number): Color3;
			/** A color as Oklab lightness and its two hues. */
			toOklab(color: Color3): Vector3;
			/** An Oklab value back as a color, clamped into range. */
			fromOklab(lab: Vector3): Color3;
		};
		/** Random points in shapes. */
		readonly shape: {
			/** A point in a box. */
			box: ShapeFunction;
			/** A point in a cylinder whose axis runs along the normal. */
			cylinder: ShapeFunction;
			/** A point in a sphere. */
			sphere: ShapeFunction;
			/** A point in a disc lying across the normal. */
			disc: ShapeFunction;
		};
		/** 3D paths. */
		readonly bezier: {
			/** A path through 3n + 1 points, or 2 for a straight one. */
			new (points: Vector3[]): Bezier;
		};
	}

	/** A custom effect module. */
	export interface Effect {
		/** The facade version it is written against. */
		sdk_version: 1;
		/** Unique across every effect. */
		id: string;
		/** How the panel shows it, and the built-ins the adder groups it with, under Custom when none. */
		display: { name: string; icon?: string; category?: Category };
		/** The selector an instance must match to play it. */
		classifier: string;
		/** A selector for the descendants it plays itself. */
		components?: string;
		/** The panel's rows: param names and groups of them. */
		layout?: unknown[];
		/** True when an Enabled loop may emit it. */
		constant?: boolean;
		/** The params, called once per load. */
		params?(sdk: V1): Params;
		/** The effect's length in seconds. */
		duration?(
			sdk: V1,
			attrs: Record<string, unknown>,
			props: Record<string, unknown>,
		): number;
		/** Plays the effect on ctx.ref. */
		emit(
			sdk: V1,
			ctx: Ctx,
			attrs: Record<string, unknown>,
			props: Record<string, unknown>,
		): void;
		/** Called on the old version before a reload drops it. */
		unload?(): void;
		/** A new instance the classifier finds, unparented, made by the plugin's adder. */
		template?(sdk: V1): Instance;
	}
}
