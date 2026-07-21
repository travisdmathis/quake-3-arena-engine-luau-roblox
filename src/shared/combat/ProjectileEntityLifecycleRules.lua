--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure projectile entity-lifecycle rules translated from Quake III Arena:
  code/game/g_missile.c (G_BounceMissile, G_ExplodeMissile,
    G_MissileImpact, G_RunMissile)
  code/game/g_main.c (G_RunFrame event aging and ET_MISSILE dispatch)
  code/game/bg_public.h (ET_MISSILE, ET_GENERAL, EVENT_VALID_MSEC)
  code/game/g_utils.c (G_AddEvent, G_FreeEntity, G_SetOrigin)

The `registered` flag is descriptive lifecycle data only. This module neither
allocates nor releases an EntitySlot capability and cannot prove authority.
The server owner must bind each accepted transition to its opaque registration.

OwnerDisconnected and MatchCleanup are Roblox administrative adaptations, not
missile simulation branches from g_missile.c. They converge on the same
G_FreeEntity-style terminal descriptor without changing impact or event aging.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local ProjectileTrajectory = require(script.Parent.ProjectileTrajectory)

export type Phase = "Missile" | "Event" | "Released"
export type EventCause = "DirectImpact" | "Fuse"
export type AdministrativeReleaseReason = "OwnerDisconnected" | "MatchCleanup"
export type ReleaseCause = "NoImpact" | "EventExpired" | "OwnerDisconnected" | "MatchCleanup"

export type TrajectoryBinding = {
	read state: ProjectileTrajectory.State,
	read base: Vector3,
}

export type MissileState = {
	read phase: "Missile",
	read registered: true,
	read levelTimeMilliseconds: number,
	read revision: number,
	read trajectory: TrajectoryBinding,
}

export type EventState = {
	read phase: "Event",
	read registered: true,
	read levelTimeMilliseconds: number,
	read revision: number,
	read trajectory: TrajectoryBinding,
	read eventTimeMilliseconds: number,
	read eventCause: EventCause,
}

export type ReleasedState = {
	read phase: "Released",
	read registered: false,
	read levelTimeMilliseconds: number,
	read revision: number,
	read releaseCause: ReleaseCause,
}

export type State = MissileState | EventState | ReleasedState

local ProjectileEntityLifecycleRules = {}

local EVENT_VALID_MILLISECONDS = 300
local MAXIMUM_LEVEL_TIME_MILLISECONDS = 2_147_483_647
local MAXIMUM_REVISION = 2_147_483_647

local Phase = table.freeze({
	Missile = "Missile" :: "Missile",
	Event = "Event" :: "Event",
	Released = "Released" :: "Released",
})

local EventCause = table.freeze({
	DirectImpact = "DirectImpact" :: "DirectImpact",
	Fuse = "Fuse" :: "Fuse",
})

local AdministrativeReleaseReason = table.freeze({
	OwnerDisconnected = "OwnerDisconnected" :: "OwnerDisconnected",
	MatchCleanup = "MatchCleanup" :: "MatchCleanup",
})

local ReleaseCause = table.freeze({
	NoImpact = "NoImpact" :: "NoImpact",
	EventExpired = "EventExpired" :: "EventExpired",
	OwnerDisconnected = "OwnerDisconnected" :: "OwnerDisconnected",
	MatchCleanup = "MatchCleanup" :: "MatchCleanup",
})

local TRAJECTORY_STATE_KEYS: { [string]: boolean } = table.freeze({
	kind = true,
	base = true,
	velocity = true,
	startServerTime = true,
	gravity = true,
	revision = true,
})
local TRAJECTORY_BINDING_KEYS: { [string]: boolean } = table.freeze({
	state = true,
	base = true,
})
local MISSILE_STATE_KEYS: { [string]: boolean } = table.freeze({
	phase = true,
	registered = true,
	levelTimeMilliseconds = true,
	revision = true,
	trajectory = true,
})
local EVENT_STATE_KEYS: { [string]: boolean } = table.freeze({
	phase = true,
	registered = true,
	levelTimeMilliseconds = true,
	revision = true,
	trajectory = true,
	eventTimeMilliseconds = true,
	eventCause = true,
})
local RELEASED_STATE_KEYS: { [string]: boolean } = table.freeze({
	phase = true,
	registered = true,
	levelTimeMilliseconds = true,
	revision = true,
	releaseCause = true,
})

