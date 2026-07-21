--[[
SPDX-License-Identifier: GPL-2.0-or-later

Data-only Roblox/Luau adaptation of client weapon-selection behavior from:
  code/cgame/cg_weapons.c (CG_WeaponSelectable, CG_OutOfAmmoChange)
  code/cgame/cg_event.c (CG_ItemPickup)
  code/cgame/cg_main.c (cg_autoswitch default)
  code/game/bg_pmove.c (PM_Weapon command ordering)

The bounded table interface and live-role filtering are the Roblox Luau port
adaptations. The server still validates every requested weapon.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

local WeaponDefinitions = require(script.Parent.WeaponDefinitions)
local WeaponTimingRules = require(script.Parent.WeaponTimingRules)
local CommandSequence = require(script.Parent.Parent.simulation.CommandSequence)

local function isUsable(
	weaponId: number,
	ownedWeapons: { [number]: boolean },
	ammoByWeapon: { [number]: number }
): boolean
	if ownedWeapons[weaponId] ~= true or WeaponDefinitions.LiveAllowed[weaponId] ~= true then
		return false
	end
	local definition = WeaponDefinitions.ById[weaponId]
	if not definition then
		return false
	end
	local ammo = ammoByWeapon[weaponId] or 0
	return definition.AmmoPerShot <= 0 or ammo < 0 or ammo >= definition.AmmoPerShot
end

local function findBestUsable(ownedWeapons: { [number]: boolean }, ammoByWeapon: { [number]: number }): number?
	-- CG_OutOfAmmoChange scans weapon numbers from highest to lowest. Roblox
	-- Arena's live roles preserve the same numeric order.
	for index = #WeaponDefinitions.CoreWeaponIds, 1, -1 do
		local weaponId = WeaponDefinitions.CoreWeaponIds[index]
		if isUsable(weaponId, ownedWeapons, ammoByWeapon) then
			return weaponId
		end
	end
	return nil
end

local function shouldAutoSwitchPickup(weaponId: number, enabled: boolean): boolean
	return enabled
		and WeaponDefinitions.LiveAllowed[weaponId] == true
		and weaponId ~= WeaponDefinitions.WeaponId.Machinegun
end

local function resolveCommand(
	respawned: boolean,
	activeWeaponId: number,
	commandWeaponId: number,
	weaponState: string,
	requestedWeaponId: number,
	requestAllowed: boolean,
	attack: boolean
)
	return WeaponTimingRules.ResolveCommandIntent(
		respawned,
		activeWeaponId,
		commandWeaponId,
		weaponState,
		requestedWeaponId,
		requestAllowed,
		attack
	)
end

local function resolveCommandPhase(
	activeWeaponId: number,
	commandWeaponId: number,
	weaponState: string,
	weaponTimeMilliseconds: number,
	msec: number,
	acceptedWeaponId: number?
): (number, number, string, number, boolean, boolean, boolean, boolean)
	return WeaponTimingRules.ResolveCommandPhase(
		activeWeaponId,
		commandWeaponId,
		weaponState,
		weaponTimeMilliseconds,
		msec,
		acceptedWeaponId
	)
end

local function combatAcknowledgesPending(pendingSequence: number?, ackSequence: number): boolean
	return pendingSequence ~= nil
		and CommandSequence.IsInRange(ackSequence)
		and CommandSequence.IsAtOrBefore(pendingSequence, ackSequence)
end

local function transportAcknowledgesCancellation(
	pendingSequence: number?,
	ackSequence: number,
	selectedWeaponId: number,
	authoritativeWeaponId: number,
	echoedWeaponId: number
): boolean
	-- A movement acknowledgement proves only transport, not ownership. It may
	-- clear A→B→A when the latest selected/echoed value is already authoritative;
	-- a genuinely new B must wait for CombatSnapshot semantic acknowledgement.
	return pendingSequence ~= nil
		and CommandSequence.IsInRange(ackSequence)
		and CommandSequence.IsAtOrBefore(pendingSequence, ackSequence)
		and selectedWeaponId == authoritativeWeaponId
		and echoedWeaponId == selectedWeaponId
end

local function reconcilePredictedSwitchTiming(
	predictedReadyAt: number,
	authoritativeReadyAt: number,
	visualSwitchScheduled: boolean,
	predictedDropStartsAt: number,
	predictedDropEndsAt: number,
	predictedRaiseEndsAt: number
): (number, number, number, number)
	if not visualSwitchScheduled then
		return math.max(predictedReadyAt, authoritativeReadyAt),
			predictedDropStartsAt,
			predictedDropEndsAt,
			predictedRaiseEndsAt
	end
	-- Once a switch is scheduled, predictedReadyAt already represents the final
	-- B raise completion. Compare A's authoritative firing-ready time with the
	-- predicted drop start, or an on-time snapshot would delay the whole switch
	-- by another complete drop+raise cycle.
	if authoritativeReadyAt <= predictedDropStartsAt then
		return predictedReadyAt, predictedDropStartsAt, predictedDropEndsAt, predictedRaiseEndsAt
	end
	local dropEndsAt = authoritativeReadyAt + WeaponDefinitions.WeaponDropSeconds
	local raiseEndsAt = authoritativeReadyAt + WeaponDefinitions.WeaponSwitchSeconds
	return math.max(predictedReadyAt, raiseEndsAt), authoritativeReadyAt, dropEndsAt, raiseEndsAt
end

return table.freeze({
	IsUsable = isUsable,
	FindBestUsable = findBestUsable,
	ShouldAutoSwitchPickup = shouldAutoSwitchPickup,
	ResolveCommand = resolveCommand,
	ShouldRunPmoveStep = WeaponTimingRules.ShouldRunPmoveStep,
	ResolveCommandPhase = resolveCommandPhase,
	ResolveAttackTiming = WeaponTimingRules.ResolveAttackTiming,
	CombatAcknowledgesPending = combatAcknowledgesPending,
	TransportAcknowledgesCancellation = transportAcknowledgesCancellation,
	ReconcilePredictedSwitchTiming = reconcilePredictedSwitchTiming,
})
