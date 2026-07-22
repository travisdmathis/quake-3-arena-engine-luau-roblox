--[[
SPDX-License-Identifier: GPL-2.0-or-later

Data-only translation helpers for reviewed Quake III brush movers:
  code/game/g_mover.c (SP_func_door, SP_func_rotating, SP_func_bobbing,
    InitMover)
  code/game/bg_misc.c (BG_EvaluateTrajectory)

The helpers retain Q3 units and entity measurements at the authoring callsite,
then apply the arena's canonical (X, Z-up, -Y) transform once. Each call emits
one bounded Block. Compound inline models may preserve their reviewed Solid
brush bounds as synchronized members sharing one mover team.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-19.
]]

--!strict

local MapSchema = require(script.Parent.MapSchema)
local MoverTrajectory = require(script.Parent.Parent.simulation.MoverTrajectory)

local Q3MoverDefinitionBuilder = {}

export type VectorMeasurement = { number }
export type ModelBounds = {
	minimum: VectorMeasurement,
	maximum: VectorMeasurement,
	size: VectorMeasurement,
}
export type BobbingMeasurement = {
	id: string,
	teamId: string,
	sourceOrder: number,
	sourceEntityIndex: number,
	modelBounds: ModelBounds,
	heightQ3: number,
	cycleSeconds: number,
	phase: number,
	spawnFlags: number,
}
export type RotatingMeasurement = {
	id: string,
	teamId: string,
	sourceOrder: number,
	sourceEntityIndex: number,
	originQ3: VectorMeasurement,
	modelBounds: ModelBounds,
	speedDegreesPerSecond: number,
	spawnFlags: number,
}
export type DoorMeasurement = {
	id: string,
	teamId: string,
	sourceOrder: number,
	sourceEntityIndex: number,
	modelBounds: ModelBounds,
	angleDegrees: number,
	speedQ3PerSecond: number,
	waitSeconds: number,
	lipQ3: number,
	spawnFlags: number,
}

local SCALE = 0.1

