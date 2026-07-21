--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure translational and angular Block-mover push rules translated from Quake III Arena:
  code/game/g_mover.c (G_TestEntityPosition, G_TryPushingEntity,
  G_MoverPush, G_MoverTeam, G_RunMover)
  code/game/bg_misc.c (BG_EvaluateTrajectory)

The bounded immutable definitions, stable string identities plus explicit Q3
entity source order, per-body contents masks, oriented Block geometry,
explicit occupancy callback, opaque one-captain continuation boundary, and
data-only result records are original the Roblox Luau port adaptations. The map
schema's Block and Wedge shapes are exact; any other shape remains rejected.

Sine crushes cross an intentional consumer boundary: G_MoverPush invokes
G_Damage synchronously, and death/gib may replace or remove the collision body
and spawn linked drops before the next entity or team part. This pure kernel
does not invent those gameplay transitions. A trusted callback returns one
strict data-only effect, which is validated and applied atomically at the exact
captured entity-list cursor before later collision decisions continue.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local MoverTrajectory = require(script.Parent.MoverTrajectory)
local MoverRotationRules = require(script.Parent.MoverRotationRules)
local SweptAABBOrientedBlock = require(script.Parent.SweptAABBOrientedBlock)
local SweptAABBOrientedWedge = require(script.Parent.SweptAABBOrientedWedge)

export type Shape = "Block" | "Wedge"

export type Definition = {
	id: string,
	teamId: string,
	sourceOrder: number,
	shape: Shape,
	cframe: CFrame,
	size: Vector3,
	trajectory: MoverTrajectory.Trajectory,
	angularTrajectory: MoverTrajectory.Trajectory,
	moverStop: boolean,
}

export type Body = {
	id: string,
	sourceOrder: number,
	position: Vector3,
	angles: Vector3,
	size: Vector3,
	centerOffset: Vector3,
	velocity: Vector3,
	groundMoverId: string?,
	contents: number,
	clipMask: number,
}

export type Pose = {
	id: string,
	teamId: string,
	sourceOrder: number,
	shape: Shape,
	position: Vector3,
	size: Vector3,
}

export type OccupancyContext = {
	movers: { Pose },
	bodies: { Body },
}

export type OccupancyTest = (candidate: Body, context: OccupancyContext) -> boolean

export type PushKind = "Carried" | "Pushed" | "LeftBehind"

export type PushDisposition = {
	kind: PushKind,
	teamId: string,
	moverId: string,
	bodyId: string,
}

export type ViewRotationDisposition = {
	teamId: string,
	moverId: string,
	bodyId: string,
	yawDeltaShort: number,
}

export type CrushDisposition = {
	teamId: string,
	moverId: string,
	bodyId: string,
}

-- G_MoverPush calls G_Damage inline for a Sine pusher, then advances past that
-- exact entity even when damage was ignored. Death may retain the live body,
-- remove it after a gib, or replace it with the same entity slot as a corpse;
-- TossClientItems/CTF handling may also link new bodies before iteration
-- continues. No effect retries the current body/pusher pair.
export type SynchronousCrushEffect =
	{ kind: "Retain", insertedBodies: { Body } }
	| { kind: "Remove", insertedBodies: { Body } }
	| { kind: "Replace", replacementBody: Body, insertedBodies: { Body } }

-- Retain the former public name as a source-compatible annotation while its
-- value contract is now the structured effect above. Service integration is a
-- separate gate; this kernel no longer accepts the former string values.
export type SynchronousCrushTransition = SynchronousCrushEffect
export type SynchronousCrushCallback = (crush: CrushDisposition, body: Body) -> SynchronousCrushEffect

export type BodyMutation =
	{ kind: "Remove", bodyId: string }
	| { kind: "Replace", body: Body }
	| { kind: "Insert", body: Body }

export type BoundaryUpdate = {
	definitions: { Definition }?,
	bodyMutations: { BodyMutation }?,
}

export type DetachReason = "ContactPush" | "LeftBehind"

export type DetachDisposition = {
	reason: DetachReason,
	teamId: string,
	moverId: string,
	bodyId: string,
	fromMoverId: string,
}

export type TeamDisposition = "Committed" | "BlockedRollback"

export type TeamResult = {
	teamId: string,
	captainMoverId: string,
	disposition: TeamDisposition,
	blockedMoverId: string?,
	blockedByBodyId: string?,
}

export type Result = {
	movers: { Pose },
	bodies: { Body },
	pushes: { PushDisposition },
	viewRotations: { ViewRotationDisposition },
	detaches: { DetachDisposition },
	crushes: { CrushDisposition },
	teams: { TeamResult },
	requiresSynchronousCrushTransition: boolean,
}

type WorkingBody = {
	id: string,
	sourceOrder: number,
	position: Vector3,
	size: Vector3,
	centerOffset: Vector3,
	velocity: Vector3,
	groundMoverId: string?,
	contents: number,
	clipMask: number,
}

type TeamPlan = {
	teamId: string,
	captainMoverId: string,
	memberMoverIds: { string },
}

type FrameData = {
	lineage: unknown,
	fromTimeMilliseconds: number,
	toTimeMilliseconds: number,
	definitions: { Definition },
	linkedPositions: { [string]: Vector3 },
	linkedAngles: { [string]: Vector3 },
	bodies: { WorkingBody },
	bodyIdsSeen: { [string]: boolean },
	bodySourceOrdersSeen: { [number]: boolean },
	teamPlans: { TeamPlan },
	nextTeamIndex: number,
	lastRanMoverTeam: boolean?,
	pushes: { PushDisposition },
	viewRotations: { ViewRotationDisposition },
	detaches: { DetachDisposition },
	crushes: { CrushDisposition },
	teams: { TeamResult },
	occupancyTest: OccupancyTest,
	synchronousCrushCallback: SynchronousCrushCallback?,
}

export type FrameState = {
	phase: "Ready",
	generation: number,
	nextTeamIndex: number,
	teamCount: number,
	fromTimeMilliseconds: number,
	toTimeMilliseconds: number,
	definitions: { Definition },
	movers: { Pose },
	bodies: { Body },
}

export type TeamBoundary = {
	phase: "Boundary",
	generation: number,
	nextTeamIndex: number,
	teamCount: number,
	fromTimeMilliseconds: number,
	toTimeMilliseconds: number,
	teamId: string,
	captainMoverId: string,
	memberMoverIds: { string },
	ranMoverTeam: boolean,
	teamResult: TeamResult,
	definitions: { Definition },
	movers: { Pose },
	bodies: { Body },
}

local MoverPushRules = {}

local MAXIMUM_DEFINITIONS = 256
local MAXIMUM_BODIES = 256
local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_GEOMETRY_SIZE = 10_000
local MAXIMUM_VELOCITY_COMPONENT = 100_000
local MAXIMUM_SOURCE_ORDER = 2_147_483_647
local MAXIMUM_CONTENTS_MASK = 4_294_967_295
local MINIMUM_GEOMETRY_SIZE = 0.001
local MAXIMUM_BODY_MUTATIONS = MAXIMUM_BODIES

type CapabilityState = {
	phase: "Ready" | "Boundary",
	generation: number,
	current: boolean,
	data: FrameData,
}

local capabilityStates = setmetatable({}, { __mode = "k" }) :: { [table]: CapabilityState }

local Contents = table.freeze({
	Solid = 1,
	PlayerClip = 0x10000,
	Body = 0x2000000,
	Corpse = 0x4000000,
	Trigger = 0x40000000,
})

local Masks = table.freeze({
	Solid = Contents.Solid,
	PlayerSolid = bit32.bor(Contents.Solid, Contents.PlayerClip, Contents.Body),
	DeadSolid = bit32.bor(Contents.Solid, Contents.PlayerClip),
	Shot = bit32.bor(Contents.Solid, Contents.Body, Contents.Corpse),
})

local DEFINITION_KEYS: { [string]: boolean } = {
	id = true,
	teamId = true,
	sourceOrder = true,
	shape = true,
	cframe = true,
	size = true,
	trajectory = true,
	angularTrajectory = true,
	moverStop = true,
}
table.freeze(DEFINITION_KEYS)

local BODY_KEYS: { [string]: boolean } = {
	id = true,
	sourceOrder = true,
	position = true,
	size = true,
	centerOffset = true,
	velocity = true,
	groundMoverId = true,
	contents = true,
	clipMask = true,
}
table.freeze(BODY_KEYS)

local BOUNDARY_UPDATE_KEYS: { [string]: boolean } = {
	definitions = true,
	bodyMutations = true,
}
table.freeze(BOUNDARY_UPDATE_KEYS)

local REMOVE_BODY_MUTATION_KEYS: { [string]: boolean } = {
	kind = true,
	bodyId = true,
}
table.freeze(REMOVE_BODY_MUTATION_KEYS)

local BODY_VALUE_MUTATION_KEYS: { [string]: boolean } = {
	kind = true,
	body = true,
}
table.freeze(BODY_VALUE_MUTATION_KEYS)

local SIMPLE_SYNCHRONOUS_CRUSH_EFFECT_KEYS: { [string]: boolean } = {
	kind = true,
	insertedBodies = true,
}
table.freeze(SIMPLE_SYNCHRONOUS_CRUSH_EFFECT_KEYS)

local REPLACE_SYNCHRONOUS_CRUSH_EFFECT_KEYS: { [string]: boolean } = {
	kind = true,
	replacementBody = true,
	insertedBodies = true,
}
table.freeze(REPLACE_SYNCHRONOUS_CRUSH_EFFECT_KEYS)

