--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure missile trajectory evaluation translated from Quake III Arena:
  code/game/bg_misc.c (BG_EvaluateTrajectory, BG_EvaluateTrajectoryDelta)
  code/game/g_missile.c (G_BounceMissile)
  code/cgame/cg_ents.c (CG_CalcEntityLerpPositions, CG_Missile)

The frozen string-keyed state and Roblox Attribute names are original Roblox
Arena transport infrastructure. The client evaluates only server-authored
trajectory state; it never predicts collision, impact, damage, or lifetime.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

export type Kind = "Stationary" | "Linear" | "Gravity"

export type State = {
	kind: Kind,
	base: Vector3,
	velocity: Vector3,
	startServerTime: number,
	gravity: number,
	revision: number,
}

local ProjectileTrajectory = {}

local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_VELOCITY_COMPONENT = 100_000
local MAXIMUM_GRAVITY = 100_000
local MAXIMUM_SERVER_TIME = 1_000_000_000_000
local MAXIMUM_REVISION = 2_147_483_647
local MAXIMUM_EVALUATION_SECONDS = 30
local MAXIMUM_WIRE_LENGTH = 384
local WIRE_VERSION = "1"

local Kind = table.freeze({
	Stationary = "Stationary" :: "Stationary",
	Linear = "Linear" :: "Linear",
	Gravity = "Gravity" :: "Gravity",
})

local Attributes = table.freeze({
	Kind = "TrajectoryKind",
	Base = "TrajectoryBase",
	Velocity = "TrajectoryVelocity",
	StartServerTime = "TrajectoryStateStartServerTime",
	Gravity = "TrajectoryGravity",
	Revision = "TrajectoryStateRevision",
	Wire = "TrajectoryStateWire",
})

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isBoundedVector(value: unknown, maximumComponent: number): boolean
	return typeof(value) == "Vector3"
		and isFinite(value.X)
		and isFinite(value.Y)
		and isFinite(value.Z)
		and math.abs(value.X) <= maximumComponent
		and math.abs(value.Y) <= maximumComponent
		and math.abs(value.Z) <= maximumComponent
end

local function validateKind(value: unknown): Kind?
	if value == Kind.Stationary or value == Kind.Linear or value == Kind.Gravity then
		return value :: Kind
	end
	return nil
end

local function inspectState(stateValue: unknown): State?
	if type(stateValue) ~= "table" then
		return nil
	end
	local state = stateValue :: any
	local kind = validateKind(state.kind)
	if
		not kind
		or not isBoundedVector(state.base, MAXIMUM_COORDINATE)
		or not isBoundedVector(state.velocity, MAXIMUM_VELOCITY_COMPONENT)
		or not isFinite(state.startServerTime)
		or math.abs(state.startServerTime) > MAXIMUM_SERVER_TIME
		or not isFinite(state.gravity)
		or state.gravity < 0
		or state.gravity > MAXIMUM_GRAVITY
		or not isFinite(state.revision)
		or state.revision % 1 ~= 0
		or state.revision < 1
		or state.revision > MAXIMUM_REVISION
	then
		return nil
	end
	if kind == Kind.Stationary and (state.velocity ~= Vector3.zero or state.gravity ~= 0) then
		return nil
	end
	if kind == Kind.Linear and state.gravity ~= 0 then
		return nil
	end
	if kind == Kind.Gravity and state.gravity <= 0 then
		return nil
	end
	return stateValue :: State
end

function ProjectileTrajectory.Create(
	kindValue: unknown,
	baseValue: unknown,
	velocityValue: unknown,
	startServerTimeValue: unknown,
	gravityValue: unknown,
	revisionValue: unknown
): (State?, string?)
	local kind = validateKind(kindValue)
	if not kind then
		return nil, "InvalidKind"
	end
	if not isBoundedVector(baseValue, MAXIMUM_COORDINATE) then
		return nil, "InvalidBase"
	end
	if not isBoundedVector(velocityValue, MAXIMUM_VELOCITY_COMPONENT) then
		return nil, "InvalidVelocity"
	end
	if not isFinite(startServerTimeValue) or math.abs(startServerTimeValue :: number) > MAXIMUM_SERVER_TIME then
		return nil, "InvalidStartServerTime"
	end
	if not isFinite(gravityValue) or (gravityValue :: number) < 0 or (gravityValue :: number) > MAXIMUM_GRAVITY then
		return nil, "InvalidGravity"
	end
	if
		not isFinite(revisionValue)
		or (revisionValue :: number) % 1 ~= 0
		or (revisionValue :: number) < 1
		or (revisionValue :: number) > MAXIMUM_REVISION
	then
		return nil, "InvalidRevision"
	end

	local velocity = velocityValue :: Vector3
	local gravity = gravityValue :: number
	if kind == Kind.Stationary and (velocity ~= Vector3.zero or gravity ~= 0) then
		return nil, "NoncanonicalStationary"
	end
	if kind == Kind.Linear and gravity ~= 0 then
		return nil, "NoncanonicalLinear"
	end
	if kind == Kind.Gravity and gravity <= 0 then
		return nil, "NoncanonicalGravity"
	end

	return table.freeze({
		kind = kind,
		base = baseValue :: Vector3,
		velocity = velocity,
		startServerTime = startServerTimeValue :: number,
		gravity = gravity,
		revision = revisionValue :: number,
	}),
		nil
