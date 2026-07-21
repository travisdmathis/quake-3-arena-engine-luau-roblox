--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure Roblox/Luau adaptation of base Quake III Arena timed powerups from:
  code/game/bg_public.h (powerup_t)
  code/game/g_items.c (Pickup_Powerup)
  code/game/g_active.c (ClientTimerActions, ClientEndFrame)
  code/game/g_combat.c (Battle Suit damage protection)
  code/game/g_weapon.c (Quad Damage)
  code/game/bg_pmove.c (Haste weapon cadence)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local PowerupRules = {}

local PowerupId = table.freeze({
	Quad = 1,
	BattleSuit = 2,
	Haste = 3,
	Invisibility = 4,
	Regeneration = 5,
	Flight = 6,
})

local ITEM_ID_BY_POWERUP_ID = table.freeze({
	[PowerupId.Quad] = "item_quad",
	[PowerupId.BattleSuit] = "item_enviro",
	[PowerupId.Haste] = "item_haste",
	[PowerupId.Invisibility] = "item_invis",
	[PowerupId.Regeneration] = "item_regen",
	[PowerupId.Flight] = "item_flight",
})

local DEFAULT_DURATION_SECONDS = 30
local FLIGHT_DURATION_SECONDS = 60
local RESPAWN_SECONDS = 120
local QUAD_DAMAGE_FACTOR = 3
local HASTE_WEAPON_FACTOR = 1.3
local FIRST_DEATH_DROP_ANGLE_DEGREES = 45
local DEATH_DROP_ANGLE_STEP_DEGREES = 45

export type DeathDrop = {
	read powerupId: number,
	read remainingSeconds: number,
	read yawOffsetDegrees: number,
}

local function isInteger(value: unknown): boolean
	return type(value) == "number" and value % 1 == 0
end

function PowerupRules.IsId(value: unknown): boolean
	return isInteger(value) and value >= PowerupId.Quad and value <= PowerupId.Flight
end

function PowerupRules.DefaultDurationSeconds(powerupId: unknown): number?
	if not PowerupRules.IsId(powerupId) then
		return nil
	end
	return if powerupId == PowerupId.Flight then FLIGHT_DURATION_SECONDS else DEFAULT_DURATION_SECONDS
end

function PowerupRules.PickupExpiryMilliseconds(
	currentExpiryMilliseconds: unknown,
	levelTimeMilliseconds: unknown,
	durationSeconds: unknown
): number?
	if
		not isInteger(currentExpiryMilliseconds)
		or currentExpiryMilliseconds < 0
		or not isInteger(levelTimeMilliseconds)
		or levelTimeMilliseconds < 0
		or not isInteger(durationSeconds)
		or durationSeconds < 1
	then
		return nil
	end
	local base = currentExpiryMilliseconds
	if base == 0 then
		base = levelTimeMilliseconds - levelTimeMilliseconds % 1_000
	end
	return base + durationSeconds * 1_000
end

function PowerupRules.IsActive(expiryMilliseconds: unknown, levelTimeMilliseconds: unknown): boolean?
	if
		not isInteger(expiryMilliseconds)
		or expiryMilliseconds < 0
		or not isInteger(levelTimeMilliseconds)
		or levelTimeMilliseconds < 0
	then
		return nil
	end
	return expiryMilliseconds > levelTimeMilliseconds
end

-- TossClientItems walks PW_QUAD..PW_FLIGHT, skips expired slots, truncates the
-- remaining milliseconds to seconds, clamps the result to one, and advances
-- the launch yaw only for an item that was actually dropped. Base Q3 suppresses
-- this loop for GT_TEAM exactly; CTF and non-team modes still drop powerups.
function PowerupRules.ResolveDeathDrops(
	expiriesValue: unknown,
	levelTimeMilliseconds: unknown,
	suppressForTeamDeathmatch: unknown
): { DeathDrop }?
	if
		type(expiriesValue) ~= "table"
		or not isInteger(levelTimeMilliseconds)
		or levelTimeMilliseconds < 0
		or type(suppressForTeamDeathmatch) ~= "boolean"
	then
		return nil
	end
	local expiries = expiriesValue :: { [unknown]: unknown }
	for key, expiry in expiries do
		if not PowerupRules.IsId(key) or not isInteger(expiry) or (expiry :: number) < 0 then
			return nil
		end
	end
	local drops: { DeathDrop } = {}
	if suppressForTeamDeathmatch then
		table.freeze(drops)
		return drops
	end
	local angle = FIRST_DEATH_DROP_ANGLE_DEGREES
	for powerupId = PowerupId.Quad, PowerupId.Flight do
		local expiry = expiries[powerupId]
		if type(expiry) == "number" and expiry > levelTimeMilliseconds then
			local drop: DeathDrop = table.freeze({
				powerupId = powerupId,
				remainingSeconds = math.max(1, math.floor((expiry - levelTimeMilliseconds) / 1_000)),
				yawOffsetDegrees = angle,
			})
			table.insert(drops, drop)
			angle += DEATH_DROP_ANGLE_STEP_DEGREES
		end
	end
	table.freeze(drops)
	return drops
end

function PowerupRules.QuadDamage(damage: unknown, active: unknown): number?
	if not isInteger(damage) or damage < 0 or type(active) ~= "boolean" then
		return nil
	end
	return if active then damage * QUAD_DAMAGE_FACTOR else damage
end

function PowerupRules.BattleSuitDamage(
	damage: unknown,
	active: unknown,
	radiusDamage: unknown,
	fallingDamage: unknown
): number?
	if
		not isInteger(damage)
		or damage < 0
		or type(active) ~= "boolean"
		or type(radiusDamage) ~= "boolean"
		or type(fallingDamage) ~= "boolean"
	then
		return nil
	end
	if not active then
		return damage
	end
	if radiusDamage or fallingDamage then
		return 0
	end
	return math.floor(damage * 0.5)
end

function PowerupRules.HasteWeaponMilliseconds(milliseconds: unknown, active: unknown): number?
	if not isInteger(milliseconds) or milliseconds < 0 or type(active) ~= "boolean" then
		return nil
	end
	return if active then math.floor(milliseconds / HASTE_WEAPON_FACTOR) else milliseconds
end

function PowerupRules.RegenerateHealth(health: unknown, maximumHealth: unknown, active: unknown): number?
	if not isInteger(health) or not isInteger(maximumHealth) or maximumHealth < 1 or type(active) ~= "boolean" then
		return nil
	end
	if not active or health >= maximumHealth * 2 then
		return health
	end
	if health < maximumHealth then
		return math.min(health + 15, math.floor(maximumHealth * 1.1))
	end
	return math.min(health + 5, maximumHealth * 2)
end

PowerupRules.PowerupId = PowerupId
PowerupRules.ItemIdByPowerupId = ITEM_ID_BY_POWERUP_ID
PowerupRules.RespawnSeconds = RESPAWN_SECONDS
PowerupRules.FirstDeathDropAngleDegrees = FIRST_DEATH_DROP_ANGLE_DEGREES
PowerupRules.DeathDropAngleStepDegrees = DEATH_DROP_ANGLE_STEP_DEGREES

return table.freeze(PowerupRules)
