--[[
SPDX-License-Identifier: GPL-2.0-or-later

Luau translation of Rocket Arena 3 spawn-side behavior from:
  ra3-sdk/code/game/arena.c
    SelectRandomArenaSpawnPoint
    clear_arena

Reference commit: 0693b7831ea303b2a93ec34c1802b33e684df046
Modified for the Roblox Luau port on 2026-07-19.
]]

--!strict

local RocketArenaSpawnRules = {}

export type TeamId = "Red" | "Blue"

local MAXIMUM_SOURCE_SPAWNS = 128

local function finiteVector(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return vector.X == vector.X
		and vector.Y == vector.Y
		and vector.Z == vector.Z
		and math.abs(vector.X) < math.huge
		and math.abs(vector.Y) < math.huge
		and math.abs(vector.Z) < math.huge
end

local function sourceHorizontalCoordinate(origin: Vector3, axis: "X" | "Y"): number
	-- The measured-map boundary transforms Q3 (X, Y, Z-up) into Roblox
	-- (X, Z-up, -Y). Restore the source horizontal coordinate for the exact
	-- SpotCompareX/SpotCompareY ordering.
	return if axis == "X" then origin.X else -origin.Z
end

function RocketArenaSpawnRules.ResolveAxis(origins: { Vector3 }): "X" | "Y"?
	if #origins < 2 or #origins > MAXIMUM_SOURCE_SPAWNS then
		return nil
	end
	local minimumX = math.huge
	local maximumX = -math.huge
	local minimumY = math.huge
	local maximumY = -math.huge
	for _, origin in origins do
		if not finiteVector(origin) then
			return nil
		end
		minimumX = math.min(minimumX, origin.X)
		maximumX = math.max(maximumX, origin.X)
		local sourceY = -origin.Z
		minimumY = math.min(minimumY, sourceY)
		maximumY = math.max(maximumY, sourceY)
	end
	-- arena.c chooses Y when the extents tie.
	return if maximumX - minimumX > maximumY - minimumY then "X" else "Y"
end

function RocketArenaSpawnRules.OrderIndices(
	originsByIndex: { [number]: Vector3 },
	indices: { number }
): ({ number }?, "X" | "Y"?)
	if #indices < 2 or #indices > MAXIMUM_SOURCE_SPAWNS then
		return nil, nil
	end
	local origins: { Vector3 } = {}
	local seen: { [number]: boolean } = {}
	for _, index in indices do
		if
			type(index) ~= "number"
			or index % 1 ~= 0
			or index < 1
			or seen[index]
			or not finiteVector(originsByIndex[index])
		then
			return nil, nil
		end
		seen[index] = true
		table.insert(origins, originsByIndex[index])
	end
	local axis = RocketArenaSpawnRules.ResolveAxis(origins)
	if not axis then
		return nil, nil
	end
	local ordered = table.clone(indices)
	table.sort(ordered, function(left: number, right: number): boolean
		local leftCoordinate = sourceHorizontalCoordinate(originsByIndex[left], axis)
		local rightCoordinate = sourceHorizontalCoordinate(originsByIndex[right], axis)
		if leftCoordinate ~= rightCoordinate then
			return leftCoordinate < rightCoordinate
		end
		return left < right
	end)
	return ordered, axis
end

function RocketArenaSpawnRules.SelectIndex(
	originsByIndex: { [number]: Vector3 },
	indices: { number },
	useNearHalf: boolean,
	roll: number
): number?
	if type(roll) ~= "number" or roll % 1 ~= 0 or roll < 0 then
		return nil
	end
	local ordered = RocketArenaSpawnRules.OrderIndices(originsByIndex, indices)
	if not ordered then
		return nil
	end
	local halfCount = math.floor(#ordered / 2)
	if halfCount < 1 then
		return nil
	end
	-- This intentionally leaves the final source spawn unreachable when the
	-- free count is odd, matching rand() % (numSpots / 2) and the far-half
	-- offset in SelectRandomArenaSpawnPoint.
	local offset = if useNearHalf then 0 else halfCount
	return ordered[offset + (roll % halfCount) + 1]
end

local function stableByteHash(value: string): number
	local hash = 2_166_136_261
	for index = 1, #value do
		hash = bit32.bxor(hash, string.byte(value, index))
		hash = bit32.band(hash * 16_777_619, 0xFFFFFFFF)
	end
	return hash
end

function RocketArenaSpawnRules.ResolveNearTeam(matchId: string, round: number): TeamId?
	if type(matchId) ~= "string" or matchId == "" or type(round) ~= "number" or round % 1 ~= 0 or round < 1 then
		return nil
	end
	-- RA3 uses one server rand() bit when clear_arena begins each round. The
	-- Roblox server's opaque match identity plus round produces the same
	-- server-owned, round-stable two-way choice without global RNG coupling.
	local bit = bit32.band(stableByteHash(matchId .. ":" .. tostring(round)), 1)
	return if bit == 1 then "Red" else "Blue"
end

RocketArenaSpawnRules.MaximumSourceSpawns = MAXIMUM_SOURCE_SPAWNS

return table.freeze(RocketArenaSpawnRules)
