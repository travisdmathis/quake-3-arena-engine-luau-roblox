--[[
SPDX-License-Identifier: GPL-2.0-or-later

Data-only Roblox translation of the Quake III Arena base-game item catalog and
pickup limits from:
  code/game/bg_public.h (weapon_t, itemType_t, gitem_t)
  code/game/bg_misc.c (bg_itemlist, BG_PlayerTouchesItem, BG_CanItemBeGrabbed)
  code/game/g_items.c (RESPAWN_*, Add_Ammo, Pickup_Weapon, Pickup_Ammo,
    Pickup_Health, Pickup_Armor)
  code/game/g_main.c (g_weaponrespawn=5, g_weaponTeamRespawn=30)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.

Retail model, icon, and sound paths from bg_itemlist are intentionally omitted.
Primitive presentation metadata below is original the Roblox Luau port work and uses
only native Roblox shapes, colors, and materials.
]]

--!strict

local Constants = require(script.Parent.Parent.simulation.Constants)
local WeaponDefinitions = require(script.Parent.Parent.combat.WeaponDefinitions)
local PowerupRules = require(script.Parent.PowerupRules)

export type ItemKind = "Weapon" | "Ammo" | "Health" | "Armor" | "Holdable" | "Powerup"
export type PrimitiveShape = "Ball" | "Block" | "Cylinder"
export type PrimitiveMaterial = "Neon" | "SmoothPlastic"

export type PrimitivePresentation = {
	shape: PrimitiveShape,
	color: Color3,
	size: Vector3,
	material: PrimitiveMaterial,
}

export type ItemDefinition = {
	id: string,
	displayName: string,
	kind: ItemKind,
	quantity: number,
	respawnSeconds: number,
	teamRespawnSeconds: number?,
	weaponId: number?,
	holdableId: number?,
	powerupId: number?,
	ammoCap: number?,
	capMultiplier: number?,
	allowsOverstack: boolean?,
	worldPickupEligible: boolean?,
	presentation: PrimitivePresentation,
}

export type EligibilityState = {
	health: number,
	maxHealth: number,
	armor: number,
	ammoByWeapon: { [number]: number },
	holdableId: number,
}

local WeaponId = WeaponDefinitions.WeaponId
local AMMO_CAP = 200
local STANDARD_HEALTH_CAP_MULTIPLIER = 1
local OVERSTACK_CAP_MULTIPLIER = 2
local ARMOR_CAP_MULTIPLIER = 2
local GREEN_ARMOR_CAP_MULTIPLIER = 1
local HOLDABLE_TELEPORTER_ID = 1
local HOLDABLE_MEDKIT_ID = 2

local RESPAWN_SECONDS = table.freeze({
	Weapon = 5,
	TeamWeapon = 30,
	Armor = 25,
	Health = 35,
	MegaHealth = 35,
	Ammo = 40,
	Holdable = 60,
	Powerup = 120,
})

local function primitive(
	shape: PrimitiveShape,
	color: Color3,
	size: Vector3,
	material: PrimitiveMaterial
): PrimitivePresentation
	return table.freeze({
		shape = shape,
		color = color,
		size = size,
		material = material,
	})
end

local function define(definition: ItemDefinition): ItemDefinition
	return table.freeze(definition)
end

local weaponPresentation = primitive("Cylinder", Color3.fromRGB(255, 155, 64), Vector3.new(1.1, 1.8, 1.1), "Neon")
local ammoPresentation = primitive("Block", Color3.fromRGB(98, 189, 255), Vector3.new(1.15, 0.8, 1.15), "SmoothPlastic")

