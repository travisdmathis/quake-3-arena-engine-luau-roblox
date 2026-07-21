--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox/Luau translation of landing behavior from:
  code/game/bg_pmove.c (PM_CrashLand)
  code/game/g_active.c (ClientEvents fall damage)
  code/cgame/cg_event.c (EV_FALL_SHORT / MEDIUM / FAR camera changes)
  code/cgame/cg_view.c and code/cgame/cg_local.h
    (LAND_DEFLECT_TIME / LAND_RETURN_TIME camera curve)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

local Constants = require(script.Parent.Constants)

export type Classification = "None" | "Footstep" | "Short" | "Medium" | "Far"

export type Input = {
	previousOriginY: number,
	landedOriginY: number,
	previousVelocityY: number,
	gravity: number,
	crouched: boolean,
	waterLevel: number,
	noDamageSurface: boolean,
}

export type Result = {
	valid: boolean,
	suppressed: boolean,
	rawDelta: number,
	delta: number,
	classification: Classification,
	damage: number,
	cameraOffsetStuds: number,
}

local Classification = table.freeze({
	None = "None" :: "None",
	Footstep = "Footstep" :: "Footstep",
	Short = "Short" :: "Short",
	Medium = "Medium" :: "Medium",
	Far = "Far" :: "Far",
})

local CAMERA_DEFLECT_SECONDS = 0.15
local CAMERA_RETURN_SECONDS = 0.3

local Landing = {
	Classification = Classification,
	CameraDeflectSeconds = CAMERA_DEFLECT_SECONDS,
	CameraReturnSeconds = CAMERA_RETURN_SECONDS,
}

-- Inputs use Roblox units. PM_CrashLand's 0.0001 scale and event thresholds
-- operate on Q3 source units, so all vertical quantities are converted together.
function Landing.ComputeDelta(
	previousOriginY: number,
	landedOriginY: number,
	previousVelocityY: number,
	gravity: number
): number?
	if gravity <= 0 then
		return nil
	end

	local dist = (landedOriginY - previousOriginY) / Constants.UnitsToStuds
	local velocity = previousVelocityY / Constants.UnitsToStuds
	local acceleration = -gravity / Constants.UnitsToStuds

	local a = acceleration / 2
	local b = velocity
	local c = -dist
	local discriminant = b * b - 4 * a * c
	if discriminant < 0 then
		return nil
	end

	local time = (-b - math.sqrt(discriminant)) / (2 * a)
	local impactVelocity = velocity + time * acceleration
	return impactVelocity * impactVelocity * 0.0001
end

function Landing.Classify(delta: number, noDamageSurface: boolean): Classification
	if delta < 1 or noDamageSurface then
		return Classification.None
	elseif delta > 60 then
		return Classification.Far
	elseif delta > 40 then
		return Classification.Medium
	elseif delta > 7 then
		return Classification.Short
	end
	return Classification.Footstep
end

local function damageFor(classification: Classification): number
	if classification == Classification.Far then
		return 10
	elseif classification == Classification.Medium then
		return 5
	end
	return 0
end

local function cameraOffsetFor(classification: Classification): number
	if classification == Classification.Far then
		return -2.4
	elseif classification == Classification.Medium then
		return -1.6
	elseif classification == Classification.Short then
		return -0.8
	end
	return 0
end

function Landing.Evaluate(input: Input): Result
	local rawDelta =
		Landing.ComputeDelta(input.previousOriginY, input.landedOriginY, input.previousVelocityY, input.gravity)
	if rawDelta == nil then
		return {
			valid = false,
			suppressed = false,
			rawDelta = 0,
			delta = 0,
			classification = Classification.None,
			damage = 0,
			cameraOffsetStuds = 0,
		}
	end

	local delta = rawDelta
	if input.crouched then
		delta *= 2
	end

	-- PM_CrashLand returns before event generation when fully submerged.
	if input.waterLevel == 3 then
		return {
			valid = true,
			suppressed = true,
			rawDelta = rawDelta,
			delta = 0,
			classification = Classification.None,
			damage = 0,
			cameraOffsetStuds = 0,
		}
	elseif input.waterLevel == 2 then
		delta *= 0.25
	elseif input.waterLevel == 1 then
		delta *= 0.5
	end

	local classification = Landing.Classify(delta, input.noDamageSurface)
	return {
		valid = true,
		suppressed = input.noDamageSurface and delta >= 1,
		rawDelta = rawDelta,
		delta = delta,
		classification = classification,
		damage = damageFor(classification),
		cameraOffsetStuds = cameraOffsetFor(classification),
	}
end

function Landing.CameraOffsetAt(cameraOffsetStuds: number, elapsedSeconds: number): number
	if elapsedSeconds <= 0 then
		return 0
	elseif elapsedSeconds < CAMERA_DEFLECT_SECONDS then
		return cameraOffsetStuds * elapsedSeconds / CAMERA_DEFLECT_SECONDS
	elseif elapsedSeconds < CAMERA_DEFLECT_SECONDS + CAMERA_RETURN_SECONDS then
		local returnElapsed = elapsedSeconds - CAMERA_DEFLECT_SECONDS
		return cameraOffsetStuds * (1 - returnElapsed / CAMERA_RETURN_SECONDS)
	end
	return 0
end

return table.freeze(Landing)
