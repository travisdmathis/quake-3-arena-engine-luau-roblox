--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure death-view policy translated from:
  code/game/g_combat.c (LookAtKiller, STAT_DEAD_YAW)
  code/cgame/cg_view.c (forced dead third person and fixed first-person angles)
  code/cgame/cg_main.c (cg_thirdPersonRange default)

The caller must supply the exact entity trajectory bases and the victim's
separately retained entity angle. Ordinary Player bases come from snapped BG
projection; G_TryPushingEntity can instead restore a client's precise
fractional ps.origin into s.pos.trBase before mover damage. Mover, projectile,
and other entity `s.pos.trBase` values can also remain fractional.
Movement.State position/viewYaw are not interchangeable source fields.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

export type Source = "Attacker" | "Inflictor" | "RetainedEntityYaw"
export type Request = {
	victimTrajectoryBase: Vector3,
	retainedEntityYawDegrees: number,
	attackerTrajectoryBase: Vector3?,
	inflictorTrajectoryBase: Vector3?,
}
export type Result = {
	read deadYawDegrees: number,
	read source: Source,
}
export type CameraTraceResult = {
	read fraction: number,
	read position: Vector3,
}
export type CameraTrace = (origin: Vector3, displacement: Vector3) -> CameraTraceResult
export type ThirdPersonView = {
	read eye: Vector3,
	read position: Vector3,
	read focusPoint: Vector3,
	read look: Vector3,
	read rollDegrees: number,
}

local DeathViewRules = {}

local MAXIMUM_COMPONENT = 100_000
local MAXIMUM_ENTITY_ANGLE = 1_000_000
local REQUEST_KEYS = table.freeze({
	victimTrajectoryBase = true,
	retainedEntityYawDegrees = true,
	attackerTrajectoryBase = true,
	inflictorTrajectoryBase = true,
})

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isBoundedVector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFinite(vector.X)
		and isFinite(vector.Y)
		and isFinite(vector.Z)
		and math.max(math.abs(vector.X), math.abs(vector.Y), math.abs(vector.Z)) <= MAXIMUM_COMPONENT
end

local function hasExactRawShape(value: unknown): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	local raw = value :: { [unknown]: unknown }
	local count = 0
	for key in next, raw do
		if type(key) ~= "string" or REQUEST_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	local expectedCount = 2
	if rawget(raw, "attackerTrajectoryBase") ~= nil then
		expectedCount += 1
	end
	if rawget(raw, "inflictorTrajectoryBase") ~= nil then
		expectedCount += 1
	end
	return count == expectedCount
end

local function truncateTowardZero(value: number): number
	return if value < 0 then math.ceil(value) else math.floor(value)
end

local function directionYawDegrees(direction: Vector3): number
	-- Documented project basis: Q3 +X = Roblox -Z, Q3 +Y = Roblox -X.
	local q3X = -direction.Z
	local q3Y = -direction.X
	if q3X == 0 and q3Y == 0 then
		return 0
	end
	local yaw = math.deg(math.atan2(q3Y, q3X))
	if yaw < 0 then
		yaw += 360
	end
	return truncateTowardZero(yaw)
end

local function q3Forward(pitchDegrees: number, yawDegrees: number): Vector3
	local pitch = math.rad(pitchDegrees)
	local yaw = math.rad(yawDegrees)
	local cosPitch = math.cos(pitch)
	-- Q3 +X = Roblox -Z, Q3 +Y = Roblox -X, Q3 +Z = Roblox +Y.
	return Vector3.new(-cosPitch * math.sin(yaw), -math.sin(pitch), -cosPitch * math.cos(yaw)).Unit
end

local function validateCameraTraceResult(value: unknown): CameraTraceResult?
	if type(value) ~= "table" then
		return nil
	end
	local result = value :: { [unknown]: unknown }
	if
		not isFinite(result.fraction)
		or (result.fraction :: number) < 0
		or (result.fraction :: number) > 1
		or not isBoundedVector(result.position)
	then
		return nil
	end
	return value :: CameraTraceResult
end