local orderedDefinitions: { ItemDefinition } = {
	define({
		id = "item_quad",
		displayName = "Quad Damage",
		kind = "Powerup",
		quantity = 30,
		respawnSeconds = RESPAWN_SECONDS.Powerup,
		powerupId = PowerupRules.PowerupId.Quad,
		presentation = primitive("Ball", Color3.fromRGB(80, 100, 255), Vector3.new(1.5, 1.5, 1.5), "Neon"),
	}),
	define({
		id = "item_enviro",
		displayName = "Battle Suit",
		kind = "Powerup",
		quantity = 30,
		respawnSeconds = RESPAWN_SECONDS.Powerup,
		powerupId = PowerupRules.PowerupId.BattleSuit,
		presentation = primitive("Ball", Color3.fromRGB(255, 196, 70), Vector3.new(1.5, 1.5, 1.5), "Neon"),
	}),
	define({
		id = "item_haste",
		displayName = "Speed",
		kind = "Powerup",
		quantity = 30,
		respawnSeconds = RESPAWN_SECONDS.Powerup,
		powerupId = PowerupRules.PowerupId.Haste,
		presentation = primitive("Ball", Color3.fromRGB(255, 210, 90), Vector3.new(1.5, 1.5, 1.5), "Neon"),
	}),
	define({
		id = "item_invis",
		displayName = "Invisibility",
		kind = "Powerup",
		quantity = 30,
		respawnSeconds = RESPAWN_SECONDS.Powerup,
		powerupId = PowerupRules.PowerupId.Invisibility,
		presentation = primitive("Ball", Color3.fromRGB(210, 210, 225), Vector3.new(1.5, 1.5, 1.5), "Neon"),
	}),
	define({
		id = "item_regen",
		displayName = "Regeneration",
		kind = "Powerup",
		quantity = 30,
		respawnSeconds = RESPAWN_SECONDS.Powerup,
		powerupId = PowerupRules.PowerupId.Regeneration,
		presentation = primitive("Ball", Color3.fromRGB(255, 90, 120), Vector3.new(1.5, 1.5, 1.5), "Neon"),
	}),
	define({
		id = "item_flight",
		displayName = "Flight",
		kind = "Powerup",
		quantity = 60,
		respawnSeconds = RESPAWN_SECONDS.Powerup,
		powerupId = PowerupRules.PowerupId.Flight,
		presentation = primitive("Ball", Color3.fromRGB(180, 120, 255), Vector3.new(1.5, 1.5, 1.5), "Neon"),
	}),
	define({
		id = "holdable_teleporter",
		displayName = "Personal Teleporter",
		kind = "Holdable",
		quantity = 1,
		respawnSeconds = RESPAWN_SECONDS.Holdable,
		holdableId = HOLDABLE_TELEPORTER_ID,
		presentation = primitive("Ball", Color3.fromRGB(95, 188, 255), Vector3.new(1.2, 1.2, 1.2), "Neon"),
	}),
	define({
		id = "holdable_medkit",
		displayName = "Medkit",
		kind = "Holdable",
		quantity = 1,
		respawnSeconds = RESPAWN_SECONDS.Holdable,
		holdableId = HOLDABLE_MEDKIT_ID,
		presentation = primitive("Ball", Color3.fromRGB(108, 255, 154), Vector3.new(1.2, 1.2, 1.2), "Neon"),
	}),
	define({
		id = "item_armor_shard",
		displayName = "Armor Shard",
		kind = "Armor",
		quantity = 5,
		respawnSeconds = RESPAWN_SECONDS.Armor,
		capMultiplier = ARMOR_CAP_MULTIPLIER,
		presentation = primitive("Ball", Color3.fromRGB(128, 225, 255), Vector3.new(1, 1, 1), "Neon"),
	}),
	define({
		-- Original CPMA-compatible extension used by the approved Aerowalk layout
		-- recreation. It is intentionally separate from the base-Q3-derived yellow
		-- and red definitions: 50 armor, 100 cap at the standard 100 max health,
		-- and the existing audited 25-second armor respawn.
		id = "item_armor_jacket",
		displayName = "Green Armor",
		kind = "Armor",
		quantity = 50,
		respawnSeconds = RESPAWN_SECONDS.Armor,
		capMultiplier = GREEN_ARMOR_CAP_MULTIPLIER,
		presentation = primitive("Block", Color3.fromRGB(70, 210, 116), Vector3.new(2, 2, 2), "Neon"),
	}),
	define({
		id = "item_armor_combat",
		displayName = "Yellow Armor",
		kind = "Armor",
		quantity = 50,
		respawnSeconds = RESPAWN_SECONDS.Armor,
		capMultiplier = ARMOR_CAP_MULTIPLIER,
		presentation = primitive("Block", Color3.fromRGB(255, 210, 66), Vector3.new(2.3, 2.3, 2.3), "Neon"),
	}),
	define({
		id = "item_armor_body",
		displayName = "Red Armor",
		kind = "Armor",
		quantity = 100,
		respawnSeconds = RESPAWN_SECONDS.Armor,
		capMultiplier = ARMOR_CAP_MULTIPLIER,
		presentation = primitive("Block", Color3.fromRGB(255, 78, 78), Vector3.new(2.65, 2.65, 2.65), "Neon"),
	}),
	define({
		id = "item_health_small",
		displayName = "5 Health",
		kind = "Health",
		quantity = 5,
		respawnSeconds = RESPAWN_SECONDS.Health,
		capMultiplier = OVERSTACK_CAP_MULTIPLIER,
		allowsOverstack = true,
		presentation = primitive("Ball", Color3.fromRGB(98, 255, 174), Vector3.new(0.7, 0.7, 0.7), "Neon"),
	}),
	define({
		id = "item_health",
		displayName = "25 Health",
		kind = "Health",
		quantity = 25,
		respawnSeconds = RESPAWN_SECONDS.Health,
		capMultiplier = STANDARD_HEALTH_CAP_MULTIPLIER,
		presentation = primitive("Ball", Color3.fromRGB(255, 214, 82), Vector3.new(1.05, 1.05, 1.05), "Neon"),
	}),
	define({
		id = "item_health_large",
		displayName = "50 Health",
		kind = "Health",
		quantity = 50,
		respawnSeconds = RESPAWN_SECONDS.Health,
		capMultiplier = STANDARD_HEALTH_CAP_MULTIPLIER,
		presentation = primitive("Ball", Color3.fromRGB(255, 102, 102), Vector3.new(1.35, 1.35, 1.35), "Neon"),
	}),
	define({
		id = "item_health_mega",
		displayName = "Mega Health",
		kind = "Health",
		quantity = 100,
		respawnSeconds = RESPAWN_SECONDS.MegaHealth,
		capMultiplier = OVERSTACK_CAP_MULTIPLIER,
		allowsOverstack = true,
		presentation = primitive("Ball", Color3.fromRGB(86, 177, 255), Vector3.new(1.75, 1.75, 1.75), "Neon"),
	}),
	define({
		id = "weapon_gauntlet",
		displayName = "Gauntlet",
		kind = "Weapon",
		quantity = 0,
		respawnSeconds = RESPAWN_SECONDS.Weapon,
		teamRespawnSeconds = RESPAWN_SECONDS.TeamWeapon,
		weaponId = WeaponId.Gauntlet,
		ammoCap = AMMO_CAP,
		-- The catalog entry remains for inventory and presentation compatibility,
		-- but every player owns the ammo-independent Gauntlet from spawn. It is
		-- never valid as an authored or dropped world pickup.
		worldPickupEligible = false,
		presentation = weaponPresentation,
	}),
	define({
		id = "weapon_machinegun",
		displayName = "Machinegun",
		kind = "Weapon",
		quantity = 40,
		respawnSeconds = RESPAWN_SECONDS.Weapon,
		teamRespawnSeconds = RESPAWN_SECONDS.TeamWeapon,
		weaponId = WeaponId.Machinegun,
		ammoCap = AMMO_CAP,
		presentation = weaponPresentation,
	}),
	define({
		id = "weapon_shotgun",
		displayName = "Shotgun",
		kind = "Weapon",
		quantity = 10,
		respawnSeconds = RESPAWN_SECONDS.Weapon,
		teamRespawnSeconds = RESPAWN_SECONDS.TeamWeapon,
		weaponId = WeaponId.Shotgun,
		ammoCap = AMMO_CAP,
		presentation = weaponPresentation,
	}),
	define({
		id = "weapon_grenadelauncher",
		displayName = "Grenade Launcher",
		kind = "Weapon",
		quantity = 10,
		respawnSeconds = RESPAWN_SECONDS.Weapon,
		teamRespawnSeconds = RESPAWN_SECONDS.TeamWeapon,
		weaponId = WeaponId.GrenadeLauncher,
		ammoCap = AMMO_CAP,
		presentation = weaponPresentation,
	}),
	define({
		id = "weapon_rocketlauncher",
		displayName = "Rocket Launcher",
		kind = "Weapon",
		quantity = 10,
		respawnSeconds = RESPAWN_SECONDS.Weapon,
		teamRespawnSeconds = RESPAWN_SECONDS.TeamWeapon,
		weaponId = WeaponId.RocketLauncher,
		ammoCap = AMMO_CAP,
		presentation = weaponPresentation,
	}),
	define({
		id = "weapon_lightning",
		displayName = "Lightning Gun",
		kind = "Weapon",
		quantity = 100,
		respawnSeconds = RESPAWN_SECONDS.Weapon,
		teamRespawnSeconds = RESPAWN_SECONDS.TeamWeapon,
		weaponId = WeaponId.LightningGun,
		ammoCap = AMMO_CAP,
		presentation = weaponPresentation,
	}),
	define({
		id = "weapon_railgun",
		displayName = "Railgun",
		kind = "Weapon",
		quantity = 10,
		respawnSeconds = RESPAWN_SECONDS.Weapon,
		teamRespawnSeconds = RESPAWN_SECONDS.TeamWeapon,
		weaponId = WeaponId.Railgun,
		ammoCap = AMMO_CAP,
		presentation = weaponPresentation,
	}),
	define({
		id = "weapon_plasmagun",
		displayName = "Plasma Gun",
		kind = "Weapon",
		quantity = 50,
		respawnSeconds = RESPAWN_SECONDS.Weapon,
		teamRespawnSeconds = RESPAWN_SECONDS.TeamWeapon,
		weaponId = WeaponId.PlasmaGun,
		ammoCap = AMMO_CAP,
		presentation = weaponPresentation,
	}),
	define({
		id = "weapon_bfg",
		displayName = "BFG",
		kind = "Weapon",
		quantity = 20,
		respawnSeconds = RESPAWN_SECONDS.Weapon,
		teamRespawnSeconds = RESPAWN_SECONDS.TeamWeapon,
		weaponId = WeaponId.Bfg,
		ammoCap = AMMO_CAP,
		presentation = weaponPresentation,
	}),
	define({
		id = "ammo_bullets",
		displayName = "Bullets",
		kind = "Ammo",
		quantity = 50,
		respawnSeconds = RESPAWN_SECONDS.Ammo,
		weaponId = WeaponId.Machinegun,
		ammoCap = AMMO_CAP,
		presentation = ammoPresentation,
	}),
	define({
		id = "ammo_shells",
		displayName = "Shells",
		kind = "Ammo",
		quantity = 10,
		respawnSeconds = RESPAWN_SECONDS.Ammo,
		weaponId = WeaponId.Shotgun,
		ammoCap = AMMO_CAP,
		presentation = ammoPresentation,
	}),
	define({
		id = "ammo_grenades",
		displayName = "Grenades",
		kind = "Ammo",
		quantity = 5,
		respawnSeconds = RESPAWN_SECONDS.Ammo,
		weaponId = WeaponId.GrenadeLauncher,
		ammoCap = AMMO_CAP,
		presentation = ammoPresentation,
	}),
	define({
		id = "ammo_rockets",
		displayName = "Rockets",
		kind = "Ammo",
		quantity = 5,
		respawnSeconds = RESPAWN_SECONDS.Ammo,
		weaponId = WeaponId.RocketLauncher,
		ammoCap = AMMO_CAP,
		presentation = ammoPresentation,
	}),
	define({
		id = "ammo_lightning",
		displayName = "Lightning",
		kind = "Ammo",
		quantity = 60,
		respawnSeconds = RESPAWN_SECONDS.Ammo,
		weaponId = WeaponId.LightningGun,
		ammoCap = AMMO_CAP,
		presentation = ammoPresentation,
	}),
	define({
		id = "ammo_slugs",
		displayName = "Slugs",
		kind = "Ammo",
		quantity = 10,
		respawnSeconds = RESPAWN_SECONDS.Ammo,
		weaponId = WeaponId.Railgun,
		ammoCap = AMMO_CAP,
		presentation = ammoPresentation,
	}),
	define({
		id = "ammo_cells",
		displayName = "Cells",
		kind = "Ammo",
		quantity = 30,
		respawnSeconds = RESPAWN_SECONDS.Ammo,
		weaponId = WeaponId.PlasmaGun,
		ammoCap = AMMO_CAP,
		presentation = ammoPresentation,
	}),
	define({
		id = "ammo_bfg",
		displayName = "BFG Ammo",
		kind = "Ammo",
		quantity = 15,
		respawnSeconds = RESPAWN_SECONDS.Ammo,
		weaponId = WeaponId.Bfg,
		ammoCap = AMMO_CAP,
		presentation = ammoPresentation,
	}),
}

