--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox/Luau adaptation of deterministic spawn-selection behavior from:
  code/game/g_client.c (SpotWouldTelefrag, SelectRandomFurthestSpawnPoint)
  code/game/g_utils.c (G_KillBox overlap contract)

The explicit roll input, team filtering, stable tie-breaking, and data-only
boundary are original the Roblox Luau port adaptations.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-10.
]]

--!strict

local RocketArenaSpawnRules = require(script.Parent.RocketArenaSpawnRules)

export type Candidate = {
	index: number,
	origin: Vector3,
	teamId: string?,
}

export type Occupant = {
	userId: number,
	origin: Vector3,
	size: Vector3,
	centerOffset: Vector3,
	active: boolean,
}

export type Selection = {
	spawnIndex: number,
	origin: Vector3,
	telefragUserIds: { number },
	usedTelefragFallback: boolean,
}

export type Policy = "FarthestHalf" | "Uniform"

local SpawnSelection = {}
local MAXIMUM_FARTHEST_CANDIDATES = 64
local MAXIMUM_UNIFORM_CANDIDATES = 32
local LINKED_BOUNDS_EXPANSION = 0.1

local function overlaps(
	leftOrigin: Vector3,
	leftSize: Vector3,
	leftCenterOffset: Vector3,
	rightOrigin: Vector3,
	rightSize: Vector3,
	rightCenterOffset: Vector3
): boolean
	local delta = (leftOrigin + leftCenterOffset) - (rightOrigin + rightCenterOffset)
	local halfExtent = (leftSize + rightSize) * 0.5
	return math.abs(delta.X) <= halfExtent.X + LINKED_BOUNDS_EXPANSION
		and math.abs(delta.Y) <= halfExtent.Y + LINKED_BOUNDS_EXPANSION
		and math.abs(delta.Z) <= halfExtent.Z + LINKED_BOUNDS_EXPANSION
end

local function occupantUserIdsAt(
	origin: Vector3,
	spawnSize: Vector3,
	spawnCenterOffset: Vector3,
	occupants: { Occupant }
): { number }
	local userIds: { number } = {}
	for _, occupant in occupants do
		if
			occupant.active
			and overlaps(origin, spawnSize, spawnCenterOffset, occupant.origin, occupant.size, occupant.centerOffset)
		then
			table.insert(userIds, occupant.userId)
		end
	end
	table.sort(userIds)
	return userIds
end

local function eligibleCandidates(candidates: { Candidate }, requestedTeam: string?, policy: Policy): { Candidate }
	local eligible: { Candidate } = {}
	local hasTeam = requestedTeam == "Red" or requestedTeam == "Blue"
	-- Q3's non-CTF ClientSpawn path consumes the ordinary deathmatch pool and
	-- does not mix team_CTF_* markers into FFA, Duel, or TDM selection. Keep a
	-- fallback for original project maps authored entirely with team markers.
	if not hasTeam then
		for _, candidate in candidates do
			if candidate.teamId == nil then
				table.insert(eligible, candidate)
			end
		end
		if #eligible > 0 then
			return eligible
		end
		return table.clone(candidates)
	end
	if hasTeam and policy == "Uniform" then
		for _, candidate in candidates do
			if candidate.teamId == requestedTeam then
				table.insert(eligible, candidate)
			end
		end
		if #eligible > 0 then
			return eligible
		end
	end
	for _, candidate in candidates do
		if candidate.teamId == nil or candidate.teamId == requestedTeam then
			table.insert(eligible, candidate)
		end
	end
	if #eligible == 0 then
		return table.clone(candidates)
	end
	return eligible
end

function SpawnSelection.Overlaps(
	leftOrigin: Vector3,
	leftSize: Vector3,
	leftCenterOffset: Vector3,
	rightOrigin: Vector3,
	rightSize: Vector3,
	rightCenterOffset: Vector3
): boolean
	return overlaps(leftOrigin, leftSize, leftCenterOffset, rightOrigin, rightSize, rightCenterOffset)
end

function SpawnSelection.OccupantUserIdsAt(
	origin: Vector3,
	spawnSize: Vector3,
	spawnCenterOffset: Vector3,
	occupants: { Occupant }
): { number }
	return occupantUserIdsAt(origin, spawnSize, spawnCenterOffset, occupants)
end