local function finiteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function measurementVector(value: VectorMeasurement, label: string): Vector3
	assert(#value == 3, label .. " must contain three components")
	assert(
		finiteNumber(value[1]) and finiteNumber(value[2]) and finiteNumber(value[3]),
		label .. " must contain finite components"
	)
	return Vector3.new(value[1], value[2], value[3])
end

local function q3Point(value: Vector3): Vector3
	return Vector3.new(value.X * SCALE, value.Z * SCALE, -value.Y * SCALE)
end

local function q3Delta(value: Vector3): Vector3
	return q3Point(value)
end

local function q3Box(modelBounds: ModelBounds, label: string): (Vector3, Vector3, Vector3)
	local minimum = measurementVector(modelBounds.minimum, label .. ".minimum")
	local maximum = measurementVector(modelBounds.maximum, label .. ".maximum")
	local measuredSize = measurementVector(modelBounds.size, label .. ".size")
	local sourceSize = maximum - minimum
	assert(sourceSize.X > 0 and sourceSize.Y > 0 and sourceSize.Z > 0, label .. " must have positive bounds")
	assert((sourceSize - measuredSize).Magnitude <= 0.003, label .. ".size disagrees with bounds")
	local sourceCenter = (minimum + maximum) * 0.5
	local size = Vector3.new(sourceSize.X * SCALE, sourceSize.Z * SCALE, sourceSize.Y * SCALE)
	return q3Point(sourceCenter), size, sourceCenter
end

local function stationary(base: Vector3): MoverTrajectory.Trajectory
	return {
		kind = MoverTrajectory.Kinds.Stationary,
		startTimeMilliseconds = 0,
		durationMilliseconds = 0,
		base = base,
		delta = Vector3.zero,
	}
end

local function stationaryAngles(): MoverTrajectory.Trajectory
	return stationary(Vector3.zero)
end

local function checkedCommon(id: string, teamId: string, sourceOrder: number, sourceEntityIndex: number)
	assert(type(id) == "string" and #id > 0, "mover id must be non-empty")
	assert(type(teamId) == "string" and #teamId > 0, "mover teamId must be non-empty")
	assert(sourceOrder % 1 == 0 and sourceOrder > 0, "mover sourceOrder must be positive")
	assert(sourceEntityIndex % 1 == 0 and sourceEntityIndex > 0, "Q3 source entity index must be positive")
end

function Q3MoverDefinitionBuilder.Bobbing(measurement: BobbingMeasurement): MapSchema.Mover
	checkedCommon(measurement.id, measurement.teamId, measurement.sourceOrder, measurement.sourceEntityIndex)
	assert(finiteNumber(measurement.heightQ3) and measurement.heightQ3 > 0, "func_bobbing height must be positive")
	assert(
		finiteNumber(measurement.cycleSeconds) and measurement.cycleSeconds > 0,
		"func_bobbing cycle must be positive"
	)
	assert(
		finiteNumber(measurement.phase) and measurement.phase >= 0 and measurement.phase <= 1,
		"func_bobbing phase must be in [0, 1]"
	)
	local base, size = q3Box(measurement.modelBounds, string.format("func_bobbing[%d]", measurement.sourceEntityIndex))
	local sourceDelta = if bit32.band(measurement.spawnFlags, 1) ~= 0
		then Vector3.new(measurement.heightQ3, 0, 0)
		elseif bit32.band(measurement.spawnFlags, 2) ~= 0 then Vector3.new(0, measurement.heightQ3, 0)
		else Vector3.new(0, 0, measurement.heightQ3)
	local durationMilliseconds = math.max(1, math.floor(measurement.cycleSeconds * 1000))
	return {
		id = measurement.id,
		teamId = measurement.teamId,
		sourceOrder = measurement.sourceOrder,
		shape = MapSchema.ChunkShapes.Block,
		cframe = CFrame.new(base),
		size = size,
		trajectory = {
			kind = MoverTrajectory.Kinds.Sine,
			startTimeMilliseconds = math.floor(durationMilliseconds * measurement.phase),
			durationMilliseconds = durationMilliseconds,
			base = base,
			delta = q3Delta(sourceDelta),
		},
		angularTrajectory = stationaryAngles(),
		moverStop = false,
	}
end

function Q3MoverDefinitionBuilder.Rotating(measurement: RotatingMeasurement): MapSchema.Mover
	checkedCommon(measurement.id, measurement.teamId, measurement.sourceOrder, measurement.sourceEntityIndex)
	assert(
		finiteNumber(measurement.speedDegreesPerSecond) and measurement.speedDegreesPerSecond ~= 0,
		"func_rotating speed must be non-zero"
	)
	local _, size, localCenterQ3 =
		q3Box(measurement.modelBounds, string.format("func_rotating[%d]", measurement.sourceEntityIndex))
	local pivotQ3 = measurementVector(
		measurement.originQ3,
		string.format("func_rotating[%d].origin", measurement.sourceEntityIndex)
	)
	-- The authoritative schema currently accepts one centered Block per Q3
	-- gentity. Use the inline model's measured center so collision and visuals
	-- agree; the pivot-to-center delta remains recorded in the source evidence.
	local base = q3Point(pivotQ3 + localCenterQ3)
	local angularDelta = if bit32.band(measurement.spawnFlags, 4) ~= 0
		then Vector3.new(measurement.speedDegreesPerSecond, 0, 0)
		elseif bit32.band(measurement.spawnFlags, 8) ~= 0 then Vector3.new(
			0,
			0,
			-measurement.speedDegreesPerSecond
		)
		else Vector3.new(0, measurement.speedDegreesPerSecond, 0)
	return {
		id = measurement.id,
		teamId = measurement.teamId,
		sourceOrder = measurement.sourceOrder,
		shape = MapSchema.ChunkShapes.Block,
		cframe = CFrame.new(base),
		size = size,
		trajectory = stationary(base),
		angularTrajectory = {
			kind = MoverTrajectory.Kinds.Linear,
			startTimeMilliseconds = 0,
			durationMilliseconds = 0,
			base = Vector3.zero,
			delta = angularDelta,
		},
		moverStop = false,
	}
end

function Q3MoverDefinitionBuilder.Door(measurement: DoorMeasurement): MapSchema.BinaryMover
	checkedCommon(measurement.id, measurement.teamId, measurement.sourceOrder, measurement.sourceEntityIndex)
	assert(
		finiteNumber(measurement.speedQ3PerSecond) and measurement.speedQ3PerSecond > 0,
		"func_door speed must be positive"
	)
	assert(
		finiteNumber(measurement.waitSeconds) and measurement.waitSeconds >= 0,
		"func_door wait must be non-negative"
	)
	assert(finiteNumber(measurement.lipQ3) and measurement.lipQ3 >= 0, "func_door lip must be non-negative")
	local position1, size, _ =
		q3Box(measurement.modelBounds, string.format("func_door[%d]", measurement.sourceEntityIndex))
	local sourceSize = measurementVector(
		measurement.modelBounds.size,
		string.format("func_door[%d].size", measurement.sourceEntityIndex)
	)
	local radians = math.rad(measurement.angleDegrees)
	local moveDirectionQ3 = Vector3.new(math.cos(radians), math.sin(radians), 0)
	local absoluteDirection =
		Vector3.new(math.abs(moveDirectionQ3.X), math.abs(moveDirectionQ3.Y), math.abs(moveDirectionQ3.Z))
	local distanceQ3 = absoluteDirection:Dot(sourceSize) - measurement.lipQ3
	assert(distanceQ3 > 0, "func_door movement distance must be positive")
	local position2 = position1 + q3Delta(moveDirectionQ3 * distanceQ3)
	if bit32.band(measurement.spawnFlags, 1) ~= 0 then
		position1, position2 = position2, position1
	end
	return {
		id = measurement.id,
		teamId = measurement.teamId,
		sourceOrder = measurement.sourceOrder,
		shape = MapSchema.ChunkShapes.Block,
		cframe = CFrame.new(position1),
		size = size,
		position1 = position1,
		position2 = position2,
		durationMilliseconds = math.max(1, math.floor(distanceQ3 * 1000 / measurement.speedQ3PerSecond)),
		waitMilliseconds = math.floor(measurement.waitSeconds * 1000),
		moverStop = false,
	}
end

function Q3MoverDefinitionBuilder.DoorPolicy(
	teamId: string,
	captainMoverId: string,
	damage: number,
	crusher: boolean
): MapSchema.BinaryMoverPolicy
	assert(type(teamId) == "string" and #teamId > 0, "door policy teamId must be non-empty")
	assert(type(captainMoverId) == "string" and #captainMoverId > 0, "door policy captain must be non-empty")
	assert(damage % 1 == 0 and damage >= 0, "door damage must be a non-negative integer")
	return {
		teamId = teamId,
		captainMoverId = captainMoverId,
		blockedBehavior = "Door",
		damage = damage,
		crusher = crusher,
		activationBehavior = "DoorTouch",
	}
end

return table.freeze(Q3MoverDefinitionBuilder)
