--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure CombatEvent presentation-schema rules translated from Quake III Arena:
  code/game/g_weapon.c (Bullet_Fire, ShotgunPellet,
    Weapon_LightningFire, weapon_railgun_fire)
  code/cgame/cg_weapons.c (CG_ShotgunPellet)
  code/cgame/cg_event.c (EV_RAILTRAIL and impact events)

The server decides which presentation fields are authorized. Clients use this
module only to reject malformed or source-impossible combinations before
presenting them.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

local WeaponDefinitions = require(script.Parent.WeaponDefinitions)

export type ScalarPresentation = {
	tracePresentation: boolean,
	terminalImpactPresentation: boolean,
}

export type EventPresentation = {
	tracePresentation: boolean,
	terminalImpactPresentation: boolean,
	pelletTraceMask: number?,
	pelletImpactMask: number?,
	pelletCount: number?,
}

local MAXIMUM_SHOTGUN_PELLETS = 16
local MAXIMUM_SHOTGUN_MASK = 2 ^ MAXIMUM_SHOTGUN_PELLETS - 1

local TRACE_AND_IMPACT: ScalarPresentation = table.freeze({
	tracePresentation = true,
	terminalImpactPresentation = true,
})
local TRACE_ONLY: ScalarPresentation = table.freeze({
	tracePresentation = true,
	terminalImpactPresentation = false,
})
local SUPPRESSED: ScalarPresentation = table.freeze({
	tracePresentation = false,
	terminalImpactPresentation = false,
})

local WeaponId = WeaponDefinitions.WeaponId
local SOURCE_SHOTGUN_PELLETS = WeaponDefinitions.ById[WeaponId.Shotgun].Pellets

local EXPECTED_KIND_BY_WEAPON_ID: { [number]: string } = table.freeze({
	[WeaponId.Gauntlet] = "Melee",
	[WeaponId.Machinegun] = "Hitscan",
	[WeaponId.Shotgun] = "Shotgun",
	[WeaponId.LightningGun] = "Hitscan",
	[WeaponId.Railgun] = "Rail",
})

local NORMAL_BY_WEAPON_ID: { [number]: ScalarPresentation } = table.freeze({
	[WeaponId.Gauntlet] = TRACE_AND_IMPACT,
	[WeaponId.Machinegun] = TRACE_AND_IMPACT,
	[WeaponId.Shotgun] = TRACE_AND_IMPACT,
	[WeaponId.LightningGun] = TRACE_AND_IMPACT,
	[WeaponId.Railgun] = TRACE_AND_IMPACT,
})

local NO_IMPACT_BY_WEAPON_ID: { [number]: ScalarPresentation } = table.freeze({
	-- A gauntlet NOIMPACT trace aborts before a CombatEvent exists.
	[WeaponId.Machinegun] = SUPPRESSED,
	[WeaponId.Shotgun] = SUPPRESSED,
	[WeaponId.LightningGun] = TRACE_ONLY,
	[WeaponId.Railgun] = TRACE_ONLY,
})

local function isFiniteInteger(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge and value % 1 == 0
end

local function isFiniteVector3(value: unknown): boolean
	return typeof(value) == "Vector3"
		and (value :: Vector3).X == (value :: Vector3).X
		and (value :: Vector3).Y == (value :: Vector3).Y
		and (value :: Vector3).Z == (value :: Vector3).Z
		and math.abs((value :: Vector3).X) < math.huge
		and math.abs((value :: Vector3).Y) < math.huge
		and math.abs((value :: Vector3).Z) < math.huge
end

local function isLiveWeaponId(value: unknown): boolean
	return isFiniteInteger(value) and WeaponDefinitions.LiveAllowed[value :: number] == true
end

local function validPelletIndex(value: unknown): boolean
	return isFiniteInteger(value) and (value :: number) >= 1 and (value :: number) <= MAXIMUM_SHOTGUN_PELLETS
end

local function validRawMask(value: unknown): boolean
	return isFiniteInteger(value) and (value :: number) >= 0 and (value :: number) <= MAXIMUM_SHOTGUN_MASK
end

local function fullPelletMask(pelletCount: unknown): number?
	if
		not isFiniteInteger(pelletCount)
		or (pelletCount :: number) < 1
		or (pelletCount :: number) > MAXIMUM_SHOTGUN_PELLETS
	then
		return nil
	end
	return 2 ^ (pelletCount :: number) - 1
end

local function isValidPelletMask(mask: unknown, pelletCount: unknown): boolean
	local fullMask = fullPelletMask(pelletCount)
	return fullMask ~= nil and validRawMask(mask) and (mask :: number) <= fullMask
end

local function setPelletMask(mask: unknown, pelletIndex: unknown, present: unknown): number?
	if not validRawMask(mask) or not validPelletIndex(pelletIndex) or type(present) ~= "boolean" then
		return nil
	end

	local bit = 2 ^ ((pelletIndex :: number) - 1)
	local hasBit = math.floor((mask :: number) / bit) % 2 == 1
	if present == hasBit then
		return mask :: number
	end
	return if present then (mask :: number) + bit else (mask :: number) - bit
end

local function testPelletMask(mask: unknown, pelletIndex: unknown): boolean
	if not validRawMask(mask) or not validPelletIndex(pelletIndex) then
		return false
	end
	local bit = 2 ^ ((pelletIndex :: number) - 1)
	return math.floor((mask :: number) / bit) % 2 == 1
end

local function popcountPelletMask(mask: unknown): number?
	if not validRawMask(mask) then
		return nil
	end

	local remaining = mask :: number
	local count = 0
	while remaining > 0 do
		count += remaining % 2
		remaining = math.floor(remaining / 2)
	end
	return count
end

-- A mask bit is meaningful only when the corresponding endpoint remains at the
-- same dense, one-based position in pelletPositions on every recipient.
local function stablePelletCount(pelletPositions: unknown): number?
	if type(pelletPositions) ~= "table" then
		return nil
	end

	local count = 0
	local maximumIndex = 0
	for key, endpoint in pelletPositions :: any do
		if not validPelletIndex(key) or not isFiniteVector3(endpoint) then
			return nil
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key :: number)
	end
	if count < 1 or count > MAXIMUM_SHOTGUN_PELLETS or maximumIndex ~= count then
		return nil
	end
	return count