function DeathViewRules.ResolveThirdPersonView(
	bodyPositionValue: unknown,
	viewHeightValue: unknown,
	deadYawDegreesValue: unknown,
	traceValue: unknown
): (ThirdPersonView?, string?)
	if
		not isBoundedVector(bodyPositionValue)
		or not isFinite(viewHeightValue)
		or math.abs(viewHeightValue :: number) > MAXIMUM_COMPONENT
		or not isFinite(deadYawDegreesValue)
		or math.abs(deadYawDegreesValue :: number) > MAXIMUM_ENTITY_ANGLE
		or type(traceValue) ~= "function"
	then
		return nil, "invalid-third-person-view-request"
	end

	local bodyPosition = bodyPositionValue :: Vector3
	local deadYawDegrees = deadYawDegreesValue :: number
	local trace = traceValue :: CameraTrace
	local eye = bodyPosition + Vector3.yAxis * (viewHeightValue :: number)
	local focusForward = q3Forward(DeathViewRules.FixedDeadPitchDegrees, deadYawDegrees)
	local focusPoint = eye + focusForward * DeathViewRules.FocusDistanceStuds
	local cameraForward = q3Forward(DeathViewRules.FixedDeadPitchDegrees * 0.5, deadYawDegrees)
	local desired = eye
		+ Vector3.yAxis * DeathViewRules.ThirdPersonInitialLiftStuds
		- cameraForward * DeathViewRules.ThirdPersonRangeStuds
	local first = validateCameraTraceResult(trace(eye, desired - eye))
	if not first then
		return nil, "invalid-third-person-first-trace"
	end
	local position = first.position
	if first.fraction ~= 1 then
		local raised = position
			+ Vector3.yAxis * ((1 - first.fraction) * DeathViewRules.ThirdPersonObstructionLiftStuds)
		local second = validateCameraTraceResult(trace(eye, raised - eye))
		if not second then
			return nil, "invalid-third-person-second-trace"
		end
		position = second.position
	end
	local look = focusPoint - position
	if look.Magnitude < 1e-6 then
		return nil, "degenerate-third-person-focus"
	end
	local result: ThirdPersonView = {
		eye = eye,
		position = position,
		focusPoint = focusPoint,
		look = look.Unit,
		rollDegrees = DeathViewRules.FixedDeadRollDegrees,
	}
	table.freeze(result)
	return result, nil
end

function DeathViewRules.Resolve(requestValue: unknown): (Result?, string?)
	if not hasExactRawShape(requestValue) then
		return nil, "invalid-death-view-request-shape"
	end
	local request = requestValue :: { [unknown]: unknown }
	local victim = rawget(request, "victimTrajectoryBase")
	local retainedYaw = rawget(request, "retainedEntityYawDegrees")
	local attacker = rawget(request, "attackerTrajectoryBase")
	local inflictor = rawget(request, "inflictorTrajectoryBase")
	if
		not isBoundedVector(victim)
		or not isFinite(retainedYaw)
		or math.abs(retainedYaw :: number) > MAXIMUM_ENTITY_ANGLE
		or (attacker ~= nil and not isBoundedVector(attacker))
		or (inflictor ~= nil and not isBoundedVector(inflictor))
	then
		return nil, "invalid-death-view-request"
	end

	local deadYawDegrees: number
	local source: Source
	if attacker ~= nil then
		deadYawDegrees = directionYawDegrees((attacker :: Vector3) - (victim :: Vector3))
		source = "Attacker"
	elseif inflictor ~= nil then
		deadYawDegrees = directionYawDegrees((inflictor :: Vector3) - (victim :: Vector3))
		source = "Inflictor"
	else
		-- LookAtKiller assigns self->s.angles[YAW] directly to an integer stat.
		-- Do not normalize this separately retained entity angle first.
		deadYawDegrees = truncateTowardZero(retainedYaw :: number)
		source = "RetainedEntityYaw"
	end
	local result: Result = {
		deadYawDegrees = deadYawDegrees,
		source = source,
	}
	table.freeze(result)
	return result, nil
end

DeathViewRules.FixedDeadPitchDegrees = -15
DeathViewRules.FixedDeadRollDegrees = 40
DeathViewRules.ThirdPersonRangeUnits = 40
DeathViewRules.ThirdPersonRangeStuds = 4
DeathViewRules.ThirdPersonHullSizeStuds = 0.8
DeathViewRules.ThirdPersonInitialLiftStuds = 0.8
DeathViewRules.ThirdPersonObstructionLiftStuds = 3.2
DeathViewRules.FocusDistanceStuds = 51.2

return table.freeze(DeathViewRules)
