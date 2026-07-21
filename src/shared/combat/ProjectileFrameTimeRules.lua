--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure projectile frame-time arithmetic translated from Quake III Arena:
  code/game/g_main.c (G_RunFrame: level.previousTime, level.time, and msec)
  code/game/g_missile.c (G_BounceMissile and fire_* missile timing)

G_RunFrame owns exact integer level-time endpoints. G_BounceMissile assigns a
nonnegative floating-point interpolation to an int, which truncates toward
zero. The fire_* paths backdate missile trajectory time by the exact prestep
and schedule think/fuse deadlines from the unmodified level.time.

Roblox synchronized server time is presentation data only. Its elapsed time is
allowed to differ from a 16/17 ms integer level-time window by at most 2 ms;
larger scheduler/clamp discontinuities require a presentation trajectory
rebase and never alter gameplay time.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

export type FrameWindow = {
	read previousLevelTimeMilliseconds: number,
	read currentLevelTimeMilliseconds: number,
	read intervalMilliseconds: number,
}

export type LaunchTiming = {
	read launchLevelTimeMilliseconds: number,
	read prestepMilliseconds: number,
	read trajectoryStartLevelTimeMilliseconds: number,
	read initialEndpointIntervalMilliseconds: number,
	read fuseMilliseconds: number,
	read fuseDeadlineLevelTimeMilliseconds: number,
}

local ProjectileFrameTimeRules = {}