local byId: { [string]: ItemDefinition } = {}
local orderedIds: { string } = {}
local weaponItemByWeaponId: { [number]: ItemDefinition } = {}
local ammoItemByWeaponId: { [number]: ItemDefinition } = {}
for _, definition in orderedDefinitions do
	assert(byId[definition.id] == nil, string.format("duplicate item id %s", definition.id))
	byId[definition.id] = definition
	table.insert(orderedIds, definition.id)
	if definition.weaponId then
		if definition.kind == "Weapon" then
			weaponItemByWeaponId[definition.weaponId] = definition
		elseif definition.kind == "Ammo" then
			ammoItemByWeaponId[definition.weaponId] = definition
		end
	end
end

local function getEligibility(definition: ItemDefinition, state: EligibilityState): (boolean, number, number)
	local maxHealth = math.max(math.floor(state.maxHealth), 1)
	if definition.kind == "Weapon" then
		local weaponId = assert(definition.weaponId, "weapon item is missing weaponId")
		return true, definition.ammoCap or AMMO_CAP, state.ammoByWeapon[weaponId] or 0
	elseif definition.kind == "Ammo" then
		local weaponId = assert(definition.weaponId, "ammo item is missing weaponId")
		local cap = definition.ammoCap or AMMO_CAP
		local current = state.ammoByWeapon[weaponId] or 0
		-- Negative ammo denotes an infinite-ammo ruleset. Base Q3 only assigns it
		-- to weapons without world ammo, so treating it as ineligible prevents a
		-- mutator from accidentally converting infinity back to finite ammo.
		return current >= 0 and current < cap, cap, current
	elseif definition.kind == "Armor" then
		local cap = math.floor(maxHealth * (definition.capMultiplier or ARMOR_CAP_MULTIPLIER))
		return state.armor < cap, cap, state.armor
	elseif definition.kind == "Health" then
		local cap = math.floor(maxHealth * (definition.capMultiplier or STANDARD_HEALTH_CAP_MULTIPLIER))
		return state.health < cap, cap, state.health
	elseif definition.kind == "Powerup" then
		return true, definition.quantity, 0
	end
	return state.holdableId == 0, 1, if state.holdableId == 0 then 0 else 1
