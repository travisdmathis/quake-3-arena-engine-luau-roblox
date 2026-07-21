--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-only ownership for bounded, damage-disabled hitscan rewind history and
shadow telemetry. Q3 does not rewind player hulls for hitscan; this is an
instrumentation-only Roblox transport adaptation used to make the final bounded
rewind decision without changing authoritative shot outcomes.

Modified for the Roblox Luau port on 2026-07-13.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local HitscanRewindRules = require(sharedRoot.combat.HitscanRewindRules)

export type Buffer = HitscanRewindRules.Buffer

export type Observation = {
	shotId: string,
	weaponId: number,
	serverFrame: number,
	inputReceivedServerTime: number,
	targetServerTime: number?,
	rewindSeconds: number?,
	targetTimeClamped: boolean,
	currentUserIds: { number },
	historicalUserIds: { number },
	occludedUserIds: { number },
	classification: string,
	damageEnabled: boolean,
}

export type DebugMetrics = {
	damageEnabled: boolean,
	historyWindowSeconds: number,
	maximumSamplesPerPlayer: number,
	maximumObservations: number,
	maximumMeasuredPlayers: number,
	lightningSampleIntervalSeconds: number,
	historyPlayerCount: number,
	totalHistorySamples: number,
	maximumObservedSamplesPerPlayer: number,
	observationCount: number,
	totalObservationCount: number,
	agreeMissCount: number,
	agreeHitSetCount: number,
	currentOnlyCount: number,
	historicalOnlyCount: number,
	differentTargetSetCount: number,
	targetTimeClampCount: number,
	targetTimeRejectCount: number,
	historyMissingTargetCount: number,
	ineligibleTargetSkipCount: number,
	historyIdentityMismatchCount: number,
	historyBeforeSegmentCount: number,
	historyClampedOldestCount: number,
	historyClampedLatestCount: number,
	historicalOccludedTargetCount: number,
	historyIdentityResetCount: number,
	historyGapResetCount: number,
	historyTeleportResetCount: number,
	historyRejectedSampleCount: number,
	budgetSkipCount: number,
	lastRewindSeconds: number,
	maximumRewindSeconds: number,
	perWeaponObservationCount: { [number]: number },
}

local MAXIMUM_OBSERVATIONS = 128
local MAXIMUM_MEASURED_PLAYERS = 16
local LIGHTNING_SAMPLE_INTERVAL_SECONDS = 0.1
local MAXIMUM_DEBUG_COUNTER = 9_007_199_254_740_991
local DAMAGE_ENABLED = false

local histories: { [Player]: Buffer } = {}
local observations: { Observation } = {}
local nextLightningSampleAt: { [Player]: number } = {}
local perWeaponObservationCount: { [number]: number } = {}
local counters: { [string]: number } = {}

local CombatHitscanRewindRuntime = {}

local function saturatedAdd(value: number, amount: number): number
	return math.min(value + amount, MAXIMUM_DEBUG_COUNTER)
end

function CombatHitscanRewindRuntime.Reset()
	table.clear(histories)
	table.clear(observations)
	table.clear(nextLightningSampleAt)
	table.clear(perWeaponObservationCount)
	table.clear(counters)
end

function CombatHitscanRewindRuntime.GetBuffer(player: Player): Buffer?
	return histories[player]
end

function CombatHitscanRewindRuntime.GetOrCreateBuffer(player: Player): Buffer
	local buffer = histories[player]
	if not buffer then
		buffer = HitscanRewindRules.NewBuffer()
		histories[player] = buffer
	end
	return buffer
end

function CombatHitscanRewindRuntime.ClearPlayer(player: Player)
	local buffer = histories[player]
	if buffer then
		HitscanRewindRules.Clear(buffer)
	end
end

function CombatHitscanRewindRuntime.RemovePlayer(player: Player)
	histories[player] = nil
	nextLightningSampleAt[player] = nil
end

function CombatHitscanRewindRuntime.Increment(metric: string)
	counters[metric] = saturatedAdd(counters[metric] or 0, 1)
end

function CombatHitscanRewindRuntime.RecordInsertionDisposition(disposition: string)
	local dispositions = HitscanRewindRules.InsertDisposition
	if disposition == dispositions.ResetIdentity then
		CombatHitscanRewindRuntime.Increment("historyIdentityResetCount")
	elseif disposition == dispositions.ResetGap then
		CombatHitscanRewindRuntime.Increment("historyGapResetCount")
	elseif disposition == dispositions.ResetTeleport then
		CombatHitscanRewindRuntime.Increment("historyTeleportResetCount")
	elseif disposition ~= dispositions.Inserted then
		CombatHitscanRewindRuntime.Increment("historyRejectedSampleCount")
	end
end