end

local function resolveWeaponPresentation(weaponId: unknown, surfaceNoImpact: unknown): ScalarPresentation?
	if not isLiveWeaponId(weaponId) or type(surfaceNoImpact) ~= "boolean" then
		return nil
	end
	if surfaceNoImpact then
		return NO_IMPACT_BY_WEAPON_ID[weaponId :: number]
	end
	return NORMAL_BY_WEAPON_ID[weaponId :: number]
end

local function samePresentation(
	presentation: ScalarPresentation,
	tracePresentation: boolean,
	terminalImpactPresentation: boolean
): boolean
	return presentation.tracePresentation == tracePresentation
		and presentation.terminalImpactPresentation == terminalImpactPresentation
end

local function isLegalWeaponPresentation(
	weaponId: unknown,
	tracePresentation: unknown,
	terminalImpactPresentation: unknown
): boolean
	if
		not isLiveWeaponId(weaponId)
		or type(tracePresentation) ~= "boolean"
		or type(terminalImpactPresentation) ~= "boolean"
	then
		return false
	end

	local normal = NORMAL_BY_WEAPON_ID[weaponId :: number]
	if normal and samePresentation(normal, tracePresentation, terminalImpactPresentation) then
		return true
	end
	local noImpact = NO_IMPACT_BY_WEAPON_ID[weaponId :: number]
	return noImpact ~= nil and samePresentation(noImpact, tracePresentation, terminalImpactPresentation)
end

local function sanitizeEventPresentation(event: unknown): EventPresentation?
	if type(event) ~= "table" then
		return nil
	end

	local raw = event :: any
	local weaponId = raw.weaponId
	local tracePresentation = raw.tracePresentation
	local terminalImpactPresentation = raw.terminalImpactPresentation
	if
		not isLiveWeaponId(weaponId)
		or raw.kind ~= EXPECTED_KIND_BY_WEAPON_ID[weaponId :: number]
		or type(tracePresentation) ~= "boolean"
		or type(terminalImpactPresentation) ~= "boolean"
	then
		return nil
	end

	if weaponId == WeaponId.Shotgun then
		local pelletCount = stablePelletCount(raw.pelletPositions)
		local pelletTraceMask = raw.pelletTraceMask
		local pelletImpactMask = raw.pelletImpactMask
		if
			pelletCount == nil
			or pelletCount ~= SOURCE_SHOTGUN_PELLETS
			or not isValidPelletMask(pelletTraceMask, pelletCount)
			or not isValidPelletMask(pelletImpactMask, pelletCount)
		then
			return nil
		end

		-- Ordinary and NOIMPACT shotgun pellets each have an exact source row:
		-- trace+impact or neither. Checking every stable position rejects an
		-- impact without its trace as well as a trace leaked through NOIMPACT.
		for pelletIndex = 1, pelletCount do
			if
				not isLegalWeaponPresentation(
					weaponId,
					testPelletMask(pelletTraceMask, pelletIndex),
					testPelletMask(pelletImpactMask, pelletIndex)
				)
			then
				return nil
			end
		end

		if
			tracePresentation ~= ((pelletTraceMask :: number) ~= 0)
			or terminalImpactPresentation ~= ((pelletImpactMask :: number) ~= 0)
		then
			return nil
		end

		return table.freeze({
			tracePresentation = tracePresentation,
			terminalImpactPresentation = terminalImpactPresentation,
			pelletTraceMask = pelletTraceMask :: number,
			pelletImpactMask = pelletImpactMask :: number,
			pelletCount = pelletCount,
		})
	end

	if
		raw.pelletPositions ~= nil
		or raw.pelletTraceMask ~= nil
		or raw.pelletImpactMask ~= nil
		or not isLegalWeaponPresentation(weaponId, tracePresentation, terminalImpactPresentation)
	then
		return nil
	end

	return table.freeze({
		tracePresentation = tracePresentation,
		terminalImpactPresentation = terminalImpactPresentation,
	})
end

local PelletMask = table.freeze({
	Full = fullPelletMask,
	IsValid = isValidPelletMask,
	Set = setPelletMask,
	Test = testPelletMask,
	Popcount = popcountPelletMask,
})

return table.freeze({
	MaximumShotgunPellets = MAXIMUM_SHOTGUN_PELLETS,
	SourceShotgunPellets = SOURCE_SHOTGUN_PELLETS,
	MaximumShotgunMask = MAXIMUM_SHOTGUN_MASK,
	PelletMask = PelletMask,
	StablePelletCount = stablePelletCount,
	ResolveWeaponPresentation = resolveWeaponPresentation,
	IsLegalWeaponPresentation = isLegalWeaponPresentation,
	SanitizeEventPresentation = sanitizeEventPresentation,
})
