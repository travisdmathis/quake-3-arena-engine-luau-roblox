--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure bounded history, server-derived timing, and ray/AABB rules for measuring
hitscan rewind disagreement. This module does not accept client timestamps,
targets, or damage and does not authorize a combat outcome.
]]

--!strict

local RemoteInterpolationRules = require(script.Parent.Parent.simulation.RemoteInterpolationRules)

export type Identity = {
	userId: number,
	matchId: string,
	character: Model,
	lifeSequence: number,
	revision: number,
}

export type Sample = {
	userId: number,
	matchId: string,
	character: Model,
	lifeSequence: number,
	revision: number,
	serverTime: number,
	frame: number,
	center: Vector3,
	size: Vector3,
	teleported: boolean,
}

export type Buffer = {
	samples: { Sample },
	segmentStartServerTime: number?,
}

export type TargetTime = {
	serverTime: number,
	rewindSeconds: number,
	halfRoundTripSeconds: number,
	inputAgeSeconds: number,
	clamped: boolean,
}

export type ResolvedSample = {
	userId: number,
	matchId: string,
	character: Model,
	lifeSequence: number,
	revision: number,
	serverTime: number,
	frame: number,
	center: Vector3,
	size: Vector3,
	targetServerTime: number,
	alpha: number,
}

export type InsertDisposition =
	"Inserted"
	| "ResetIdentity"
	| "ResetGap"
	| "ResetTeleport"
	| "RejectedIdentity"
	| "RejectedSample"
	| "RejectedTime"

export type ResolveDisposition =
	"Exact"
	| "Interpolated"
	| "ClampedOldest"
	| "ClampedLatest"
	| "Missing"
	| "IdentityMismatch"
	| "UnavailableBeforeSegment"
	| "RejectedInputTime"
	| "RejectedServerTime"
	| "RejectedRoundTrip"
	| "RejectedTargetTime"

local HISTORY_WINDOW_SECONDS = 0.35
local MAXIMUM_SAMPLES = 32
local MAXIMUM_SAMPLE_GAP_SECONDS = 0.1
local MAXIMUM_HALF_ROUND_TRIP_SECONDS = 0.15
local MAXIMUM_REWIND_SECONDS = 0.25
local TELEPORT_RESET_DISTANCE_STUDS = RemoteInterpolationRules.TeleportSnapDistanceStuds
local INTERPOLATION_DELAY_SECONDS = RemoteInterpolationRules.InterpolationDelaySeconds

local EPSILON = 1e-9

local InsertDisposition = table.freeze({
	Inserted = "Inserted" :: "Inserted",
	ResetIdentity = "ResetIdentity" :: "ResetIdentity",
	ResetGap = "ResetGap" :: "ResetGap",
	ResetTeleport = "ResetTeleport" :: "ResetTeleport",
	RejectedIdentity = "RejectedIdentity" :: "RejectedIdentity",
	RejectedSample = "RejectedSample" :: "RejectedSample",
	RejectedTime = "RejectedTime" :: "RejectedTime",
})

local ResolveDisposition = table.freeze({
	Exact = "Exact" :: "Exact",
	Interpolated = "Interpolated" :: "Interpolated",
	ClampedOldest = "ClampedOldest" :: "ClampedOldest",
	ClampedLatest = "ClampedLatest" :: "ClampedLatest",
	Missing = "Missing" :: "Missing",
	IdentityMismatch = "IdentityMismatch" :: "IdentityMismatch",
	UnavailableBeforeSegment = "UnavailableBeforeSegment" :: "UnavailableBeforeSegment",
	RejectedInputTime = "RejectedInputTime" :: "RejectedInputTime",
	RejectedServerTime = "RejectedServerTime" :: "RejectedServerTime",
	RejectedRoundTrip = "RejectedRoundTrip" :: "RejectedRoundTrip",
	RejectedTargetTime = "RejectedTargetTime" :: "RejectedTargetTime",
})