function CombatHitscanRewindRuntime.ShouldMeasure(
	player: Player,
	isLightning: boolean,
	serverNow: number,
	playerCount: number
): boolean
	if playerCount > MAXIMUM_MEASURED_PLAYERS then
		CombatHitscanRewindRuntime.Increment("budgetSkipCount")
		return false
	end
	if isLightning then
		local nextAllowed = nextLightningSampleAt[player] or -math.huge
		if serverNow < nextAllowed then
			CombatHitscanRewindRuntime.Increment("budgetSkipCount")
			return false
		end
		nextLightningSampleAt[player] = serverNow + LIGHTNING_SAMPLE_INTERVAL_SECONDS
	end
	return true
end

function CombatHitscanRewindRuntime.RecordTargetTime(rewindSeconds: number, clamped: boolean)
	if clamped then
		CombatHitscanRewindRuntime.Increment("targetTimeClampCount")
	end
	counters.lastRewindSeconds = rewindSeconds
	counters.maximumRewindSeconds = math.max(counters.maximumRewindSeconds or 0, rewindSeconds)
end

function CombatHitscanRewindRuntime.IncrementClassification(classification: string)
	if classification == "AgreeMiss" then
		CombatHitscanRewindRuntime.Increment("agreeMissCount")
	elseif classification == "AgreeHitSet" then
		CombatHitscanRewindRuntime.Increment("agreeHitSetCount")
	elseif classification == "CurrentOnly" then
		CombatHitscanRewindRuntime.Increment("currentOnlyCount")
	elseif classification == "HistoricalOnly" then
		CombatHitscanRewindRuntime.Increment("historicalOnlyCount")
	else
		CombatHitscanRewindRuntime.Increment("differentTargetSetCount")
	end
end

function CombatHitscanRewindRuntime.AppendObservation(observation: Observation)
	CombatHitscanRewindRuntime.Increment("totalObservationCount")
	perWeaponObservationCount[observation.weaponId] =
		saturatedAdd(perWeaponObservationCount[observation.weaponId] or 0, 1)
	table.insert(observations, table.freeze(observation))
	if #observations > MAXIMUM_OBSERVATIONS then
		table.remove(observations, 1)
	end
end

function CombatHitscanRewindRuntime.GetObservations(): { Observation }
	return table.freeze(table.clone(observations))
end

function CombatHitscanRewindRuntime.GetDebugMetrics(): DebugMetrics
	local historyPlayerCount = 0
	local totalHistorySamples = 0
	local maximumObservedSamplesPerPlayer = 0
	for _, buffer in histories do
		local count = HitscanRewindRules.Count(buffer)
		if count > 0 then
			historyPlayerCount += 1
			totalHistorySamples += count
			maximumObservedSamplesPerPlayer = math.max(maximumObservedSamplesPerPlayer, count)
		end
	end
	local function count(name: string): number
		return counters[name] or 0
	end
	return table.freeze({
		damageEnabled = DAMAGE_ENABLED,
		historyWindowSeconds = HitscanRewindRules.HistoryWindowSeconds,
		maximumSamplesPerPlayer = HitscanRewindRules.MaximumSamples,
		maximumObservations = MAXIMUM_OBSERVATIONS,
		maximumMeasuredPlayers = MAXIMUM_MEASURED_PLAYERS,
		lightningSampleIntervalSeconds = LIGHTNING_SAMPLE_INTERVAL_SECONDS,
		historyPlayerCount = historyPlayerCount,
		totalHistorySamples = totalHistorySamples,
		maximumObservedSamplesPerPlayer = maximumObservedSamplesPerPlayer,
		observationCount = #observations,
		totalObservationCount = count("totalObservationCount"),
		agreeMissCount = count("agreeMissCount"),
		agreeHitSetCount = count("agreeHitSetCount"),
		currentOnlyCount = count("currentOnlyCount"),
		historicalOnlyCount = count("historicalOnlyCount"),
		differentTargetSetCount = count("differentTargetSetCount"),
		targetTimeClampCount = count("targetTimeClampCount"),
		targetTimeRejectCount = count("targetTimeRejectCount"),
		historyMissingTargetCount = count("historyMissingTargetCount"),
		ineligibleTargetSkipCount = count("ineligibleTargetSkipCount"),
		historyIdentityMismatchCount = count("historyIdentityMismatchCount"),
		historyBeforeSegmentCount = count("historyBeforeSegmentCount"),
		historyClampedOldestCount = count("historyClampedOldestCount"),
		historyClampedLatestCount = count("historyClampedLatestCount"),
		historicalOccludedTargetCount = count("historicalOccludedTargetCount"),
		historyIdentityResetCount = count("historyIdentityResetCount"),
		historyGapResetCount = count("historyGapResetCount"),
		historyTeleportResetCount = count("historyTeleportResetCount"),
		historyRejectedSampleCount = count("historyRejectedSampleCount"),
		budgetSkipCount = count("budgetSkipCount"),
		lastRewindSeconds = count("lastRewindSeconds"),
		maximumRewindSeconds = count("maximumRewindSeconds"),
		perWeaponObservationCount = table.freeze(table.clone(perWeaponObservationCount)),
	})
end

CombatHitscanRewindRuntime.DamageEnabled = DAMAGE_ENABLED

return table.freeze(CombatHitscanRewindRuntime)