local function isBoundedInteger(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function hasExactFrozenRawKeys(value: unknown, allowedKeys: { [string]: boolean }, expectedCount: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil or not table.isfrozen(value :: table) then
		return false
	end
	local raw = value :: { [unknown]: unknown }
	local count = 0
	for key in next, raw do
		if type(key) ~= "string" or allowedKeys[key] ~= true then
			return false
		end
		count += 1
	end
	return count == expectedCount
end

local function inspectTrajectoryState(value: unknown): ProjectileTrajectory.State?
	if not hasExactFrozenRawKeys(value, TRAJECTORY_STATE_KEYS, 6) then
		return nil
	end
	-- Serialize delegates to ProjectileTrajectory's canonical kind/vector/time/
	-- gravity/revision validation. Exact shape and immutability are stricter here.
	if ProjectileTrajectory.Serialize(value) == nil then
		return nil
	end
	return value :: ProjectileTrajectory.State
end

local function inspectTrajectoryBinding(value: unknown): TrajectoryBinding?
	if not hasExactFrozenRawKeys(value, TRAJECTORY_BINDING_KEYS, 2) then
		return nil
	end
	local raw = value :: { [unknown]: unknown }
	local state = inspectTrajectoryState(rawget(raw, "state"))
	local base = rawget(raw, "base")
	if not state or typeof(base) ~= "Vector3" or base ~= state.base then
		return nil
	end
	return value :: TrajectoryBinding
end

local function nextRevision(revision: number): (number?, string?)
	if revision >= MAXIMUM_REVISION then
		return nil, "projectile-lifecycle-revision-exhausted"
	end
	return revision + 1, nil
end

local function inspectState(value: unknown): State?
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil
	end
	local raw = value :: { [unknown]: unknown }
	local phase = rawget(raw, "phase")
	local levelTimeMilliseconds = rawget(raw, "levelTimeMilliseconds")
	local revision = rawget(raw, "revision")
	if
		not isBoundedInteger(levelTimeMilliseconds, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS)
		or not isBoundedInteger(revision, 1, MAXIMUM_REVISION)
	then
		return nil
	end

	if phase == Phase.Missile then
		if not hasExactFrozenRawKeys(value, MISSILE_STATE_KEYS, 5) or rawget(raw, "registered") ~= true then
			return nil
		end
		local trajectory = inspectTrajectoryBinding(rawget(raw, "trajectory"))
		if not trajectory or trajectory.state.revision ~= (revision :: number) then
			return nil
		end
		return value :: MissileState
	elseif phase == Phase.Event then
		local eventTimeMilliseconds = rawget(raw, "eventTimeMilliseconds")
		if
			not hasExactFrozenRawKeys(value, EVENT_STATE_KEYS, 7)
			or rawget(raw, "registered") ~= true
			or not isBoundedInteger(eventTimeMilliseconds, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS)
			or (revision :: number) < 2
			or (eventTimeMilliseconds :: number) > (levelTimeMilliseconds :: number)
			or (levelTimeMilliseconds :: number) - (eventTimeMilliseconds :: number) > EVENT_VALID_MILLISECONDS
		then
			return nil
		end
		local eventCause = rawget(raw, "eventCause")
		if eventCause ~= EventCause.DirectImpact and eventCause ~= EventCause.Fuse then
			return nil
		end
		local trajectory = inspectTrajectoryBinding(rawget(raw, "trajectory"))
		if
			not trajectory
			or trajectory.state.kind ~= ProjectileTrajectory.Kind.Stationary
			or trajectory.state.revision < 2
			or trajectory.state.revision > (revision :: number)
		then
			return nil
		end
		return value :: EventState
	elseif phase == Phase.Released then
		if
			not hasExactFrozenRawKeys(value, RELEASED_STATE_KEYS, 5)
			or rawget(raw, "registered") ~= false
			or (revision :: number) < 2
		then
			return nil
		end
		local releaseCause = rawget(raw, "releaseCause")
		if
			releaseCause ~= ReleaseCause.NoImpact
			and releaseCause ~= ReleaseCause.EventExpired
			and releaseCause ~= ReleaseCause.OwnerDisconnected
			and releaseCause ~= ReleaseCause.MatchCleanup
		then
			return nil
		end
		return value :: ReleasedState
	end
	return nil
end

local function inspectMissileAt(
	stateValue: unknown,
	levelTimeMillisecondsValue: unknown
): (MissileState?, number?, string?)
	local state = inspectState(stateValue)
	if not state then
		return nil, nil, "invalid-projectile-lifecycle-state"
	end
	if state.phase ~= Phase.Missile then
		return nil, nil, "projectile-is-not-missile"
	end
	if not isBoundedInteger(levelTimeMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS) then
		return nil, nil, "invalid-projectile-level-time"
	end
	local levelTimeMilliseconds = levelTimeMillisecondsValue :: number
	if levelTimeMilliseconds < state.levelTimeMilliseconds then
		return nil, nil, "non-monotonic-projectile-level-time"
	end
	return state :: MissileState, levelTimeMilliseconds, nil
end

local function inspectNextTrajectory(
	state: MissileState,
	trajectoryBindingValue: unknown,
	requireStationary: boolean
): (TrajectoryBinding?, string?)
	local trajectory = inspectTrajectoryBinding(trajectoryBindingValue)
	if not trajectory then
		return nil, "invalid-projectile-trajectory-binding"
	end
	if state.trajectory.state.revision >= ProjectileTrajectory.MaximumRevision then
		return nil, "projectile-trajectory-revision-exhausted"
	end
	if trajectory.state.revision ~= state.trajectory.state.revision + 1 then
		return nil, "non-monotonic-projectile-trajectory-revision"
	end
	if requireStationary and trajectory.state.kind ~= ProjectileTrajectory.Kind.Stationary then
		return nil, "projectile-event-trajectory-not-stationary"
	end
	return trajectory, nil
end

function ProjectileEntityLifecycleRules.BindTrajectory(
	trajectoryStateValue: unknown,
	trajectoryBaseValue: unknown
): (TrajectoryBinding?, string?)
	local state = inspectTrajectoryState(trajectoryStateValue)
	if not state then
		return nil, "invalid-projectile-trajectory-state"
	end
	if typeof(trajectoryBaseValue) ~= "Vector3" or trajectoryBaseValue ~= state.base then
		return nil, "projectile-trajectory-base-mismatch"
	end
	local binding: TrajectoryBinding = {
		state = state,
		base = trajectoryBaseValue :: Vector3,
	}
	table.freeze(binding)
	return binding, nil
end

function ProjectileEntityLifecycleRules.InspectTrajectoryBinding(value: unknown): TrajectoryBinding?
	return inspectTrajectoryBinding(value)
end

function ProjectileEntityLifecycleRules.Create(
	trajectoryBindingValue: unknown,
	levelTimeMillisecondsValue: unknown
): (MissileState?, string?)
	local trajectory = inspectTrajectoryBinding(trajectoryBindingValue)
	if not trajectory then
		return nil, "invalid-projectile-trajectory-binding"
	end
	if trajectory.state.revision ~= 1 then
		return nil, "invalid-initial-projectile-trajectory-revision"
	end
	if not isBoundedInteger(levelTimeMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS) then
		return nil, "invalid-projectile-level-time"
	end
	local state: MissileState = {
		phase = Phase.Missile,
		registered = true,
		levelTimeMilliseconds = levelTimeMillisecondsValue :: number,
		revision = 1,
		trajectory = trajectory,
	}
	table.freeze(state)
	return state, nil
end

function ProjectileEntityLifecycleRules.Inspect(value: unknown): State?
	return inspectState(value)
end

function ProjectileEntityLifecycleRules.Bounce(
	stateValue: unknown,
	nextTrajectoryBindingValue: unknown,
	levelTimeMillisecondsValue: unknown
): (MissileState?, string?)
	local state, levelTimeMilliseconds, stateError = inspectMissileAt(stateValue, levelTimeMillisecondsValue)
	if not state or not levelTimeMilliseconds then
		return nil, stateError
	end
	local trajectory, trajectoryError = inspectNextTrajectory(state, nextTrajectoryBindingValue, false)
	if not trajectory then
		return nil, trajectoryError
	end
	local revision, revisionError = nextRevision(state.revision)
	if not revision then
		return nil, revisionError
	end
	local nextState: MissileState = {
		phase = Phase.Missile,
		registered = true,
		levelTimeMilliseconds = levelTimeMilliseconds,
		revision = revision,
		-- G_BounceMissile mutates s.pos on the same ET_MISSILE entity. Keep the
		-- exact caller-resolved trajectory binding; do not clone or resnap it.
		trajectory = trajectory,
	}
	table.freeze(nextState)
	return nextState, nil
end

local function transitionToEvent(
	stateValue: unknown,
	nextTrajectoryBindingValue: unknown,
	levelTimeMillisecondsValue: unknown,
	eventCause: EventCause
): (EventState?, string?)
	local state, levelTimeMilliseconds, stateError = inspectMissileAt(stateValue, levelTimeMillisecondsValue)
	if not state or not levelTimeMilliseconds then
		return nil, stateError
	end
	local trajectory, trajectoryError = inspectNextTrajectory(state, nextTrajectoryBindingValue, true)
	if not trajectory then
		return nil, trajectoryError
	end
	local revision, revisionError = nextRevision(state.revision)
	if not revision then
		return nil, revisionError
	end
	local nextState: EventState = {
		phase = Phase.Event,
		registered = true,
		levelTimeMilliseconds = levelTimeMilliseconds,
		revision = revision,
		trajectory = trajectory,
		-- G_AddEvent writes ent->eventTime = level.time for both the direct
		-- G_MissileImpact and fuse-driven G_ExplodeMissile paths.
		eventTimeMilliseconds = levelTimeMilliseconds,
		eventCause = eventCause,
	}
	table.freeze(nextState)
	return nextState, nil
end

function ProjectileEntityLifecycleRules.Impact(
	stateValue: unknown,
	nextTrajectoryBindingValue: unknown,
	levelTimeMillisecondsValue: unknown
): (EventState?, string?)
	return transitionToEvent(
		stateValue,
		nextTrajectoryBindingValue,
		levelTimeMillisecondsValue,
		EventCause.DirectImpact
	)
end

ProjectileEntityLifecycleRules.DirectImpact = ProjectileEntityLifecycleRules.Impact

function ProjectileEntityLifecycleRules.Fuse(
	stateValue: unknown,
	nextTrajectoryBindingValue: unknown,
	levelTimeMillisecondsValue: unknown
): (EventState?, string?)
	return transitionToEvent(stateValue, nextTrajectoryBindingValue, levelTimeMillisecondsValue, EventCause.Fuse)
end

function ProjectileEntityLifecycleRules.NoImpact(
	stateValue: unknown,
	levelTimeMillisecondsValue: unknown
): (ReleasedState?, string?)
	local state, levelTimeMilliseconds, stateError = inspectMissileAt(stateValue, levelTimeMillisecondsValue)
	if not state or not levelTimeMilliseconds then
		return nil, stateError
	end
	local revision, revisionError = nextRevision(state.revision)
	if not revision then
		return nil, revisionError
	end
	local nextState: ReleasedState = {
		phase = Phase.Released,
		registered = false,
		levelTimeMilliseconds = levelTimeMilliseconds,
		revision = revision,
		releaseCause = ReleaseCause.NoImpact,
	}
	table.freeze(nextState)
	return nextState, nil
end

function ProjectileEntityLifecycleRules.AdministrativeRelease(
	stateValue: unknown,
	levelTimeMillisecondsValue: unknown,
	reasonValue: unknown
): (ReleasedState?, string?)
	local state = inspectState(stateValue)
	if not state then
		return nil, "invalid-projectile-lifecycle-state"
	end
	if state.phase == Phase.Released then
		return nil, "projectile-already-released"
	end
	if
		reasonValue ~= AdministrativeReleaseReason.OwnerDisconnected
		and reasonValue ~= AdministrativeReleaseReason.MatchCleanup
	then
		return nil, "invalid-projectile-administrative-release-reason"
	end
	if not isBoundedInteger(levelTimeMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS) then
		return nil, "invalid-projectile-level-time"
	end
	local levelTimeMilliseconds = levelTimeMillisecondsValue :: number
	if levelTimeMilliseconds < state.levelTimeMilliseconds then
		return nil, "non-monotonic-projectile-level-time"
	end
	local revision, revisionError = nextRevision(state.revision)
	if not revision then
		return nil, revisionError
	end
	local nextState: ReleasedState = {
		phase = Phase.Released,
		registered = false,
		levelTimeMilliseconds = levelTimeMilliseconds,
		revision = revision,
		releaseCause = reasonValue :: AdministrativeReleaseReason,
	}
	table.freeze(nextState)
	return nextState, nil
end

function ProjectileEntityLifecycleRules.Advance(
	stateValue: unknown,
	levelTimeMillisecondsValue: unknown
): (State?, string?)
	local state = inspectState(stateValue)
	if not state then
		return nil, "invalid-projectile-lifecycle-state"
	end
	if state.phase ~= Phase.Event then
		return nil, "projectile-is-not-event"
	end
	if not isBoundedInteger(levelTimeMillisecondsValue, 0, MAXIMUM_LEVEL_TIME_MILLISECONDS) then
		return nil, "invalid-projectile-level-time"
	end
	local levelTimeMilliseconds = levelTimeMillisecondsValue :: number
	if levelTimeMilliseconds < state.levelTimeMilliseconds then
		return nil, "non-monotonic-projectile-level-time"
	end
	local eventState = state :: EventState
	local eventAge = levelTimeMilliseconds - eventState.eventTimeMilliseconds
	if levelTimeMilliseconds == eventState.levelTimeMilliseconds then
		return eventState, nil
	end
	local revision, revisionError = nextRevision(eventState.revision)
	if not revision then
		return nil, revisionError
	end
	if eventAge > EVENT_VALID_MILLISECONDS then
		local released: ReleasedState = {
			phase = Phase.Released,
			registered = false,
			levelTimeMilliseconds = levelTimeMilliseconds,
			revision = revision,
			releaseCause = ReleaseCause.EventExpired,
		}
		table.freeze(released)
		return released, nil
	end
	local retained: EventState = {
		phase = Phase.Event,
		registered = true,
		levelTimeMilliseconds = levelTimeMilliseconds,
		revision = revision,
		trajectory = eventState.trajectory,
		eventTimeMilliseconds = eventState.eventTimeMilliseconds,
		eventCause = eventState.eventCause,
	}
	table.freeze(retained)
	return retained, nil
end

ProjectileEntityLifecycleRules.Phase = Phase
ProjectileEntityLifecycleRules.EventCause = EventCause
ProjectileEntityLifecycleRules.AdministrativeReleaseReason = AdministrativeReleaseReason
ProjectileEntityLifecycleRules.ReleaseCause = ReleaseCause
ProjectileEntityLifecycleRules.EventValidMilliseconds = EVENT_VALID_MILLISECONDS
ProjectileEntityLifecycleRules.MaximumLevelTimeMilliseconds = MAXIMUM_LEVEL_TIME_MILLISECONDS
ProjectileEntityLifecycleRules.MaximumRevision = MAXIMUM_REVISION

return table.freeze(ProjectileEntityLifecycleRules)
