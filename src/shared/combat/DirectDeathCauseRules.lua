--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure closed direct-death cause classification translated from Quake III Arena:
  code/game/bg_public.h (meansOfDeath_t)
  code/game/g_weapon.c (player weapon G_Damage calls)
  code/game/g_missile.c (G_MissileImpact and G_RadiusDamage)
  code/game/g_active.c (falling/world-effect G_Damage calls)
  code/game/g_combat.c (G_Damage and player_die)
  code/game/g_cmds.c (Cmd_Kill_f direct player_die)
  code/game/g_utils.c (G_KillBox telefrag G_Damage)

Q3 has no Void means-of-death route through G_Damage. the Roblox Luau port's Void
boundary is therefore admitted only as a forced world player_die equivalent,
never as WorldDamage. Ordinary world damage admits the live World, Falling,
Water, Lava, and Slime owners.

The exact-shape requests and immutable normalized classifications are Roblox
Arena authority adaptations. A server owner may retain the returned object in
its private capability and require both object identity and Validate before
applying a direct-death transaction. This module owns no services, Instances,
clocks, remotes, or mutable authority.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local WeaponDefinitions = require(script.Parent.WeaponDefinitions)

export type CauseKind =
	"PlayerDirect"
	| "MissileImpact"
	| "ProjectileSplash"
	| "WorldDamage"
	| "ForcedWorldPlayerDie"
	| "SuicidePlayerDie"
	| "Telefrag"

export type DamageMode = "GDamage" | "PlayerDie"
export type MeansOfDeath = "Ordinary" | "MOD_SUICIDE"
export type WeaponKind =
	"Melee"
	| "Hitscan"
	| "PelletHitscan"
	| "ContinuousHitscan"
	| "PenetratingHitscan"
	| "LinearProjectile"
	| "GravityProjectile"

export type WeaponRequest = {
	kind: "PlayerDirect" | "MissileImpact" | "ProjectileSplash",
	weaponId: number,
	means: string,
}

export type NonWeaponRequest = {
	kind: "WorldDamage" | "ForcedWorldPlayerDie" | "SuicidePlayerDie" | "Telefrag",
	means: string,
}

export type Request = WeaponRequest | NonWeaponRequest

export type Classification = {
	read kind: CauseKind,
	read damageMode: DamageMode,
	read weaponId: number | false,
	read weaponKind: WeaponKind | false,
	read means: string,
	read meansOfDeath: MeansOfDeath,
	read isSplash: boolean,
	read bypassCombatEligibility: boolean,
}

local DirectDeathCauseRules = {}

local Kinds = table.freeze({
	PlayerDirect = "PlayerDirect" :: CauseKind,
	MissileImpact = "MissileImpact" :: CauseKind,
	ProjectileSplash = "ProjectileSplash" :: CauseKind,
	WorldDamage = "WorldDamage" :: CauseKind,
	ForcedWorldPlayerDie = "ForcedWorldPlayerDie" :: CauseKind,
	SuicidePlayerDie = "SuicidePlayerDie" :: CauseKind,
	Telefrag = "Telefrag" :: CauseKind,
})

local DamageModes = table.freeze({
	GDamage = "GDamage" :: DamageMode,
	PlayerDie = "PlayerDie" :: DamageMode,
})

local MeansOfDeaths = table.freeze({
	Ordinary = "Ordinary" :: MeansOfDeath,
	Suicide = "MOD_SUICIDE" :: MeansOfDeath,
})

local WeaponKinds = table.freeze({
	Melee = "Melee" :: WeaponKind,
	Hitscan = "Hitscan" :: WeaponKind,
	PelletHitscan = "PelletHitscan" :: WeaponKind,
	ContinuousHitscan = "ContinuousHitscan" :: WeaponKind,
	PenetratingHitscan = "PenetratingHitscan" :: WeaponKind,
	LinearProjectile = "LinearProjectile" :: WeaponKind,
	GravityProjectile = "GravityProjectile" :: WeaponKind,
})

local PLAYER_DIRECT_WEAPON_KINDS: { [string]: boolean } = table.freeze({
	[WeaponKinds.Melee] = true,
	[WeaponKinds.Hitscan] = true,
	[WeaponKinds.PelletHitscan] = true,
	[WeaponKinds.ContinuousHitscan] = true,
	[WeaponKinds.PenetratingHitscan] = true,
})

