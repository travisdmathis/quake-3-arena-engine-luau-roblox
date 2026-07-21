--[[
SPDX-License-Identifier: GPL-2.0-or-later

Prepared lethal Movement-state kernel translated from:
  code/game/g_combat.c (G_Damage impulse before player_die)
  code/game/bg_pmove.c (PMF_TIME_KNOCKBACK / pm_time)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

export type Snapshot = {
	read frame: number,
	read position: Vector3,
	read velocity: Vector3,
	read look: Vector3,
	read viewPitch: number,
	read viewYaw: number,
	read viewRoll: number,
	read deltaPitch: number,
	read deltaYaw: number,
	read deltaRoll: number,
	read grounded: boolean,
	read groundPlane: boolean,
	read groundNormal: Vector3,
	read groundSlick: boolean,
	read groundNoDamage: boolean,
	read groundMoverId: string?,
	read jumpHeld: boolean,
	read crouched: boolean,
	read waterLevel: number,
	read waterType: number,
	read movementTime: number,
	read timeLand: boolean,
	read timeKnockback: boolean,
	read timeWaterJump: boolean,
	read respawned: boolean,
}
export type State = Snapshot

local MovementNormalToDeadStateRuntime = {}

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

function MovementNormalToDeadStateRuntime.Snapshot(state: State): Snapshot
	return table.freeze({
		frame = state.frame,
		position = state.position,
		velocity = state.velocity,
		look = state.look,
		viewPitch = state.viewPitch,
		viewYaw = state.viewYaw,
		viewRoll = state.viewRoll,
		deltaPitch = state.deltaPitch,
		deltaYaw = state.deltaYaw,
		deltaRoll = state.deltaRoll,
		grounded = state.grounded,
		groundPlane = state.groundPlane,
		groundNormal = state.groundNormal,
		groundSlick = state.groundSlick,
		groundNoDamage = state.groundNoDamage,
		groundMoverId = state.groundMoverId,
		jumpHeld = state.jumpHeld,
		crouched = state.crouched,
		waterLevel = state.waterLevel,
		waterType = state.waterType,
		movementTime = state.movementTime,
		timeLand = state.timeLand,
		timeKnockback = state.timeKnockback,
		timeWaterJump = state.timeWaterJump,
		respawned = state.respawned,
	})
end

function MovementNormalToDeadStateRuntime.Matches(state: State, snapshot: Snapshot): boolean
	return state.frame == snapshot.frame
		and state.position == snapshot.position
		and state.velocity == snapshot.velocity
		and state.look == snapshot.look
		and state.viewPitch == snapshot.viewPitch
		and state.viewYaw == snapshot.viewYaw
		and state.viewRoll == snapshot.viewRoll
		and state.deltaPitch == snapshot.deltaPitch
		and state.deltaYaw == snapshot.deltaYaw
		and state.deltaRoll == snapshot.deltaRoll
		and state.grounded == snapshot.grounded
		and state.groundPlane == snapshot.groundPlane
		and state.groundNormal == snapshot.groundNormal
		and state.groundSlick == snapshot.groundSlick
		and state.groundNoDamage == snapshot.groundNoDamage
		and state.groundMoverId == snapshot.groundMoverId
		and state.jumpHeld == snapshot.jumpHeld
		and state.crouched == snapshot.crouched
		and state.waterLevel == snapshot.waterLevel
		and state.waterType == snapshot.waterType
		and state.movementTime == snapshot.movementTime
		and state.timeLand == snapshot.timeLand
		and state.timeKnockback == snapshot.timeKnockback
		and state.timeWaterJump == snapshot.timeWaterJump
		and state.respawned == snapshot.respawned
end

function MovementNormalToDeadStateRuntime.BuildLethal(
	state: State,
	velocityDeltaValue: unknown,
	knockbackSecondsValue: unknown,
	minimumKnockbackSeconds: number,
	maximumKnockbackSeconds: number
): (State?, number?, string?)
	if
		typeof(velocityDeltaValue) ~= "Vector3"
		or not isFinite((velocityDeltaValue :: Vector3).X)
		or not isFinite((velocityDeltaValue :: Vector3).Y)
		or not isFinite((velocityDeltaValue :: Vector3).Z)
	then
		return nil, nil, "invalid-normal-to-dead-lethal-velocity"
	end
	if
		knockbackSecondsValue ~= nil
		and (not isFinite(knockbackSecondsValue) or (knockbackSecondsValue :: number) < 0)
	then
		return nil, nil, "invalid-normal-to-dead-knockback-time"
	end
	local nextVelocity = state.velocity + (velocityDeltaValue :: Vector3)
	if not isFinite(nextVelocity.X) or not isFinite(nextVelocity.Y) or not isFinite(nextVelocity.Z) then
		return nil, nil, "normal-to-dead-lethal-velocity-overflow"
	end
	local retainedKnockbackSeconds = knockbackSecondsValue :: number?
	local nextMovementTime = state.movementTime
	local nextTimeKnockback = state.timeKnockback
	if nextMovementTime <= 0 and retainedKnockbackSeconds and retainedKnockbackSeconds > 0 then
		nextMovementTime = math.clamp(retainedKnockbackSeconds, minimumKnockbackSeconds, maximumKnockbackSeconds)
		nextTimeKnockback = true
	end
	local nextState: State = table.clone(state)
	nextState.velocity = nextVelocity
	nextState.movementTime = nextMovementTime
	nextState.timeKnockback = nextTimeKnockback
	table.freeze(nextState)
	return nextState, retainedKnockbackSeconds, nil
end

return table.freeze(MovementNormalToDeadStateRuntime)
