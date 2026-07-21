--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure playerState_t -> entityState_t conversion primitives translated from:
  code/game/bg_misc.c (BG_PlayerStateToEntityState)
  code/game/q_shared.h (SnapVector C integer truncation)
  code/game/g_weapon.c (SnapVectorTowards)
  code/game/g_missile.c (impact/fuse terminal position snapping)
  code/game/q_math.c (vectoangles and AngleVectors)
  code/game/g_client.c (SetClientViewAngle generic s.angles ownership)
  code/game/g_combat.c (player_die generic pitch/roll clearing)

The entity angular trajectory (`s.apos.trBase`) and generic entity angles
(`s.angles`) are intentionally separate domains. Ordinary BG conversion writes
only the former; SetClientViewAngle writes the latter.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local CommandQuantization = require(script.Parent.CommandQuantization)
local Constants = require(script.Parent.Constants)

export type Angles = {
	read pitch: number,
	read yaw: number,
	read roll: number,
	read look: Vector3,
}

local EntityStateConversionRules = {}

local MAXIMUM_COMPONENT = 100_000
local ANGLE_MATCH_EPSILON = 1e-6
local ZERO_EPSILON = 1e-9
local FULL_TURN_DEGREES = 360
local ANGLE_KEYS: { [string]: boolean } = table.freeze({
	pitch = true,
	yaw = true,
	roll = true,
	look = true,
})

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isBoundedVector(value: unknown, maximum: number): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFinite(vector.X)
		and isFinite(vector.Y)
		and isFinite(vector.Z)
		and math.max(math.abs(vector.X), math.abs(vector.Y), math.abs(vector.Z)) <= maximum
end

local function normalizedFiniteVector(value: unknown): Vector3?
	if not isBoundedVector(value, MAXIMUM_COMPONENT) then
		return nil
	end
	local vector = value :: Vector3
	local largest = math.max(math.abs(vector.X), math.abs(vector.Y), math.abs(vector.Z))
	if largest == 0 then
		return nil
	end
	local scaled = vector / largest
	local magnitude = scaled.Magnitude
	if not isFinite(magnitude) or magnitude == 0 then
		return nil
	end
	return scaled / magnitude
end

local function q3Look(pitchDegrees: number, yawDegrees: number): Vector3
	local pitch = math.rad(pitchDegrees)
	local yaw = math.rad(yawDegrees)
	local cosPitch = math.cos(pitch)
	-- Q3 +X -> Roblox -Z, Q3 +Y -> Roblox -X, Q3 +Z -> Roblox +Y.
	return Vector3.new(-cosPitch * math.sin(yaw), -math.sin(pitch), -cosPitch * math.cos(yaw)).Unit
end

local function hasExactAngleShape(value: unknown): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	local raw = value :: { [unknown]: unknown }
	local count = 0
	for key in next, raw do
		if type(key) ~= "string" or ANGLE_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 4
end

local function inspectAngles(value: unknown): Angles?
	if not hasExactAngleShape(value) then
		return nil
	end
	local raw = value :: { [unknown]: unknown }
	local pitch = rawget(raw, "pitch")
	local yaw = rawget(raw, "yaw")
	local roll = rawget(raw, "roll")
	local look = rawget(raw, "look")
	if
		not isFinite(pitch)
		or not isFinite(yaw)
		or not isFinite(roll)
		or math.max(math.abs(pitch :: number), math.abs(yaw :: number), math.abs(roll :: number)) > MAXIMUM_COMPONENT
		or not isBoundedVector(look, 1)
	then
		return nil
	end
	local lookVector = look :: Vector3
	if
		lookVector.Magnitude < 1 - ANGLE_MATCH_EPSILON
		or lookVector.Magnitude > 1 + ANGLE_MATCH_EPSILON
		or q3Look(pitch :: number, yaw :: number):Dot(lookVector.Unit) < 1 - ANGLE_MATCH_EPSILON
	then
		return nil
	end
	return value :: Angles
end

local function makeAngles(pitch: number, yaw: number, roll: number): Angles
	local angles: Angles = {
		pitch = if math.abs(pitch) <= ZERO_EPSILON then 0 else pitch,
		yaw = if math.abs(yaw) <= ZERO_EPSILON then 0 else yaw,
		roll = if math.abs(roll) <= ZERO_EPSILON then 0 else roll,
		look = q3Look(pitch, yaw),
	}
	table.freeze(angles)
	return angles
end

local function truncate(value: number): number
	return assert(CommandQuantization.TruncateTowardZero(value), "validated entity-state component did not truncate")
end

function EntityStateConversionRules.SnapTrajectoryBase(positionValue: unknown): Vector3?
	if not isBoundedVector(positionValue, MAXIMUM_COMPONENT) then
		return nil
	end
	local position = positionValue :: Vector3
	local scale = Constants.UnitsToStuds
	local function snap(component: number): number
		local result = truncate(component / scale) * scale
		return if math.abs(result) <= ZERO_EPSILON then 0 else result
	end
	return Vector3.new(snap(position.X), snap(position.Y), snap(position.Z))
end

