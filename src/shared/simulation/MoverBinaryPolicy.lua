--[[
SPDX-License-Identifier: GPL-2.0-or-later

Immutable server policy paired with MoverBinaryState's geometry/timing Programs.
The first bounded policy mirrors code/game/g_mover.c Blocked_Door: non-door
binary teams have no blocked callback, while door/platform teams may damage a
client and optionally suppress reversal with the CRUSHER flag. Item/flag
branches remain separate body-consumer work and are not represented here.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local MoverBinaryState = require(script.Parent.MoverBinaryState)

export type BlockedBehavior = "None" | "Door"
export type ActivationBehavior = "None" | "DoorTouch" | "PlatTouch"
export type Policy = {
	teamId: string,
	captainMoverId: string,
	blockedBehavior: BlockedBehavior,
	damage: number,
	crusher: boolean,
	activationBehavior: ActivationBehavior,
}

local MoverBinaryPolicy = {}

local MAXIMUM_DAMAGE = 100_000
local POLICY_KEYS: { [string]: boolean } = table.freeze({
	teamId = true,
	captainMoverId = true,
	blockedBehavior = true,
	damage = true,
	crusher = true,
	activationBehavior = true,
})

local BlockedBehavior = table.freeze({
	None = "None" :: "None",
	Door = "Door" :: "Door",
})
local ActivationBehavior = table.freeze({
	None = "None" :: "None",
	DoorTouch = "DoorTouch" :: "DoorTouch",
	PlatTouch = "PlatTouch" :: "PlatTouch",
})

local function hasExactKeys(value: { [unknown]: unknown }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or POLICY_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 6
end

local function denseArrayLength(value: unknown, maximum: number): (number?, string?)
	if type(value) ~= "table" then
		return nil, "policies-not-array"
	end
	local count = 0
	local maximumIndex = 0
	for key in value :: { [unknown]: unknown } do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "policies-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > maximum or maximumIndex > maximum then
			return nil, "too-many-policies"
		end
	end
	if maximumIndex ~= count then
		return nil, "policies-not-dense-array"
	end
	return count, nil
end

local function programRuntime(programsValue: unknown): (MoverBinaryState.Runtime?, string?)
	local runtime, runtimeError = MoverBinaryState.Create(programsValue)
	if not runtime then
		return nil, "programs-not-validated:" .. (runtimeError or "invalid")
	end
	return runtime, nil
end

function MoverBinaryPolicy.ValidateAndOrder(programsValue: unknown, policiesValue: unknown): ({ Policy }?, string?)
	local runtime, runtimeError = programRuntime(programsValue)
	if not runtime then
		return nil, runtimeError
	end
	local count, countError = denseArrayLength(policiesValue, #runtime.teams)
	if not count then
		return nil, countError
	end
	if count ~= #runtime.teams then
		return nil, "policy-team-count-mismatch"
	end

	local policyByTeam: { [string]: Policy } = {}
	local observedCaptains: { [string]: boolean } = {}
	for index = 1, count do
		local rawValue = (policiesValue :: { [unknown]: unknown })[index]
		if type(rawValue) ~= "table" then
			return nil, string.format("policy-%d:not-table", index)
		end
		local raw = rawValue :: { [unknown]: unknown }
		if not hasExactKeys(raw) then
			return nil, string.format("policy-%d:invalid-shape", index)
		end
		if raw.blockedBehavior ~= BlockedBehavior.None and raw.blockedBehavior ~= BlockedBehavior.Door then
			return nil, string.format("policy-%d:invalid-blocked-behavior", index)
		end
		if
			type(raw.damage) ~= "number"
			or raw.damage ~= raw.damage
			or math.abs(raw.damage) == math.huge
			or raw.damage % 1 ~= 0
			or raw.damage < 0
			or raw.damage > MAXIMUM_DAMAGE
		then
			return nil, string.format("policy-%d:invalid-damage", index)
		end
		if type(raw.crusher) ~= "boolean" then
			return nil, string.format("policy-%d:invalid-crusher", index)
		end
		if
			raw.activationBehavior ~= ActivationBehavior.None
			and raw.activationBehavior ~= ActivationBehavior.DoorTouch
			and raw.activationBehavior ~= ActivationBehavior.PlatTouch
		then
			return nil, string.format("policy-%d:invalid-activation-behavior", index)
		end
		if raw.blockedBehavior == BlockedBehavior.None and (raw.damage ~= 0 or raw.crusher ~= false) then
			return nil, string.format("policy-%d:noncanonical-none", index)
		end
		if
			(
				raw.activationBehavior == ActivationBehavior.DoorTouch
				or raw.activationBehavior == ActivationBehavior.PlatTouch
			) and raw.blockedBehavior ~= BlockedBehavior.Door
		then
			return nil, string.format("policy-%d:touch-requires-door-blocking", index)
		end
		if type(raw.teamId) ~= "string" or policyByTeam[raw.teamId] then
			return nil, string.format("policy-%d:duplicate-or-invalid-team", index)
		end
		if type(raw.captainMoverId) ~= "string" or observedCaptains[raw.captainMoverId] then
			return nil, string.format("policy-%d:duplicate-or-invalid-captain", index)
		end
		local policy: Policy = {
			teamId = raw.teamId,
			captainMoverId = raw.captainMoverId,
			blockedBehavior = raw.blockedBehavior :: BlockedBehavior,
			damage = raw.damage,
			crusher = raw.crusher,
			activationBehavior = raw.activationBehavior :: ActivationBehavior,
		}
		table.freeze(policy)
		policyByTeam[policy.teamId] = policy
		observedCaptains[policy.captainMoverId] = true
	end

	local ordered: { Policy } = table.create(#runtime.teams)
	for _, team in runtime.teams do
		local policy = policyByTeam[team.teamId]
		if not policy then
			return nil, "missing-team-policy:" .. team.teamId
		end
		if policy.captainMoverId ~= team.captainMoverId then
			return nil, "policy-captain-mismatch:" .. team.teamId
		end
		table.insert(ordered, policy)
	end
	table.freeze(ordered)
	return ordered, nil
end

function MoverBinaryPolicy.CreateDefaults(programsValue: unknown): ({ Policy }?, string?)
	local runtime, runtimeError = programRuntime(programsValue)
	if not runtime then
		return nil, runtimeError
	end
	local defaults: { Policy } = table.create(#runtime.teams)
	for _, team in runtime.teams do
		table.insert(defaults, {
			teamId = team.teamId,
			captainMoverId = team.captainMoverId,
			blockedBehavior = BlockedBehavior.None,
			damage = 0,
			crusher = false,
			activationBehavior = ActivationBehavior.None,
		})
	end
	return MoverBinaryPolicy.ValidateAndOrder(programsValue, defaults)
end

function MoverBinaryPolicy.IndexByTeam(programsValue: unknown, policiesValue: unknown): ({ [string]: Policy }?, string?)
	local policies, policyError = MoverBinaryPolicy.ValidateAndOrder(programsValue, policiesValue)
	if not policies then
		return nil, policyError
	end
	local byTeam: { [string]: Policy } = {}
	for _, policy in policies do
		byTeam[policy.teamId] = policy
	end
	table.freeze(byTeam)
	return byTeam, nil
end

MoverBinaryPolicy.BlockedBehavior = BlockedBehavior
MoverBinaryPolicy.ActivationBehavior = ActivationBehavior
MoverBinaryPolicy.MaximumDamage = MAXIMUM_DAMAGE

return table.freeze(MoverBinaryPolicy)
