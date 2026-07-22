--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-only owner of the Q3-equivalent global frame-time capability:
  code/game/g_main.c (G_RunFrame, level.framenum, level.previousTime, level.time)

The current Movement fixed-step owner commits exactly one already-applied
MoverClock step and its owner-authored step timestamp here. The first commit
anchors the nominal synchronized-server-time mapping; gameplay milliseconds
always come only from MoverClock. A later scheduler migration will own clamp
discontinuities, Heartbeat, and all entity phases behind this boundary. Until
then, this is a time-provenance foundation, not a claim that every live service
already shares Q3 ordering or that the mapping survives dropped simulation
time.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "AuthoritativeFrameService is server-only")

local simulation = ReplicatedStorage:WaitForChild("Q3Engine"):WaitForChild("simulation")
local AuthoritativeFrameRules = require(simulation:WaitForChild("AuthoritativeFrameRules"))
local MoverClock = require(simulation:WaitForChild("MoverClock"))

local AuthoritativeFrameService = {}

export type Owner = {}
export type Frame = {}
export type Summary = AuthoritativeFrameRules.Summary
export type DebugSnapshot = {
	read started: boolean,
	read current: boolean,
	read clockRevision: number,
	read clockStep: number,
	read previousTimeMilliseconds: number,
	read currentTimeMilliseconds: number,
	read currentServerTimeSeconds: number,
	read stepServerTime: number,
}

type FrameStatus = "Open" | "Current" | "Retired" | "Aborted"
type FrameCapability = {
	frame: Frame,
	status: FrameStatus,
	rulesState: AuthoritativeFrameRules.State,
	summary: Summary,
	clock: MoverClock.Snapshot,
	stepServerTime: number,
}

local started = false
local faulted = false
local ownerCapability: Owner? = nil
local rulesState: AuthoritativeFrameRules.State? = nil
local rulesSummary: Summary? = nil
local committedClock: MoverClock.Snapshot? = nil
local currentFrame: Frame? = nil
local currentFrameCapability: FrameCapability? = nil
local openFrame: Frame? = nil
local openFrameCapability: FrameCapability? = nil
local frameCapabilities: { [Frame]: FrameCapability } = setmetatable({}, { __mode = "k" })

local function isFiniteNonnegative(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) >= 0
end

local function exactClock(value: unknown): MoverClock.Snapshot?
	if
		type(value) ~= "table"
		or getmetatable(value) ~= nil
		or not table.isfrozen(value :: table)
	then
		return nil
	end
	local supplied = value :: { [unknown]: unknown }
	local keyCount = 0
	for key in next, supplied do
		if key ~= "revision" and key ~= "step" then
			return nil
		end
		keyCount += 1
	end
	if keyCount ~= 2 then
		return nil
	end
	local validated = MoverClock.ValidateSnapshot(value)
	if
		not validated
		or validated.revision ~= supplied.revision
		or validated.step ~= supplied.step
	then
		return nil
	end
	return value :: MoverClock.Snapshot
end

local function currentCapability(frameValue: unknown): FrameCapability?
	if type(frameValue) ~= "table" then
		return nil
	end
	local frame = frameValue :: Frame
	local capability = frameCapabilities[frame]
	if
		not capability
		or capability.status ~= "Current"
		or capability.frame ~= frame
		or currentFrame ~= frame
		or currentFrameCapability ~= capability
		or rulesState ~= capability.rulesState
		or rulesSummary ~= capability.summary
		or committedClock ~= capability.clock
		or not isFiniteNonnegative(capability.stepServerTime)
		or not table.isfrozen(frame :: any)
		or not AuthoritativeFrameRules.ValidateDependency(capability.rulesState, capability.summary)
	then
		return nil
	end
	return capability
end

local function inspectableCapability(frameValue: unknown): FrameCapability?
	if type(frameValue) ~= "table" then
		return nil
	end
	local frame = frameValue :: Frame
	local capability = frameCapabilities[frame]
	if
		not capability
		or capability.frame ~= frame
		or not table.isfrozen(frame :: any)
		or rulesState ~= capability.rulesState
		or rulesSummary ~= capability.summary
		or not AuthoritativeFrameRules.ValidateDependency(capability.rulesState, capability.summary)
	then
		return nil
	end
	if capability.status == "Open" then
		if openFrame ~= frame or openFrameCapability ~= capability then
			return nil
		end
		return capability
	end
	if capability.status == "Current" then
		if
			openFrame ~= nil
			or currentFrame ~= frame
			or currentFrameCapability ~= capability
			or committedClock ~= capability.clock
		then
			return nil
		end
		return capability
	end
	return nil