end

local function getGrantAmount(current: number, quantity: number, cap: number): number
	return math.max(math.min(math.floor(quantity), math.floor(cap - current)), 0)
end

local function getWeaponAmmoGrant(currentAmmo: number, pickupQuantity: number, fullPickupQuantity: boolean): number
	if currentAmmo < 0 then
		return 0
	end

	local desired = pickupQuantity
	if not fullPickupQuantity then
		if currentAmmo < pickupQuantity then
			desired = pickupQuantity - currentAmmo
		else
			desired = 1
		end
	end
	return getGrantAmount(currentAmmo, desired, AMMO_CAP)
end

local touchMinimumOffset = Vector3.new(-50, -36, -36) * Constants.UnitsToStuds
local touchMaximumOffset = Vector3.new(44, 36, 36) * Constants.UnitsToStuds

local function playerTouchesItem(playerPosition: Vector3, itemPosition: Vector3): boolean
	local offset = playerPosition - itemPosition
	return offset.X >= touchMinimumOffset.X
		and offset.X <= touchMaximumOffset.X
		and offset.Y >= touchMinimumOffset.Y
		and offset.Y <= touchMaximumOffset.Y
		and offset.Z >= touchMinimumOffset.Z
		and offset.Z <= touchMaximumOffset.Z
