--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure authoritative-frame lineage for the fixed the Roblox Luau port simulation clock,
translated from Quake III Arena:
  code/game/g_main.c (G_RunFrame: level.previousTime, level.time, and msec)

Q3 receives one integer levelTime from the server for each G_RunFrame call.
the Roblox Luau port instead owns a fixed 60 Hz step, so gameplay time below is derived
only from an exact MoverClock window. The server-time anchor is retained solely
to map those integer boundaries into rewind/presentation time; it never authors
level.previousTime, level.time, or msec.

The opaque state/summary identity is an authority-composition adaptation. A
MoverClock window is canonical deterministic data; the server owner's private
advance token supplies authority when it bootstraps and advances this lineage.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local MoverClock = require(script.Parent.MoverClock)

export type Lineage = {}
export type State = {}

export type Summary = {
	read lineage: Lineage,
	read window: MoverClock.Window,
	read clockRevision: number,
	read fromStep: number,
	read toStep: number,
	read previousTimeMilliseconds: number,
	read currentTimeMilliseconds: number,
	read msec: number,
	read anchorStep: number,
	read anchorTimeMilliseconds: number,
	read serverTimeAnchorSeconds: number,
	read previousServerTimeSeconds: number,
	read currentServerTimeSeconds: number,
}

type Capability = {
	state: State,
	current: boolean,
	lineage: Lineage,
	summary: Summary,
	window: MoverClock.Window,
	anchorStep: number,
	anchorTimeMilliseconds: number,
	serverTimeAnchorSeconds: number,
}

local AuthoritativeFrameRules = {}

local WINDOW_KEYS: { [string]: boolean } = table.freeze({
	revision = true,
	fromStep = true,
	toStep = true,
	fromTimeMilliseconds = true,
	toTimeMilliseconds = true,
})

local SUMMARY_KEYS: { [string]: boolean } = table.freeze({
	lineage = true,
	window = true,
	clockRevision = true,
	fromStep = true,
	toStep = true,
	previousTimeMilliseconds = true,
	currentTimeMilliseconds = true,
	msec = true,
	anchorStep = true,
	anchorTimeMilliseconds = true,
	serverTimeAnchorSeconds = true,
	previousServerTimeSeconds = true,
	currentServerTimeSeconds = true,
})

local capabilities = setmetatable({}, { __mode = "k" }) :: { [State]: Capability }
local statesBySummary = setmetatable({}, { __mode = "k" }) :: { [Summary]: State }

local function isFiniteNonnegative(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) >= 0
end

