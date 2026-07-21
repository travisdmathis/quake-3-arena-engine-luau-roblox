--[[
SPDX-License-Identifier: GPL-2.0-or-later

Schema-to-runtime boundary for Block movers. The
accepted fields and ordering preserve the Quake III mover data needed by:
  code/game/g_mover.c (G_MoverTeam, G_MoverPush, moverStop)
  code/game/bg_misc.c (BG_EvaluateTrajectory)

Map bounds, an explicit fixed-clock domain, immutable validation, and the
oriented Roblox Block/Wedge representations are original the Roblox Luau port
adaptations. Shapes outside that schema deliberately fail closed.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local MoverClock = require(script.Parent.Parent.simulation.MoverClock)
local MoverBinaryState = require(script.Parent.Parent.simulation.MoverBinaryState)
local MoverPushRules = require(script.Parent.Parent.simulation.MoverPushRules)
local MoverTrajectory = require(script.Parent.Parent.simulation.MoverTrajectory)

export type Definition = MoverPushRules.Definition
export type BinaryProgram = MoverBinaryState.Program
export type Bounds = {
	minimum: Vector3,
	maximum: Vector3,
}
export type Domains = {
	legacyDefinitions: { Definition },
	binaryPrograms: { BinaryProgram },
	initialDefinitions: { Definition },
}

local MapMoverContract = {}

local maximumClockTimeMilliseconds =
	assert(MoverClock.TimeForStep(MoverClock.MaximumStep), "mover clock maximum step must have a representable time")

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isFiniteVector3(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFiniteNumber(vector.X) and isFiniteNumber(vector.Y) and isFiniteNumber(vector.Z)
end

local function validateBounds(value: unknown): (Bounds?, string?)
	if type(value) ~= "table" then
		return nil, "bounds-not-table"
	end
	local bounds = value :: any
	if not isFiniteVector3(bounds.minimum) or not isFiniteVector3(bounds.maximum) then
		return nil, "invalid-bounds-vectors"
	end
	local minimum = bounds.minimum :: Vector3
	local maximum = bounds.maximum :: Vector3
	if minimum.X >= maximum.X or minimum.Y >= maximum.Y or minimum.Z >= maximum.Z then
		return nil, "invalid-bounds-order"
	end
	return {
		minimum = minimum,
		maximum = maximum,
	}, nil
end

local function componentMinimum(left: Vector3, right: Vector3): Vector3
	return Vector3.new(math.min(left.X, right.X), math.min(left.Y, right.Y), math.min(left.Z, right.Z))
end

local function componentMaximum(left: Vector3, right: Vector3): Vector3
	return Vector3.new(math.max(left.X, right.X), math.max(left.Y, right.Y), math.max(left.Z, right.Z))
end

local function componentAbsolute(value: Vector3): Vector3
	return Vector3.new(math.abs(value.X), math.abs(value.Y), math.abs(value.Z))
end

local function insideBounds(point: Vector3, bounds: Bounds): boolean
	return point.X >= bounds.minimum.X
		and point.Y >= bounds.minimum.Y
		and point.Z >= bounds.minimum.Z
		and point.X <= bounds.maximum.X
		and point.Y <= bounds.maximum.Y
		and point.Z <= bounds.maximum.Z
end

local function fullTrajectoryExtents(definition: Definition): (Vector3, Vector3)
	local trajectory = definition.trajectory
	local localHalf = definition.size * 0.5
	local cframe = definition.cframe
	local x = cframe.XVector
	local y = cframe.YVector
	local z = cframe.ZVector
	local half = Vector3.new(
		math.abs(x.X) * localHalf.X + math.abs(y.X) * localHalf.Y + math.abs(z.X) * localHalf.Z,
		math.abs(x.Y) * localHalf.X + math.abs(y.Y) * localHalf.Y + math.abs(z.Y) * localHalf.Z,
		math.abs(x.Z) * localHalf.X + math.abs(y.Z) * localHalf.Y + math.abs(z.Z) * localHalf.Z
	)
	if definition.angularTrajectory.kind ~= MoverTrajectory.Kinds.Stationary then
		half = Vector3.one * localHalf.Magnitude
	end
	if trajectory.kind == MoverTrajectory.Kinds.Sine then
		local amplitude = componentAbsolute(trajectory.delta)
		return trajectory.base - amplitude - half, trajectory.base + amplitude + half
	end

	local endpoint = trajectory.base
	if trajectory.kind == MoverTrajectory.Kinds.LinearStop then
		endpoint = trajectory.base + trajectory.delta * (trajectory.durationMilliseconds * 0.001)
	end
	return componentMinimum(trajectory.base, endpoint) - half, componentMaximum(trajectory.base, endpoint) + half
end

local function validateTrajectoryClockDomain(trajectory: MoverTrajectory.Trajectory, label: string): string?
	if trajectory.startTimeMilliseconds < 0 then
		return label .. "-start-before-clock"
	end
	if trajectory.startTimeMilliseconds > maximumClockTimeMilliseconds then
		return label .. "-start-after-clock"
	end

	if trajectory.kind == MoverTrajectory.Kinds.Stationary then
		if trajectory.durationMilliseconds ~= 0 or trajectory.delta ~= Vector3.zero then
			return "noncanonical-stationary-" .. label
		end
		return nil
	end

	local endTime = trajectory.startTimeMilliseconds + trajectory.durationMilliseconds
	if endTime > maximumClockTimeMilliseconds then
		return label .. "-end-after-clock"
	end
	return nil
end

function MapMoverContract.ValidateAndOrder(definitionsValue: unknown, boundsValue: unknown): ({ Definition }?, string?)
	local bounds, boundsError = validateBounds(boundsValue)
	if not bounds then
		return nil, boundsError
	end

	local definitions, definitionError = MoverPushRules.ValidateAndOrderDefinitions(definitionsValue)
	if not definitions then
		return nil, definitionError
	end

	for _, definition in definitions do
		local clockError = validateTrajectoryClockDomain(definition.trajectory, "trajectory")
			or validateTrajectoryClockDomain(definition.angularTrajectory, "angular-trajectory")
		if clockError then
			return nil, string.format("mover-%s:%s", definition.id, clockError)
		end
		local minimum, maximum = fullTrajectoryExtents(definition)
		if not insideBounds(minimum, bounds) or not insideBounds(maximum, bounds) then
			return nil, string.format("mover-%s:trajectory-outside-map-bounds", definition.id)
		end
	end

	-- MoverPushRules returns source-order-sorted, recursively immutable records.
	return definitions, nil
end

local function endpointHullInsideBounds(position: Vector3, size: Vector3, bounds: Bounds): boolean
	local half = size * 0.5
	return insideBounds(position - half, bounds) and insideBounds(position + half, bounds)
end

function MapMoverContract.ValidateAndOrderBinaryPrograms(
	programsValue: unknown,
	boundsValue: unknown
): ({ BinaryProgram }?, string?)
	local bounds, boundsError = validateBounds(boundsValue)
	if not bounds then
		return nil, boundsError
	end
	local programs, programError = MoverBinaryState.ValidateAndOrderPrograms(programsValue)
	if not programs then
		return nil, programError
	end
	for _, program in programs do
		if not endpointHullInsideBounds(program.position1, program.size, bounds) then
			return nil, string.format("binary-mover-%s:position1-hull-outside-map-bounds", program.id)
		end
		if not endpointHullInsideBounds(program.position2, program.size, bounds) then
			return nil, string.format("binary-mover-%s:position2-hull-outside-map-bounds", program.id)
		end
	end
	return programs, nil
end

function MapMoverContract.ComposeDomains(
	legacyDefinitionsValue: unknown,
	binaryProgramsValue: unknown
): (Domains?, string?)
	local legacyDefinitions, legacyError = MoverPushRules.ValidateAndOrderDefinitions(legacyDefinitionsValue)
	if not legacyDefinitions then
		return nil, "legacy-definitions-invalid:" .. (legacyError or "invalid")
	end
	local binaryRuntime, runtimeError = MoverBinaryState.Create(binaryProgramsValue)
	if not binaryRuntime then
		return nil, "binary-programs-not-validated:" .. (runtimeError or "invalid")
	end
	local binaryPrograms = binaryProgramsValue :: { BinaryProgram }
	if #legacyDefinitions + #binaryPrograms > MoverPushRules.MaximumDefinitions then
		return nil, "too-many-combined-movers"
	end

	local legacyIds: { [string]: boolean } = {}
	local legacySourceOrders: { [number]: boolean } = {}
	local legacyTeams: { [string]: boolean } = {}
	for _, definition in legacyDefinitions do
		legacyIds[definition.id] = true
		legacySourceOrders[definition.sourceOrder] = true
		legacyTeams[definition.teamId] = true
	end
	for _, program in binaryPrograms do
		if legacyIds[program.id] then
			return nil, "mover-domain-id-collision:" .. program.id
		end
		if legacySourceOrders[program.sourceOrder] then
			return nil, "mover-domain-source-order-collision:" .. tostring(program.sourceOrder)
		end
		if legacyTeams[program.teamId] then
			return nil, "mover-domain-team-mixing:" .. program.teamId
		end
	end

	local binaryDefinitions, definitionError = MoverBinaryState.MaterializeDefinitions(binaryPrograms, binaryRuntime)
	if not binaryDefinitions then
		return nil, "binary-initial-definitions-invalid:" .. (definitionError or "invalid")
	end
	local combined: { Definition } = table.create(#legacyDefinitions + #binaryDefinitions)
	for _, definition in legacyDefinitions do
		table.insert(combined, definition)
	end
	for _, definition in binaryDefinitions do
		table.insert(combined, definition)
	end
	local initialDefinitions, initialError = MoverPushRules.ValidateAndOrderDefinitions(combined)
	if not initialDefinitions then
		return nil, "initial-definitions-invalid:" .. (initialError or "invalid")
	end
	local domains: Domains = {
		legacyDefinitions = legacyDefinitions,
		binaryPrograms = binaryPrograms,
		initialDefinitions = initialDefinitions,
	}
	table.freeze(domains)
	return domains, nil
end

MapMoverContract.MaximumMovers = MoverPushRules.MaximumDefinitions
MapMoverContract.MaximumClockTimeMilliseconds = maximumClockTimeMilliseconds

return table.freeze(MapMoverContract)
