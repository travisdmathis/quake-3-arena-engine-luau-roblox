--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure SURF_NOIMPACT decisions translated from Quake III Arena:
  code/game/g_weapon.c (CheckGauntletAttack, Bullet_Fire, ShotgunPellet,
    Weapon_LightningFire, weapon_railgun_fire)
  code/game/g_missile.c (G_RunMissile)

The decision rows deliberately describe only the SURF_NOIMPACT override. A nil
result means ordinary weapon resolution continues unchanged.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

export type Family = "Gauntlet" | "Machinegun" | "ShotgunPellet" | "Lightning" | "Rail" | "Projectile"

export type Action =
	"AbortAttack"
	| "SuppressTrace"
	| "SuppressPellet"
	| "SuppressWorldImpact"
	| "SuppressTerminalImpact"
	| "DestroyWithoutImpact"

export type Decision = {
	action: Action,
	weaponCycle: boolean,
	directDamage: boolean,
	splashDamage: boolean,
	pathPresentation: boolean,
	endpointPresentation: boolean,
	terminalImpact: boolean,
	continueShotgunPattern: boolean,
	destroyProjectile: boolean,
	projectileBounce: boolean,
	projectileExplosion: boolean,
}

local Family = table.freeze({
	Gauntlet = "Gauntlet" :: "Gauntlet",
	Machinegun = "Machinegun" :: "Machinegun",
	ShotgunPellet = "ShotgunPellet" :: "ShotgunPellet",
	Lightning = "Lightning" :: "Lightning",
	Rail = "Rail" :: "Rail",
	Projectile = "Projectile" :: "Projectile",
})

local Action = table.freeze({
	AbortAttack = "AbortAttack" :: "AbortAttack",
	SuppressTrace = "SuppressTrace" :: "SuppressTrace",
	SuppressPellet = "SuppressPellet" :: "SuppressPellet",
	SuppressWorldImpact = "SuppressWorldImpact" :: "SuppressWorldImpact",
	SuppressTerminalImpact = "SuppressTerminalImpact" :: "SuppressTerminalImpact",
	DestroyWithoutImpact = "DestroyWithoutImpact" :: "DestroyWithoutImpact",
})

local function decision(values: Decision): Decision
	return table.freeze(values)
end

local NO_IMPACT_BY_FAMILY: { [Family]: Decision } = table.freeze({
	-- CheckGauntletAttack returns false before PM_Weapon can create a fire event,
	-- consume the 400 ms cycle, or apply contact damage.
	[Family.Gauntlet] = decision({
		action = Action.AbortAttack,
		weaponCycle = false,
		directDamage = false,
		splashDamage = false,
		pathPresentation = false,
		endpointPresentation = false,
		terminalImpact = false,
		continueShotgunPattern = false,
		destroyProjectile = false,
		projectileBounce = false,
		projectileExplosion = false,
	}),

	-- Bullet_Fire returns after the weapon cycle already consumed ammo/refire and
	-- produced the firing cue, suppressing the bullet event, damage, and impact.
	[Family.Machinegun] = decision({
		action = Action.SuppressTrace,
		weaponCycle = true,
		directDamage = false,
		splashDamage = false,
		pathPresentation = false,
		endpointPresentation = false,
		terminalImpact = false,
		continueShotgunPattern = false,
		destroyProjectile = false,
		projectileBounce = false,
		projectileExplosion = false,
	}),

	-- ShotgunPellet returns only for that pellet. The blast cycle remains and the
	-- deterministic pattern continues so other pellets resolve independently.
	[Family.ShotgunPellet] = decision({
		action = Action.SuppressPellet,
		weaponCycle = true,
		directDamage = false,
		splashDamage = false,
		pathPresentation = false,
		endpointPresentation = false,
		terminalImpact = false,
		continueShotgunPattern = true,
		destroyProjectile = false,
		projectileBounce = false,
		projectileExplosion = false,
	}),

	-- Weapon_LightningFire still owns beam, endpoint, and damage semantics; only
	-- the EV_MISSILE_MISS world-impact event is suppressed.
	[Family.Lightning] = decision({
		action = Action.SuppressWorldImpact,
		weaponCycle = true,
		directDamage = true,
		splashDamage = false,
		pathPresentation = true,
		endpointPresentation = true,
		terminalImpact = false,
		continueShotgunPattern = false,
		destroyProjectile = false,
		projectileBounce = false,
		projectileExplosion = false,
	}),

	-- weapon_railgun_fire preserves penetration, damage, and EV_RAILTRAIL while
	-- eventParm 255 suppresses only the terminal explosion/mark.
	[Family.Rail] = decision({
		action = Action.SuppressTerminalImpact,
		weaponCycle = true,
		directDamage = true,
		splashDamage = false,
		pathPresentation = true,
		endpointPresentation = true,
		terminalImpact = false,
		continueShotgunPattern = false,
		destroyProjectile = false,
		projectileBounce = false,
		projectileExplosion = false,
	}),

	-- G_RunMissile frees the missile before G_MissileImpact. The already visible
	-- projectile path may fade, but no direct/splash damage, bounce, or explosion
	-- is authorized at this collision.
	[Family.Projectile] = decision({
		action = Action.DestroyWithoutImpact,
		weaponCycle = true,
		directDamage = false,
		splashDamage = false,
		pathPresentation = true,
		endpointPresentation = false,
		terminalImpact = false,
		continueShotgunPattern = false,
		destroyProjectile = true,
		projectileBounce = false,
		projectileExplosion = false,
	}),
})

local function resolve(family: Family, surfaceNoImpact: boolean): Decision?
	if not surfaceNoImpact then
		return nil
	end

	local result = NO_IMPACT_BY_FAMILY[family]
	if not result then
		error(string.format("unsupported SURF_NOIMPACT weapon family %s", tostring(family)))
	end
	return result
end

return table.freeze({
	Family = Family,
	Action = Action,
	Resolve = resolve,
})
