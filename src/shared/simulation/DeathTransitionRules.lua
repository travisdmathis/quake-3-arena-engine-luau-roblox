--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure player_die transition policy translated from:
  code/game/g_combat.c (G_Damage world normalization, player_die, LookAtKiller)
  code/game/bg_misc.c (cached entity-state projection remains distinct)
  code/game/g_client.c (SetClientViewAngle generic/player-state angle ownership)
  code/game/g_missile.c (direct-impact and bounced-segment trajectory bases)
  code/game/g_mover.c (mover trajectory-base sources and precise client-origin
  restoration before Sine/blocked damage)
  code/game/g_utils.c (G_SetOrigin exact non-player trajectory bases)

Source kinds in this module are already-resolved identity/data. They are not
authority proof: the future Movement owner must mint them from opaque player,
mover, projectile, map-entity, or world capabilities before calling Resolve.
In particular, `External` must never become a raw-vector production seam.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Constants = require(script.Parent.Constants)
local DeathViewRules = require(script.Parent.DeathViewRules)
local EntityStateConversionRules = require(script.Parent.EntityStateConversionRules)

export type SourceKind = "Victim" | "World" | "Player" | "Mover" | "Projectile" | "External"
export type ResolvedSource =
	{ read kind: "Victim" }
	| { read kind: "World" }
	| {
		read kind: "Player" | "Mover" | "Projectile" | "External",
		read trajectoryBase: Vector3,
	}
export type Request = {
	lifeSequence: number,
	crouched: boolean,
	victimTrajectoryBase: Vector3,
	retainedGenericAngles: EntityStateConversionRules.Angles,
	attacker: ResolvedSource,
	inflictor: ResolvedSource,
}
export type Result = {
	read pmType: "Dead",
	read deadLifeSequence: number,
	read initialViewHeight: number,
	read deathGenericAngles: EntityStateConversionRules.Angles,
	read playerStateViewAngles: EntityStateConversionRules.Angles,
	read deadYawDegrees: number,
	read deadYawSource: DeathViewRules.Source,
	read selectedEntityKind: SourceKind,
}

local DeathTransitionRules = {}

local MAXIMUM_LIFE_SEQUENCE = 2_147_483_647
local REQUEST_KEYS: { [string]: boolean } = table.freeze({
	lifeSequence = true,
	crouched = true,
	victimTrajectoryBase = true,
	retainedGenericAngles = true,
	attacker = true,
	inflictor = true,
})
local SOURCE_KEYS: { [string]: boolean } = table.freeze({
	kind = true,
	trajectoryBase = true,
})

