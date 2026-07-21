--[[
SPDX-License-Identifier: GPL-2.0-or-later

Translated from Quake III Arena weapon behavior in:
  code/game/bg_public.h
  code/game/bg_pmove.c (PM_Weapon cadence and weapon-change timing)
  code/game/g_weapon.c (weapon_grenadelauncher_fire and weapon definitions)
  code/game/g_missile.c (projectile trajectories, bounce,
  MISSILE_PRESTEP_TIME)
  code/game/g_combat.c (G_Damage knockback timer)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Constants = require(script.Parent.Parent.simulation.Constants)
local CommandSequence = require(script.Parent.Parent.simulation.CommandSequence)
local WeaponTimingRules = require(script.Parent.WeaponTimingRules)

local ARMOR_PROTECTION = 0.66
local MAXIMUM_COMMAND_SEQUENCE = CommandSequence.Maximum
local Q3_RANDOM_RANGE = 65_536
local PROJECTILE_PRESTEP_MILLISECONDS = 50
local PROJECTILE_PRESTEP_SECONDS = PROJECTILE_PRESTEP_MILLISECONDS / 1000

local function q3Distance(value: number): number
	return value * Constants.UnitsToStuds
end

local function isValidSequence(value: unknown, previous: number): boolean
	return CommandSequence.IsInRange(value) and (previous == -1 or CommandSequence.IsNewer(value, previous))
end

local function resolveDamage(rawDamage: number, armor: number, isSelfDamage: boolean): (number, number, number)
	local adjustedDamage = math.max(math.floor(rawDamage), 0)
	if adjustedDamage == 0 then
		return 0, 0, 0
	end

	if isSelfDamage then
		adjustedDamage = math.floor(adjustedDamage * 0.5)
	end
	adjustedDamage = math.max(adjustedDamage, 1)

	local armorSave = math.min(math.ceil(adjustedDamage * ARMOR_PROTECTION), math.max(armor, 0))
	return adjustedDamage, armorSave, adjustedDamage - armorSave
end

local function splashDamage(baseDamage: number, distance: number, radius: number): number
	if baseDamage <= 0 or distance < 0 or radius <= 0 or distance >= radius then
		return 0
	end
	return math.max(math.floor(baseDamage * (1 - distance / radius)), 0)
end

local function distanceToAxisAlignedBox(point: Vector3, center: Vector3, size: Vector3): number
	local halfSize = size * 0.5
	local offset = point - center
	local outside = Vector3.new(
		math.max(math.abs(offset.X) - halfSize.X, 0),
		math.max(math.abs(offset.Y) - halfSize.Y, 0),
		math.max(math.abs(offset.Z) - halfSize.Z, 0)
	)
	return outside.Magnitude
end

local function makeShotId(userId: number, lifeSequence: number, shotSequence: number): string
	return string.format("shot:%d:%d:%d", userId, lifeSequence, shotSequence)
end

local function makeEventId(shotId: string, eventSequence: number): string
	return string.format("%s:event:%d", shotId, eventSequence)
end

local function makeShotSeed(userId: number, lifeSequence: number, shotSequence: number): number
	local seed = bit32.bxor(
		bit32.band(userId, 0xFFFFFFFF),
		bit32.lrotate(bit32.band(lifeSequence, 0xFFFFFFFF), 11),
		bit32.lrotate(bit32.band(shotSequence, 0xFFFFFFFF), 22)
	)
	return if seed == 0 then 0x6D2B79F5 else seed
end

local function nextRandom(seed: number): (number, number)
	local nextSeed = bit32.band(seed * 69_069 + 1, 0xFFFFFFFF)
	return nextSeed, bit32.band(nextSeed, 0xFFFF) / Q3_RANDOM_RANGE
end

local function spreadDirection(forward: Vector3, spread: number, range: number, seed: number): (Vector3, number)
	local right = forward:Cross(Vector3.yAxis)
	if right.Magnitude <= 1e-6 then
		right = forward:Cross(Vector3.xAxis)
	end
	right = right.Unit
	local up = right:Cross(forward).Unit

	local horizontalRandom: number
	local verticalRandom: number
	seed, horizontalRandom = nextRandom(seed)
	seed, verticalRandom = nextRandom(seed)
	local horizontalOffset = q3Distance((horizontalRandom * 2 - 1) * spread * 16)
	local verticalOffset = q3Distance((verticalRandom * 2 - 1) * spread * 16)
	local endpoint = forward * range + right * horizontalOffset + up * verticalOffset
	return endpoint.Unit, seed
end

local function bulletSpreadDirection(forward: Vector3, spread: number, range: number, seed: number): (Vector3, number)
	local right = forward:Cross(Vector3.yAxis)
	if right.Magnitude <= 1e-6 then
		right = forward:Cross(Vector3.xAxis)
	end
	right = right.Unit
	local up = right:Cross(forward).Unit

	local angleRandom: number
	local horizontalRandom: number
	local verticalRandom: number
	seed, angleRandom = nextRandom(seed)
	seed, horizontalRandom = nextRandom(seed)
	seed, verticalRandom = nextRandom(seed)
	local angle = (angleRandom * 2 - 1) * math.pi * 2
	local horizontalOffset = q3Distance(math.cos(angle) * (horizontalRandom * 2 - 1) * spread * 16)
	local verticalOffset = q3Distance(math.sin(angle) * (verticalRandom * 2 - 1) * spread * 16)
	local endpoint = forward * range + right * horizontalOffset + up * verticalOffset
	return endpoint.Unit, seed
end

local function integrateProjectile(velocity: Vector3, gravity: number, deltaTime: number): (Vector3, Vector3)
	local acceleration = -Vector3.yAxis * math.max(gravity, 0)
	local endVelocity = velocity + acceleration * deltaTime
	return (velocity + endVelocity) * 0.5 * deltaTime, endVelocity
end

local function bounceVelocity(
	velocity: Vector3,
	normal: Vector3,
	bounceFactor: number,
	stopSpeed: number
): (Vector3, boolean)
	local reflected = velocity - normal * 2 * velocity:Dot(normal)
	local bounced = reflected * math.max(bounceFactor, 0)
	local stopped = normal.Y > 0.2 and bounced.Magnitude < math.max(stopSpeed, 0)
	return if stopped then Vector3.zero else bounced, stopped
end

local function knockbackDurationSeconds(rawDamage: number): number
	if rawDamage <= 0 then
		return 0
	end
	-- G_Damage sets pm_time to clamp(knockback * 2, 50, 200) milliseconds.
	return math.clamp(math.min(rawDamage, 200) * 0.002, 0.05, 0.2)
end

local function missileImpactDirection(trajectoryDelta: Vector3): Vector3
	-- G_MissileImpact supplies an upward direction when a stopped missile has no
	-- trajectory delta (the canonical case is stepping onto a settled grenade).
	return if trajectoryDelta.Magnitude == 0 then Vector3.yAxis else trajectoryDelta
end

local WeaponId = table.freeze({
	None = 0,
	Gauntlet = 1,
	Machinegun = 2,
	Shotgun = 3,
	GrenadeLauncher = 4,
	RocketLauncher = 5,
	LightningGun = 6,
	Railgun = 7,
	PlasmaGun = 8,
	Bfg = 9,
})

local RefireMillisecondsByWeaponId = table.freeze({
	[WeaponId.Gauntlet] = 400,
	[WeaponId.Machinegun] = 100,
	[WeaponId.Shotgun] = 1000,
	[WeaponId.GrenadeLauncher] = 800,
	[WeaponId.RocketLauncher] = 800,
	[WeaponId.LightningGun] = 50,
	[WeaponId.Railgun] = 1500,
	[WeaponId.PlasmaGun] = 100,
	[WeaponId.Bfg] = 200,
})

local ById = table.freeze({
	[WeaponId.Gauntlet] = table.freeze({
		Id = WeaponId.Gauntlet,
		Name = "Gauntlet",
		Kind = "Melee",
		Damage = 50,
		DirectMeans = "Gauntlet",
		RefireMilliseconds = RefireMillisecondsByWeaponId[WeaponId.Gauntlet],
		RefireSeconds = RefireMillisecondsByWeaponId[WeaponId.Gauntlet] / 1000,
		Range = q3Distance(32),
		AmmoPerShot = 0,
		SpawnAmmo = 0,
		WeaponPickupAmmo = 0,
		AmmoPickupAmmo = 0,
		MaximumAmmo = 0,
	}),
	[WeaponId.Machinegun] = table.freeze({
		Id = WeaponId.Machinegun,
		Name = "Machinegun",
		Kind = "Hitscan",
		Damage = 7,
		TeamDamage = 5,
		DirectMeans = "Machinegun",
		RefireMilliseconds = RefireMillisecondsByWeaponId[WeaponId.Machinegun],
		RefireSeconds = RefireMillisecondsByWeaponId[WeaponId.Machinegun] / 1000,
		Spread = 200,
		Range = q3Distance(8192 * 16),
		AmmoPerShot = 1,
		SpawnAmmo = 100,
		WeaponPickupAmmo = 40,
		AmmoPickupAmmo = 50,
		MaximumAmmo = 200,
	}),
	[WeaponId.Shotgun] = table.freeze({
		Id = WeaponId.Shotgun,
		Name = "Shotgun",
		Kind = "PelletHitscan",
		Pellets = 11,
		Damage = 10,
		DirectMeans = "Shotgun",
		RefireMilliseconds = RefireMillisecondsByWeaponId[WeaponId.Shotgun],
		RefireSeconds = RefireMillisecondsByWeaponId[WeaponId.Shotgun] / 1000,
		Spread = 700,
		Range = q3Distance(8192 * 16),
		AmmoPerShot = 1,
		SpawnAmmo = 10,
		WeaponPickupAmmo = 10,
		AmmoPickupAmmo = 10,
		MaximumAmmo = 200,
	}),
	[WeaponId.GrenadeLauncher] = table.freeze({
		Id = WeaponId.GrenadeLauncher,
		Name = "Grenade Launcher",
		Kind = "GravityProjectile",
		Damage = 100,
		DirectMeans = "Grenade",
		SplashDamage = 100,
		SplashMeans = "GrenadeSplash",
		SplashRadius = q3Distance(150),
		ProjectileSpeed = q3Distance(700),
		ProjectileGravity = Constants.Gravity,
		BounceFactor = 0.65,
		BounceStopSpeed = q3Distance(40),
		FuseMilliseconds = 2500,
		RefireMilliseconds = RefireMillisecondsByWeaponId[WeaponId.GrenadeLauncher],
		RefireSeconds = RefireMillisecondsByWeaponId[WeaponId.GrenadeLauncher] / 1000,
		AmmoPerShot = 1,
		SpawnAmmo = 10,
		WeaponPickupAmmo = 10,
		AmmoPickupAmmo = 5,
		MaximumAmmo = 200,
	}),
	[WeaponId.RocketLauncher] = table.freeze({
		Id = WeaponId.RocketLauncher,
		Name = "Rocket Launcher",
		Kind = "LinearProjectile",
		Damage = 100,
		DirectMeans = "Rocket",
		SplashDamage = 100,
		SplashMeans = "RocketSplash",
		SplashRadius = q3Distance(120),
		ProjectileSpeed = q3Distance(900),
		FuseMilliseconds = 15000,
		RefireMilliseconds = RefireMillisecondsByWeaponId[WeaponId.RocketLauncher],
		RefireSeconds = RefireMillisecondsByWeaponId[WeaponId.RocketLauncher] / 1000,
		AmmoPerShot = 1,
		SpawnAmmo = 10,
		WeaponPickupAmmo = 10,
		AmmoPickupAmmo = 5,
		MaximumAmmo = 200,
	}),
	[WeaponId.LightningGun] = table.freeze({
		Id = WeaponId.LightningGun,
		Name = "Lightning Gun",
		Kind = "ContinuousHitscan",
		Damage = 8,
		DirectMeans = "Lightning",
		Range = q3Distance(768),
		RefireMilliseconds = RefireMillisecondsByWeaponId[WeaponId.LightningGun],
		RefireSeconds = RefireMillisecondsByWeaponId[WeaponId.LightningGun] / 1000,
		AmmoPerShot = 1,
		SpawnAmmo = 100,
		WeaponPickupAmmo = 100,
		AmmoPickupAmmo = 60,
		MaximumAmmo = 200,
	}),
	[WeaponId.Railgun] = table.freeze({
		Id = WeaponId.Railgun,
		Name = "Railgun",
		Kind = "PenetratingHitscan",
		Damage = 100,
		DirectMeans = "Railgun",
		Range = q3Distance(8192),
		MaximumPenetrations = 4,
		RefireMilliseconds = RefireMillisecondsByWeaponId[WeaponId.Railgun],
		RefireSeconds = RefireMillisecondsByWeaponId[WeaponId.Railgun] / 1000,
		AmmoPerShot = 1,
		SpawnAmmo = 10,
		WeaponPickupAmmo = 10,
		AmmoPickupAmmo = 10,
		MaximumAmmo = 200,
	}),
	[WeaponId.PlasmaGun] = table.freeze({
		Id = WeaponId.PlasmaGun,
		Name = "Plasma Gun",
		Kind = "LinearProjectile",
		Damage = 20,
		DirectMeans = "Plasma",
		SplashDamage = 15,
		SplashMeans = "PlasmaSplash",
		SplashRadius = q3Distance(20),
		ProjectileSpeed = q3Distance(2000),
		FuseMilliseconds = 10000,
		RefireMilliseconds = RefireMillisecondsByWeaponId[WeaponId.PlasmaGun],
		RefireSeconds = RefireMillisecondsByWeaponId[WeaponId.PlasmaGun] / 1000,
		AmmoPerShot = 1,
		SpawnAmmo = 50,
		WeaponPickupAmmo = 50,
		AmmoPickupAmmo = 30,
		MaximumAmmo = 200,
	}),
	[WeaponId.Bfg] = table.freeze({
		Id = WeaponId.Bfg,
		Name = "BFG",
		Kind = "LinearProjectile",
		Damage = 100,
		DirectMeans = "BFG",
		SplashDamage = 100,
		SplashMeans = "BFGSplash",
		SplashRadius = q3Distance(120),
		ProjectileSpeed = q3Distance(2000),
		FuseMilliseconds = 10000,
		RefireMilliseconds = RefireMillisecondsByWeaponId[WeaponId.Bfg],
		RefireSeconds = RefireMillisecondsByWeaponId[WeaponId.Bfg] / 1000,
		AmmoPerShot = 1,
		SpawnAmmo = 20,
		WeaponPickupAmmo = 20,
		AmmoPickupAmmo = 15,
		MaximumAmmo = 200,
	}),
})

local LiveAllowed = table.freeze({
	[WeaponId.Gauntlet] = true,
	[WeaponId.Machinegun] = true,
	[WeaponId.Shotgun] = true,
	[WeaponId.GrenadeLauncher] = true,
	[WeaponId.RocketLauncher] = true,
	[WeaponId.LightningGun] = true,
	[WeaponId.Railgun] = true,
	[WeaponId.PlasmaGun] = true,
	[WeaponId.Bfg] = true,
})

return table.freeze({
	SourceCommit = Constants.SourceCommit,
	WeaponId = WeaponId,
	RefireMillisecondsByWeaponId = RefireMillisecondsByWeaponId,
	ById = ById,
	LiveAllowed = LiveAllowed,
	CoreWeaponIds = table.freeze({
		WeaponId.Gauntlet,
		WeaponId.Machinegun,
		WeaponId.Shotgun,
		WeaponId.GrenadeLauncher,
		WeaponId.RocketLauncher,
		WeaponId.LightningGun,
		WeaponId.Railgun,
		WeaponId.PlasmaGun,
		WeaponId.Bfg,
	}),
	FoundationAllowed = table.freeze({
		[WeaponId.RocketLauncher] = true,
		[WeaponId.Railgun] = true,
	}),
	InitialWeaponId = WeaponId.Railgun,
	InitialHealth = 100,
	InitialArmor = 0,
	ArmorProtection = ARMOR_PROTECTION,
	MaximumCommandSequence = MAXIMUM_COMMAND_SEQUENCE,
	MaximumFireCommandsPerSecond = 90,
	FireReleaseSeconds = 0.1,
	NoAmmoMilliseconds = WeaponTimingRules.NoAmmoMilliseconds,
	NoAmmoSeconds = WeaponTimingRules.NoAmmoMilliseconds / 1000,
	WeaponDropMilliseconds = WeaponTimingRules.WeaponDropMilliseconds,
	WeaponDropSeconds = WeaponTimingRules.WeaponDropMilliseconds / 1000,
	WeaponRaiseMilliseconds = WeaponTimingRules.WeaponRaiseMilliseconds,
	WeaponRaiseSeconds = WeaponTimingRules.WeaponRaiseMilliseconds / 1000,
	WeaponSwitchMilliseconds = WeaponTimingRules.WeaponDropMilliseconds + WeaponTimingRules.WeaponRaiseMilliseconds,
	WeaponSwitchSeconds = (WeaponTimingRules.WeaponDropMilliseconds + WeaponTimingRules.WeaponRaiseMilliseconds) / 1000,
	Knockback = 1000,
	PlayerMass = 200,
	ProjectilePrestepMilliseconds = PROJECTILE_PRESTEP_MILLISECONDS,
	ProjectilePrestepSeconds = PROJECTILE_PRESTEP_SECONDS,
	MuzzleForwardOffset = q3Distance(14),
	RadiusDirectionLift = q3Distance(24),
	IsValidSequence = isValidSequence,
	ResolveDamage = resolveDamage,
	SplashDamage = splashDamage,
	DistanceToAxisAlignedBox = distanceToAxisAlignedBox,
	MakeShotId = makeShotId,
	MakeEventId = makeEventId,
	MakeShotSeed = makeShotSeed,
	NextRandom = nextRandom,
	SpreadDirection = spreadDirection,
	BulletSpreadDirection = bulletSpreadDirection,
	IntegrateProjectile = integrateProjectile,
	BounceVelocity = bounceVelocity,
	KnockbackDurationSeconds = knockbackDurationSeconds,
	MissileImpactDirection = missileImpactDirection,
})
