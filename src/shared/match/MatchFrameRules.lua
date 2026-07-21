--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure integer level-time rules for the Q3 match lifecycle translated from:
  code/game/g_main.c (G_RunFrame, CheckTournament, CheckExitRules, LogExit,
    BeginIntermission)
  code/game/g_local.h (INTERMISSION_DELAY_TIME)

Roblox synchronized server time is presentation mapping only. Match authority
uses the exact integer level.time supplied by the shared fixed frame.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

export type IntermissionLatch = {
	read qualifiedAtMilliseconds: number,
	read startsAtMilliseconds: number,
	read reason: string,
	read winnerUserIds: { number },
	read winnerTeamIds: { string },
}

local MatchFrameRules = {}

local MILLISECONDS_PER_SECOND = 1_000
local INTERMISSION_DELAY_MILLISECONDS = 1_000
local MAXIMUM_LEVEL_TIME_MILLISECONDS = 2_147_483_647
local MAXIMUM_IDENTITY_INTEGER = 9_007_199_254_740_991
local MAXIMUM_REASON_LENGTH = 128
local MAXIMUM_WINNERS = 64
local DURATION_EPSILON_MILLISECONDS = 1e-6

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return isFiniteNumber(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function durationMilliseconds(secondsValue: unknown): number?
	if not isFiniteNumber(secondsValue) or (secondsValue :: number) < 0 then
		return nil
	end
	local exactMilliseconds = (secondsValue :: number) * MILLISECONDS_PER_SECOND
	local roundedMilliseconds = math.floor(exactMilliseconds + 0.5)
	if
		math.abs(exactMilliseconds - roundedMilliseconds) > DURATION_EPSILON_MILLISECONDS
		or roundedMilliseconds > MAXIMUM_LEVEL_TIME_MILLISECONDS
	then
		return nil
	end
	return roundedMilliseconds
end

local function deadlineMilliseconds(startMillisecondsValue: unknown, durationSecondsValue: unknown): number?
	if not isIntegerInRange(startMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS) then
		return nil
	end
	local duration = durationMilliseconds(durationSecondsValue)
	if duration == nil then
		return nil
	end
	local deadline = (startMillisecondsValue :: number) + duration
	return if deadline <= MAXIMUM_LEVEL_TIME_MILLISECONDS then deadline else nil
end

local function shouldRunFrame(lastMillisecondsValue: unknown, currentMillisecondsValue: unknown): boolean
	if
		not isIntegerInRange(lastMillisecondsValue, -1, MAXIMUM_LEVEL_TIME_MILLISECONDS)
		or not isIntegerInRange(currentMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS)
	then
		error("invalid Match frame level time", 2)
	end
	local lastMilliseconds = lastMillisecondsValue :: number
	local currentMilliseconds = currentMillisecondsValue :: number
	if lastMilliseconds < 0 then
		return true
	end
	if currentMilliseconds < lastMilliseconds then
		error("regressing Match frame level time", 2)
	end
	return currentMilliseconds > lastMilliseconds
end

local function presentationTimeForLevel(
	currentLevelMillisecondsValue: unknown,
	currentServerTimeSecondsValue: unknown,
	targetLevelMillisecondsValue: unknown
): number?
	if
		not isIntegerInRange(currentLevelMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS)
		or not isFiniteNumber(currentServerTimeSecondsValue)
		or (currentServerTimeSecondsValue :: number) < 0
		or not isIntegerInRange(targetLevelMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS)
	then
		return nil
	end
	local mapped = (currentServerTimeSecondsValue :: number)
		+ ((targetLevelMillisecondsValue :: number) - (currentLevelMillisecondsValue :: number))
			/ MILLISECONDS_PER_SECOND
	return if isFiniteNumber(mapped) and mapped >= 0 then mapped else nil
end

local function remainingSeconds(deadlineMillisecondsValue: unknown, currentMillisecondsValue: unknown): number?
	if
		not isIntegerInRange(deadlineMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS)
		or not isIntegerInRange(currentMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS)
	then
		return nil
	end
	return math.max(
		math.ceil(
			((deadlineMillisecondsValue :: number) - (currentMillisecondsValue :: number)) / MILLISECONDS_PER_SECOND
		),
		0
	)
end

local function cloneWinnerIds(values: unknown): { number }?
	if type(values) ~= "table" or #values > MAXIMUM_WINNERS then
		return nil
	end
	local cloned: { number } = {}
	local seen: { [number]: boolean } = {}
	for _, value in values :: { unknown } do
		if
			not isIntegerInRange(value, -MAXIMUM_IDENTITY_INTEGER, MAXIMUM_IDENTITY_INTEGER) or seen[value :: number]
		then
			return nil
		end
		seen[value :: number] = true
		table.insert(cloned, value :: number)
	end
	table.freeze(cloned)
	return cloned
end

local function cloneWinnerTeams(values: unknown): { string }?
	if type(values) ~= "table" or #values > MAXIMUM_WINNERS then
		return nil
	end
	local cloned: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, value in values :: { unknown } do
		if type(value) ~= "string" or value == "" or #value > 64 or seen[value] then
			return nil
		end
		seen[value] = true
		table.insert(cloned, value)
	end
	table.freeze(cloned)
	return cloned
end

local function createIntermissionLatch(
	existing: IntermissionLatch?,
	qualifiedAtMillisecondsValue: unknown,
	reasonValue: unknown,
	winnerUserIdsValue: unknown,
	winnerTeamIdsValue: unknown
): (IntermissionLatch?, boolean, string?)
	if existing then
		return existing, false, nil
	end
	if
		not isIntegerInRange(
			qualifiedAtMillisecondsValue,
			0,
			MAXIMUM_LEVEL_TIME_MILLISECONDS - INTERMISSION_DELAY_MILLISECONDS
		)
		or type(reasonValue) ~= "string"
		or reasonValue == ""
		or #reasonValue > MAXIMUM_REASON_LENGTH
	then
		return nil, false, "invalid-intermission-latch"
	end
	local users = cloneWinnerIds(winnerUserIdsValue)
	local teams = cloneWinnerTeams(winnerTeamIdsValue)
	if not users or not teams then
		return nil, false, "invalid-intermission-winners"
	end
	local qualifiedAtMilliseconds = qualifiedAtMillisecondsValue :: number
	local latch: IntermissionLatch = {
		qualifiedAtMilliseconds = qualifiedAtMilliseconds,
		startsAtMilliseconds = qualifiedAtMilliseconds + INTERMISSION_DELAY_MILLISECONDS,
		reason = reasonValue,
		winnerUserIds = users,
		winnerTeamIds = teams,
	}
	table.freeze(latch)
	return latch, true, nil
end

local function isIntermissionLatchDue(latchValue: unknown, currentMillisecondsValue: unknown): boolean
	if
		type(latchValue) ~= "table"
		or not table.isfrozen(latchValue :: table)
		or not isIntegerInRange(currentMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS)
	then
		return false
	end
	local latch = latchValue :: IntermissionLatch
	return isIntegerInRange(latch.qualifiedAtMilliseconds, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS)
		and isIntegerInRange(latch.startsAtMilliseconds, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS)
		and latch.startsAtMilliseconds == latch.qualifiedAtMilliseconds + INTERMISSION_DELAY_MILLISECONDS
		and (currentMillisecondsValue :: number) >= latch.startsAtMilliseconds
end

MatchFrameRules.MillisecondsPerSecond = MILLISECONDS_PER_SECOND
MatchFrameRules.IntermissionDelayMilliseconds = INTERMISSION_DELAY_MILLISECONDS
MatchFrameRules.MaximumLevelTimeMilliseconds = MAXIMUM_LEVEL_TIME_MILLISECONDS
MatchFrameRules.DurationMilliseconds = durationMilliseconds
MatchFrameRules.DeadlineMilliseconds = deadlineMilliseconds
MatchFrameRules.ShouldRunFrame = shouldRunFrame
MatchFrameRules.PresentationTimeForLevel = presentationTimeForLevel
MatchFrameRules.RemainingSeconds = remainingSeconds
MatchFrameRules.CreateIntermissionLatch = createIntermissionLatch
MatchFrameRules.IsIntermissionLatchDue = isIntermissionLatchDue

return table.freeze(MatchFrameRules)
