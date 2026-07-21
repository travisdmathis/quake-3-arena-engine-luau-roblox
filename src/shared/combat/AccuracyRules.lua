--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure accuracy-accounting rules translated from Quake III Arena:
  code/game/g_weapon.c (FireWeapon, LogAccuracyHit, Bullet_Fire,
  ShotgunPellet, ShotgunPattern, Weapon_LightningFire, weapon_railgun_fire)
  code/game/g_missile.c (G_MissileImpact and G_ExplodeMissile)
  code/game/g_combat.c (G_RadiusDamage)

Q3 deliberately evaluates different weapon families on different sides of
G_Damage. Machinegun, rail, and projectile direct/radius contacts call
LogAccuracyHit before damage. Shotgun pellets and lightning call it after
damage. A shotgun blast, rail trace, or projectile explosion contributes at
most one authoritative accuracy hit even when several contacts qualify; rail
retains its qualifying penetration count separately for the Impressive award.

The exact-shape bounded data boundary and immutable result records are Roblox
Arena authority adaptations. Callers provide trusted snapshots from their
server-owned damage transaction; this module owns no services, Instances,
clocks, remotes, storage, or mutable state.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

export type WeaponFamily = "Gauntlet" | "Machinegun" | "Shotgun" | "Lightning" | "Rail" | "Projectile"
export type EvaluationPhase = "Untracked" | "PreDamage" | "PostDamage"
export type TargetKind = "LiveClient" | "ClientCorpse" | "NonClient"
export type CreditChannel = "None" | "Direct" | "Radius"

export type Contact = {
	read targetKind: TargetKind,
	read targetTakesDamage: boolean,
	read attackerIsClient: boolean,
	read sameEntity: boolean,
	read sameTeam: boolean,
	read healthBefore: number,
	read healthAfter: number,
}

export type ShotInput = {
	read family: WeaponFamily,
	read directContacts: { Contact },
	read radiusContacts: { Contact },
}

export type ContactDecision = {
	read phase: "PreDamage" | "PostDamage",
	read evaluatedHealth: number,
	read qualifies: boolean,
}

export type ShotResult = {
	read family: WeaponFamily,
	read evaluationPhase: EvaluationPhase,
	read tracked: boolean,
	read accuracyShotsDelta: number,
	read accuracyHitsDelta: number,
	read qualifyingDirectCount: number,
	read qualifyingRadiusCount: number,
	read creditedChannel: CreditChannel,
	read impressiveQualifyingPenetrationCount: number,
}

local WeaponFamilies = table.freeze({
	Gauntlet = "Gauntlet" :: WeaponFamily,
	Machinegun = "Machinegun" :: WeaponFamily,
	Shotgun = "Shotgun" :: WeaponFamily,
	Lightning = "Lightning" :: WeaponFamily,
	Rail = "Rail" :: WeaponFamily,
	Projectile = "Projectile" :: WeaponFamily,
})

local EvaluationPhases = table.freeze({
	Untracked = "Untracked" :: EvaluationPhase,
	PreDamage = "PreDamage" :: EvaluationPhase,
	PostDamage = "PostDamage" :: EvaluationPhase,
})

local TargetKinds = table.freeze({
	LiveClient = "LiveClient" :: TargetKind,
	ClientCorpse = "ClientCorpse" :: TargetKind,
	NonClient = "NonClient" :: TargetKind,
})

local CreditChannels = table.freeze({
	None = "None" :: CreditChannel,
	Direct = "Direct" :: CreditChannel,
	Radius = "Radius" :: CreditChannel,
})

local MAXIMUM_HEALTH_MAGNITUDE = 1_000_000
local MAXIMUM_SHOTGUN_PELLETS = 11
local MAXIMUM_RAIL_PENETRATIONS = 4
local MAXIMUM_RADIUS_CONTACTS = 1_024

type FamilyRule = {
	phase: EvaluationPhase,
	maximumDirectContacts: number,
	maximumRadiusContacts: number,
}

