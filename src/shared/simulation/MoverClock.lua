--[[
SPDX-License-Identifier: GPL-2.0-or-later

Deterministic mover-time adapter for Quake III Arena's integer level clock:
  code/game/g_main.c (level.previousTime, level.time, G_RunFrame)
  code/game/g_mover.c (G_MoverTeam)
  code/cgame/cg_predict.c (cg.physicsTime and mover prediction)

Q3 receives integer-millisecond server times. the Roblox Luau port advances gameplay
on a fixed 60 Hz simulation, so this module derives those milliseconds from a
server-owned step index using an exact rational conversion. Clients may replay
a received step index; they never submit mover time.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local MoverTrajectory = require(script.Parent.MoverTrajectory)

export type Snapshot = {
	revision: number,
	step: number,
}

export type Window = {
	revision: number,
	fromStep: number,
	toStep: number,
	fromTimeMilliseconds: number,
	toTimeMilliseconds: number,
}

local MoverClock = {}

local STEPS_PER_SECOND = 60
local MILLISECONDS_PER_SECOND = 1_000
local MAXIMUM_REVISION = 2_147_483_647
local MAXIMUM_STEP = math.floor(MoverTrajectory.MaximumTimeMilliseconds * STEPS_PER_SECOND / MILLISECONDS_PER_SECOND)

local SNAPSHOT_KEYS: { [string]: boolean } = {
	revision = true,
	step = true,
}
table.freeze(SNAPSHOT_KEYS)

local function isBoundedInteger(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function hasExactSnapshotKeys(value: { [unknown]: unknown }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or SNAPSHOT_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 2
end

function MoverClock.TimeForStep(stepValue: unknown): number?
	if not isBoundedInteger(stepValue, 0, MAXIMUM_STEP) then
		return nil
	end
	local step = stepValue :: number
	-- floor(x + 0.5) is deterministic here because both operands are bounded
	-- integers and the 60 Hz rational remains far below IEEE-754's exact-int cap.
	return math.floor(step * MILLISECONDS_PER_SECOND / STEPS_PER_SECOND + 0.5)
end

function MoverClock.ValidateSnapshot(value: unknown): (Snapshot?, string?)
	if type(value) ~= "table" then
		return nil, "snapshot-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not hasExactSnapshotKeys(source) then
		return nil, "invalid-snapshot-shape"
	end
	if not isBoundedInteger(source.revision, 1, MAXIMUM_REVISION) then
		return nil, "invalid-snapshot-revision"
	end
	if not isBoundedInteger(source.step, 0, MAXIMUM_STEP) then
		return nil, "invalid-snapshot-step"
	end
	local snapshot: Snapshot = {
		revision = source.revision :: number,
		step = source.step :: number,
	}
	table.freeze(snapshot)
	return snapshot, nil
end

function MoverClock.Create(revisionValue: unknown, stepValue: unknown?): (Snapshot?, string?)
	return MoverClock.ValidateSnapshot({
		revision = revisionValue,
		step = if stepValue == nil then 0 else stepValue,
	})
end

function MoverClock.WindowFor(snapshotValue: unknown): (Window?, string?)
	local snapshot, snapshotError = MoverClock.ValidateSnapshot(snapshotValue)
	if not snapshot then
		return nil, snapshotError
	end
	if snapshot.step >= MAXIMUM_STEP then
		return nil, "mover-clock-exhausted"
	end
	local toStep = snapshot.step + 1
	local window: Window = {
		revision = snapshot.revision,
		fromStep = snapshot.step,
		toStep = toStep,
		fromTimeMilliseconds = MoverClock.TimeForStep(snapshot.step) :: number,
		toTimeMilliseconds = MoverClock.TimeForStep(toStep) :: number,
	}
	table.freeze(window)
	return window, nil
end

function MoverClock.Advance(snapshotValue: unknown): (Snapshot?, string?)
	local window, windowError = MoverClock.WindowFor(snapshotValue)
	if not window then
		return nil, windowError
	end
	local snapshot: Snapshot = {
		revision = window.revision,
		step = window.toStep,
	}
	table.freeze(snapshot)
	return snapshot, nil
end

MoverClock.StepsPerSecond = STEPS_PER_SECOND
MoverClock.MillisecondsPerSecond = MILLISECONDS_PER_SECOND
MoverClock.MaximumRevision = MAXIMUM_REVISION
MoverClock.MaximumStep = MAXIMUM_STEP

return table.freeze(MoverClock)