local function hasExactFrozenRawKeys(value: unknown, allowedKeys: { [string]: boolean }, expectedCount: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil or not table.isfrozen(value :: table) then
		return false
	end
	local count = 0
	for key in next, value :: { [unknown]: unknown } do
		if type(key) ~= "string" or allowedKeys[key] ~= true then
			return false
		end
		count += 1
	end
	return count == expectedCount
end

local function isOpaqueEmpty(value: unknown): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil or not table.isfrozen(value :: table) then
		return false
	end
	return next(value :: { [unknown]: unknown }) == nil
end

local function inspectWindow(value: unknown): (MoverClock.Window?, string?)
	if not hasExactFrozenRawKeys(value, WINDOW_KEYS, 5) then
		return nil, "invalid-authoritative-frame-window-shape"
	end
	local supplied = value :: MoverClock.Window
	local fromClock, clockError = MoverClock.Create(supplied.revision, supplied.fromStep)
	if not fromClock then
		return nil, clockError or "invalid-authoritative-frame-clock"
	end
	local expected, windowError = MoverClock.WindowFor(fromClock)
	if not expected then
		return nil, windowError or "invalid-authoritative-frame-clock-window"
	end
	if
		supplied.toStep ~= expected.toStep
		or supplied.fromTimeMilliseconds ~= expected.fromTimeMilliseconds
		or supplied.toTimeMilliseconds ~= expected.toTimeMilliseconds
	then
		return nil, "authoritative-frame-window-clock-mismatch"
	end
	return supplied, nil
end

local function mappedServerTime(
	anchorSeconds: number,
	anchorTimeMilliseconds: number,
	levelTimeMilliseconds: number
): number?
	local mapped = anchorSeconds + (levelTimeMilliseconds - anchorTimeMilliseconds) / MoverClock.MillisecondsPerSecond
	return if isFiniteNonnegative(mapped) then mapped else nil
end

local function makeSummary(
	lineage: Lineage,
	window: MoverClock.Window,
	anchorStep: number,
	anchorTimeMilliseconds: number,
	serverTimeAnchorSeconds: number
): (Summary?, string?)
	local previousServerTimeSeconds =
		mappedServerTime(serverTimeAnchorSeconds, anchorTimeMilliseconds, window.fromTimeMilliseconds)
	local currentServerTimeSeconds =
		mappedServerTime(serverTimeAnchorSeconds, anchorTimeMilliseconds, window.toTimeMilliseconds)
	if
		previousServerTimeSeconds == nil
		or currentServerTimeSeconds == nil
		or currentServerTimeSeconds < previousServerTimeSeconds
	then
		return nil, "invalid-authoritative-frame-server-time-mapping"
	end
	local msec = window.toTimeMilliseconds - window.fromTimeMilliseconds
	if msec <= 0 then
		return nil, "invalid-authoritative-frame-msec"
	end
	local summary: Summary = {
		lineage = lineage,
		window = window,
		clockRevision = window.revision,
		fromStep = window.fromStep,
		toStep = window.toStep,
		previousTimeMilliseconds = window.fromTimeMilliseconds,
		currentTimeMilliseconds = window.toTimeMilliseconds,
		msec = msec,
		anchorStep = anchorStep,
		anchorTimeMilliseconds = anchorTimeMilliseconds,
		serverTimeAnchorSeconds = serverTimeAnchorSeconds,
		previousServerTimeSeconds = previousServerTimeSeconds,
		currentServerTimeSeconds = currentServerTimeSeconds,
	}
	table.freeze(summary)
	return summary, nil
end

local function currentCapability(stateValue: unknown, summaryValue: unknown?): (Capability?, string?)
	if not isOpaqueEmpty(stateValue) then
		return nil, "invalid-authoritative-frame-state"
	end
	local state = stateValue :: State
	local capability = capabilities[state]
	if
		not capability
		or not capability.current
		or capability.state ~= state
		or not isOpaqueEmpty(capability.lineage)
		or not hasExactFrozenRawKeys(capability.summary, SUMMARY_KEYS, 13)
		or capability.summary.lineage ~= capability.lineage
		or capability.summary.window ~= capability.window
		or capability.summary.clockRevision ~= capability.window.revision
		or capability.summary.fromStep ~= capability.window.fromStep
		or capability.summary.toStep ~= capability.window.toStep
		or capability.summary.previousTimeMilliseconds ~= capability.window.fromTimeMilliseconds
		or capability.summary.currentTimeMilliseconds ~= capability.window.toTimeMilliseconds
		or capability.summary.msec ~= capability.window.toTimeMilliseconds - capability.window.fromTimeMilliseconds
		or capability.summary.anchorStep ~= capability.anchorStep
		or capability.summary.anchorTimeMilliseconds ~= capability.anchorTimeMilliseconds
		or capability.summary.serverTimeAnchorSeconds ~= capability.serverTimeAnchorSeconds
		or statesBySummary[capability.summary] ~= state
	then
		return nil, "stale-authoritative-frame-state"
	end
	if summaryValue ~= nil then
		if
			type(summaryValue) ~= "table"
			or summaryValue ~= capability.summary
			or statesBySummary[summaryValue :: Summary] ~= state
		then
			return nil, "forged-authoritative-frame-summary"
		end
	end
	return capability, nil
end

local function register(
	lineage: Lineage,
	window: MoverClock.Window,
	anchorStep: number,
	anchorTimeMilliseconds: number,
	serverTimeAnchorSeconds: number
): (State?, Summary?, string?)
	local summary, summaryError =
		makeSummary(lineage, window, anchorStep, anchorTimeMilliseconds, serverTimeAnchorSeconds)
	if not summary then
		return nil, nil, summaryError
	end
	local state: State = table.freeze({})
	capabilities[state] = {
		state = state,
		current = true,
		lineage = lineage,
		summary = summary,
		window = window,
		anchorStep = anchorStep,
		anchorTimeMilliseconds = anchorTimeMilliseconds,
		serverTimeAnchorSeconds = serverTimeAnchorSeconds,
	}
	statesBySummary[summary] = state
	return state, summary, nil
end

function AuthoritativeFrameRules.Create(
	windowValue: unknown,
	serverTimeAnchorSecondsValue: unknown
): (State?, Summary?, string?)
	local window, windowError = inspectWindow(windowValue)
	if not window then
		return nil, nil, windowError
	end
	if not isFiniteNonnegative(serverTimeAnchorSecondsValue) then
		return nil, nil, "invalid-authoritative-frame-server-time-anchor"
	end
	local lineage: Lineage = table.freeze({})
	return register(
		lineage,
		window,
		window.fromStep,
		window.fromTimeMilliseconds,
		serverTimeAnchorSecondsValue :: number
	)
end

function AuthoritativeFrameRules.Inspect(stateValue: unknown): Summary?
	local capability = select(1, currentCapability(stateValue, nil))
	return if capability then capability.summary else nil
end

function AuthoritativeFrameRules.ValidateDependency(stateValue: unknown, summaryValue: unknown): (boolean, string?)
	local capability, capabilityError = currentCapability(stateValue, summaryValue)
	return capability ~= nil, capabilityError
end

function AuthoritativeFrameRules.Advance(
	stateValue: unknown,
	summaryValue: unknown,
	windowValue: unknown
): (State?, Summary?, string?)
	local capability, capabilityError = currentCapability(stateValue, summaryValue)
	if not capability then
		return nil, nil, capabilityError
	end
	local window, windowError = inspectWindow(windowValue)
	if not window then
		return nil, nil, windowError
	end
	if
		window.revision ~= capability.window.revision
		or window.fromStep ~= capability.window.toStep
		or window.fromTimeMilliseconds ~= capability.window.toTimeMilliseconds
	then
		return nil, nil, "non-contiguous-authoritative-frame-window"
	end

	local nextState, nextSummary, registerError = register(
		capability.lineage,
		window,
		capability.anchorStep,
		capability.anchorTimeMilliseconds,
		capability.serverTimeAnchorSeconds
	)
	if not nextState or not nextSummary then
		return nil, nil, registerError
	end

	-- Retire the exact prior boundary only after every fallible validation and
	-- allocation above has succeeded. A frame lineage therefore advances once.
	capability.current = false
	statesBySummary[capability.summary] = nil
	return nextState, nextSummary, nil
end

AuthoritativeFrameRules.StepsPerSecond = MoverClock.StepsPerSecond
AuthoritativeFrameRules.MillisecondsPerSecond = MoverClock.MillisecondsPerSecond

return table.freeze(AuthoritativeFrameRules)
