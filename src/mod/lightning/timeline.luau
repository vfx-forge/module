export type Plan = {
  appear: string,
  disappear: string,
  appearTime: number,
  hold: number,
  still: number,
  wait: number,
  disappearTime: number,
  strikes: { number },
  total: number,
}

export type State = {
  visible: boolean,
  strike: number,
  head: number,
  tail: number,
  width: number,
  glow: number,
  opacity: number,
  flash: number,
}

type range = { Min: number, Max: number }

type rows = {
  appear: string,
  appearTime: range,
  hold: range,
  restrikes: number,
  disappear: string,
  disappearTime: number,
}

const BLINK = 0.04
const FLASH_FALL = 0.15
const FLASH_REST = 0.6

const timeline = {
  BLINK = BLINK,
  LEADER_WIDTH = 0.35,
  LEADER_GLOW = 0.3,
}

const function clamp01(x: number): number
  return math.clamp(x, 0, 1)
end

-- a zero length phase is done the moment it starts, never a division by zero
const function progress(elapsed: number, length: number): number
  if length <= 0 then
    return if elapsed >= 0 then 1 else 0
  end

  return clamp01(elapsed / length)
end

-- fadeAt, when given, holds the bolt until then before it disappears (never sooner than its own hold ends): its
-- restrikes stay within its own hold, which ends at still, and it waits wait seconds after that in its last shape
function timeline.plan(next: () -> number, rows: rows, fadeAt: number?): Plan
  const appearTime = rows.appearTime.Min + (rows.appearTime.Max - rows.appearTime.Min) * next()
  const hold = rows.hold.Min + (rows.hold.Max - rows.hold.Min) * next()
  const strikes = { 0 }
  -- every gap is two blinks at least, so blinks never merge or run past the hold
  const restrikes = math.min(rows.restrikes, math.max(0, math.floor(hold / (2 * BLINK)) - 1))
  const gap = hold / (restrikes + 1)

  for i = 1, restrikes do
    table.insert(strikes, appearTime + gap * i + (next() * 2 - 1) * gap / 4)
  end

  const still = appearTime + hold
  const wait = if fadeAt then math.max(0, fadeAt - still) else 0

  return {
    appear = rows.appear,
    disappear = rows.disappear,
    appearTime = appearTime,
    hold = hold + wait,
    still = still,
    wait = wait,
    disappearTime = rows.disappearTime,
    strikes = strikes,
    total = appearTime + hold + wait + rows.disappearTime,
  }
end

function timeline.duration(rows: rows): number
  return rows.appearTime.Max + rows.hold.Max + rows.disappearTime
end

function timeline.at(plan: Plan, t: number, appearCurve: (number) -> number, disappearCurve: (number) -> number): State
  const state: State = {
    visible = true,
    strike = 1,
    head = 1,
    tail = 0,
    width = 1,
    glow = 1,
    opacity = 1,
    flash = 1,
  }

  if t < 0 or t > plan.total then
    state.visible = false

    return state
  end

  const holdEnd = plan.appearTime + plan.hold
  const strikes = plan.strikes

  for i = 2, #strikes do
    if t >= strikes[i] then
      state.strike = i
    end
  end

  if state.strike > 1 and t < strikes[state.strike] + BLINK then
    state.visible = false
  end

  if t < plan.appearTime then
    if plan.appear ~= "Instant" then
      state.head = clamp01(appearCurve(progress(t, plan.appearTime)))
    end

    if plan.appear == "Strike" then
      state.width = timeline.LEADER_WIDTH
      state.glow = timeline.LEADER_GLOW
      state.flash = 0
    end
  end

  if plan.appear == "Strike" and t >= plan.appearTime then
    -- a restrike is first seen once its blink is over, so its flash falls from there
    const since = t - (if state.strike > 1 then strikes[state.strike] + BLINK else plan.appearTime)

    state.flash = FLASH_REST + (1 - FLASH_REST) * (1 - progress(since, FLASH_FALL))
  end

  if t >= holdEnd then
    const elapsed = t - holdEnd
    const eased = clamp01(disappearCurve(progress(elapsed, plan.disappearTime)))

    state.flash *= 1 - eased

    if plan.disappear == "Thin" then
      state.width = 1 - eased
    elseif plan.disappear == "Fade" then
      state.opacity = 1 - eased
    elseif plan.disappear == "Retract" then
      state.tail = eased
    elseif plan.disappear == "Recoil" then
      state.head = 1 - eased
    end
  end

  if not state.visible then
    state.flash = 0
  end

  return state
end

-- whether a bolt keeps its shape at t: only while it waits for the emit's common fade
function timeline.waiting(plan: Plan, t: number): boolean
  return plan.wait > 0 and t >= plan.still and t < plan.still + plan.wait
end

-- the time a bolt's motion has run by t, less the wait it spent in its last shape, so it moves on from there
function timeline.moving(plan: Plan, t: number): number
  if t < plan.still then
    return t
  end

  return math.max(plan.still, t - plan.wait)
end

-- a Highlight draws nothing over a part that is not opaque, a Part or an EditableMesh at Transparency 0.02 or 0.2
-- alike (measured 2026-10-24), so a covered bolt lifts its Highlight away over the first half of a fade, opaque
-- underneath, and fades its own parts over the second
function timeline.cover(opacity: number): (number, number)
  return clamp01(2 * opacity - 1), clamp01(2 * opacity)
end

return timeline