local HitscanRewindRules = {
	HistoryWindowSeconds = HISTORY_WINDOW_SECONDS,
	MaximumSamples = MAXIMUM_SAMPLES,
	MaximumSampleGapSeconds = MAXIMUM_SAMPLE_GAP_SECONDS,
	MaximumHalfRoundTripSeconds = MAXIMUM_HALF_ROUND_TRIP_SECONDS,
	MaximumRewindSeconds = MAXIMUM_REWIND_SECONDS,
	TeleportResetDistanceStuds = TELEPORT_RESET_DISTANCE_STUDS,
	InterpolationDelaySeconds = INTERPOLATION_DELAY_SECONDS,
	InsertDisposition = InsertDisposition,
	ResolveDisposition = ResolveDisposition,
}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteInteger(value: any): boolean
	return isFiniteNumber(value) and value % 1 == 0
end

local function isFiniteVector3(value: any): boolean
	return typeof(value) == "Vector3"
		and isFiniteNumber(value.X)
		and isFiniteNumber(value.Y)
		and isFiniteNumber(value.Z)
end

local function isPositiveFiniteVector3(value: any): boolean
	return isFiniteVector3(value) and value.X > 0 and value.Y > 0 and value.Z > 0
end

local function isIdentity(value: any): boolean
	return type(value) == "table"
		and isFiniteInteger(value.userId)
		and value.userId ~= 0
		and type(value.matchId) == "string"
		and value.matchId ~= ""
		and typeof(value.character) == "Instance"
		and value.character:IsA("Model")
		and isFiniteInteger(value.lifeSequence)
		and value.lifeSequence >= 1
		and isFiniteInteger(value.revision)
		and value.revision >= 1
end

local function isSample(value: any): boolean
	return isIdentity(value)
		and isFiniteNumber(value.serverTime)
		and isFiniteInteger(value.frame)
		and value.frame >= 0
		and isFiniteVector3(value.center)
		and isPositiveFiniteVector3(value.size)
		and type(value.teleported) == "boolean"
end

local function sameIdentity(left: Identity, right: Identity): boolean
	return left.userId == right.userId
		and left.matchId == right.matchId
		and left.character == right.character
		and left.lifeSequence == right.lifeSequence
		and left.revision == right.revision
end

local function freezeSample(sample: Sample): Sample
	return table.freeze({
		userId = sample.userId,
		matchId = sample.matchId,
		character = sample.character,
		lifeSequence = sample.lifeSequence,
		revision = sample.revision,
		serverTime = sample.serverTime,
		frame = sample.frame,
		center = sample.center,
		size = sample.size,
		teleported = sample.teleported,
	})
end

local function resetTo(buffer: Buffer, sample: Sample)
	table.clear(buffer.samples)
	table.insert(buffer.samples, sample)
	buffer.segmentStartServerTime = sample.serverTime
end

local function trim(buffer: Buffer, latestServerTime: number)
	while #buffer.samples > MAXIMUM_SAMPLES do
		table.remove(buffer.samples, 1)
	end
	while #buffer.samples > 1 and latestServerTime - buffer.samples[1].serverTime > HISTORY_WINDOW_SECONDS do
		table.remove(buffer.samples, 1)
	end
end

local function resolvedFromSample(sample: Sample, targetServerTime: number, alpha: number): ResolvedSample
	return table.freeze({
		userId = sample.userId,
		matchId = sample.matchId,
		character = sample.character,
		lifeSequence = sample.lifeSequence,
		revision = sample.revision,
		serverTime = sample.serverTime,
		frame = sample.frame,
		center = sample.center,
		size = sample.size,
		targetServerTime = targetServerTime,
		alpha = alpha,
	})
end

function HitscanRewindRules.NewBuffer(): Buffer
	return {
		samples = {},
		segmentStartServerTime = nil,
	}
end

function HitscanRewindRules.Clear(buffer: Buffer)
	table.clear(buffer.samples)
	buffer.segmentStartServerTime = nil
end

function HitscanRewindRules.Count(buffer: Buffer): number
	return #buffer.samples
end