type TryPushOutcome = {
	pushed: boolean,
	kind: PushKind?,
	detachedFromMoverId: string?,
	yawDeltaShort: number,
}

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isBoundedVector(value: unknown, maximumComponent: number): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFiniteNumber(vector.X)
		and isFiniteNumber(vector.Y)
		and isFiniteNumber(vector.Z)
		and math.abs(vector.X) <= maximumComponent
		and math.abs(vector.Y) <= maximumComponent
		and math.abs(vector.Z) <= maximumComponent
end

local function isValidId(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function isValidSize(value: unknown): boolean
	if not isBoundedVector(value, MAXIMUM_GEOMETRY_SIZE) then
		return false
	end
	local size = value :: Vector3
	return size.X >= MINIMUM_GEOMETRY_SIZE and size.Y >= MINIMUM_GEOMETRY_SIZE and size.Z >= MINIMUM_GEOMETRY_SIZE
end

local function isValidTime(value: unknown): boolean
	return isFiniteNumber(value)
		and (value :: number) % 1 == 0
		and math.abs(value :: number) <= MoverTrajectory.MaximumTimeMilliseconds
end

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return isFiniteNumber(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function geometryFitsWithinWorld(center: Vector3, size: Vector3): boolean
	local half = size * 0.5
	return math.abs(center.X) + half.X <= MAXIMUM_COORDINATE
		and math.abs(center.Y) + half.Y <= MAXIMUM_COORDINATE
		and math.abs(center.Z) + half.Z <= MAXIMUM_COORDINATE
end

local function rotatedHalfExtents(cframe: CFrame, size: Vector3): Vector3
	local half = size * 0.5
	local x = cframe.XVector
	local y = cframe.YVector
	local z = cframe.ZVector
	return Vector3.new(
		math.abs(x.X) * half.X + math.abs(y.X) * half.Y + math.abs(z.X) * half.Z,
		math.abs(x.Y) * half.X + math.abs(y.Y) * half.Y + math.abs(z.Y) * half.Z,
		math.abs(x.Z) * half.X + math.abs(y.Z) * half.Y + math.abs(z.Z) * half.Z
	)
end

local function halfExtentsFitWithinWorld(center: Vector3, half: Vector3): boolean
	return math.abs(center.X) + half.X <= MAXIMUM_COORDINATE
		and math.abs(center.Y) + half.Y <= MAXIMUM_COORDINATE
		and math.abs(center.Z) + half.Z <= MAXIMUM_COORDINATE
end

local function isFiniteCFrame(value: unknown): boolean
	if typeof(value) ~= "CFrame" then
		return false
	end
	local components = { (value :: CFrame):GetComponents() }
	for index = 1, 3 do
		if not isFiniteNumber(components[index]) or math.abs(components[index] :: number) > MAXIMUM_COORDINATE then
			return false
		end
	end

	for index = 1, 9 do
		local component = components[index + 3]
		if not isFiniteNumber(component) then
			return false
		end
	end
	return true
end

local function cframeRotationMatchesDegrees(cframe: CFrame, degrees: Vector3): boolean
	local expected = CFrame.Angles(math.rad(degrees.X), math.rad(degrees.Y), math.rad(degrees.Z))
	local actualComponents = { cframe.Rotation:GetComponents() }
	local expectedComponents = { expected:GetComponents() }
	for index = 4, 12 do
		if math.abs(actualComponents[index] - expectedComponents[index]) > 1e-12 then
			return false
		end
	end
	return true
end

local function hasExactKeys(
	value: { [unknown]: unknown },
	allowed: { [string]: boolean },
	expectedCount: number
): boolean
	local observed = 0
	for key in value do
		if type(key) ~= "string" or allowed[key] ~= true then
			return false
		end
		observed += 1
	end
	return observed == expectedCount
end

local function denseArrayLength(
	value: { [unknown]: unknown },
	maximumLength: number,
	arrayName: string
): (number?, string?)
	local count = 0
	local maximumIndex = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, arrayName .. "-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > maximumLength or maximumIndex > maximumLength then
			return nil, "too-many-" .. arrayName
		end
	end
	if maximumIndex ~= count then
		return nil, arrayName .. "-not-dense-array"
	end
	return count, nil
end

local function trajectoryStaysBounded(trajectory: MoverTrajectory.Trajectory, size: Vector3, cframe: CFrame): boolean
	local half = rotatedHalfExtents(cframe, size)
	if not isBoundedVector(trajectory.base, MAXIMUM_COORDINATE) then
		return false
	end
	if trajectory.kind == MoverTrajectory.Kinds.Stationary then
		return halfExtentsFitWithinWorld(trajectory.base, half)
	end
	if trajectory.kind == MoverTrajectory.Kinds.Sine then
		local maximum = Vector3.new(
			math.abs(trajectory.base.X) + math.abs(trajectory.delta.X) + half.X,
			math.abs(trajectory.base.Y) + math.abs(trajectory.delta.Y) + half.Y,
			math.abs(trajectory.base.Z) + math.abs(trajectory.delta.Z) + half.Z
		)
		return maximum.X <= MAXIMUM_COORDINATE and maximum.Y <= MAXIMUM_COORDINATE and maximum.Z <= MAXIMUM_COORDINATE
	end

	local durationSeconds = trajectory.durationMilliseconds * 0.001
	local endpoint = trajectory.base + trajectory.delta * durationSeconds
	return halfExtentsFitWithinWorld(trajectory.base, half)
		and isBoundedVector(endpoint, MAXIMUM_COORDINATE)
		and halfExtentsFitWithinWorld(endpoint, half)
end

local function stationaryAngularTrajectory(): MoverTrajectory.Trajectory
	return assert(MoverRotationRules.ValidateAngularTrajectory({
		kind = MoverTrajectory.Kinds.Stationary,
		startTimeMilliseconds = 0,
		durationMilliseconds = 0,
		base = Vector3.zero,
		delta = Vector3.zero,
	}))
end

local function validateDefinition(value: unknown): (Definition?, string?)
	if type(value) ~= "table" then
		return nil, "definition-not-table"
	end
	local source = value :: { [unknown]: unknown }
	local expectedKeys = if source.angularTrajectory == nil then 8 else 9
	if not hasExactKeys(source, DEFINITION_KEYS, expectedKeys) then
		return nil, "invalid-definition-shape"
	end
	if not isValidId(source.id) then
		return nil, "invalid-mover-id"
	end
	if not isValidId(source.teamId) then
		return nil, "invalid-team-id"
	end
	if not isIntegerInRange(source.sourceOrder, 1, MAXIMUM_SOURCE_ORDER) then
		return nil, "invalid-source-order"
	end
	if source.shape ~= "Block" and source.shape ~= "Wedge" then
		return nil, "unsupported-mover-shape"
	end
	if not isFiniteCFrame(source.cframe) then
		return nil, "invalid-mover-cframe"
	end
	if not isValidSize(source.size) then
		return nil, "invalid-mover-size"
	end
	if type(source.moverStop) ~= "boolean" then
		return nil, "invalid-mover-stop"
	end

	local trajectory, trajectoryError = MoverTrajectory.Validate(source.trajectory)
	if not trajectory then
		return nil, "invalid-mover-trajectory:" .. (trajectoryError or "invalid")
	end
	if
		trajectory.kind ~= MoverTrajectory.Kinds.Stationary
		and trajectory.kind ~= MoverTrajectory.Kinds.LinearStop
		and trajectory.kind ~= MoverTrajectory.Kinds.Sine
	then
		return nil, "unsupported-mover-trajectory"
	end
	if not trajectoryStaysBounded(trajectory, source.size :: Vector3, source.cframe :: CFrame) then
		return nil, "mover-trajectory-out-of-bounds"
	end
	if (source.cframe :: CFrame).Position ~= trajectory.base then
		return nil, "mover-cframe-trajectory-mismatch"
	end
	local angularTrajectory: MoverTrajectory.Trajectory?
	local angularTrajectoryError: string? = nil
	if source.angularTrajectory == nil then
		angularTrajectory = stationaryAngularTrajectory()
	else
		angularTrajectory, angularTrajectoryError =
			MoverRotationRules.ValidateAngularTrajectory(source.angularTrajectory)
	end
	if not angularTrajectory then
		return nil, "invalid-mover-angular-trajectory:" .. (angularTrajectoryError or "invalid")
	end
	if
		angularTrajectory.kind ~= MoverTrajectory.Kinds.Stationary
		and angularTrajectory.kind ~= MoverTrajectory.Kinds.Linear
		and angularTrajectory.kind ~= MoverTrajectory.Kinds.LinearStop
		and angularTrajectory.kind ~= MoverTrajectory.Kinds.Sine
	then
		return nil, "unsupported-mover-angular-motion"
	end
	if not cframeRotationMatchesDegrees(source.cframe :: CFrame, angularTrajectory.base) then
		return nil, "mover-cframe-angular-trajectory-mismatch"
	end

	local definition: Definition = {
		id = source.id :: string,
		teamId = source.teamId :: string,
		sourceOrder = source.sourceOrder :: number,
		shape = source.shape :: Shape,
		cframe = source.cframe :: CFrame,
		size = source.size :: Vector3,
		trajectory = trajectory,
		angularTrajectory = angularTrajectory,
		moverStop = source.moverStop :: boolean,
	}
	table.freeze(definition)
	return definition, nil
end

local function validateBody(value: unknown): (Body?, string?)
	if type(value) ~= "table" then
		return nil, "body-not-table"
	end
	local source = value :: { [unknown]: unknown }
	local expectedKeys = if source.groundMoverId == nil then 8 else 9
	if not hasExactKeys(source, BODY_KEYS, expectedKeys) then
		return nil, "invalid-body-shape"
	end
	if not isValidId(source.id) then
		return nil, "invalid-body-id"
	end
	if not isIntegerInRange(source.sourceOrder, 1, MAXIMUM_SOURCE_ORDER) then
		return nil, "invalid-body-source-order"
	end
	if not isBoundedVector(source.position, MAXIMUM_COORDINATE) then
		return nil, "invalid-body-position"
	end
	if not isValidSize(source.size) then
		return nil, "invalid-body-size"
	end
	if not isBoundedVector(source.centerOffset, MAXIMUM_GEOMETRY_SIZE) then
		return nil, "invalid-body-center-offset"
	end
	if not isBoundedVector(source.velocity, MAXIMUM_VELOCITY_COMPONENT) then
		return nil, "invalid-body-velocity"
	end
	if source.groundMoverId ~= nil and not isValidId(source.groundMoverId) then
		return nil, "invalid-ground-mover-id"
	end
	if not isIntegerInRange(source.contents, 0, MAXIMUM_CONTENTS_MASK) then
		return nil, "invalid-body-contents"
	end
	if not isIntegerInRange(source.clipMask, 0, MAXIMUM_CONTENTS_MASK) then
		return nil, "invalid-body-clip-mask"
	end
	local center = (source.position :: Vector3) + (source.centerOffset :: Vector3)
	if
		not isBoundedVector(center, MAXIMUM_COORDINATE) or not geometryFitsWithinWorld(center, source.size :: Vector3)
	then
		return nil, "body-center-out-of-bounds"
	end

	local body: Body = {
		id = source.id :: string,
		sourceOrder = source.sourceOrder :: number,
		position = source.position :: Vector3,
		size = source.size :: Vector3,
		centerOffset = source.centerOffset :: Vector3,
		velocity = source.velocity :: Vector3,
		groundMoverId = source.groundMoverId :: string?,
		contents = source.contents :: number,
		clipMask = source.clipMask :: number,
	}
	table.freeze(body)
	return body, nil
end

function MoverPushRules.ValidateAndOrderDefinitions(value: unknown): ({ Definition }?, string?)
	if type(value) ~= "table" then
		return nil, "definitions-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local count, arrayError = denseArrayLength(source, MAXIMUM_DEFINITIONS, "definitions")
	if not count then
		return nil, arrayError
	end

	local definitions: { Definition } = {}
	local observedIds: { [string]: boolean } = {}
	local observedSourceOrders: { [number]: boolean } = {}
	for index = 1, count do
		local definition, definitionError = validateDefinition(source[index])
		if not definition then
			return nil, string.format("definition-%d:%s", index, definitionError or "invalid")
		end
		if observedIds[definition.id] then
			return nil, string.format("definition-%d:duplicate-mover-id", index)
		end
		if observedSourceOrders[definition.sourceOrder] then
			return nil, string.format("definition-%d:duplicate-source-order", index)
		end
		observedIds[definition.id] = true
		observedSourceOrders[definition.sourceOrder] = true
		table.insert(definitions, definition)
	end
	table.sort(definitions, function(left, right): boolean
		return left.sourceOrder < right.sourceOrder
	end)
	table.freeze(definitions)
	return definitions, nil
end

function MoverPushRules.ValidateAndOrderBodies(value: unknown): ({ Body }?, string?)
	if type(value) ~= "table" then
		return nil, "bodies-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local count, arrayError = denseArrayLength(source, MAXIMUM_BODIES, "bodies")
	if not count then
		return nil, arrayError
	end

	local bodies: { Body } = {}
	local observedIds: { [string]: boolean } = {}
	local observedSourceOrders: { [number]: boolean } = {}
	for index = 1, count do
		local body, bodyError = validateBody(source[index])
		if not body then
			return nil, string.format("body-%d:%s", index, bodyError or "invalid")
		end
		if observedIds[body.id] then
			return nil, string.format("body-%d:duplicate-body-id", index)
		end
		if observedSourceOrders[body.sourceOrder] then
			return nil, string.format("body-%d:duplicate-source-order", index)
		end
		observedIds[body.id] = true
		observedSourceOrders[body.sourceOrder] = true
		table.insert(bodies, body)
	end
	table.sort(bodies, function(left, right): boolean
		return left.sourceOrder < right.sourceOrder
	end)
	table.freeze(bodies)
	return bodies, nil
end

local function evaluateValidatedPoses(definitions: { Definition }, atTimeMilliseconds: number): ({ Pose }?, string?)
	local poses: { Pose } = {}
	for _, definition in definitions do
		local position = MoverTrajectory.Evaluate(definition.trajectory, atTimeMilliseconds)
		local angles = MoverRotationRules.EvaluateDegrees(definition.angularTrajectory, atTimeMilliseconds)
		if not isBoundedVector(position, MAXIMUM_COORDINATE) then
			return nil, "mover-" .. definition.id .. ":evaluated-position-out-of-bounds"
		end
		local pose: Pose = {
			id = definition.id,
			teamId = definition.teamId,
			sourceOrder = definition.sourceOrder,
			shape = definition.shape,
			position = position,
			angles = angles,
			size = definition.size,
		}
		table.freeze(pose)
		table.insert(poses, pose)
	end
	table.freeze(poses)
	return poses, nil
end

function MoverPushRules.EvaluatePoses(definitionsValue: unknown, atTimeMillisecondsValue: unknown): ({ Pose }?, string?)
	if not isValidTime(atTimeMillisecondsValue) then
		return nil, "invalid-evaluation-time"
	end
	local definitions, definitionError = MoverPushRules.ValidateAndOrderDefinitions(definitionsValue)
	if not definitions then
		return nil, definitionError
	end
	return evaluateValidatedPoses(definitions, atTimeMillisecondsValue :: number)
end

local function cloneWorkingBody(body: Body): WorkingBody
	return {
		id = body.id,
		sourceOrder = body.sourceOrder,
		position = body.position,
		size = body.size,
		centerOffset = body.centerOffset,
		velocity = body.velocity,
		groundMoverId = body.groundMoverId,
		contents = body.contents,
		clipMask = body.clipMask,
	}
end

local function freezeBody(body: WorkingBody): Body
	local frozen: Body = {
		id = body.id,
		sourceOrder = body.sourceOrder,
		position = body.position,
		size = body.size,
		centerOffset = body.centerOffset,
		velocity = body.velocity,
		groundMoverId = body.groundMoverId,
		contents = body.contents,
		clipMask = body.clipMask,
	}
	table.freeze(frozen)
	return frozen
end

local function bodiesOverlap(left: WorkingBody, right: WorkingBody): boolean
	local delta = (left.position + left.centerOffset) - (right.position + right.centerOffset)
	local half = (left.size + right.size) * 0.5
	return math.abs(delta.X) < half.X and math.abs(delta.Y) < half.Y and math.abs(delta.Z) < half.Z
end

local function bodyOverlapsMover(
	body: WorkingBody,
	moverPosition: Vector3,
	moverAngles: Vector3,
	definition: Definition
): boolean
	local cframe = CFrame.new(moverPosition)
		* CFrame.Angles(math.rad(moverAngles.X), math.rad(moverAngles.Y), math.rad(moverAngles.Z))
	local shape = {
		id = definition.id,
		sourceOrder = definition.sourceOrder,
		cframe = cframe,
		size = definition.size,
		contents = Contents.Solid,
		active = true,
	}
	local result = if definition.shape == "Block"
		then assert(
			SweptAABBOrientedBlock.TraceOrderedBlocks(
				body.position,
				Vector3.zero,
				body.size,
				body.centerOffset,
				{ shape },
				Contents.Solid
			)
		)
		else assert(
			SweptAABBOrientedWedge.TraceOrderedWedges(
				body.position,
				Vector3.zero,
				body.size,
				body.centerOffset,
				{ shape },
				Contents.Solid
			)
		)
	return result.startSolid
end

local function snapshotPoses(
	definitions: { Definition },
	positions: { [string]: Vector3 },
	angles: { [string]: Vector3 }
): { Pose }
	local poses: { Pose } = {}
	for _, definition in definitions do
		local pose: Pose = {
			id = definition.id,
			teamId = definition.teamId,
			sourceOrder = definition.sourceOrder,
			shape = definition.shape,
			position = positions[definition.id],
			angles = angles[definition.id],
			size = definition.size,
		}
		table.freeze(pose)
		table.insert(poses, pose)
	end
	table.freeze(poses)
	return poses
end

local function snapshotBodies(bodies: { WorkingBody }, overrideBodyId: string?, overrideBody: WorkingBody?): { Body }
	local snapshot: { Body } = {}
	for _, body in bodies do
		local selected = if body.id == overrideBodyId and overrideBody then overrideBody else body
		table.insert(snapshot, freezeBody(selected))
	end
	table.freeze(snapshot)
	return snapshot
end

local function positionIsBlocked(
	candidate: WorkingBody,
	definitions: { Definition },
	moverPositions: { [string]: Vector3 },
	moverAngles: { [string]: Vector3 },
	bodies: { WorkingBody },
	occupancyTest: OccupancyTest
): (boolean?, string?)
	local candidateCenter = candidate.position + candidate.centerOffset
	if
		not isBoundedVector(candidate.position, MAXIMUM_COORDINATE)
		or not isBoundedVector(candidateCenter, MAXIMUM_COORDINATE)
		or not geometryFitsWithinWorld(candidateCenter, candidate.size)
	then
		return true, nil
	end

	if bit32.band(candidate.clipMask, Contents.Solid) ~= 0 then
		for _, definition in definitions do
			if bodyOverlapsMover(candidate, moverPositions[definition.id], moverAngles[definition.id], definition) then
				return true, nil
			end
		end
	end
	for _, other in bodies do
		if
			other.id ~= candidate.id
			and bit32.band(candidate.clipMask, other.contents) ~= 0
			and bodiesOverlap(candidate, other)
		then
			return true, nil
		end
	end

	local immutableCandidate = freezeBody(candidate)
	local context: OccupancyContext = {
		movers = snapshotPoses(definitions, moverPositions, moverAngles),
		bodies = snapshotBodies(bodies, candidate.id, candidate),
	}
	table.freeze(context)
	local succeeded, blockedValue = pcall(occupancyTest, immutableCandidate, context)
	if not succeeded or type(blockedValue) ~= "boolean" then
		return nil, "occupancy-test-failed"
	end
	return blockedValue, nil
end

local function tryPushBody(
	body: WorkingBody,
	definition: Definition,
	move: Vector3,
	angularMove: Vector3,
	isRider: boolean,
	definitions: { Definition },
	moverPositions: { [string]: Vector3 },
	moverAngles: { [string]: Vector3 },
	bodies: { WorkingBody },
	occupancyTest: OccupancyTest
): (TryPushOutcome?, string?)
	-- EF_MOVER_STOP refuses contact pushes before saving or mutating the entity,
	-- while a body grounded on this mover is still carried normally.
	if definition.moverStop and not isRider then
		return { pushed = false, kind = nil, detachedFromMoverId = nil, yawDeltaShort = 0 }, nil
	end

	local originalPosition = body.position
	local originalGroundMoverId = body.groundMoverId
	local proposedGroundMoverId = if isRider then body.groundMoverId else nil
	local displacement =
		MoverRotationRules.PushDisplacement(originalPosition, moverPositions[definition.id], move, angularMove)
	if not displacement then
		return nil, "invalid-angular-push-displacement"
	end
	local yawDeltaShort = MoverRotationRules.YawDeltaShort(angularMove)
	if yawDeltaShort == nil then
		return nil, "invalid-angular-push-yaw"
	end
	local proposed: WorkingBody = {
		id = body.id,
		sourceOrder = body.sourceOrder,
		position = originalPosition + displacement,
		size = body.size,
		centerOffset = body.centerOffset,
		velocity = body.velocity,
		groundMoverId = proposedGroundMoverId,
		contents = body.contents,
		clipMask = body.clipMask,
	}
	local proposedBlocked, proposedError =
		positionIsBlocked(proposed, definitions, moverPositions, moverAngles, bodies, occupancyTest)
	if proposedBlocked == nil then
		return nil, proposedError
	end
	if not proposedBlocked then
		body.position = proposed.position
		body.groundMoverId = proposedGroundMoverId
		return {
			pushed = true,
			kind = if isRider then "Carried" else "Pushed",
			detachedFromMoverId = if originalGroundMoverId ~= nil and proposedGroundMoverId == nil
				then originalGroundMoverId
				else nil,
			yawDeltaShort = yawDeltaShort,
		},
			nil
	end

	-- Q3 restores the old origin after a failed push, then permits a sliding
	-- trapdoor to leave the body behind if that old origin became clear. A
	-- non-rider has already lost its ground entity at this point.
	local restored: WorkingBody = {
		id = body.id,
		sourceOrder = body.sourceOrder,
		position = originalPosition,
		size = body.size,
		centerOffset = body.centerOffset,
		velocity = body.velocity,
		groundMoverId = proposedGroundMoverId,
		contents = body.contents,
		clipMask = body.clipMask,
	}
	local restoredBlocked, restoredError =
		positionIsBlocked(restored, definitions, moverPositions, moverAngles, bodies, occupancyTest)
	if restoredBlocked == nil then
		return nil, restoredError
	end
	body.position = originalPosition
	body.groundMoverId = proposedGroundMoverId
	if not restoredBlocked then
		body.groundMoverId = nil
		return {
			pushed = true,
			kind = "LeftBehind",
			detachedFromMoverId = originalGroundMoverId,
			yawDeltaShort = yawDeltaShort,
		},
			nil
	end
	return {
		pushed = false,
		kind = nil,
		detachedFromMoverId = if originalGroundMoverId ~= nil and proposedGroundMoverId == nil
			then originalGroundMoverId
			else nil,
		yawDeltaShort = 0,
	},
		nil
end

local function copyArray<T>(source: { T }): { T }
	local output: { T } = table.create(#source)
	for _, value in source do
		table.insert(output, value)
	end
	return output
end

local function copyPositions(source: { [string]: Vector3 }): { [string]: Vector3 }
	return table.clone(source)
end

local function copyWorkingBodies(source: { WorkingBody }): { WorkingBody }
	local output: { WorkingBody } = table.create(#source)
	for _, body in source do
		table.insert(output, {
			id = body.id,
			sourceOrder = body.sourceOrder,
			position = body.position,
			size = body.size,
			centerOffset = body.centerOffset,
			velocity = body.velocity,
			groundMoverId = body.groundMoverId,
			contents = body.contents,
			clipMask = body.clipMask,
		})
	end
	return output
end

local function copyStringSet(source: { [string]: boolean }): { [string]: boolean }
	return table.clone(source)
end

local function copyNumberSet(source: { [number]: boolean }): { [number]: boolean }
	return table.clone(source)
end

local function copyFrameData(source: FrameData): FrameData
	return {
		lineage = source.lineage,
		fromTimeMilliseconds = source.fromTimeMilliseconds,
		toTimeMilliseconds = source.toTimeMilliseconds,
		definitions = source.definitions,
		linkedPositions = copyPositions(source.linkedPositions),
		linkedAngles = copyPositions(source.linkedAngles),
		bodies = copyWorkingBodies(source.bodies),
		bodyIdsSeen = copyStringSet(source.bodyIdsSeen),
		bodySourceOrdersSeen = copyNumberSet(source.bodySourceOrdersSeen),
		teamPlans = source.teamPlans,
		nextTeamIndex = source.nextTeamIndex,
		lastRanMoverTeam = source.lastRanMoverTeam,
		pushes = copyArray(source.pushes),
		viewRotations = copyArray(source.viewRotations),
		detaches = copyArray(source.detaches),
		crushes = copyArray(source.crushes),
		teams = copyArray(source.teams),
		occupancyTest = source.occupancyTest,
		synchronousCrushCallback = source.synchronousCrushCallback,
	}
end

local function validateEntitySourceOrders(definitions: { Definition }, bodies: { Body }): string?
	local definitionById: { [string]: Definition } = {}
	local occupiedSourceOrders: { [number]: boolean } = {}
	for _, definition in definitions do
		definitionById[definition.id] = definition
		occupiedSourceOrders[definition.sourceOrder] = true
	end
	for _, body in bodies do
		if definitionById[body.id] ~= nil then
			return "body-" .. body.id .. ":duplicate-entity-id"
		end
		if occupiedSourceOrders[body.sourceOrder] then
			return "body-" .. body.id .. ":duplicate-entity-source-order"
		end
		occupiedSourceOrders[body.sourceOrder] = true
		if body.groundMoverId ~= nil and definitionById[body.groundMoverId] == nil then
			return "body-" .. body.id .. ":unknown-ground-mover-id"
		end
	end
	return nil
end

local function indexWorkingBodiesById(bodies: { WorkingBody }): { [string]: WorkingBody }
	local output: { [string]: WorkingBody } = {}
	for _, body in bodies do
		output[body.id] = body
	end
	return output
end

local function insertedBodiesAreSourceOrdered(rawBodies: { [unknown]: unknown }, orderedBodies: { Body }): boolean
	for index, body in orderedBodies do
		local rawBodyValue = rawBodies[index]
		if type(rawBodyValue) ~= "table" then
			return false
		end
		local rawBody = rawBodyValue :: { [unknown]: unknown }
		if rawBody.id ~= body.id or rawBody.sourceOrder ~= body.sourceOrder then
			return false
		end
	end
	return true
end

local function applySynchronousCrushEffect(
	definitions: { Definition },
	workingBodies: { WorkingBody },
	bodyIdsSeen: { [string]: boolean },
	bodySourceOrdersSeen: { [number]: boolean },
	currentBody: WorkingBody,
	effectValue: unknown
): ({ WorkingBody }?, { [string]: boolean }?, {
	[number]: boolean,
}?, SynchronousCrushEffect?, string?)
	if type(effectValue) ~= "table" then
		return nil, nil, nil, nil, "effect-not-table"
	end
	local rawEffect = effectValue :: { [unknown]: unknown }
	local kind = rawEffect.kind
	if kind == "Retain" or kind == "Remove" then
		if not hasExactKeys(rawEffect, SIMPLE_SYNCHRONOUS_CRUSH_EFFECT_KEYS, 2) then
			return nil, nil, nil, nil, "invalid-effect-shape"
		end
	elseif kind == "Replace" then
		if not hasExactKeys(rawEffect, REPLACE_SYNCHRONOUS_CRUSH_EFFECT_KEYS, 3) then
			return nil, nil, nil, nil, "invalid-effect-shape"
		end
	else
		return nil, nil, nil, nil, "invalid-effect-kind"
	end

	if type(rawEffect.insertedBodies) ~= "table" then
		return nil, nil, nil, nil, "inserted-bodies-not-array"
	end
	local rawInsertedBodies = rawEffect.insertedBodies :: { [unknown]: unknown }
	local insertedCount, insertedCountError =
		denseArrayLength(rawInsertedBodies, MAXIMUM_BODY_MUTATIONS, "inserted-bodies")
	if not insertedCount then
		return nil, nil, nil, nil, insertedCountError
	end
	local insertedBodies, insertedBodyError = MoverPushRules.ValidateAndOrderBodies(rawInsertedBodies)
	if not insertedBodies then
		return nil, nil, nil, nil, "invalid-inserted-bodies:" .. (insertedBodyError or "invalid")
	end
	if not insertedBodiesAreSourceOrdered(rawInsertedBodies, insertedBodies) then
		return nil, nil, nil, nil, "inserted-bodies-not-source-ordered"
	end

	local replacementBody: Body? = nil
	if kind == "Replace" then
		local replacement, replacementError = validateBody(rawEffect.replacementBody)
		if not replacement then
			return nil, nil, nil, nil, "invalid-replacement-body:" .. (replacementError or "invalid")
		end
		if replacement.id ~= currentBody.id then
			return nil, nil, nil, nil, "replacement-body-id-mismatch"
		end
		if replacement.sourceOrder ~= currentBody.sourceOrder then
			return nil, nil, nil, nil, "replacement-body-source-order-mismatch"
		end
		if replacement.position ~= currentBody.position then
			return nil, nil, nil, nil, "replacement-body-position-mismatch"
		end
		if replacement.velocity ~= currentBody.velocity then
			return nil, nil, nil, nil, "replacement-body-velocity-mismatch"
		end
		if replacement.groundMoverId ~= currentBody.groundMoverId then
			return nil, nil, nil, nil, "replacement-body-ground-mover-mismatch"
		end
		replacementBody = replacement
	end

	local nextBodyCount = #workingBodies + insertedCount
	if kind == "Remove" then
		nextBodyCount -= 1
	end
	if nextBodyCount > MAXIMUM_BODIES then
		return nil, nil, nil, nil, "too-many-effect-bodies"
	end
	for _, insertedBody in insertedBodies do
		if bodyIdsSeen[insertedBody.id] then
			return nil, nil, nil, nil, "inserted-body-id-not-new:" .. insertedBody.id
		end
		if bodySourceOrdersSeen[insertedBody.sourceOrder] then
			return nil, nil, nil, nil, "inserted-body-source-order-not-new:" .. tostring(insertedBody.sourceOrder)
		end
	end

	local mutableBodies: { Body } = copyArray(snapshotBodies(workingBodies, nil, nil))
	local currentIndex: number? = nil
	for index, body in mutableBodies do
		if body.id == currentBody.id then
			currentIndex = index
			break
		end
	end
	if not currentIndex then
		return nil, nil, nil, nil, "current-body-missing"
	end
	if kind == "Remove" then
		table.remove(mutableBodies, currentIndex)
	elseif kind == "Replace" then
		mutableBodies[currentIndex] = replacementBody :: Body
	end
	for _, insertedBody in insertedBodies do
		table.insert(mutableBodies, insertedBody)
	end

	local validatedBodies, bodiesError = MoverPushRules.ValidateAndOrderBodies(mutableBodies)
	if not validatedBodies then
		return nil, nil, nil, nil, "invalid-effect-bodies:" .. (bodiesError or "invalid")
	end
	local entityError = validateEntitySourceOrders(definitions, validatedBodies)
	if entityError then
		return nil, nil, nil, nil, "invalid-effect-entity-order:" .. entityError
	end

	local nextWorkingBodies: { WorkingBody } = table.create(#validatedBodies)
	for _, body in validatedBodies do
		table.insert(nextWorkingBodies, cloneWorkingBody(body))
	end
	local nextBodyIdsSeen = copyStringSet(bodyIdsSeen)
	local nextBodySourceOrdersSeen = copyNumberSet(bodySourceOrdersSeen)
	for _, insertedBody in insertedBodies do
		nextBodyIdsSeen[insertedBody.id] = true
		nextBodySourceOrdersSeen[insertedBody.sourceOrder] = true
	end

	local effect: SynchronousCrushEffect
	if kind == "Replace" then
		effect = {
			kind = "Replace",
			replacementBody = replacementBody :: Body,
			insertedBodies = insertedBodies,
		}
	elseif kind == "Remove" then
		effect = {
			kind = "Remove",
			insertedBodies = insertedBodies,
		}
	else
		effect = {
			kind = "Retain",
			insertedBodies = insertedBodies,
		}
	end
	table.freeze(effect)
	return nextWorkingBodies, nextBodyIdsSeen, nextBodySourceOrdersSeen, effect, nil
end

local function buildTeamPlans(definitions: { Definition }): { TeamPlan }
	-- G_RunFrame reaches captains by entity number. G_FindTeams keeps the first
	-- source entity as captain but prepends every later match to teamchain, so
	-- slaves run in descending source order.
	local plans: { TeamPlan } = {}
	local byTeamId: { [string]: TeamPlan } = {}
	for _, definition in definitions do
		local plan = byTeamId[definition.teamId]
		if not plan then
			plan = {
				teamId = definition.teamId,
				captainMoverId = definition.id,
				memberMoverIds = {},
			}
			byTeamId[definition.teamId] = plan
			table.insert(plans, plan)
			table.insert(plan.memberMoverIds, definition.id)
		else
			table.insert(plan.memberMoverIds, 2, definition.id)
		end
	end
	for _, plan in plans do
		table.freeze(plan.memberMoverIds)
		table.freeze(plan)
	end
	table.freeze(plans)
	return plans
end

local function definitionsById(definitions: { Definition }): { [string]: Definition }
	local output: { [string]: Definition } = {}
	for _, definition in definitions do
		output[definition.id] = definition
	end
	return output
end

local function makeReadyState(data: FrameData, generation: number): FrameState
	local state: FrameState = {
		phase = "Ready",
		generation = generation,
		nextTeamIndex = data.nextTeamIndex,
		teamCount = #data.teamPlans,
		fromTimeMilliseconds = data.fromTimeMilliseconds,
		toTimeMilliseconds = data.toTimeMilliseconds,
		definitions = data.definitions,
		movers = snapshotPoses(data.definitions, data.linkedPositions, data.linkedAngles),
		bodies = snapshotBodies(data.bodies, nil, nil),
	}
	table.freeze(state)
	capabilityStates[state] = {
		phase = "Ready",
		generation = generation,
		current = true,
		data = data,
	}
	return state
end

local function makeTeamBoundary(data: FrameData, generation: number): TeamBoundary
	local plan = data.teamPlans[data.nextTeamIndex]
	local teamResult = data.teams[data.nextTeamIndex]
	assert(plan and teamResult, "team boundary data is incomplete")
	local ranMoverTeam = data.lastRanMoverTeam
	assert(ranMoverTeam ~= nil, "team boundary execution state is missing")
	local boundary: TeamBoundary = {
		phase = "Boundary",
		generation = generation,
		nextTeamIndex = data.nextTeamIndex,
		teamCount = #data.teamPlans,
		fromTimeMilliseconds = data.fromTimeMilliseconds,
		toTimeMilliseconds = data.toTimeMilliseconds,
		teamId = plan.teamId,
		captainMoverId = plan.captainMoverId,
		memberMoverIds = plan.memberMoverIds,
		ranMoverTeam = ranMoverTeam,
		teamResult = teamResult,
		definitions = data.definitions,
		movers = snapshotPoses(data.definitions, data.linkedPositions, data.linkedAngles),
		bodies = snapshotBodies(data.bodies, nil, nil),
	}
	table.freeze(boundary)
	capabilityStates[boundary] = {
		phase = "Boundary",
		generation = generation,
		current = true,
		data = data,
	}
	return boundary
end

local function currentCapability(value: unknown, expectedPhase: "Ready" | "Boundary"): (CapabilityState?, string?)
	if type(value) ~= "table" then
		return nil, "continuation-not-capability"
	end
	local capability = capabilityStates[value :: table]
	if not capability then
		return nil, "continuation-not-capability"
	end
	if not capability.current then
		return nil, "continuation-not-current"
	end
	if capability.phase ~= expectedPhase then
		return nil, "continuation-phase-mismatch"
	end
	local exposed = value :: { [unknown]: unknown }
	if exposed.phase ~= expectedPhase or exposed.generation ~= capability.generation then
		return nil, "continuation-capability-mismatch"
	end
	return capability, nil
end

local function beginFrame(
	definitionsValue: unknown,
	bodiesValue: unknown,
	fromTimeMillisecondsValue: unknown,
	toTimeMillisecondsValue: unknown,
	occupancyTestValue: unknown,
	synchronousCrushCallback: SynchronousCrushCallback?
): (FrameState?, string?)
	if not isValidTime(fromTimeMillisecondsValue) or not isValidTime(toTimeMillisecondsValue) then
		return nil, "invalid-step-time"
	end
	local fromTimeMilliseconds = fromTimeMillisecondsValue :: number
	local toTimeMilliseconds = toTimeMillisecondsValue :: number
	if toTimeMilliseconds < fromTimeMilliseconds then
		return nil, "step-time-went-backwards"
	end
	if type(occupancyTestValue) ~= "function" then
		return nil, "occupancy-test-required"
	end
	local definitions, definitionError = MoverPushRules.ValidateAndOrderDefinitions(definitionsValue)
	if not definitions then
		return nil, definitionError
	end
	local bodies, bodyError = MoverPushRules.ValidateAndOrderBodies(bodiesValue)
	if not bodies then
		return nil, bodyError
	end
	local entityError = validateEntitySourceOrders(definitions, bodies)
	if entityError then
		return nil, entityError
	end
	local fromPoses, fromPoseError = evaluateValidatedPoses(definitions, fromTimeMilliseconds)
	if not fromPoses then
		return nil, fromPoseError
	end
	local _, toPoseError = evaluateValidatedPoses(definitions, toTimeMilliseconds)
	if toPoseError then
		return nil, toPoseError
	end
	local linkedPositions: { [string]: Vector3 } = {}
	local linkedAngles: { [string]: Vector3 } = {}
	for _, pose in fromPoses do
		linkedPositions[pose.id] = pose.position
		linkedAngles[pose.id] = pose.angles
	end
	local workingBodies: { WorkingBody } = table.create(#bodies)
	local bodyIdsSeen: { [string]: boolean } = {}
	local bodySourceOrdersSeen: { [number]: boolean } = {}
	for _, body in bodies do
		table.insert(workingBodies, cloneWorkingBody(body))
		bodyIdsSeen[body.id] = true
		bodySourceOrdersSeen[body.sourceOrder] = true
	end
	local data: FrameData = {
		-- Identity, rather than exposed clock scalars, binds every successor to this
		-- exact BeginFrame transaction. The token is intentionally created only
		-- inside this module and cannot be supplied by a caller.
		lineage = table.freeze({}),
		fromTimeMilliseconds = fromTimeMilliseconds,
		toTimeMilliseconds = toTimeMilliseconds,
		definitions = definitions,
		linkedPositions = linkedPositions,
		linkedAngles = linkedAngles,
		bodies = workingBodies,
		bodyIdsSeen = bodyIdsSeen,
		bodySourceOrdersSeen = bodySourceOrdersSeen,
		teamPlans = buildTeamPlans(definitions),
		nextTeamIndex = 1,
		lastRanMoverTeam = nil,
		pushes = {},
		viewRotations = {},
		detaches = {},
		crushes = {},
		teams = {},
		occupancyTest = occupancyTestValue :: OccupancyTest,
		synchronousCrushCallback = synchronousCrushCallback,
	}
	return makeReadyState(data, 1), nil
end

local function processNextTeam(source: FrameData): (FrameData?, string?)
	-- AdvanceNextTeam consumes the opaque Ready continuation before entering this
	-- function. That leaves this private FrameData with one owner, so the next
	-- continuation can take it over without cloning every body and history list.
	local data = source
	local plan = data.teamPlans[data.nextTeamIndex]
	if not plan then
		return nil, "no-team-remaining"
	end
	local byId = definitionsById(data.definitions)
	local captain = byId[plan.captainMoverId]
	assert(captain, "validated continuation captain is missing")
	local teamDefinitions: { Definition } = table.create(#plan.memberMoverIds)
	for _, moverId in plan.memberMoverIds do
		local definition = byId[moverId]
		assert(definition, "validated continuation member is missing")
		table.insert(teamDefinitions, definition)
	end
	-- Q3's pushed_t stack restores origins but never rewinds death/entity
	-- transitions. Initial bodies start from the team entrance pose. A later
	-- inline replacement retains that saved origin while changing entity shape;
	-- only a newly inserted identity installs its insertion pose as a baseline.
	local teamRollbackPositions: { [string]: Vector3 } = {}
	for _, body in data.bodies do
		teamRollbackPositions[body.id] = body.position
	end
	local pushCountAtTeamStart = #data.pushes
	local viewRotationCountAtTeamStart = #data.viewRotations
	local teamStartMoverPositions: { [string]: Vector3 } = {}
	local teamStartMoverAngles: { [string]: Vector3 } = {}
	for _, definition in teamDefinitions do
		teamStartMoverPositions[definition.id] = data.linkedPositions[definition.id]
		teamStartMoverAngles[definition.id] = data.linkedAngles[definition.id]
	end
	local blockedMoverId: string? = nil
	local blockedByBodyId: string? = nil
	local teamIsActive = captain.trajectory.kind ~= MoverTrajectory.Kinds.Stationary
		or captain.angularTrajectory.kind ~= MoverTrajectory.Kinds.Stationary
	data.lastRanMoverTeam = teamIsActive

	if teamIsActive then
		for _, definition in teamDefinitions do
			local oldMoverPosition = data.linkedPositions[definition.id]
			local destinationMoverPosition = MoverTrajectory.Evaluate(definition.trajectory, data.toTimeMilliseconds)
			if not isBoundedVector(destinationMoverPosition, MAXIMUM_COORDINATE) then
				return nil, "mover-" .. definition.id .. ":evaluated-position-out-of-bounds"
			end
			local move = destinationMoverPosition - oldMoverPosition
			local oldMoverAngles = data.linkedAngles[definition.id]
			local destinationMoverAngles =
				MoverRotationRules.EvaluateDegrees(definition.angularTrajectory, data.toTimeMilliseconds)
			local angularMove = destinationMoverAngles - oldMoverAngles
			data.linkedPositions[definition.id] = destinationMoverPosition
			data.linkedAngles[definition.id] = destinationMoverAngles

			-- trap_EntitiesInBox fills one fixed entityList before this pusher is
			-- linked at its destination. Preserve that cursor identity separately
			-- from the live body set: inline insertions participate in collision now,
			-- but only a later pusher part may capture and process them as entities.
			local capturedBodyIds: { string } = table.create(#data.bodies)
			local bodyById = indexWorkingBodiesById(data.bodies)
			for _, capturedBody in data.bodies do
				table.insert(capturedBodyIds, capturedBody.id)
			end
			for _, capturedBodyId in capturedBodyIds do
				local body = bodyById[capturedBodyId]
				if not body then
					continue
				end
				local isRider = body.groundMoverId == definition.id
				if
					not isRider
					and (
						bit32.band(body.clipMask, Contents.Solid) == 0
						or not bodyOverlapsMover(body, destinationMoverPosition, destinationMoverAngles, definition)
					)
				then
					continue
				end

				local outcome, pushError = tryPushBody(
					body,
					definition,
					move,
					angularMove,
					isRider,
					data.definitions,
					data.linkedPositions,
					data.linkedAngles,
					data.bodies,
					data.occupancyTest
				)
				if not outcome then
					return nil, "mover-" .. definition.id .. ":" .. (pushError or "push-failed")
				end
				if outcome.detachedFromMoverId ~= nil then
					local detach: DetachDisposition = {
						reason = if outcome.kind == "LeftBehind" then "LeftBehind" else "ContactPush",
						teamId = plan.teamId,
						moverId = definition.id,
						bodyId = body.id,
						fromMoverId = outcome.detachedFromMoverId,
					}
					table.freeze(detach)
					table.insert(data.detaches, detach)
				end
				if outcome.pushed then
					local disposition: PushDisposition = {
						kind = outcome.kind :: PushKind,
						teamId = plan.teamId,
						moverId = definition.id,
						bodyId = body.id,
					}
					table.freeze(disposition)
					table.insert(data.pushes, disposition)
					if outcome.yawDeltaShort ~= 0 then
						local viewRotation: ViewRotationDisposition = {
							teamId = plan.teamId,
							moverId = definition.id,
							bodyId = body.id,
							yawDeltaShort = outcome.yawDeltaShort,
						}
						table.freeze(viewRotation)
						table.insert(data.viewRotations, viewRotation)
					end
					continue
				end

				if
					definition.trajectory.kind == MoverTrajectory.Kinds.Sine
					or definition.angularTrajectory.kind == MoverTrajectory.Kinds.Sine
				then
					local crush: CrushDisposition = {
						teamId = plan.teamId,
						moverId = definition.id,
						bodyId = body.id,
					}
					table.freeze(crush)
					local crushYawDeltaShort = assert(MoverRotationRules.YawDeltaShort(angularMove))
					if crushYawDeltaShort ~= 0 then
						local viewRotation: ViewRotationDisposition = {
							teamId = plan.teamId,
							moverId = definition.id,
							bodyId = body.id,
							yawDeltaShort = crushYawDeltaShort,
						}
						table.freeze(viewRotation)
						table.insert(data.viewRotations, viewRotation)
					end
					if data.synchronousCrushCallback then
						local callbackBody = freezeBody(body)
						local succeeded, effectValue = pcall(data.synchronousCrushCallback, crush, callbackBody)
						if not succeeded then
							return nil, "synchronous-crush-callback-failed:" .. body.id
						end
						local nextBodies, nextBodyIdsSeen, nextBodySourceOrdersSeen, effect, effectError =
							applySynchronousCrushEffect(
								data.definitions,
								data.bodies,
								data.bodyIdsSeen,
								data.bodySourceOrdersSeen,
								body,
								effectValue
							)
						if not nextBodies or not nextBodyIdsSeen or not nextBodySourceOrdersSeen or not effect then
							return nil,
								"invalid-synchronous-crush-effect:" .. body.id .. ":" .. (effectError or "invalid")
						end
						data.bodies = nextBodies
						data.bodyIdsSeen = nextBodyIdsSeen
						data.bodySourceOrdersSeen = nextBodySourceOrdersSeen
						-- A synchronous effect may remove, replace, or insert bodies. Keep
						-- the fixed captured cursor, but point its remaining IDs at the
						-- current live objects. A later pusher part performs a fresh capture.
						bodyById = indexWorkingBodiesById(data.bodies)
						if effect.kind == "Remove" then
							teamRollbackPositions[body.id] = nil
						end
						for _, insertedBody in effect.insertedBodies do
							teamRollbackPositions[insertedBody.id] = insertedBody.position
						end
					else
						table.insert(data.crushes, crush)
					end
					continue
				end

				blockedMoverId = definition.id
				blockedByBodyId = body.id
				break
			end
			if blockedMoverId ~= nil then
				break
			end
		end
	end

	local teamResult: TeamResult
	if blockedMoverId ~= nil then
		for _, definition in teamDefinitions do
			data.linkedPositions[definition.id] = teamStartMoverPositions[definition.id]
			data.linkedAngles[definition.id] = teamStartMoverAngles[definition.id]
		end
		for _, body in data.bodies do
			-- pushed_t does not save groundEntityNum; preserve a detach while
			-- restoring only the origin of bodies that survived this team. Every
			-- replacement retains the original entity's saved origin; an insertion
			-- starts at its insertion pose. Only position rolls back, so neither
			-- case resurrects the prior entity state.
			local rollbackPosition = teamRollbackPositions[body.id]
			assert(rollbackPosition, "surviving team body has no rollback baseline")
			body.position = rollbackPosition
		end
		while #data.pushes > pushCountAtTeamStart do
			table.remove(data.pushes)
		end
		while #data.viewRotations > viewRotationCountAtTeamStart do
			table.remove(data.viewRotations)
		end
		teamResult = {
			teamId = plan.teamId,
			captainMoverId = plan.captainMoverId,
			disposition = "BlockedRollback",
			blockedMoverId = blockedMoverId,
			blockedByBodyId = blockedByBodyId,
		}
	else
		teamResult = {
			teamId = plan.teamId,
			captainMoverId = plan.captainMoverId,
			disposition = "Committed",
			blockedMoverId = nil,
			blockedByBodyId = nil,
		}
	end
	table.freeze(teamResult)
	table.insert(data.teams, teamResult)
	return data, nil
end

local function trajectoryEqual(left: MoverTrajectory.Trajectory, right: MoverTrajectory.Trajectory): boolean
	return left.kind == right.kind
		and left.startTimeMilliseconds == right.startTimeMilliseconds
		and left.durationMilliseconds == right.durationMilliseconds
		and left.base == right.base
		and left.delta == right.delta
end

local function validateDefinitionTopology(current: { Definition }, candidate: { Definition }): string?
	if #candidate ~= #current then
		return "boundary-definition-count-mismatch"
	end
	for index, expected in current do
		local observed = candidate[index]
		if
			observed.id ~= expected.id
			or observed.teamId ~= expected.teamId
			or observed.sourceOrder ~= expected.sourceOrder
			or observed.shape ~= expected.shape
			or observed.size ~= expected.size
			or observed.moverStop ~= expected.moverStop
		then
			return "boundary-definition-topology-mismatch:" .. expected.id
		end
	end
	return nil
end

local function validateRawDefinitionOrder(current: { Definition }, value: unknown): string?
	if type(value) ~= "table" then
		return "boundary-definitions-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local count, countError = denseArrayLength(source, MAXIMUM_DEFINITIONS, "definitions")
	if not count then
		return countError
	end
	if count ~= #current then
		return "boundary-definition-count-mismatch"
	end
	for index, expected in current do
		local raw = source[index]
		if type(raw) ~= "table" then
			return "boundary-definitions-not-source-ordered"
		end
		local definition = raw :: { [unknown]: unknown }
		if definition.id ~= expected.id or definition.sourceOrder ~= expected.sourceOrder then
			return "boundary-definitions-not-source-ordered"
		end
	end
	return nil
end

type AppliedBodyMutations = {
	bodies: { WorkingBody },
	bodyIdsSeen: { [string]: boolean },
	bodySourceOrdersSeen: { [number]: boolean },
}

local function applyBodyMutations(
	definitions: { Definition },
	workingBodies: { WorkingBody },
	bodyIdsSeen: { [string]: boolean },
	bodySourceOrdersSeen: { [number]: boolean },
	mutationsValue: unknown
): (AppliedBodyMutations?, string?)
	if type(mutationsValue) ~= "table" then
		return nil, "body-mutations-not-array"
	end
	local rawMutations = mutationsValue :: { [unknown]: unknown }
	local count, countError = denseArrayLength(rawMutations, MAXIMUM_BODY_MUTATIONS, "body-mutations")
	if not count then
		return nil, countError
	end
	local bodies: { Body } = snapshotBodies(workingBodies, nil, nil)
	local mutableBodies: { Body } = copyArray(bodies)
	local nextBodyIdsSeen = copyStringSet(bodyIdsSeen)
	local nextBodySourceOrdersSeen = copyNumberSet(bodySourceOrdersSeen)
	for mutationIndex = 1, count do
		local rawValue = rawMutations[mutationIndex]
		if type(rawValue) ~= "table" then
			return nil, string.format("body-mutation-%d:not-table", mutationIndex)
		end
		local raw = rawValue :: { [unknown]: unknown }
		if raw.kind == "Remove" then
			if not hasExactKeys(raw, REMOVE_BODY_MUTATION_KEYS, 2) or not isValidId(raw.bodyId) then
				return nil, string.format("body-mutation-%d:invalid-remove", mutationIndex)
			end
			local removeIndex: number? = nil
			for index, body in mutableBodies do
				if body.id == raw.bodyId then
					removeIndex = index
					break
				end
			end
			if not removeIndex then
				return nil, "body-mutation-remove-missing:" .. (raw.bodyId :: string)
			end
			table.remove(mutableBodies, removeIndex)
		elseif raw.kind == "Replace" or raw.kind == "Insert" then
			if not hasExactKeys(raw, BODY_VALUE_MUTATION_KEYS, 2) then
				return nil, string.format("body-mutation-%d:invalid-value", mutationIndex)
			end
			local body, bodyError = validateBody(raw.body)
			if not body then
				return nil, string.format("body-mutation-%d:%s", mutationIndex, bodyError or "invalid-body")
			end
			local existingIndex: number? = nil
			for index, existing in mutableBodies do
				if existing.id == body.id then
					existingIndex = index
					break
				end
			end
			if raw.kind == "Replace" then
				if not existingIndex then
					return nil, "body-mutation-replace-missing:" .. body.id
				end
				if mutableBodies[existingIndex].sourceOrder ~= body.sourceOrder then
					return nil, "body-mutation-replace-source-order:" .. body.id
				end
				mutableBodies[existingIndex] = body
			else
				if existingIndex then
					return nil, "body-mutation-insert-duplicate:" .. body.id
				end
				if nextBodyIdsSeen[body.id] then
					return nil, "body-mutation-insert-reuses-id:" .. body.id
				end
				if nextBodySourceOrdersSeen[body.sourceOrder] then
					return nil, "body-mutation-insert-reuses-source-order:" .. tostring(body.sourceOrder)
				end
				table.insert(mutableBodies, body)
				nextBodyIdsSeen[body.id] = true
				nextBodySourceOrdersSeen[body.sourceOrder] = true
			end
		else
			return nil, string.format("body-mutation-%d:invalid-kind", mutationIndex)
		end
	end
	local validated, bodyError = MoverPushRules.ValidateAndOrderBodies(mutableBodies)
	if not validated then
		return nil, "invalid-mutated-bodies:" .. (bodyError or "invalid")
	end
	local entityError = validateEntitySourceOrders(definitions, validated)
	if entityError then
		return nil, entityError
	end
	local output: { WorkingBody } = table.create(#validated)
	for _, body in validated do
		table.insert(output, cloneWorkingBody(body))
	end
	return {
		bodies = output,
		bodyIdsSeen = nextBodyIdsSeen,
		bodySourceOrdersSeen = nextBodySourceOrdersSeen,
	},
		nil
end

function MoverPushRules.BeginFrame(
	definitionsValue: unknown,
	bodiesValue: unknown,
	fromTimeMillisecondsValue: unknown,
	toTimeMillisecondsValue: unknown,
	occupancyTestValue: unknown
): (FrameState?, string?)
	return beginFrame(
		definitionsValue,
		bodiesValue,
		fromTimeMillisecondsValue,
		toTimeMillisecondsValue,
		occupancyTestValue,
		nil
	)
end

function MoverPushRules.BeginFrameWithSynchronousCrush(
	definitionsValue: unknown,
	bodiesValue: unknown,
	fromTimeMillisecondsValue: unknown,
	toTimeMillisecondsValue: unknown,
	occupancyTestValue: unknown,
	synchronousCrushCallbackValue: unknown
): (FrameState?, string?)
	if type(synchronousCrushCallbackValue) ~= "function" then
		return nil, "synchronous-crush-callback-required"
	end
	return beginFrame(
		definitionsValue,
		bodiesValue,
		fromTimeMillisecondsValue,
		toTimeMillisecondsValue,
		occupancyTestValue,
		synchronousCrushCallbackValue :: SynchronousCrushCallback
	)
end

-- Use_BinaryMover may call SetMoverState from a client/trigger interaction
-- after level.time advances but before G_RunMover reaches the captain. Q3 links
-- the changed mover at that current time without pushing intersecting bodies;
-- G_MoverTeam then sees the relinked position as its physical starting point.
-- Keep that pre-captain transition explicit instead of rebuilding BeginFrame
-- from the new trajectory, which would incorrectly replay motion from
-- level.previousTime. This gate is deliberately available only before the
-- first source-ordered team has run.
function MoverPushRules.RelinkReadyDefinitionsAtCurrentTime(
	frameValue: unknown,
	definitionsValue: unknown
): (FrameState?, string?)
	local capability, capabilityError = currentCapability(frameValue, "Ready")
	if not capability then
		return nil, capabilityError
	end
	if capability.data.nextTeamIndex ~= 1 then
		return nil, "ready-definition-relink-after-team-processing"
	end

	local data = copyFrameData(capability.data)
	local currentDefinitions = data.definitions
	local orderError = validateRawDefinitionOrder(currentDefinitions, definitionsValue)
	if orderError then
		return nil, orderError
	end
	local validated, definitionError = MoverPushRules.ValidateAndOrderDefinitions(definitionsValue)
	if not validated then
		return nil, "invalid-ready-definitions:" .. (definitionError or "invalid")
	end
	local topologyError = validateDefinitionTopology(currentDefinitions, validated)
	if topologyError then
		return nil, topologyError
	end
	local currentPoses, poseError = evaluateValidatedPoses(validated, data.toTimeMilliseconds)
	if not currentPoses then
		return nil, poseError
	end
	local currentPositions: { [string]: Vector3 } = {}
	local currentAngles: { [string]: Vector3 } = {}
	for _, pose in currentPoses do
		currentPositions[pose.id] = pose.position
		currentAngles[pose.id] = pose.angles
	end
	for index, definition in currentDefinitions do
		local candidate = validated[index]
		if not trajectoryEqual(definition.trajectory, candidate.trajectory) then
			data.linkedPositions[candidate.id] = currentPositions[candidate.id]
		end
		if not trajectoryEqual(definition.angularTrajectory, candidate.angularTrajectory) then
			data.linkedAngles[candidate.id] = currentAngles[candidate.id]
		end
	end
	data.definitions = validated
	capability.current = false
	return makeReadyState(data, capability.generation + 1), nil
end

function MoverPushRules.AdvanceNextTeam(frameValue: unknown): (TeamBoundary?, string?)
	local capability, capabilityError = currentCapability(frameValue, "Ready")
	if not capability then
		return nil, capabilityError
	end
	if capability.data.nextTeamIndex > #capability.data.teamPlans then
		return nil, "no-team-remaining"
	end
	-- Consume before invoking occupancy or synchronous crush callbacks. A
	-- callback cannot re-enter the same physical team and duplicate movement or
	-- damage; a callback failure has no reusable continuation successor.
	capability.current = false
	local data, processingError = processNextTeam(capability.data)
	if not data then
		return nil, processingError
	end
	return makeTeamBoundary(data, capability.generation + 1), nil
end

function MoverPushRules.InspectTeamBoundary(boundaryValue: unknown): (TeamBoundary?, string?)
	local capability, capabilityError = currentCapability(boundaryValue, "Boundary")
	if not capability then
		return nil, capabilityError
	end
	return boundaryValue :: TeamBoundary, nil
end

function MoverPushRules.InspectContinuationLineage(continuationValue: unknown): (unknown?, string?)
	if type(continuationValue) ~= "table" then
		return nil, "continuation-not-capability"
	end
	local capability = capabilityStates[continuationValue :: table]
	if not capability then
		return nil, "continuation-not-capability"
	end
	if not capability.current then
		return nil, "continuation-not-current"
	end
	local exposed = continuationValue :: { [unknown]: unknown }
	if exposed.phase ~= capability.phase or exposed.generation ~= capability.generation then
		return nil, "continuation-capability-mismatch"
	end
	return capability.data.lineage, nil
end

function MoverPushRules.ApplyBoundaryUpdate(boundaryValue: unknown, updateValue: unknown): (TeamBoundary?, string?)
	local capability, capabilityError = currentCapability(boundaryValue, "Boundary")
	if not capability then
		return nil, capabilityError
	end
	if type(updateValue) ~= "table" then
		return nil, "boundary-update-not-table"
	end
	local update = updateValue :: { [unknown]: unknown }
	local expectedKeys = (if update.definitions == nil then 0 else 1) + (if update.bodyMutations == nil then 0 else 1)
	if expectedKeys == 0 then
		return nil, "boundary-update-empty"
	end
	if not hasExactKeys(update, BOUNDARY_UPDATE_KEYS, expectedKeys) then
		return nil, "invalid-boundary-update-shape"
	end

	local data = copyFrameData(capability.data)
	local definitions = data.definitions
	if update.definitions ~= nil then
		local orderError = validateRawDefinitionOrder(definitions, update.definitions)
		if orderError then
			return nil, orderError
		end
		local validated, definitionError = MoverPushRules.ValidateAndOrderDefinitions(update.definitions)
		if not validated then
			return nil, "invalid-boundary-definitions:" .. (definitionError or "invalid")
		end
		local topologyError = validateDefinitionTopology(definitions, validated)
		if topologyError then
			return nil, topologyError
		end
		for index, current in definitions do
			local candidate = validated[index]
			if not trajectoryEqual(current.trajectory, candidate.trajectory) then
				data.linkedPositions[candidate.id] =
					MoverTrajectory.Evaluate(candidate.trajectory, data.toTimeMilliseconds)
			end
			if not trajectoryEqual(current.angularTrajectory, candidate.angularTrajectory) then
				data.linkedAngles[candidate.id] =
					MoverRotationRules.EvaluateDegrees(candidate.angularTrajectory, data.toTimeMilliseconds)
			end
		end
		definitions = validated
		data.definitions = validated
	end
	if update.bodyMutations ~= nil then
		local applied, mutationError = applyBodyMutations(
			definitions,
			data.bodies,
			data.bodyIdsSeen,
			data.bodySourceOrdersSeen,
			update.bodyMutations
		)
		if not applied then
			return nil, mutationError
		end
		data.bodies = applied.bodies
		data.bodyIdsSeen = applied.bodyIdsSeen
		data.bodySourceOrdersSeen = applied.bodySourceOrdersSeen
	end
	capability.current = false
	return makeTeamBoundary(data, capability.generation + 1), nil
end

function MoverPushRules.CloseBoundary(boundaryValue: unknown): (FrameState?, string?)
	local capability, capabilityError = currentCapability(boundaryValue, "Boundary")
	if not capability then
		return nil, capabilityError
	end
	-- The boundary is one-shot. Consume it before transferring its private data
	-- to the successor so no current capability can observe in-place mutation.
	capability.current = false
	local data = capability.data
	data.nextTeamIndex += 1
	data.lastRanMoverTeam = nil
	return makeReadyState(data, capability.generation + 1), nil
end

function MoverPushRules.FinishFrame(frameValue: unknown): (Result?, string?)
	local capability, capabilityError = currentCapability(frameValue, "Ready")
	if not capability then
		return nil, capabilityError
	end
	local data = capability.data
	if data.nextTeamIndex <= #data.teamPlans then
		return nil, "teams-remain-unprocessed"
	end
	local result: Result = {
		movers = snapshotPoses(data.definitions, data.linkedPositions, data.linkedAngles),
		bodies = snapshotBodies(data.bodies, nil, nil),
		pushes = table.freeze(copyArray(data.pushes)),
		viewRotations = table.freeze(copyArray(data.viewRotations)),
		detaches = table.freeze(copyArray(data.detaches)),
		crushes = table.freeze(copyArray(data.crushes)),
		teams = table.freeze(copyArray(data.teams)),
		requiresSynchronousCrushTransition = #data.crushes > 0,
	}
	table.freeze(result)
	capability.current = false
	return result, nil
end

local function resolve(
	definitionsValue: unknown,
	bodiesValue: unknown,
	fromTimeMillisecondsValue: unknown,
	toTimeMillisecondsValue: unknown,
	occupancyTestValue: unknown,
	synchronousCrushCallback: SynchronousCrushCallback?
): (Result?, string?)
	local frame, frameError = beginFrame(
		definitionsValue,
		bodiesValue,
		fromTimeMillisecondsValue,
		toTimeMillisecondsValue,
		occupancyTestValue,
		synchronousCrushCallback
	)
	if not frame then
		return nil, frameError
	end
	while frame.nextTeamIndex <= frame.teamCount do
		local boundary, boundaryError = MoverPushRules.AdvanceNextTeam(frame)
		if not boundary then
			return nil, boundaryError
		end
		local nextFrame, closeError = MoverPushRules.CloseBoundary(boundary)
		if not nextFrame then
			return nil, closeError
		end
		frame = nextFrame
	end
	return MoverPushRules.FinishFrame(frame)
end

function MoverPushRules.Resolve(
	definitionsValue: unknown,
	bodiesValue: unknown,
	fromTimeMillisecondsValue: unknown,
	toTimeMillisecondsValue: unknown,
	occupancyTestValue: unknown
): (Result?, string?)
	return resolve(
		definitionsValue,
		bodiesValue,
		fromTimeMillisecondsValue,
		toTimeMillisecondsValue,
		occupancyTestValue,
		nil
	)
end

function MoverPushRules.ResolveWithSynchronousCrush(
	definitionsValue: unknown,
	bodiesValue: unknown,
	fromTimeMillisecondsValue: unknown,
	toTimeMillisecondsValue: unknown,
	occupancyTestValue: unknown,
	synchronousCrushCallbackValue: unknown
): (Result?, string?)
	if type(synchronousCrushCallbackValue) ~= "function" then
		return nil, "synchronous-crush-callback-required"
	end
	return resolve(
		definitionsValue,
		bodiesValue,
		fromTimeMillisecondsValue,
		toTimeMillisecondsValue,
		occupancyTestValue,
		synchronousCrushCallbackValue :: SynchronousCrushCallback
	)
end

MoverPushRules.MaximumDefinitions = MAXIMUM_DEFINITIONS
MoverPushRules.MaximumBodies = MAXIMUM_BODIES
MoverPushRules.MaximumCoordinate = MAXIMUM_COORDINATE
MoverPushRules.MaximumGeometrySize = MAXIMUM_GEOMETRY_SIZE
MoverPushRules.MaximumSourceOrder = MAXIMUM_SOURCE_ORDER
MoverPushRules.Contents = Contents
MoverPushRules.Masks = Masks

return table.freeze(MoverPushRules)