local PROJECTILE_WEAPON_KINDS: { [string]: boolean } = table.freeze({
	[WeaponKinds.LinearProjectile] = true,
	[WeaponKinds.GravityProjectile] = true,
})

local WEAPON_REQUEST_KEYS: { [string]: boolean } = table.freeze({
	kind = true,
	weaponId = true,
	means = true,
})

local NON_WEAPON_REQUEST_KEYS: { [string]: boolean } = table.freeze({
	kind = true,
	means = true,
})

local CLASSIFICATION_KEYS: { [string]: boolean } = table.freeze({
	kind = true,
	damageMode = true,
	weaponId = true,
	weaponKind = true,
	means = true,
	meansOfDeath = true,
	isSplash = true,
	bypassCombatEligibility = true,
})

local function hasExactRawKeys(value: unknown, allowedKeys: { [string]: boolean }, expectedCount: number): boolean
	if type(value) ~= "table" or getmetatable(value) ~= nil then
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

local function isWeaponId(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
end

local function makeClassification(
	kind: CauseKind,
	damageMode: DamageMode,
	weaponId: number | false,
	weaponKind: WeaponKind | false,
	means: string,
	meansOfDeath: MeansOfDeath,
	isSplash: boolean,
	bypassCombatEligibility: boolean
): Classification
	return table.freeze({
		kind = kind,
		damageMode = damageMode,
		weaponId = weaponId,
		weaponKind = weaponKind,
		means = means,
		meansOfDeath = meansOfDeath,
		isSplash = isSplash,
		bypassCombatEligibility = bypassCombatEligibility,
	})
end

local function resolveWeaponCause(raw: { [unknown]: unknown }): (Classification?, string?)
	if not hasExactRawKeys(raw, WEAPON_REQUEST_KEYS, 3) then
		return nil, "invalid-direct-death-weapon-request-shape"
	end
	local kind = rawget(raw, "kind")
	local weaponIdValue = rawget(raw, "weaponId")
	local meansValue = rawget(raw, "means")
	if not isWeaponId(weaponIdValue) or type(meansValue) ~= "string" then
		return nil, "invalid-direct-death-weapon-request"
	end
	local weaponId = weaponIdValue :: number
	local definition = WeaponDefinitions.ById[weaponId]
	if
		type(definition) ~= "table"
		or not table.isfrozen(definition)
		or definition.Id ~= weaponId
		or WeaponDefinitions.LiveAllowed[weaponId] ~= true
		or type(definition.Kind) ~= "string"
		or type(definition.DirectMeans) ~= "string"
	then
		return nil, "direct-death-weapon-definition-unavailable"
	end
	local weaponKind = definition.Kind
	if kind == Kinds.PlayerDirect then
		if PLAYER_DIRECT_WEAPON_KINDS[weaponKind] ~= true or meansValue ~= definition.DirectMeans then
			return nil, "invalid-player-direct-death-cause"
		end
		return makeClassification(
			Kinds.PlayerDirect,
			DamageModes.GDamage,
			weaponId,
			weaponKind :: WeaponKind,
			meansValue,
			MeansOfDeaths.Ordinary,
			false,
			false
		),
			nil
	elseif kind == Kinds.MissileImpact then
		if PROJECTILE_WEAPON_KINDS[weaponKind] ~= true or meansValue ~= definition.DirectMeans then
			return nil, "invalid-missile-impact-death-cause"
		end
		return makeClassification(
			Kinds.MissileImpact,
			DamageModes.GDamage,
			weaponId,
			weaponKind :: WeaponKind,
			meansValue,
			MeansOfDeaths.Ordinary,
			false,
			false
		),
			nil
	elseif kind == Kinds.ProjectileSplash then
		if
			PROJECTILE_WEAPON_KINDS[weaponKind] ~= true
			or type(definition.SplashMeans) ~= "string"
			or meansValue ~= definition.SplashMeans
		then
			return nil, "invalid-projectile-splash-death-cause"
		end
		return makeClassification(
			Kinds.ProjectileSplash,
			DamageModes.GDamage,
			weaponId,
			weaponKind :: WeaponKind,
			meansValue,
			MeansOfDeaths.Ordinary,
			true,
			false
		),
			nil
	end
	return nil, "invalid-direct-death-cause-kind"
end

local function resolveNonWeaponCause(raw: { [unknown]: unknown }): (Classification?, string?)
	if not hasExactRawKeys(raw, NON_WEAPON_REQUEST_KEYS, 2) then
		return nil, "invalid-direct-death-nonweapon-request-shape"
	end
	local kind = rawget(raw, "kind")
	local means = rawget(raw, "means")
	if type(means) ~= "string" then
		return nil, "invalid-direct-death-nonweapon-request"
	end
	if kind == Kinds.WorldDamage then
		if means ~= "World" and means ~= "Falling" and means ~= "Water" and means ~= "Lava" and means ~= "Slime" then
			return nil, "invalid-world-damage-death-cause"
		end
		return makeClassification(
			Kinds.WorldDamage,
			DamageModes.GDamage,
			false,
			false,
			means,
			MeansOfDeaths.Ordinary,
			false,
			false
		),
			nil
	elseif kind == Kinds.ForcedWorldPlayerDie then
		if means ~= "World" and means ~= "Void" then
			return nil, "invalid-forced-world-player-die-cause"
		end
		return makeClassification(
			Kinds.ForcedWorldPlayerDie,
			DamageModes.PlayerDie,
			false,
			false,
			means,
			MeansOfDeaths.Ordinary,
			false,
			false
		),
			nil
	elseif kind == Kinds.SuicidePlayerDie then
		if means ~= "Suicide" then
			return nil, "invalid-suicide-player-die-cause"
		end
		return makeClassification(
			Kinds.SuicidePlayerDie,
			DamageModes.PlayerDie,
			false,
			false,
			"Suicide",
			MeansOfDeaths.Suicide,
			false,
			false
		),
			nil
	elseif kind == Kinds.Telefrag then
		if means ~= "Telefrag" then
			return nil, "invalid-telefrag-death-cause"
		end
		return makeClassification(
			Kinds.Telefrag,
			DamageModes.GDamage,
			false,
			false,
			"Telefrag",
			MeansOfDeaths.Ordinary,
			false,
			true
		),
			nil
	end
	return nil, "invalid-direct-death-cause-kind"
end

function DirectDeathCauseRules.Resolve(requestValue: unknown): (Classification?, string?)
	if type(requestValue) ~= "table" or getmetatable(requestValue :: table) ~= nil then
		return nil, "invalid-direct-death-cause-request"
	end
	local raw = requestValue :: { [unknown]: unknown }
	local kind = rawget(raw, "kind")
	if kind == Kinds.PlayerDirect or kind == Kinds.MissileImpact or kind == Kinds.ProjectileSplash then
		return resolveWeaponCause(raw)
	end
	return resolveNonWeaponCause(raw)
end

-- Validate is deliberately structural and returns the exact supplied frozen
-- object. A private server capability can additionally require that identity
-- to equal the result it retained from Resolve, rejecting cloned records while
-- keeping this shared kernel deterministic and stateless.
function DirectDeathCauseRules.Validate(value: unknown): (Classification?, string?)
	if not hasExactRawKeys(value, CLASSIFICATION_KEYS, 8) or not table.isfrozen(value :: table) then
		return nil, "invalid-direct-death-classification-shape"
	end
	local raw = value :: { [unknown]: unknown }
	local weaponId = rawget(raw, "weaponId")
	local request: { [string]: unknown }
	if weaponId == false then
		request = {
			kind = rawget(raw, "kind"),
			means = rawget(raw, "means"),
		}
	else
		request = {
			kind = rawget(raw, "kind"),
			weaponId = weaponId,
			means = rawget(raw, "means"),
		}
	end
	local resolved, resolveError = DirectDeathCauseRules.Resolve(request)
	if not resolved then
		return nil, resolveError or "invalid-direct-death-classification"
	end
	for key in CLASSIFICATION_KEYS do
		if rawget(raw, key) ~= (resolved :: any)[key] then
			return nil, "direct-death-classification-mismatch"
		end
	end
	return value :: Classification, nil
end

DirectDeathCauseRules.Kinds = Kinds
DirectDeathCauseRules.DamageModes = DamageModes
DirectDeathCauseRules.MeansOfDeath = MeansOfDeaths
DirectDeathCauseRules.WeaponKinds = WeaponKinds

return table.freeze(DirectDeathCauseRules)