end

function ProjectileTrajectory.Evaluate(stateValue: unknown, atServerTimeValue: unknown): Vector3?
	if not isFinite(atServerTimeValue) then
		return nil
	end
	local validated = inspectState(stateValue)
	if not validated then
		return nil
	end

	local elapsed = (atServerTimeValue :: number) - validated.startServerTime
	if math.abs(elapsed) > MAXIMUM_EVALUATION_SECONDS then
		return nil
	end
	if validated.kind == Kind.Stationary then
		return validated.base
	end

	local position = validated.base + validated.velocity * elapsed
	if validated.kind == Kind.Gravity then
		position -= Vector3.yAxis * (0.5 * validated.gravity * elapsed * elapsed)
	end
	return if isBoundedVector(position, MAXIMUM_COORDINATE) then position else nil
end

function ProjectileTrajectory.EvaluateDelta(stateValue: unknown, atServerTimeValue: unknown): Vector3?
	if not isFinite(atServerTimeValue) then
		return nil
	end
	local validated = inspectState(stateValue)
	if not validated then
		return nil
	end
	local elapsed = (atServerTimeValue :: number) - validated.startServerTime
	if math.abs(elapsed) > MAXIMUM_EVALUATION_SECONDS then
		return nil
	end
	if validated.kind == Kind.Stationary then
		return Vector3.zero
	end
	local velocity = validated.velocity
	if validated.kind == Kind.Gravity then
		velocity -= Vector3.yAxis * (validated.gravity * elapsed)
	end
	return if isBoundedVector(velocity, MAXIMUM_VELOCITY_COMPONENT) then velocity else nil
end

function ProjectileTrajectory.Serialize(stateValue: unknown): string?
	local state = inspectState(stateValue)
	if not state then
		return nil
	end
	local kindToken = if state.kind == Kind.Stationary then "S" elseif state.kind == Kind.Linear then "L" else "G"
	return table.concat({
		WIRE_VERSION,
		string.format("%.17g", state.revision),
		kindToken,
		string.format("%.17g", state.base.X),
		string.format("%.17g", state.base.Y),
		string.format("%.17g", state.base.Z),
		string.format("%.17g", state.velocity.X),
		string.format("%.17g", state.velocity.Y),
		string.format("%.17g", state.velocity.Z),
		string.format("%.17g", state.startServerTime),
		string.format("%.17g", state.gravity),
	}, "|")
end

function ProjectileTrajectory.Deserialize(wireValue: unknown): (State?, string?)
	if type(wireValue) ~= "string" or wireValue == "" or #wireValue > MAXIMUM_WIRE_LENGTH then
		return nil, "InvalidWire"
	end
	local fields = string.split(wireValue, "|")
	if #fields ~= 11 or fields[1] ~= WIRE_VERSION then
		return nil, "InvalidWireShape"
	end
	local kind = if fields[3] == "S"
		then Kind.Stationary
		elseif fields[3] == "L" then Kind.Linear
		elseif fields[3] == "G" then Kind.Gravity
		else nil
	if not kind then
		return nil, "InvalidWireKind"
	end
	local revision = tonumber(fields[2])
	local baseX = tonumber(fields[4])
	local baseY = tonumber(fields[5])
	local baseZ = tonumber(fields[6])
	local velocityX = tonumber(fields[7])
	local velocityY = tonumber(fields[8])
	local velocityZ = tonumber(fields[9])
	local startServerTime = tonumber(fields[10])
	local gravity = tonumber(fields[11])
	if
		revision == nil
		or baseX == nil
		or baseY == nil
		or baseZ == nil
		or velocityX == nil
		or velocityY == nil
		or velocityZ == nil
		or startServerTime == nil
		or gravity == nil
	then
		return nil, "InvalidWireNumber"
	end
	return ProjectileTrajectory.Create(
		kind,
		Vector3.new(baseX, baseY, baseZ),
		Vector3.new(velocityX, velocityY, velocityZ),
		startServerTime,
		gravity,
		revision
	)
end

ProjectileTrajectory.Kind = Kind
ProjectileTrajectory.Attributes = Attributes
ProjectileTrajectory.MaximumCoordinate = MAXIMUM_COORDINATE
ProjectileTrajectory.MaximumVelocityComponent = MAXIMUM_VELOCITY_COMPONENT
ProjectileTrajectory.MaximumGravity = MAXIMUM_GRAVITY
ProjectileTrajectory.MaximumRevision = MAXIMUM_REVISION
ProjectileTrajectory.MaximumEvaluationSeconds = MAXIMUM_EVALUATION_SECONDS
ProjectileTrajectory.MaximumWireLength = MAXIMUM_WIRE_LENGTH
ProjectileTrajectory.WireVersion = WIRE_VERSION

return table.freeze(ProjectileTrajectory)