function HitscanRewindRules.Latest(buffer: Buffer): Sample?
	return buffer.samples[#buffer.samples]
end

function HitscanRewindRules.SameIdentity(left: Identity, right: Identity): boolean
	return isIdentity(left) and isIdentity(right) and sameIdentity(left, right)
end

function HitscanRewindRules.Insert(buffer: Buffer, sample: Sample): (boolean, InsertDisposition)
	if not isIdentity(sample) then
		return false, InsertDisposition.RejectedIdentity
	end
	if not isSample(sample) then
		return false, InsertDisposition.RejectedSample
	end

	local frozenSample = freezeSample(sample)
	local latest = HitscanRewindRules.Latest(buffer)
	if not latest then
		table.insert(buffer.samples, frozenSample)
		buffer.segmentStartServerTime = frozenSample.serverTime
		return true, InsertDisposition.Inserted
	end
	if frozenSample.serverTime <= latest.serverTime then
		return false, InsertDisposition.RejectedTime
	end
	if not sameIdentity(latest, frozenSample) then
		resetTo(buffer, frozenSample)
		return true, InsertDisposition.ResetIdentity
	end
	if frozenSample.teleported or (frozenSample.center - latest.center).Magnitude >= TELEPORT_RESET_DISTANCE_STUDS then
		resetTo(buffer, frozenSample)
		return true, InsertDisposition.ResetTeleport
	end
	if frozenSample.serverTime - latest.serverTime > MAXIMUM_SAMPLE_GAP_SECONDS then
		resetTo(buffer, frozenSample)
		return true, InsertDisposition.ResetGap
	end

	table.insert(buffer.samples, frozenSample)
	trim(buffer, frozenSample.serverTime)
	return true, InsertDisposition.Inserted
end

function HitscanRewindRules.ComputeTargetTime(
	inputReceivedServerTime: number,
	serverNow: number,
	roundTripSeconds: number
): (TargetTime?, ResolveDisposition?)
	if not isFiniteNumber(serverNow) then
		return nil, ResolveDisposition.RejectedServerTime
	end
	if not isFiniteNumber(inputReceivedServerTime) or inputReceivedServerTime > serverNow then
		return nil, ResolveDisposition.RejectedInputTime
	end
	if not isFiniteNumber(roundTripSeconds) or roundTripSeconds < 0 then
		return nil, ResolveDisposition.RejectedRoundTrip
	end

	local halfRoundTripSeconds = math.min(roundTripSeconds * 0.5, MAXIMUM_HALF_ROUND_TRIP_SECONDS)
	local rawTargetServerTime = inputReceivedServerTime - INTERPOLATION_DELAY_SECONDS - halfRoundTripSeconds
	local rawRewindSeconds = serverNow - rawTargetServerTime
	local rewindSeconds = math.min(rawRewindSeconds, MAXIMUM_REWIND_SECONDS)
	local clamped = rawRewindSeconds > MAXIMUM_REWIND_SECONDS + EPSILON

	return table.freeze({
		serverTime = serverNow - rewindSeconds,
		rewindSeconds = rewindSeconds,
		halfRoundTripSeconds = halfRoundTripSeconds,
		inputAgeSeconds = serverNow - inputReceivedServerTime,
		clamped = clamped,
	}),
		nil
end

function HitscanRewindRules.ResolveAt(
	buffer: Buffer,
	identity: Identity,
	targetServerTime: number
): (ResolvedSample?, ResolveDisposition)
	if not isFiniteNumber(targetServerTime) then
		return nil, ResolveDisposition.RejectedTargetTime
	end
	if not isIdentity(identity) then
		return nil, ResolveDisposition.IdentityMismatch
	end

	local samples = buffer.samples
	local sampleCount = #samples
	if sampleCount == 0 then
		return nil, ResolveDisposition.Missing
	end
	local latest = samples[sampleCount]
	if not sameIdentity(latest, identity) then
		return nil, ResolveDisposition.IdentityMismatch
	end
	local segmentStartServerTime = buffer.segmentStartServerTime
	if segmentStartServerTime == nil then
		return nil, ResolveDisposition.Missing
	end
	if targetServerTime < segmentStartServerTime then
		return nil, ResolveDisposition.UnavailableBeforeSegment
	end

	local oldest = samples[1]
	if targetServerTime <= oldest.serverTime then
		local disposition = if math.abs(targetServerTime - oldest.serverTime) <= EPSILON
			then ResolveDisposition.Exact
			else ResolveDisposition.ClampedOldest
		return resolvedFromSample(oldest, targetServerTime, 0), disposition
	end

	for index = 2, sampleCount do
		local following = samples[index]
		if targetServerTime <= following.serverTime then
			if math.abs(targetServerTime - following.serverTime) <= EPSILON then
				return resolvedFromSample(following, targetServerTime, 1), ResolveDisposition.Exact
			end

			local previous = samples[index - 1]
			local duration = following.serverTime - previous.serverTime
			local alpha = math.clamp((targetServerTime - previous.serverTime) / duration, 0, 1)
			local discrete = if alpha >= 0.5 then following else previous
			return table.freeze({
				userId = previous.userId,
				matchId = previous.matchId,
				character = previous.character,
				lifeSequence = previous.lifeSequence,
				revision = previous.revision,
				serverTime = targetServerTime,
				frame = discrete.frame,
				center = previous.center:Lerp(following.center, alpha),
				size = discrete.size,
				targetServerTime = targetServerTime,
				alpha = alpha,
			}),
				ResolveDisposition.Interpolated
		end
	end

	return resolvedFromSample(latest, targetServerTime, 1), ResolveDisposition.ClampedLatest
end

function HitscanRewindRules.Resolve(
	buffer: Buffer,
	identity: Identity,
	inputReceivedServerTime: number,
	serverNow: number,
	roundTripSeconds: number
): (ResolvedSample?, ResolveDisposition)
	local targetTime, rejectedDisposition =
		HitscanRewindRules.ComputeTargetTime(inputReceivedServerTime, serverNow, roundTripSeconds)
	if not targetTime then
		return nil, rejectedDisposition :: ResolveDisposition
	end
	return HitscanRewindRules.ResolveAt(buffer, identity, targetTime.serverTime)
end

local function slab(
	origin: number,
	direction: number,
	minimum: number,
	maximum: number,
	entryDistance: number,
	exitDistance: number
): (number?, number?)
	if math.abs(direction) <= EPSILON then
		if origin < minimum or origin > maximum then
			return nil, nil
		end
		return entryDistance, exitDistance
	end

	local first = (minimum - origin) / direction
	local second = (maximum - origin) / direction
	if first > second then
		first, second = second, first
	end
	local nextEntry = math.max(entryDistance, first)
	local nextExit = math.min(exitDistance, second)
	if nextEntry > nextExit then
		return nil, nil
	end
	return nextEntry, nextExit
end

function HitscanRewindRules.RayAabbDistance(
	origin: Vector3,
	direction: Vector3,
	maximumDistance: number,
	center: Vector3,
	size: Vector3
): number?
	if
		not isFiniteVector3(origin)
		or not isFiniteVector3(direction)
		or not isFiniteNumber(maximumDistance)
		or maximumDistance < 0
		or not isFiniteVector3(center)
		or not isPositiveFiniteVector3(size)
	then
		return nil
	end

	local directionMagnitude = direction.Magnitude
	if not isFiniteNumber(directionMagnitude) or directionMagnitude <= EPSILON then
		return nil
	end
	local unitDirection = direction / directionMagnitude
	local halfSize = size * 0.5
	local minimum = center - halfSize
	local maximum = center + halfSize
	local entryDistance = 0
	local exitDistance = maximumDistance

	local nextEntry, nextExit = slab(origin.X, unitDirection.X, minimum.X, maximum.X, entryDistance, exitDistance)
	if nextEntry == nil or nextExit == nil then
		return nil
	end
	entryDistance, exitDistance = nextEntry, nextExit

	nextEntry, nextExit = slab(origin.Y, unitDirection.Y, minimum.Y, maximum.Y, entryDistance, exitDistance)
	if nextEntry == nil or nextExit == nil then
		return nil
	end
	entryDistance, exitDistance = nextEntry, nextExit

	nextEntry, nextExit = slab(origin.Z, unitDirection.Z, minimum.Z, maximum.Z, entryDistance, exitDistance)
	if nextEntry == nil or nextExit == nil then
		return nil
	end
	return nextEntry
end

return table.freeze(HitscanRewindRules)