end

return table.freeze({
	SourceCommit = Constants.SourceCommit,
	ById = table.freeze(byId),
	OrderedIds = table.freeze(orderedIds),
	WeaponItemByWeaponId = table.freeze(weaponItemByWeaponId),
	AmmoItemByWeaponId = table.freeze(ammoItemByWeaponId),
	Caps = table.freeze({
		Ammo = AMMO_CAP,
		StandardHealthMultiplier = STANDARD_HEALTH_CAP_MULTIPLIER,
		OverstackMultiplier = OVERSTACK_CAP_MULTIPLIER,
		ArmorMultiplier = ARMOR_CAP_MULTIPLIER,
	}),
	RespawnSeconds = RESPAWN_SECONDS,
	HoldableIds = table.freeze({ None = 0, Teleporter = 1, Medkit = HOLDABLE_MEDKIT_ID }),
	TouchMinimumOffset = touchMinimumOffset,
	TouchMaximumOffset = touchMaximumOffset,
	ScanIntervalSeconds = 1 / 20,
	MarkerTag = "ArenaPickup",
	Attributes = table.freeze({
		ItemId = "ArenaItemId",
		PickupId = "ArenaPickupId",
		Quantity = "ArenaPickupQuantity",
		RespawnSeconds = "ArenaPickupRespawnSeconds",
		Enabled = "ArenaPickupEnabled",
		Active = "ArenaPickupActive",
		RespawnAt = "ArenaPickupRespawnAt",
		Revision = "ArenaPickupRevision",
		Kind = "ArenaPickupKind",
	}),
	Network = table.freeze({
		Folder = "Network",
		Snapshot = "ItemSnapshot",
		Event = "ItemEvent",
	}),
	GetEligibility = getEligibility,
	GetGrantAmount = getGrantAmount,
	GetWeaponAmmoGrant = getWeaponAmmoGrant,
	PlayerTouchesItem = playerTouchesItem,
})
