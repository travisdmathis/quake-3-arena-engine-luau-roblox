--[[
SPDX-License-Identifier: GPL-2.0-or-later

Luau extraction of inventory and ps.weapon command-phase ownership mapped to:
  code/game/g_client.c (ClientSpawn inventory/loadout initialization)
  code/game/bg_pmove.c (PM_BeginWeaponChange, PM_FinishWeaponChange, PM_Weapon)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-13.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local HoldableRules = require(sharedRoot.items.HoldableRules)
local WeaponDefinitions = require(sharedRoot.combat.WeaponDefinitions)
local WeaponSelection = require(sharedRoot.combat.WeaponSelection)

export type WeaponState = "Ready" | "Firing" | "Dropping" | "Raising"

export type Record = {
	alive: boolean,
	weaponId: number,
	commandWeaponId: number,
	weaponState: WeaponState,
	weaponTimeMilliseconds: number,
	ownedWeapons: { [number]: boolean },
	ammoByWeapon: { [number]: number },
	infiniteAmmo: boolean,
	holdableId: number,
	holdableUseHeld: boolean,
	powerupExpiries: { [number]: number },
	lastWeaponIntentId: number,
}

export type Rules = {
	OneShot: boolean,
	RoundBased: boolean,
	InfiniteAmmo: boolean,
	AllowedWeaponIds: { [number]: boolean },
	SpawnAmmoByWeaponId: { [number]: number },
	ModeKind: string,
}

export type Snapshot = {
	selectedWeaponId: number,
	infiniteAmmo: boolean,
	holdableId: number,
	holdableUseHeld: boolean,
	ownedWeaponIds: { number },
	ammoByWeapon: { [number]: number },
}

export type AmmoEntry = {
	weaponId: number,
	ammo: number,
}

local CombatInventoryRuntime = {}

local function ownedWeaponIds(record: Record): { number }
	local weaponIds: { number } = {}
	for weaponId, owned in record.ownedWeapons do
		if owned then
			table.insert(weaponIds, weaponId)
		end
	end
	table.sort(weaponIds)
	return weaponIds
end

function CombatInventoryRuntime.GetSelectedAmmo(record: Record): number
	local selectedWeaponId = record.commandWeaponId
	local definition = WeaponDefinitions.ById[selectedWeaponId]
	if not definition or definition.AmmoPerShot <= 0 then
		return 0
	end
	if record.infiniteAmmo then
		return -1
	end
	return record.ammoByWeapon[selectedWeaponId] or 0
end

function CombatInventoryRuntime.BuildSnapshot(record: Record): Snapshot
	local ammoByWeapon = table.clone(record.ammoByWeapon)
	if record.infiniteAmmo then
		for weaponId, owned in record.ownedWeapons do
			local definition = WeaponDefinitions.ById[weaponId]
			if owned and definition and definition.AmmoPerShot > 0 then
				ammoByWeapon[weaponId] = -1
			end
		end
	end
	return {
		selectedWeaponId = record.commandWeaponId,
		infiniteAmmo = record.infiniteAmmo,
		holdableId = record.holdableId,
		holdableUseHeld = record.holdableUseHeld,
		ownedWeaponIds = ownedWeaponIds(record),
		ammoByWeapon = ammoByWeapon,
	}
end

function CombatInventoryRuntime.SerializeAmmo(
	ammoByWeapon: { [number]: number }
): ({ [string]: number }, { AmmoEntry })
	local byWeaponId: { [string]: number } = {}
	local entries: { AmmoEntry } = {}
	for weaponId, ammo in ammoByWeapon do
		byWeaponId[tostring(weaponId)] = ammo
		table.insert(
			entries,
			table.freeze({
				weaponId = weaponId,
				ammo = ammo,
			})
		)
	end
	table.sort(entries, function(left, right)
		return left.weaponId < right.weaponId
	end)
	return table.freeze(byWeaponId), table.freeze(entries)
end

function CombatInventoryRuntime.Reset(
	record: Record,
	rules: Rules,
	spawnWeaponId: number,
	infiniteAmmoOverride: boolean?
)
	record.ownedWeapons = {}
	record.ammoByWeapon = {}
	record.holdableId = HoldableRules.HoldableId.None
	record.holdableUseHeld = false
	record.powerupExpiries = {}
	record.infiniteAmmo = if infiniteAmmoOverride ~= nil
		then infiniteAmmoOverride
		else rules.InfiniteAmmo

	local gauntletId = WeaponDefinitions.WeaponId.Gauntlet
	record.ownedWeapons[gauntletId] = true
	record.ammoByWeapon[gauntletId] = 0

	local function grantSpawnWeapon(weaponId: number)
		local definition = WeaponDefinitions.ById[weaponId]
		if definition and WeaponDefinitions.LiveAllowed[weaponId] then
			record.ownedWeapons[weaponId] = true
			record.ammoByWeapon[weaponId] = rules.SpawnAmmoByWeaponId[weaponId]
				or definition.SpawnAmmo
		end
	end

	if rules.RoundBased then
		for _, weaponId in WeaponDefinitions.CoreWeaponIds do
			if rules.AllowedWeaponIds[weaponId] then
				grantSpawnWeapon(weaponId)
			end
		end
	else
		grantSpawnWeapon(spawnWeaponId)
	end

	if
		rules.ModeKind == "TeamDeathmatch"
		and spawnWeaponId == WeaponDefinitions.WeaponId.Machinegun
		and not record.infiniteAmmo
	then
		record.ammoByWeapon[spawnWeaponId] = 50
	end
	record.weaponId = if record.ownedWeapons[spawnWeaponId] then spawnWeaponId else gauntletId
	record.commandWeaponId = record.weaponId
	record.lastWeaponIntentId = record.weaponId
	record.weaponState = "Ready"
	record.weaponTimeMilliseconds = 0
end

function CombatInventoryRuntime.AdvanceWeaponCommandPhase(
	record: Record,
	msec: number,
	acceptedWeaponId: number?
): (boolean, boolean, boolean, boolean)
	if not record.alive then
		return false, false, false, false
	end

	local activeWeaponId, commandWeaponId, weaponState, weaponTimeMilliseconds, changed, phaseConsumed, commandChanged, attackBranchReachable =
		WeaponSelection.ResolveCommandPhase(
			record.weaponId,
			record.commandWeaponId,
			record.weaponState,
			record.weaponTimeMilliseconds,
			msec,
			acceptedWeaponId
		)
	record.weaponId = activeWeaponId
	record.commandWeaponId = commandWeaponId
	record.weaponState = weaponState :: WeaponState
	record.weaponTimeMilliseconds = weaponTimeMilliseconds
	return changed, phaseConsumed, commandChanged, attackBranchReachable
end

return table.freeze(CombatInventoryRuntime)