local FamilyRules: { [WeaponFamily]: FamilyRule } = {
	[WeaponFamilies.Gauntlet] = table.freeze({
		phase = EvaluationPhases.Untracked,
		maximumDirectContacts = 1,
		maximumRadiusContacts = 0,
	}),
	[WeaponFamilies.Machinegun] = table.freeze({
		phase = EvaluationPhases.PreDamage,
		maximumDirectContacts = 1,
		maximumRadiusContacts = 0,
	}),
	[WeaponFamilies.Shotgun] = table.freeze({
		phase = EvaluationPhases.PostDamage,
		maximumDirectContacts = MAXIMUM_SHOTGUN_PELLETS,
		maximumRadiusContacts = 0,
	}),
	[WeaponFamilies.Lightning] = table.freeze({
		phase = EvaluationPhases.PostDamage,
		maximumDirectContacts = 1,
		maximumRadiusContacts = 0,
	}),
	[WeaponFamilies.Rail] = table.freeze({
		phase = EvaluationPhases.PreDamage,
		maximumDirectContacts = MAXIMUM_RAIL_PENETRATIONS,
		maximumRadiusContacts = 0,
	}),
	[WeaponFamilies.Projectile] = table.freeze({
		phase = EvaluationPhases.PreDamage,
		maximumDirectContacts = 1,
		maximumRadiusContacts = MAXIMUM_RADIUS_CONTACTS,
	}),
}
table.freeze(FamilyRules)

local ContactKeys = table.freeze({
	targetKind = true,
	targetTakesDamage = true,
	attackerIsClient = true,
	sameEntity = true,
	sameTeam = true,
	healthBefore = true,
	healthAfter = true,
})

local ShotInputKeys = table.freeze({
	family = true,
	directContacts = true,
	radiusContacts = true,
})

local function isFiniteIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value % 1 == 0
		and value >= minimum
		and value <= maximum
end

local function hasExactKeys(value: { [unknown]: unknown }, keys: { [string]: boolean }, expectedCount: number): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or keys[key] ~= true then
			return false
		end
		count += 1
	end
	if count ~= expectedCount then
		return false
	end
	for key in keys do
		if value[key] == nil then
			return false
		end
	end
	return true
end

local function isWeaponFamily(value: unknown): boolean
	return value == WeaponFamilies.Gauntlet
		or value == WeaponFamilies.Machinegun
		or value == WeaponFamilies.Shotgun
		or value == WeaponFamilies.Lightning
		or value == WeaponFamilies.Rail
		or value == WeaponFamilies.Projectile
end

local function isTargetKind(value: unknown): boolean
	return value == TargetKinds.LiveClient or value == TargetKinds.ClientCorpse or value == TargetKinds.NonClient
end

local function validateContact(value: unknown): (Contact?, string?)
	if type(value) ~= "table" then
		return nil, "contact-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, ContactKeys, 7) then
		return nil, "invalid-contact-shape"
	end

	local targetKind = raw.targetKind
	local targetTakesDamage = raw.targetTakesDamage
	local attackerIsClient = raw.attackerIsClient
	local sameEntity = raw.sameEntity
	local sameTeam = raw.sameTeam
	local healthBefore = raw.healthBefore
	local healthAfter = raw.healthAfter
	if not isTargetKind(targetKind) then
		return nil, "invalid-target-kind"
	end
	if
		type(targetTakesDamage) ~= "boolean"
		or type(attackerIsClient) ~= "boolean"
		or type(sameEntity) ~= "boolean"
		or type(sameTeam) ~= "boolean"
	then
		return nil, "invalid-contact-boolean"
	end
	if
		not isFiniteIntegerInRange(healthBefore, -MAXIMUM_HEALTH_MAGNITUDE, MAXIMUM_HEALTH_MAGNITUDE)
		or not isFiniteIntegerInRange(healthAfter, -MAXIMUM_HEALTH_MAGNITUDE, MAXIMUM_HEALTH_MAGNITUDE)
	then
		return nil, "invalid-contact-health"
	end
	if (healthAfter :: number) > (healthBefore :: number) then
		return nil, "contact-health-increased"
	end

	local contact: Contact = {
		targetKind = targetKind :: TargetKind,
		targetTakesDamage = targetTakesDamage :: boolean,
		attackerIsClient = attackerIsClient :: boolean,
		sameEntity = sameEntity :: boolean,
		sameTeam = sameTeam :: boolean,
		healthBefore = healthBefore :: number,
		healthAfter = healthAfter :: number,
	}
	table.freeze(contact)
	return contact, nil
end

local function validateContactSequence(value: unknown, maximumCount: number, channel: string): ({ Contact }?, string?)
	if type(value) ~= "table" then
		return nil, channel .. "-contacts-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	local count = 0
	for key in raw do
		if type(key) ~= "number" or key ~= key or math.abs(key) == math.huge or key % 1 ~= 0 or key < 1 then
			return nil, channel .. "-contacts-not-sequence"
		end
		count += 1
		if count > maximumCount then
			return nil, "too-many-" .. channel .. "-contacts"
		end
	end

	local contacts: { Contact } = {}
	for index = 1, count do
		local entry = raw[index]
		if entry == nil then
			return nil, channel .. "-contacts-not-sequence"
		end
		local contact, contactError = validateContact(entry)
		if not contact then
			return nil, string.format("%s-contact-%d-%s", channel, index, contactError)
		end
		table.insert(contacts, contact)
	end
	table.freeze(contacts)
	return contacts, nil
