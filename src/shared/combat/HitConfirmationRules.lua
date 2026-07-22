--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox/Luau adaptation of:
  code/game/bg_public.h (PERS_HITS)
  code/game/g_combat.c (G_Damage attacker hit-counter update)
  code/cgame/cg_playerstate.c (CG_CheckLocalSounds hit transition)

Q3 transports PERS_HITS in an owner snapshot and CG_CheckLocalSounds emits one
local cue when that snapshot changes. the Roblox Luau port's server already publishes a
trusted, post-close Damage event for every applied G_Damage contact. The event
carries an opponent-only bit and shot identity; the client validates that small
presentation record and suppresses later contacts from the same shot. No hit
presentation state is allowed to mutate authoritative CombatRecord state.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-21.
]]

--!strict

local HitConfirmationRules = {}

-- ProjectileEntityService owns the same 128-byte authority boundary. Keeping
-- that bound here also leaves ample room for the local `hit-confirm:`
-- correlation prefix under LayeredAudioRuntime's 256-byte maximum.
local MAXIMUM_SHOT_ID_LENGTH = 128
local MAXIMUM_USER_ID = 9_007_199_254_740_991
local MAXIMUM_VITAL = 100_000

export type Confirmation = {
	read shotId: string,
	read targetUserId: number,
	read targetHealth: number,
	read targetArmor: number,
}

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value % 1 == 0
		and value >= minimum
		and value <= maximum
end

-- Returns only a server-authored opponent confirmation for this local player.
-- Teammate, self, world, victim-only, and malformed Damage events are silent.
function HitConfirmationRules.ReadDamageConfirmation(value: unknown, localUserId: unknown): Confirmation?
	if type(value) ~= "table" then
		return nil
	end
	local event = value :: any
	if
		not isIntegerInRange(localUserId, -MAXIMUM_USER_ID, MAXIMUM_USER_ID)
		or event.kind ~= "Damage"
		or event.hitConfirmed ~= true
		or event.isSelfDamage ~= false
		or not isIntegerInRange(event.attackerUserId, -MAXIMUM_USER_ID, MAXIMUM_USER_ID)
		or event.attackerUserId ~= localUserId
		or not isIntegerInRange(event.targetUserId, -MAXIMUM_USER_ID, MAXIMUM_USER_ID)
		or event.targetUserId == 0
		or event.targetUserId == localUserId
		or type(event.shotId) ~= "string"
		or event.shotId == ""
		or #event.shotId > MAXIMUM_SHOT_ID_LENGTH
		or not isIntegerInRange(event.targetHealth, 0, MAXIMUM_VITAL)
		or not isIntegerInRange(event.targetArmor, 0, MAXIMUM_VITAL)
	then
		return nil
	end
	return table.freeze({
		shotId = event.shotId,
		targetUserId = event.targetUserId,
		targetHealth = event.targetHealth,
		targetArmor = event.targetArmor,
	})
end

HitConfirmationRules.MaximumShotIdLength = MAXIMUM_SHOT_ID_LENGTH

return table.freeze(HitConfirmationRules)