-- Roblox Vector3 stores float32 components. With the 0.1 stud source scale,
-- an exact integer source coordinate can round just below its decimal stud
-- value, so applying C truncation a second time is not an idempotence test.
-- A fixed source-unit epsilon is also invalid because float32 spacing grows
-- with world magnitude. Rebuild the nearest source-grid coordinate as a
-- Vector3 instead: its constructor performs the same float32 storage rounding,
-- so exact equality accepts every value emitted by SnapTrajectoryBase while
-- still rejecting a distinct representable off-grid value.
function EntityStateConversionRules.IsSnappedTrajectoryBase(positionValue: unknown): boolean
	if not isBoundedVector(positionValue, MAXIMUM_COMPONENT) then
		return false
	end
	local position = positionValue :: Vector3
	local scale = Constants.UnitsToStuds
	local function canonicalStoredComponent(component: number): number
		return math.round(component / scale) * scale
	end
	return position
		== Vector3.new(
			canonicalStoredComponent(position.X),
			canonicalStoredComponent(position.Y),
			canonicalStoredComponent(position.Z)
		)
end

function EntityStateConversionRules.SnapTrajectoryBaseTowards(positionValue: unknown, towardValue: unknown): Vector3?
	if not isBoundedVector(positionValue, MAXIMUM_COMPONENT) or not isBoundedVector(towardValue, MAXIMUM_COMPONENT) then
		return nil
	end
	local position = positionValue :: Vector3
	local toward = towardValue :: Vector3
	local scale = Constants.UnitsToStuds
	local function snap(component: number, towardComponent: number): number
		local sourceComponent = component / scale
		local sourceToward = towardComponent / scale
		-- Preserve the pinned C exactly: `(int)v` truncates toward zero, and
		-- the `to > v` branch adds one even for negative components.
		local result = truncate(sourceComponent)
		if sourceToward > sourceComponent then
			result += 1
		end
		local scaled = result * scale
		return if math.abs(scaled) <= ZERO_EPSILON then 0 else scaled
	end
	local snapped = Vector3.new(snap(position.X, toward.X), snap(position.Y, toward.Y), snap(position.Z, toward.Z))
	return if isBoundedVector(snapped, MAXIMUM_COMPONENT) then snapped else nil
end

-- Canonical vectoangles inverse for the project's documented basis. Roblox map
-- data stores a direction rather than Q3's raw authored angle vector, so this
-- preserves the exact canonical source direction available to SetClientViewAngle.
function EntityStateConversionRules.AnglesForLook(lookValue: unknown): Angles?
	local normalized = normalizedFiniteVector(lookValue)
	if not normalized then
		return nil
	end
	local q3X = -normalized.Z
	local q3Y = -normalized.X
	local q3Z = normalized.Y
	local yaw: number
	local pitch: number
	if q3X == 0 and q3Y == 0 then
		yaw = 0
		pitch = if q3Z > 0 then 90 else 270
	else
		yaw = math.deg(math.atan2(q3Y, q3X))
		if yaw < 0 then
			yaw += FULL_TURN_DEGREES
		end
		local horizontal = math.sqrt(q3X * q3X + q3Y * q3Y)
		pitch = math.deg(math.atan2(q3Z, horizontal))
		if pitch < 0 then
			pitch += FULL_TURN_DEGREES
		end
	end
	return makeAngles(-pitch, yaw, 0)
end

function EntityStateConversionRules.SnapAngularTrajectoryBase(anglesValue: unknown): Angles?
	local angles = inspectAngles(anglesValue)
	if not angles then
		return nil
	end
	return makeAngles(truncate(angles.pitch), truncate(angles.yaw), truncate(angles.roll))
end

function EntityStateConversionRules.MovementViewAngles(
	viewPitchValue: unknown,
	viewYawValue: unknown,
	viewRollValue: unknown
): Angles?
	local pitch = CommandQuantization.Short2Angle(viewPitchValue)
	local yaw = CommandQuantization.Short2Angle(viewYawValue)
	local roll = CommandQuantization.Short2Angle(viewRollValue)
	if pitch == nil or yaw == nil or roll == nil then
		return nil
	end
	return makeAngles(pitch, yaw, roll)
end

function EntityStateConversionRules.SnapMovementViewAngles(
	viewPitchValue: unknown,
	viewYawValue: unknown,
	viewRollValue: unknown
): Angles?
	local angles = EntityStateConversionRules.MovementViewAngles(viewPitchValue, viewYawValue, viewRollValue)
	return if angles then EntityStateConversionRules.SnapAngularTrajectoryBase(angles) else nil
end

function EntityStateConversionRules.DeathGenericAngles(anglesValue: unknown): Angles?
	local angles = inspectAngles(anglesValue)
	if not angles then
		return nil
	end
	-- player_die clears s.angles[PITCH/ROLL] and leaves generic yaw untouched.
	return makeAngles(0, angles.yaw, 0)
end

function EntityStateConversionRules.InspectAngles(value: unknown): Angles?
	return inspectAngles(value)
end

EntityStateConversionRules.ZeroAngles = makeAngles(0, 0, 0)
EntityStateConversionRules.MaximumComponent = MAXIMUM_COMPONENT

return table.freeze(EntityStateConversionRules)