end

local function evaluateValidatedContact(contact: Contact, phase: "PreDamage" | "PostDamage"): ContactDecision
	local health = if phase == EvaluationPhases.PreDamage then contact.healthBefore else contact.healthAfter
	local decision: ContactDecision = {
		phase = phase,
		evaluatedHealth = health,
		qualifies = contact.targetTakesDamage
			and contact.attackerIsClient
			and contact.targetKind == TargetKinds.LiveClient
			and not contact.sameEntity
			and not contact.sameTeam
			and health > 0,
	}
	table.freeze(decision)
	return decision
end

local function evaluateContact(value: unknown, phase: unknown): (ContactDecision?, string?)
	if phase ~= EvaluationPhases.PreDamage and phase ~= EvaluationPhases.PostDamage then
		return nil, "invalid-evaluation-phase"
	end
	local contact, contactError = validateContact(value)
	if not contact then
		return nil, contactError
	end
	return evaluateValidatedContact(contact, phase :: "PreDamage" | "PostDamage"), nil
end

local function countQualifying(contacts: { Contact }, phase: "PreDamage" | "PostDamage"): number
	local count = 0
	for _, contact in contacts do
		if evaluateValidatedContact(contact, phase).qualifies then
			count += 1
		end
	end
	return count
end

local function resolveShot(value: unknown): (ShotResult?, string?)
	if type(value) ~= "table" then
		return nil, "shot-input-not-table"
	end
	local raw = value :: { [unknown]: unknown }
	if not hasExactKeys(raw, ShotInputKeys, 3) then
		return nil, "invalid-shot-input-shape"
	end
	if not isWeaponFamily(raw.family) then
		return nil, "invalid-weapon-family"
	end
	local family = raw.family :: WeaponFamily
	local rule = FamilyRules[family]
	local directContacts, directError =
		validateContactSequence(raw.directContacts, rule.maximumDirectContacts, "direct")
	if not directContacts then
		return nil, directError
	end
	local radiusContacts, radiusError =
		validateContactSequence(raw.radiusContacts, rule.maximumRadiusContacts, "radius")
	if not radiusContacts then
		return nil, radiusError
	end

	if rule.phase == EvaluationPhases.Untracked then
		local result: ShotResult = {
			family = family,
			evaluationPhase = EvaluationPhases.Untracked,
			tracked = false,
			accuracyShotsDelta = 0,
			accuracyHitsDelta = 0,
			qualifyingDirectCount = 0,
			qualifyingRadiusCount = 0,
			creditedChannel = CreditChannels.None,
			impressiveQualifyingPenetrationCount = 0,
		}
		table.freeze(result)
		return result, nil
	end

	local phase = rule.phase :: "PreDamage" | "PostDamage"
	local qualifyingDirectCount = countQualifying(directContacts, phase)
	local qualifyingRadiusCount = countQualifying(radiusContacts, phase)
	local creditedChannel: CreditChannel = CreditChannels.None
	if qualifyingDirectCount > 0 then
		creditedChannel = CreditChannels.Direct
	elseif qualifyingRadiusCount > 0 then
		creditedChannel = CreditChannels.Radius
	end
	local result: ShotResult = {
		family = family,
		evaluationPhase = phase,
		tracked = true,
		accuracyShotsDelta = 1,
		accuracyHitsDelta = if creditedChannel == CreditChannels.None then 0 else 1,
		qualifyingDirectCount = qualifyingDirectCount,
		qualifyingRadiusCount = qualifyingRadiusCount,
		creditedChannel = creditedChannel,
		impressiveQualifyingPenetrationCount = if family == WeaponFamilies.Rail then qualifyingDirectCount else 0,
	}
	table.freeze(result)
	return result, nil
end

return table.freeze({
	WeaponFamilies = WeaponFamilies,
	EvaluationPhases = EvaluationPhases,
	TargetKinds = TargetKinds,
	CreditChannels = CreditChannels,
	MaximumHealthMagnitude = MAXIMUM_HEALTH_MAGNITUDE,
	MaximumShotgunPellets = MAXIMUM_SHOTGUN_PELLETS,
	MaximumRailPenetrations = MAXIMUM_RAIL_PENETRATIONS,
	MaximumRadiusContacts = MAXIMUM_RADIUS_CONTACTS,
	EvaluateContact = evaluateContact,
	ResolveShot = resolveShot,
})
