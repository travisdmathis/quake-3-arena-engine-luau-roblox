--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox/Luau adaptation of death-dropped weapon behavior from:
  code/game/g_combat.c (TossClientItems)
  code/game/g_items.c (Pickup_Weapon, LaunchItem, Drop_Item, G_RunItem,
  G_BounceItem)

Stable IDs, per-drop deterministic launch variance, a hard live-drop cap, and
the service-free rule boundary are original the Roblox Luau port adaptations. The
pinned source leaves LaunchItem.physicsBounce at zero despite EF_BOUNCE_HALF;
this implementation preserves that literal first-impact settle behavior.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

local Constants = require(script.Parent.Parent.simulation.Constants)
local WeaponDefinitions = require(script.Parent.Parent.combat.WeaponDefinitions)
local ItemDefs = require(script.Parent.ItemDefs)

export type Candidate = {
	weaponId: number,
	itemId: string,
	quantity: number,
}

local WeaponId = WeaponDefinitions.WeaponId
local eligibleWeaponIds = table.freeze({
	[WeaponId.Shotgun] = true,
	[WeaponId.GrenadeLauncher] = true,
	[WeaponId.RocketLauncher] = true,
	[WeaponId.LightningGun] = true,
	[WeaponId.Railgun] = true,
	[WeaponId.PlasmaGun] = true,
	[WeaponId.Bfg] = true,
})

local HORIZONTAL_SPEED = 150 * Constants.UnitsToStuds
local VERTICAL_BASE_SPEED = 200 * Constants.UnitsToStuds
local VERTICAL_VARIANCE = 50 * Constants.UnitsToStuds
local ITEM_HULL_SIZE = Vector3.one * 30 * Constants.UnitsToStuds
local EXPIRE_SECONDS = 30
local BOUNCE_SCALE = 0
local STOP_VERTICAL_SPEED = 40 * Constants.UnitsToStuds
local SURFACE_NUDGE = 1 * Constants.UnitsToStuds
local MAXIMUM_LIVE_DROPS = 128
local MAXIMUM_WORLD_COORDINATE = 100_000
local VECTOR_TOLERANCE = 1e-4

local function isFinite(value: number): boolean
	return value == value and math.abs(value) < math.huge
end

local function isFiniteVector(value: Vector3): boolean
	return isFinite(value.X) and isFinite(value.Y) and isFinite(value.Z)
end

local function isValidPosition(position: Vector3): boolean
	return isFiniteVector(position)
		and math.max(math.abs(position.X), math.abs(position.Y), math.abs(position.Z)) <= MAXIMUM_WORLD_COORDINATE
end

local function isValidLaunchVelocity(velocity: Vector3): boolean
	if not isFiniteVector(velocity) then
		return false
	end
	local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	return math.abs(horizontalSpeed - HORIZONTAL_SPEED) <= VECTOR_TOLERANCE
		and velocity.Y >= VERTICAL_BASE_SPEED - VERTICAL_VARIANCE - VECTOR_TOLERANCE
		and velocity.Y <= VERTICAL_BASE_SPEED + VERTICAL_VARIANCE + VECTOR_TOLERANCE
end

local function snapSourceUnit(value: number): number
	local sourceUnits = value / Constants.UnitsToStuds
	local snapped = if sourceUnits >= 0 then math.floor(sourceUnits) else math.ceil(sourceUnits)
	return snapped * Constants.UnitsToStuds
end

local function nextRandom(seed: number): (number, number)
	local nextSeed = (seed * 1_664_525 + 1_013_904_223) % 4_294_967_296
	return nextSeed, nextSeed / 4_294_967_296
end

local function makeSeed(matchId: string, userId: number, lifeSequence: number): number
	local hash = 2_166_136_261
	local source = string.format("%s:%d:%d", matchId, userId, lifeSequence)
	for index = 1, #source do
		hash = bit32.bxor(hash, string.byte(source, index))
		hash = (hash * 16_777_619) % 4_294_967_296
	end
	return hash
end

local function resolveCandidate(
	weaponId: number,
	owned: boolean,
	ammo: number,
	infiniteAmmo: boolean,
	enabled: boolean
): Candidate?
	if not enabled or infiniteAmmo or not owned or ammo <= 0 or eligibleWeaponIds[weaponId] ~= true then
		return nil
	end
	local definition = ItemDefs.WeaponItemByWeaponId[weaponId]
	if not definition then
		return nil
	end
	return {
		weaponId = weaponId,
		itemId = definition.id,
		quantity = definition.quantity,
	}
end

local function makeDropId(matchId: string, userId: number, lifeSequence: number): string
	return string.format("drop:%s:%d:%d", matchId, userId, lifeSequence)
end

local function launchVelocity(look: Vector3, seed: number): (Vector3, number)
	local horizontal = Vector3.new(look.X, 0, look.Z)
	if horizontal.Magnitude <= 1e-6 then
		horizontal = Vector3.new(0, 0, -1)
	else
		horizontal = horizontal.Unit
	end
	local nextSeed, randomValue = nextRandom(seed)
	local verticalSpeed = VERTICAL_BASE_SPEED + (randomValue * 2 - 1) * VERTICAL_VARIANCE
	return horizontal * HORIZONTAL_SPEED + Vector3.yAxis * verticalSpeed, nextSeed
end

local function integrate(position: Vector3, velocity: Vector3, deltaTime: number): (Vector3, Vector3)
	local nextVelocity = velocity - Vector3.yAxis * Constants.Gravity * deltaTime
	local averageVelocity = (velocity + nextVelocity) * 0.5
	return position + averageVelocity * deltaTime, nextVelocity
end

local function bounce(velocity: Vector3, normal: Vector3): (Vector3, boolean)
	local reflected = (velocity - normal * (2 * velocity:Dot(normal))) * BOUNCE_SCALE
	local settled = normal.Y > 0 and reflected.Y < STOP_VERTICAL_SPEED
	return if settled then Vector3.zero else reflected, settled
end

return table.freeze({
	EligibleWeaponIds = eligibleWeaponIds,
	HorizontalSpeed = HORIZONTAL_SPEED,
	VerticalBaseSpeed = VERTICAL_BASE_SPEED,
	VerticalVariance = VERTICAL_VARIANCE,
	ItemHullSize = ITEM_HULL_SIZE,
	ExpireSeconds = EXPIRE_SECONDS,
	BounceScale = BOUNCE_SCALE,
	StopVerticalSpeed = STOP_VERTICAL_SPEED,
	SurfaceNudge = SURFACE_NUDGE,
	MaximumLiveDrops = MAXIMUM_LIVE_DROPS,
	MaximumWorldCoordinate = MAXIMUM_WORLD_COORDINATE,
	ResolveCandidate = resolveCandidate,
	MakeDropId = makeDropId,
	MakeSeed = makeSeed,
	LaunchVelocity = launchVelocity,
	Integrate = integrate,
	Bounce = bounce,
	IsValidPosition = isValidPosition,
	IsValidLaunchVelocity = isValidLaunchVelocity,
	SnapSourceUnit = snapSourceUnit,
})
