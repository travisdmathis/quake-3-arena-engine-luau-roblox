--[[
SPDX-License-Identifier: GPL-2.0-or-later

Shared mover trajectory rules translated from Quake III Arena:
  code/game/bg_misc.c (BG_EvaluateTrajectory, BG_EvaluateTrajectoryDelta)
  code/game/g_mover.c (SetMoverState, Use_BinaryMover)
  code/cgame/cg_ents.c (CG_AdjustPositionForMover)

The strict immutable validation boundary and Vector3/Roblox coordinate adapter
are original the Roblox Luau port adaptations. Time remains integer milliseconds at
this boundary so later server and prediction consumers cannot evaluate movers
from unrelated wall clocks.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Constants = require(script.Parent.Constants)

export type TrajectoryKind = "Stationary" | "Interpolate" | "Linear" | "LinearStop" | "Sine" | "Gravity"

export type Trajectory = {
	kind: TrajectoryKind,
	startTimeMilliseconds: number,
	durationMilliseconds: number,
	base: Vector3,
	delta: Vector3,
}

export type BinaryState = "Pos1" | "Pos2" | "OneToTwo" | "TwoToOne"

local MoverTrajectory = {}

local Kinds = table.freeze({
	Stationary = "Stationary" :: TrajectoryKind,
	Interpolate = "Interpolate" :: TrajectoryKind,
	Linear = "Linear" :: TrajectoryKind,
	LinearStop = "LinearStop" :: TrajectoryKind,
	Sine = "Sine" :: TrajectoryKind,
	Gravity = "Gravity" :: TrajectoryKind,
})

local BinaryStates = table.freeze({
	Pos1 = "Pos1" :: BinaryState,
	Pos2 = "Pos2" :: BinaryState,
	OneToTwo = "OneToTwo" :: BinaryState,
	TwoToOne = "TwoToOne" :: BinaryState,
})

local MAXIMUM_TIME_MILLISECONDS = 2_147_483_647
local MAXIMUM_COMPONENT = 1_000_000
local TWO_PI = math.pi * 2

local TRAJECTORY_KEYS: { [string]: boolean } = {
	kind = true,
	startTimeMilliseconds = true,
	durationMilliseconds = true,
	base = true,
	delta = true,
}
table.freeze(TRAJECTORY_KEYS)

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isIntegerTime(value: unknown): boolean
	return isFiniteNumber(value)
		and (value :: number) % 1 == 0
		and math.abs(value :: number) <= MAXIMUM_TIME_MILLISECONDS
end

local function isBoundedVector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFiniteNumber(vector.X)
		and isFiniteNumber(vector.Y)
		and isFiniteNumber(vector.Z)
		and math.abs(vector.X) <= MAXIMUM_COMPONENT
		and math.abs(vector.Y) <= MAXIMUM_COMPONENT
		and math.abs(vector.Z) <= MAXIMUM_COMPONENT
end

local function isTrajectoryKind(value: unknown): boolean
	return value == Kinds.Stationary
		or value == Kinds.Interpolate
		or value == Kinds.Linear
		or value == Kinds.LinearStop
		or value == Kinds.Sine
		or value == Kinds.Gravity
end

local function hasExactKeys(value: { [unknown]: unknown }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or TRAJECTORY_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 5
end

function MoverTrajectory.Validate(value: unknown): (Trajectory?, string?)
	if type(value) ~= "table" then
		return nil, "trajectory-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not hasExactKeys(source) then
		return nil, "invalid-trajectory-shape"
	end
	if not isTrajectoryKind(source.kind) then
		return nil, "invalid-trajectory-kind"
	end
	if not isIntegerTime(source.startTimeMilliseconds) then
		return nil, "invalid-trajectory-start-time"
	end
	if not isIntegerTime(source.durationMilliseconds) or (source.durationMilliseconds :: number) < 0 then
		return nil, "invalid-trajectory-duration"
	end
	if (source.kind == Kinds.LinearStop or source.kind == Kinds.Sine) and source.durationMilliseconds == 0 then
		return nil, "trajectory-duration-must-be-positive"
	end
	if not isBoundedVector(source.base) then
		return nil, "invalid-trajectory-base"
	end
	if not isBoundedVector(source.delta) then
		return nil, "invalid-trajectory-delta"
	end

	return table.freeze({
		kind = source.kind :: TrajectoryKind,
		startTimeMilliseconds = source.startTimeMilliseconds :: number,
		durationMilliseconds = source.durationMilliseconds :: number,
		base = source.base :: Vector3,
		delta = source.delta :: Vector3,
	}),
		nil
end

local function assertEvaluationTime(atTimeMilliseconds: number)
	assert(isIntegerTime(atTimeMilliseconds), "mover evaluation time must be a bounded integer")
end

function MoverTrajectory.Evaluate(trajectory: Trajectory, atTimeMilliseconds: number): Vector3
	assertEvaluationTime(atTimeMilliseconds)
	local kind = trajectory.kind
	if kind == Kinds.Stationary or kind == Kinds.Interpolate then
		return trajectory.base
	end

	local evaluationTime = atTimeMilliseconds
	if kind == Kinds.LinearStop then
		evaluationTime = math.min(evaluationTime, trajectory.startTimeMilliseconds + trajectory.durationMilliseconds)
	end
	local elapsedSeconds = (evaluationTime - trajectory.startTimeMilliseconds) * 0.001
	if kind == Kinds.LinearStop then
		elapsedSeconds = math.max(elapsedSeconds, 0)
	end

	if kind == Kinds.Linear or kind == Kinds.LinearStop then
		return trajectory.base + trajectory.delta * elapsedSeconds
	elseif kind == Kinds.Sine then
		local phase =
			math.sin((evaluationTime - trajectory.startTimeMilliseconds) / trajectory.durationMilliseconds * TWO_PI)
		return trajectory.base + trajectory.delta * phase
	end

	assert(kind == Kinds.Gravity, "unknown validated mover trajectory kind")
	return trajectory.base
		+ trajectory.delta * elapsedSeconds
		- Vector3.yAxis * (0.5 * Constants.Gravity * elapsedSeconds * elapsedSeconds)
end

function MoverTrajectory.EvaluateDelta(trajectory: Trajectory, atTimeMilliseconds: number): Vector3
	assertEvaluationTime(atTimeMilliseconds)
	local kind = trajectory.kind
	if kind == Kinds.Stationary or kind == Kinds.Interpolate then
		return Vector3.zero
	elseif kind == Kinds.Linear then
		return trajectory.delta
	elseif kind == Kinds.LinearStop then
		if atTimeMilliseconds > trajectory.startTimeMilliseconds + trajectory.durationMilliseconds then
			return Vector3.zero
		end
		return trajectory.delta
	elseif kind == Kinds.Sine then
		-- This deliberately preserves Q3's published implementation: the routine
		-- returns delta * cos(phase) * 0.5 rather than the mathematical derivative.
		local phase =
			math.cos((atTimeMilliseconds - trajectory.startTimeMilliseconds) / trajectory.durationMilliseconds * TWO_PI)
		return trajectory.delta * phase * 0.5
	end

	assert(kind == Kinds.Gravity, "unknown validated mover trajectory kind")
	local elapsedSeconds = (atTimeMilliseconds - trajectory.startTimeMilliseconds) * 0.001
	return trajectory.delta - Vector3.yAxis * (Constants.Gravity * elapsedSeconds)
end

local function makeTrajectory(
	kind: TrajectoryKind,
	startTimeMilliseconds: number,
	durationMilliseconds: number,
	base: Vector3,
	delta: Vector3
): Trajectory
	local trajectory, validationError = MoverTrajectory.Validate({
		kind = kind,
		startTimeMilliseconds = startTimeMilliseconds,
		durationMilliseconds = durationMilliseconds,
		base = base,
		delta = delta,
	})
	assert(trajectory, validationError or "invalid generated mover trajectory")
	return trajectory
end

function MoverTrajectory.SetBinaryState(
	position1: Vector3,
	position2: Vector3,
	durationMilliseconds: number,
	state: BinaryState,
	startTimeMilliseconds: number
): Trajectory
	assert(isBoundedVector(position1) and isBoundedVector(position2), "invalid binary positions")
	assert(
		isIntegerTime(durationMilliseconds) and durationMilliseconds >= 1,
		"binary duration must be a positive bounded integer"
	)
	assert(isIntegerTime(startTimeMilliseconds), "invalid binary start time")

	if state == BinaryStates.Pos1 then
		return makeTrajectory(Kinds.Stationary, startTimeMilliseconds, 0, position1, Vector3.zero)
	elseif state == BinaryStates.Pos2 then
		return makeTrajectory(Kinds.Stationary, startTimeMilliseconds, 0, position2, Vector3.zero)
	end

	local base: Vector3
	local destination: Vector3
	if state == BinaryStates.OneToTwo then
		base = position1
		destination = position2
	else
		assert(state == BinaryStates.TwoToOne, "invalid binary mover state")
		base = position2
		destination = position1
	end
	local delta = (destination - base) * (1000 / durationMilliseconds)
	return makeTrajectory(Kinds.LinearStop, startTimeMilliseconds, durationMilliseconds, base, delta)
end

function MoverTrajectory.ReversedStartTime(
	currentStartTimeMilliseconds: number,
	durationMilliseconds: number,
	atTimeMilliseconds: number
): number
	assert(isIntegerTime(currentStartTimeMilliseconds), "invalid binary current start time")
	assert(isIntegerTime(durationMilliseconds) and durationMilliseconds >= 1, "invalid binary duration")
	assert(isIntegerTime(atTimeMilliseconds), "invalid binary reversal time")
	-- Use_BinaryMover caps only the upper progress bound. A synchronous second
	-- use can reverse during the 50 ms future-start window, producing negative
	-- partial progress and, legitimately, a signed negative replacement start.
	local partial = math.min(atTimeMilliseconds - currentStartTimeMilliseconds, durationMilliseconds)
	return atTimeMilliseconds - (durationMilliseconds - partial)
end

function MoverTrajectory.AdjustPositionForMover(
	position: Vector3,
	positionTrajectory: Trajectory,
	fromTimeMilliseconds: number,
	toTimeMilliseconds: number
): Vector3
	-- CG_AdjustPositionForMover intentionally applies only translation. Q3's
	-- corresponding rotational origin adjustment is itself left as a FIXME.
	local oldOrigin = MoverTrajectory.Evaluate(positionTrajectory, fromTimeMilliseconds)
	local newOrigin = MoverTrajectory.Evaluate(positionTrajectory, toTimeMilliseconds)
	return position + (newOrigin - oldOrigin)
end

MoverTrajectory.Kinds = Kinds
MoverTrajectory.BinaryStates = BinaryStates
MoverTrajectory.BinaryActivationDelayMilliseconds = 50
MoverTrajectory.MaximumTimeMilliseconds = MAXIMUM_TIME_MILLISECONDS

return table.freeze(MoverTrajectory)