end

function AuthoritativeFrameService.Start(): (Owner?, string?)
	if started then
		return nil, "authoritative-frame-service-already-started"
	end
	local clock = assert(MoverClock.Create(1, 0))
	local owner: Owner = table.freeze({})
	started = true
	faulted = false
	ownerCapability = owner
	rulesState = nil
	rulesSummary = nil
	committedClock = clock
	currentFrame = nil
	currentFrameCapability = nil
	openFrame = nil
	openFrameCapability = nil
	return owner, nil
end

function AuthoritativeFrameService.IsStarted(): boolean
	return started
end

function AuthoritativeFrameService.ValidateOwner(ownerValue: unknown): boolean
	return started
		and type(ownerValue) == "table"
		and ownerValue == ownerCapability
		and not faulted
		and table.isfrozen(ownerValue :: table)
		and next(ownerValue :: { [unknown]: unknown }) == nil
end

function AuthoritativeFrameService.BeginNext(
	ownerValue: unknown,
	nextClockValue: unknown,
	stepServerTimeValue: unknown
): (Frame?, string?)
	if not AuthoritativeFrameService.ValidateOwner(ownerValue) then
		return nil, "invalid-authoritative-frame-owner"
	end
	if openFrameCapability ~= nil then
		return nil, "authoritative-frame-already-open"
	end
	local nextClock = exactClock(nextClockValue)
	if not nextClock then
		return nil, "invalid-authoritative-frame-next-clock"
	end
	if not isFiniteNonnegative(stepServerTimeValue) then
		return nil, "invalid-authoritative-frame-step-server-time"
	end
	local baseClock = assert(committedClock, "authoritative frame clock is unavailable")
	if nextClock.revision ~= baseClock.revision or nextClock.step ~= baseClock.step + 1 then
		return nil, "noncontiguous-authoritative-frame-commit"
	end

	local nextState: AuthoritativeFrameRules.State?
	local nextSummary: Summary?
	if currentFrameCapability == nil then
		if rulesState ~= nil or rulesSummary ~= nil then
			return nil, "invalid-authoritative-frame-bootstrap-state"
		end
		local firstWindow, windowError = MoverClock.WindowFor(baseClock)
		if not firstWindow then
			return nil, windowError
		end
		local frameDurationSeconds = (
			firstWindow.toTimeMilliseconds - firstWindow.fromTimeMilliseconds
		) / MoverClock.MillisecondsPerSecond
		local serverTimeAtFromStep = (stepServerTimeValue :: number) - frameDurationSeconds
		if not isFiniteNonnegative(serverTimeAtFromStep) then
			return nil, "invalid-authoritative-frame-bootstrap-server-time"
		end
		nextState, nextSummary = AuthoritativeFrameRules.Create(firstWindow, serverTimeAtFromStep)
	else
		local baseState = assert(rulesState, "authoritative frame rules state is unavailable")
		local baseSummary = assert(rulesSummary, "authoritative frame summary is unavailable")
		local nextWindow, windowError = MoverClock.WindowFor(baseClock)
		if not nextWindow then
			return nil, windowError
		end
		local advancedState, advancedSummary, advanceError =
			AuthoritativeFrameRules.Advance(baseState, baseSummary, nextWindow)
		if not advancedState or not advancedSummary then
			return nil, advanceError
		end
		nextState, nextSummary = advancedState, advancedSummary
	end
	if not nextState or not nextSummary then
		return nil, "authoritative-frame-construction-failed"
	end
	if nextSummary.clockRevision ~= nextClock.revision or nextSummary.toStep ~= nextClock.step then
		return nil, "authoritative-frame-clock-summary-mismatch"
	end

	local frame: Frame = table.freeze({})
	local capability: FrameCapability = {
		frame = frame,
		status = "Open",
		rulesState = nextState,
		summary = nextSummary,
		clock = nextClock,
		stepServerTime = stepServerTimeValue :: number,
	}
	frameCapabilities[frame] = capability
	rulesState = nextState
	rulesSummary = nextSummary
	openFrame = frame
	openFrameCapability = capability
	return frame, nil
end