function SpawnSelection.Select(
	candidates: { Candidate },
	occupants: { Occupant },
	spawnSize: Vector3,
	spawnCenterOffset: Vector3,
	requestedTeam: string?,
	avoidPoint: Vector3?,
	roll: number,
	policy: Policy,
	requestedIndex: number?
): Selection?
	if #candidates == 0 or roll % 1 ~= 0 or roll < 0 or (policy ~= "FarthestHalf" and policy ~= "Uniform") then
		return nil
	end

	if requestedIndex ~= nil then
		if requestedIndex % 1 ~= 0 then
			return nil
		end
		for _, candidate in candidates do
			if candidate.index == requestedIndex then
				local telefragUserIds = occupantUserIdsAt(candidate.origin, spawnSize, spawnCenterOffset, occupants)
				return {
					spawnIndex = candidate.index,
					origin = candidate.origin,
					telefragUserIds = telefragUserIds,
					usedTelefragFallback = #telefragUserIds > 0,
				}
			end
		end
		return nil
	end

	local eligible = eligibleCandidates(candidates, requestedTeam, policy)
	if #eligible == 0 then
		return nil
	end

	local free: { { candidate: Candidate, distance: number } } = {}
	for _, candidate in eligible do
		if #occupantUserIdsAt(candidate.origin, spawnSize, spawnCenterOffset, occupants) == 0 then
			table.insert(free, {
				candidate = candidate,
				distance = if avoidPoint then (candidate.origin - avoidPoint).Magnitude else 0,
			})
		end
	end

	if #free == 0 then
		local fallback = eligible[1]
		return {
			spawnIndex = fallback.index,
			origin = fallback.origin,
			telefragUserIds = occupantUserIdsAt(fallback.origin, spawnSize, spawnCenterOffset, occupants),
			usedTelefragFallback = true,
		}
	end

	if policy == "Uniform" then
		while #free > MAXIMUM_UNIFORM_CANDIDATES do
			table.remove(free)
		end
		local selected = free[(roll % #free) + 1].candidate
		return {
			spawnIndex = selected.index,
			origin = selected.origin,
			telefragUserIds = {},
			usedTelefragFallback = false,
		}
	end

	table.sort(free, function(left, right): boolean
		if left.distance ~= right.distance then
			return left.distance > right.distance
		end
		return left.candidate.index < right.candidate.index
	end)
	while #free > MAXIMUM_FARTHEST_CANDIDATES do
		table.remove(free)
	end

	-- Q3 multiplies random() by integer division (numSpots / 2), so odd
	-- candidate counts intentionally round the farthest half down.
	local farthestCount = math.max(math.floor(#free / 2), 1)
	local selected = free[(roll % farthestCount) + 1].candidate
	return {
		spawnIndex = selected.index,
		origin = selected.origin,
		telefragUserIds = {},
		usedTelefragFallback = false,
	}
end

function SpawnSelection.SelectRocketArena(
	candidates: { Candidate },
	occupants: { Occupant },
	spawnSize: Vector3,
	spawnCenterOffset: Vector3,
	useNearHalf: boolean,
	roll: number,
	requestedIndex: number?
): Selection?
	if #candidates == 0 or roll % 1 ~= 0 or roll < 0 then
		return nil
	end
	if requestedIndex ~= nil then
		return SpawnSelection.Select(
			candidates,
			occupants,
			spawnSize,
			spawnCenterOffset,
			nil,
			nil,
			roll,
			"Uniform",
			requestedIndex
		)
	end

	-- RA3 filters telefragging spots before it measures the widest source XY
	-- axis and divides the remaining ordered set into near/far halves.
	local free: { Candidate } = {}
	local originsByIndex: { [number]: Vector3 } = {}
	local freeIndices: { number } = {}
	for _, candidate in candidates do
		if #occupantUserIdsAt(candidate.origin, spawnSize, spawnCenterOffset, occupants) == 0 then
			table.insert(free, candidate)
			originsByIndex[candidate.index] = candidate.origin
			table.insert(freeIndices, candidate.index)
		end
	end
	if #free == 0 then
		local fallback = candidates[1]
		return {
			spawnIndex = fallback.index,
			origin = fallback.origin,
			telefragUserIds = occupantUserIdsAt(fallback.origin, spawnSize, spawnCenterOffset, occupants),
			usedTelefragFallback = true,
		}
	end
	if #free == 1 then
		local selected = free[1]
		return {
			spawnIndex = selected.index,
			origin = selected.origin,
			telefragUserIds = {},
			usedTelefragFallback = false,
		}
	end

	local selectedIndex = RocketArenaSpawnRules.SelectIndex(originsByIndex, freeIndices, useNearHalf, roll)
	if selectedIndex == nil then
		return nil
	end
	for _, candidate in free do
		if candidate.index == selectedIndex then
			return {
				spawnIndex = candidate.index,
				origin = candidate.origin,
				telefragUserIds = {},
				usedTelefragFallback = false,
			}
		end
	end
	return nil
end

return table.freeze(SpawnSelection)
