--[[
SPDX-License-Identifier: GPL-2.0-or-later

Direct Luau translation of the shared weapon counter transitions in:
  code/game/bg_pmove.c (PM_Weapon, PM_BeginWeaponChange,
  PM_FinishWeaponChange)
  code/game/g_active.c (synchronous G_RunClient cached-command Pmove and
  pre-Pmove gauntlet weaponTime gate)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local WEAPON_DROP_MILLISECONDS = 200
local WEAPON_RAISE_MILLISECONDS = 250
local NO_AMMO_MILLISECONDS = 500
local MAXIMUM_ABSOLUTE_WEAPON_TIME_MILLISECONDS = 2_147_483_647

local validStates = table.freeze({
	Ready = true,
	Firing = true,
	Dropping = true,
	Raising = true,
})

local function isIntegerInRange(value: number, minimum: number, maximum: number): boolean
	return value == value
		and value > -math.huge
		and value < math.huge
		and value % 1 == 0
		and value >= minimum
		and value <= maximum
end

local function resolveCommandIntent(
	respawned: boolean,
	activeWeaponId: number,
	commandWeaponId: number,
	weaponState: string,
	requestedWeaponId: number,
	requestAllowed: boolean,
	attack: boolean
)
	-- PM_Weapon returns before decrement, selection, or attack while
	-- PMF_RESPAWNED is set. The release command that clears RESP may continue
	-- through this function in the same PmoveSingle.
	if respawned then
		return table.freeze({
			process = false,
			acceptedWeaponId = nil,
			attackRequested = false,
			weaponStateAfterIntent = weaponState,
			canReachFireCheck = false,
		})
	end

	local acceptedWeaponId = if requestAllowed then requestedWeaponId else nil
	local stateAfterIntent = weaponState
	if
		acceptedWeaponId
		and acceptedWeaponId ~= commandWeaponId
		and (weaponState == "Ready" or (weaponState == "Raising" and activeWeaponId ~= acceptedWeaponId))
	then
		stateAfterIntent = "Dropping"
	end
	return table.freeze({
		process = true,
		acceptedWeaponId = acceptedWeaponId,
		attackRequested = attack,
		weaponStateAfterIntent = stateAfterIntent,
		canReachFireCheck = attack and stateAfterIntent == "Ready",
	})
end

local function shouldRunPmoveStep(lastLevelTimeMilliseconds: number, currentLevelTimeMilliseconds: number): boolean
	assert(
		isIntegerInRange(lastLevelTimeMilliseconds, -1, MAXIMUM_ABSOLUTE_WEAPON_TIME_MILLISECONDS),
		"PM_Weapon previous level time must be a bounded integer"
	)
	assert(
		isIntegerInRange(currentLevelTimeMilliseconds, 0, MAXIMUM_ABSOLUTE_WEAPON_TIME_MILLISECONDS),
		"PM_Weapon current level time must be a bounded integer"
	)
	if lastLevelTimeMilliseconds == currentLevelTimeMilliseconds then
		return false
	end
	assert(lastLevelTimeMilliseconds < currentLevelTimeMilliseconds, "PM_Weapon level time regressed")
	return true
end

local function resolveCommandPhase(
	activeWeaponId: number,
	commandWeaponId: number,
	weaponState: string,
	weaponTimeMilliseconds: number,
	msec: number,
	acceptedWeaponId: number?
): (number, number, string, number, boolean, boolean, boolean, boolean)
	assert(
		isIntegerInRange(
			weaponTimeMilliseconds,
			-MAXIMUM_ABSOLUTE_WEAPON_TIME_MILLISECONDS,
			MAXIMUM_ABSOLUTE_WEAPON_TIME_MILLISECONDS
		),
		"PM_Weapon requires a bounded signed integer weaponTime"
	)
	assert(
		isIntegerInRange(msec, 1, MAXIMUM_ABSOLUTE_WEAPON_TIME_MILLISECONDS),
		"PM_Weapon requires a positive bounded integer msec"
	)
	assert(validStates[weaponState] == true, "PM_Weapon received an invalid weapon state")

	-- pers.cmd.weapon is installed before PM_Weapon evaluates an expired
	-- dropping boundary. Invalid/unowned commands are rejected by the caller,
	-- matching PM_BeginWeaponChange's ownership gate.
	local nextActiveWeaponId = activeWeaponId
	local nextCommandWeaponId = commandWeaponId
	local nextWeaponState = weaponState
	local nextWeaponTimeMilliseconds = weaponTimeMilliseconds
	local commandChanged = false
	local stateChanged = false
	if acceptedWeaponId ~= nil and acceptedWeaponId ~= commandWeaponId then
		nextCommandWeaponId = acceptedWeaponId
		commandChanged = true
	end

	-- Q3 deliberately preserves negative frame overshoot. The same signed
	-- counter is then reused by firing, dropping, raising, and no-ammo.
	if nextWeaponTimeMilliseconds > 0 then
		nextWeaponTimeMilliseconds -= msec
	end

	if
		nextActiveWeaponId ~= nextCommandWeaponId
		and (nextWeaponTimeMilliseconds <= 0 or nextWeaponState ~= "Firing")
		and nextWeaponState ~= "Dropping"
	then
		nextWeaponState = "Dropping"
		nextWeaponTimeMilliseconds += WEAPON_DROP_MILLISECONDS
		stateChanged = true
	end

	if nextWeaponTimeMilliseconds > 0 then
		return nextActiveWeaponId,
			nextCommandWeaponId,
			nextWeaponState,
			nextWeaponTimeMilliseconds,
			stateChanged,
			false,
			commandChanged,
			false
	end

	if nextWeaponState == "Dropping" then
		nextActiveWeaponId = nextCommandWeaponId
		nextWeaponState = "Raising"
		nextWeaponTimeMilliseconds += WEAPON_RAISE_MILLISECONDS
		return nextActiveWeaponId,
			nextCommandWeaponId,
			nextWeaponState,
			nextWeaponTimeMilliseconds,
			true,
			true,
			commandChanged,
			false
	end

	if nextWeaponState == "Raising" then
		nextWeaponState = "Ready"
		return nextActiveWeaponId,
			nextCommandWeaponId,
			nextWeaponState,
			nextWeaponTimeMilliseconds,
			true,
			true,
			commandChanged,
			false
	end

	-- An expired Firing timer remains Firing until this same command's attack or
	-- release branch runs. This prevents a transient Ready state between held
	-- shots and is observably different from a deadline-based state observer.
	return nextActiveWeaponId,
		nextCommandWeaponId,
		nextWeaponState,
		nextWeaponTimeMilliseconds,
		stateChanged,
		false,
		commandChanged,
		true
end

local function resolveAttackTiming(
	weaponState: string,
	weaponTimeMilliseconds: number,
	attack: boolean,
	isGauntlet: boolean,
	gauntletHit: boolean,
	hasAmmo: boolean,
	refireMilliseconds: number
): (string, number, string)
	assert(weaponState == "Ready" or weaponState == "Firing", "PM_Weapon attack branch retained a transition state")
	assert(
		isIntegerInRange(weaponTimeMilliseconds, -MAXIMUM_ABSOLUTE_WEAPON_TIME_MILLISECONDS, 0),
		"PM_Weapon attack branch requires an expired signed weaponTime"
	)

	if not attack then
		return "Ready", 0, "Release"
	end
	if isGauntlet and not gauntletHit then
		return "Ready", 0, "GauntletMiss"
	end
	if not hasAmmo then
		return "Firing", weaponTimeMilliseconds + NO_AMMO_MILLISECONDS, "NoAmmo"
	end
	assert(
		isIntegerInRange(refireMilliseconds, 1, MAXIMUM_ABSOLUTE_WEAPON_TIME_MILLISECONDS),
		"PM_Weapon fire branch requires a positive integer refire duration"
	)
	return "Firing", weaponTimeMilliseconds + refireMilliseconds, "Fire"
end

return table.freeze({
	WeaponDropMilliseconds = WEAPON_DROP_MILLISECONDS,
	WeaponRaiseMilliseconds = WEAPON_RAISE_MILLISECONDS,
	NoAmmoMilliseconds = NO_AMMO_MILLISECONDS,
	MaximumAbsoluteWeaponTimeMilliseconds = MAXIMUM_ABSOLUTE_WEAPON_TIME_MILLISECONDS,
	ShouldRunPmoveStep = shouldRunPmoveStep,
	ResolveCommandIntent = resolveCommandIntent,
	ResolveCommandPhase = resolveCommandPhase,
	ResolveAttackTiming = resolveAttackTiming,
})