function AuthoritativeFrameService.CommitOpen(
	ownerValue: unknown,
	frameValue: unknown,
	committedClockValue: unknown
): (Frame?, string?)
	if not AuthoritativeFrameService.ValidateOwner(ownerValue) then
		return nil, "invalid-authoritative-frame-owner"
	end
	local capability = inspectableCapability(frameValue)
	if not capability or capability.status ~= "Open" then
		return nil, "invalid-open-authoritative-frame"
	end
	local nextClock = exactClock(committedClockValue)
	if not nextClock then
		return nil, "invalid-authoritative-frame-committed-clock"
	end
	local baseClock = assert(committedClock, "authoritative frame clock is unavailable")
	if
		nextClock.revision ~= baseClock.revision
		or nextClock.step ~= baseClock.step + 1
		or nextClock.revision ~= capability.clock.revision
		or nextClock.step ~= capability.clock.step
		or capability.summary.clockRevision ~= nextClock.revision
		or capability.summary.toStep ~= nextClock.step
	then
		return nil, "open-authoritative-frame-clock-mismatch"
	end

	local previousCapability = currentFrameCapability
	if previousCapability then
		previousCapability.status = "Retired"
		frameCapabilities[previousCapability.frame] = nil
	end
	capability.clock = nextClock
	capability.status = "Current"
	committedClock = nextClock
	currentFrame = capability.frame
	currentFrameCapability = capability
	openFrame = nil
	openFrameCapability = nil
	return capability.frame, nil
end

function AuthoritativeFrameService.AbortOpen(ownerValue: unknown, frameValue: unknown): boolean
	if not AuthoritativeFrameService.ValidateOwner(ownerValue) then
		return false
	end
	local capability = inspectableCapability(frameValue)
	if not capability or capability.status ~= "Open" then
		return false
	end
	capability.status = "Aborted"
	frameCapabilities[capability.frame] = nil
	openFrame = nil
	openFrameCapability = nil
	local previousCapability = currentFrameCapability
	if previousCapability then
		previousCapability.status = "Retired"
		frameCapabilities[previousCapability.frame] = nil
	end
	currentFrame = nil
	currentFrameCapability = nil
	faulted = true
	return true
end

function AuthoritativeFrameService.CommitNext(
	ownerValue: unknown,
	committedClockValue: unknown,
	stepServerTimeValue: unknown
): (Frame?, string?)
	local frame, beginError =
		AuthoritativeFrameService.BeginNext(ownerValue, committedClockValue, stepServerTimeValue)
	if not frame then
		return nil, beginError
	end
	local committed, commitError =
		AuthoritativeFrameService.CommitOpen(ownerValue, frame, committedClockValue)
	if not committed then
		AuthoritativeFrameService.AbortOpen(ownerValue, frame)
		return nil, commitError
	end
	return committed, nil
end

function AuthoritativeFrameService.GetCurrentFrame(): Frame?
	return if openFrame == nil then currentFrame else nil
end

function AuthoritativeFrameService.GetOpenFrame(): Frame?
	return openFrame
end

function AuthoritativeFrameService.InspectFrame(frameValue: unknown): Summary?
	local capability = inspectableCapability(frameValue)
	return if capability then capability.summary else nil
end

function AuthoritativeFrameService.InspectCurrentFrame(frameValue: unknown): Summary?
	local capability = currentCapability(frameValue)
	return if capability then capability.summary else nil
end

function AuthoritativeFrameService.InspectCurrentStepServerTime(frameValue: unknown): number?
	local capability = currentCapability(frameValue)
	return if capability then capability.stepServerTime else nil
end

function AuthoritativeFrameService.InspectFrameStepServerTime(frameValue: unknown): number?
	local capability = inspectableCapability(frameValue)
	return if capability then capability.stepServerTime else nil
end

function AuthoritativeFrameService.ValidateFrameDependency(
	frameValue: unknown,
	summaryValue: unknown
): boolean
	local capability = inspectableCapability(frameValue)
	return capability ~= nil and capability.summary == summaryValue
end

function AuthoritativeFrameService.GetDebugSnapshot(): DebugSnapshot
	local summary = if currentFrameCapability then currentFrameCapability.summary else nil
	local clock = committedClock
	return table.freeze({
		started = started,
		current = summary ~= nil and openFrame == nil,
		clockRevision = if clock then clock.revision else 0,
		clockStep = if clock then clock.step else 0,
		previousTimeMilliseconds = if summary then summary.previousTimeMilliseconds else 0,
		currentTimeMilliseconds = if summary then summary.currentTimeMilliseconds else 0,
		currentServerTimeSeconds = if summary then summary.currentServerTimeSeconds else 0,
		stepServerTime = if currentFrameCapability
			then currentFrameCapability.stepServerTime
			else 0,
	})
end

return table.freeze(AuthoritativeFrameService)