local function hasExactRawKeys(value: unknown, allowed: { [string]: boolean }, expectedCount: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false
	end
	local raw = value :: { [unknown]: unknown }
	local count = 0
	for key in next, raw do
		if type(key) ~= "string" or allowed[key] ~= true then
			return false
		end
		count += 1
	end
	return count == expectedCount
end

local function isLifeSequence(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= 1
		and (value :: number) <= MAXIMUM_LIFE_SEQUENCE
end

local function isSnappedTrajectoryBase(value: unknown): boolean
	return EntityStateConversionRules.IsSnappedTrajectoryBase(value)
end

local function isBoundedTrajectoryBase(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	local maximum = EntityStateConversionRules.MaximumComponent
	return vector.X == vector.X
		and vector.Y == vector.Y
		and vector.Z == vector.Z
		and math.abs(vector.X) < math.huge
		and math.abs(vector.Y) < math.huge
		and math.abs(vector.Z) < math.huge
		and math.max(math.abs(vector.X), math.abs(vector.Y), math.abs(vector.Z)) <= maximum
end

local function inspectSource(value: unknown): (ResolvedSource?, string?)
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return nil, "invalid-death-transition-source-shape"
	end
	local raw = value :: { [unknown]: unknown }
	local kind = rawget(raw, "kind")
	if kind == "Victim" or kind == "World" then
		if not hasExactRawKeys(value, SOURCE_KEYS, 1) then
			return nil, "invalid-death-transition-source-shape"
		end
		return value :: ResolvedSource, nil
	end
	if kind ~= "Player" and kind ~= "Mover" and kind ~= "Projectile" and kind ~= "External" then
		return nil, "invalid-death-transition-source-kind"
	end
	if
		not hasExactRawKeys(value, SOURCE_KEYS, 2)
		or not isBoundedTrajectoryBase(rawget(raw, "trajectoryBase"))
		or (kind == "Player" and not isSnappedTrajectoryBase(rawget(raw, "trajectoryBase")))
	then
		return nil, "invalid-death-transition-source"
	end
	return value :: ResolvedSource, nil
end

local function sourceTrajectoryBase(source: ResolvedSource): Vector3?
	if source.kind == "Victim" then
		return nil
	elseif source.kind == "World" then
		-- G_Damage replaces nil attacker/inflictor with ENTITYNUM_WORLD before
		-- player_die. Its zero-initialized s.pos.trBase is a real source, not nil.
		return Vector3.zero
	else
		return source.trajectoryBase
	end
end

local function resolve(requestValue: unknown, allowMoverRestoredVictimBase: boolean): (Result?, string?)
	if not hasExactRawKeys(requestValue, REQUEST_KEYS, 6) then
		return nil, "invalid-death-transition-request-shape"
	end
	local raw = requestValue :: { [unknown]: unknown }
	local lifeSequence = rawget(raw, "lifeSequence")
	local crouched = rawget(raw, "crouched")
	local victimTrajectoryBase = rawget(raw, "victimTrajectoryBase")
	local retainedGenericAnglesValue = rawget(raw, "retainedGenericAngles")
	if not isLifeSequence(lifeSequence) then
		return nil, "invalid-death-transition-life-sequence"
	end
	if type(crouched) ~= "boolean" then
		return nil, "invalid-death-transition-crouched"
	end
	if
		if allowMoverRestoredVictimBase
			then not isBoundedTrajectoryBase(victimTrajectoryBase)
			else not isSnappedTrajectoryBase(victimTrajectoryBase)
	then
		return nil, "invalid-death-transition-victim-trajectory-base"
	end
	if type(retainedGenericAnglesValue) ~= "table" or not table.isfrozen(retainedGenericAnglesValue :: table) then
		return nil, "invalid-death-transition-retained-generic-angles"
	end
	local retainedGenericAngles = EntityStateConversionRules.InspectAngles(retainedGenericAnglesValue)
	if not retainedGenericAngles then
		return nil, "invalid-death-transition-generic-angles"
	end
	local attacker, attackerError = inspectSource(rawget(raw, "attacker"))
	if not attacker then
		return nil, attackerError
	end
	local inflictor, inflictorError = inspectSource(rawget(raw, "inflictor"))
	if not inflictor then
		return nil, inflictorError
	end
	if
		allowMoverRestoredVictimBase
		and (
			attacker.kind ~= "Mover"
			or inflictor.kind ~= "Mover"
			or attacker.trajectoryBase ~= inflictor.trajectoryBase
		)
	then
		return nil, "invalid-mover-pushed-client-death-sources"
	end

	local attackerBase = sourceTrajectoryBase(attacker)
	local inflictorBase = if attacker.kind == "Victim" then sourceTrajectoryBase(inflictor) else nil
	local selectedEntityKind: SourceKind
	if attacker.kind ~= "Victim" then
		selectedEntityKind = attacker.kind
	elseif inflictor.kind ~= "Victim" then
		selectedEntityKind = inflictor.kind
	else
		selectedEntityKind = "Victim"
	end
	local deadView, deadViewError = DeathViewRules.Resolve({
		victimTrajectoryBase = victimTrajectoryBase :: Vector3,
		retainedEntityYawDegrees = retainedGenericAngles.yaw,
		attackerTrajectoryBase = attackerBase,
		inflictorTrajectoryBase = inflictorBase,
	})
	if not deadView then
		return nil, deadViewError or "death-transition-view-resolution-failed"
	end
	local deathGenericAngles = EntityStateConversionRules.DeathGenericAngles(retainedGenericAngles)
	if not deathGenericAngles then
		return nil, "death-transition-generic-angle-resolution-failed"
	end
	local result: Result = {
		pmType = "Dead",
		deadLifeSequence = lifeSequence :: number,
		initialViewHeight = Constants.ViewHeightFor(crouched :: boolean),
		deathGenericAngles = deathGenericAngles,
		-- VectorCopy creates the same values in ps.viewangles. Because the record
		-- is immutable, sharing this value identity cannot alias later mutation;
		-- either owner replaces its field independently.
		playerStateViewAngles = deathGenericAngles,
		deadYawDegrees = deadView.deadYawDegrees,
		deadYawSource = deadView.source,
		selectedEntityKind = selectedEntityKind,
	}
	table.freeze(result)
	return result, nil
end

function DeathTransitionRules.Resolve(requestValue: unknown): (Result?, string?)
	return resolve(requestValue, false)
end

-- G_TryPushingEntity saves a client's precise ps.origin and restores that
-- value into s.pos.trBase before an inline Sine crush or the later blocked
-- callback calls G_Damage. Unlike the ordinary post-BG projection path, this
-- victim base can therefore remain fractional. Keep that exception narrow:
-- only the prepared mover owner may resolve equal Mover attacker/inflictor
-- sources through this explicitly named entry point.
function DeathTransitionRules.ResolveMoverPushedClient(requestValue: unknown): (Result?, string?)
	return resolve(requestValue, true)
end

return table.freeze(DeathTransitionRules)