local MINIMUM_SIGNED_LEVEL_TIME_MILLISECONDS = -2_147_483_648
local MAXIMUM_LEVEL_TIME_MILLISECONDS = 2_147_483_647
local PRESENTATION_CLOCK_TOLERANCE_SECONDS = 0.002

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isBoundedInteger(value: unknown, minimum: number, maximum: number): boolean
	return isFinite(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isFiniteNonnegative(value: unknown): boolean
	return isFinite(value) and (value :: number) >= 0
end

function ProjectileFrameTimeRules.ValidateFrameWindow(
	previousLevelTimeMillisecondsValue: unknown,
	currentLevelTimeMillisecondsValue: unknown
): (FrameWindow?, string?)
	if not isBoundedInteger(previousLevelTimeMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS) then
		return nil, "invalid-projectile-frame-previous-level-time"
	end
	if not isBoundedInteger(currentLevelTimeMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS) then
		return nil, "invalid-projectile-frame-current-level-time"
	end

	local previousLevelTimeMilliseconds = previousLevelTimeMillisecondsValue :: number
	local currentLevelTimeMilliseconds = currentLevelTimeMillisecondsValue :: number
	if currentLevelTimeMilliseconds <= previousLevelTimeMilliseconds then
		return nil, "non-advancing-projectile-frame-window"
	end

	local window: FrameWindow = {
		previousLevelTimeMilliseconds = previousLevelTimeMilliseconds,
		currentLevelTimeMilliseconds = currentLevelTimeMilliseconds,
		intervalMilliseconds = currentLevelTimeMilliseconds - previousLevelTimeMilliseconds,
	}
	table.freeze(window)
	return window, nil
end

function ProjectileFrameTimeRules.DeriveBounceTimeMilliseconds(
	previousLevelTimeMillisecondsValue: unknown,
	currentLevelTimeMillisecondsValue: unknown,
	impactFractionValue: unknown
): (number?, string?)
	local window, windowError = ProjectileFrameTimeRules.ValidateFrameWindow(
		previousLevelTimeMillisecondsValue,
		currentLevelTimeMillisecondsValue
	)
	if not window then
		return nil, windowError
	end
	if
		not isFinite(impactFractionValue)
		or (impactFractionValue :: number) < 0
		or (impactFractionValue :: number) > 1
	then
		return nil, "invalid-projectile-bounce-fraction"
	end

	local interpolated = window.previousLevelTimeMilliseconds
		+ window.intervalMilliseconds * (impactFractionValue :: number)
	-- C converts this nonnegative float to int by truncating toward zero. floor
	-- is exactly equivalent because the validated G_RunFrame endpoints and
	-- fraction cannot produce a negative interpolation.
	return math.floor(interpolated), nil
end

function ProjectileFrameTimeRules.DeriveLaunchTiming(
	launchLevelTimeMillisecondsValue: unknown,
	prestepMillisecondsValue: unknown,
	fuseMillisecondsValue: unknown
): (LaunchTiming?, string?)
	if not isBoundedInteger(launchLevelTimeMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS) then
		return nil, "invalid-projectile-launch-level-time"
	end
	if not isBoundedInteger(prestepMillisecondsValue, 1, MAXIMUM_LEVEL_TIME_MILLISECONDS) then
		return nil, "invalid-projectile-prestep-milliseconds"
	end
	if not isBoundedInteger(fuseMillisecondsValue, 1, MAXIMUM_LEVEL_TIME_MILLISECONDS) then
		return nil, "invalid-projectile-fuse-milliseconds"
	end

	local launchLevelTimeMilliseconds = launchLevelTimeMillisecondsValue :: number
	local prestepMilliseconds = prestepMillisecondsValue :: number
	local fuseMilliseconds = fuseMillisecondsValue :: number
	local trajectoryStartLevelTimeMilliseconds = launchLevelTimeMilliseconds - prestepMilliseconds
	local fuseDeadlineLevelTimeMilliseconds = launchLevelTimeMilliseconds + fuseMilliseconds
	if trajectoryStartLevelTimeMilliseconds < MINIMUM_SIGNED_LEVEL_TIME_MILLISECONDS then
		return nil, "projectile-prestep-level-time-underflow"
	end
	if fuseDeadlineLevelTimeMilliseconds > MAXIMUM_LEVEL_TIME_MILLISECONDS then
		return nil, "projectile-fuse-level-time-overflow"
	end

	local timing: LaunchTiming = {
		launchLevelTimeMilliseconds = launchLevelTimeMilliseconds,
		prestepMilliseconds = prestepMilliseconds,
		trajectoryStartLevelTimeMilliseconds = trajectoryStartLevelTimeMilliseconds,
		initialEndpointIntervalMilliseconds = launchLevelTimeMilliseconds - trajectoryStartLevelTimeMilliseconds,
		fuseMilliseconds = fuseMilliseconds,
		fuseDeadlineLevelTimeMilliseconds = fuseDeadlineLevelTimeMilliseconds,
	}
	table.freeze(timing)
	return timing, nil
end

function ProjectileFrameTimeRules.IsPresentationClockDiscontinuous(
	levelIntervalMillisecondsValue: unknown,
	presentationIntervalSecondsValue: unknown
): (boolean?, string?)
	-- A launch prestep makes the first endpoint interval 50 ms even when the
	-- enclosing G_RunFrame window is 0 -> 17, so this accepts the exact derived
	-- interval rather than requiring two nonnegative global level-time endpoints.
	if not isBoundedInteger(levelIntervalMillisecondsValue, 1, MAXIMUM_LEVEL_TIME_MILLISECONDS) then
		return nil, "invalid-projectile-level-time-interval"
	end
	if not isFiniteNonnegative(presentationIntervalSecondsValue) then
		return nil, "invalid-projectile-presentation-time-interval"
	end

	local levelIntervalSeconds = (levelIntervalMillisecondsValue :: number) / 1000
	local presentationIntervalSeconds = presentationIntervalSecondsValue :: number
	return math.abs(presentationIntervalSeconds - levelIntervalSeconds) > PRESENTATION_CLOCK_TOLERANCE_SECONDS, nil
end

ProjectileFrameTimeRules.MaximumLevelTimeMilliseconds = MAXIMUM_LEVEL_TIME_MILLISECONDS
ProjectileFrameTimeRules.MinimumSignedLevelTimeMilliseconds = MINIMUM_SIGNED_LEVEL_TIME_MILLISECONDS
ProjectileFrameTimeRules.PresentationClockToleranceSeconds = PRESENTATION_CLOCK_TOLERANCE_SECONDS

return table.freeze(ProjectileFrameTimeRules)
