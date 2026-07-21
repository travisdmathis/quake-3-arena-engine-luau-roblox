--[[
SPDX-License-Identifier: GPL-2.0-or-later

Data-only playerclip authority translated from Quake III Arena:
  code/game/bg_public.h (CONTENTS_PLAYERCLIP and MASK_PLAYERSOLID)
  code/qcommon/cm_trace.c (box trace startsolid/allsolid behavior)

Playerclip constrains player movement but is deliberately absent from
MASK_SHOT. This module therefore owns immutable authored AABBs without ever
creating a Workspace Instance. Movement and spawn code opt into this domain;
ordinary static-world and weapon queries cannot discover it accidentally.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-16.
]]

--!strict

local Constants = require(script.Parent.Constants)
local SweptAABB = require(script.Parent.SweptAABB)

export type Chunk = {
	id: string,
	position: Vector3,
	size: Vector3,
}

export type Domain = {}
export type Occupant = {}
export type TraceResult = SweptAABB.Result

type StoredChunk = {
	id: string,
	index: number,
	minimum: Vector3,
	maximum: Vector3,
	body: SweptAABB.Body,
	occupant: Occupant,
}

type DomainRecord = {
	chunks: { StoredChunk },
	cells: { [string]: { number } },
	globalIndices: { number },
}

local PlayerClipDomain = {}

local MAXIMUM_CHUNKS = 8192
local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_GEOMETRY_SIZE = 10_000
local MINIMUM_GEOMETRY_SIZE = 0.001
local CELL_SIZE = 32
local MAXIMUM_CELLS_PER_CHUNK = 4096
local MAXIMUM_CELLS_PER_QUERY = 4096
local OVERLAP_EPSILON = 1e-7

local CHUNK_KEYS = table.freeze({
	id = true,
	position = true,
	size = true,
}) :: { [string]: boolean }

local records: { [Domain]: DomainRecord } = setmetatable({}, { __mode = "k" }) :: any

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isBoundedVector(value: unknown, maximumComponent: number): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFiniteNumber(vector.X)
		and isFiniteNumber(vector.Y)
		and isFiniteNumber(vector.Z)
		and math.abs(vector.X) <= maximumComponent
		and math.abs(vector.Y) <= maximumComponent
		and math.abs(vector.Z) <= maximumComponent
end

local function isValidSize(value: unknown): boolean
	if not isBoundedVector(value, MAXIMUM_GEOMETRY_SIZE) then
		return false
	end
	local size = value :: Vector3
	return size.X >= MINIMUM_GEOMETRY_SIZE and size.Y >= MINIMUM_GEOMETRY_SIZE and size.Z >= MINIMUM_GEOMETRY_SIZE
end

local function isValidId(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function hasExactChunkKeys(value: { [unknown]: unknown }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or CHUNK_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 3
end

local function denseArrayLength(value: { [unknown]: unknown }): (number?, string?)
	local count = 0
	local maximumIndex = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "chunks-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > MAXIMUM_CHUNKS or maximumIndex > MAXIMUM_CHUNKS then
			return nil, "too-many-chunks"
		end
	end
	if maximumIndex ~= count then
		return nil, "chunks-not-dense-array"
	end
	return count, nil
end

local function geometryFitsWithinWorld(position: Vector3, size: Vector3): boolean
	local half = size * 0.5
	return math.abs(position.X) + half.X <= MAXIMUM_COORDINATE
		and math.abs(position.Y) + half.Y <= MAXIMUM_COORDINATE
		and math.abs(position.Z) + half.Z <= MAXIMUM_COORDINATE
end

local function cellCoordinate(value: number): number
	return math.floor(value / CELL_SIZE)
end

local function cellKey(x: number, y: number, z: number): string
	return string.format("%d:%d:%d", x, y, z)
end

local function cellCount(
	minimumX: number,
	maximumX: number,
	minimumY: number,
	maximumY: number,
	minimumZ: number,
	maximumZ: number
): number
	return (maximumX - minimumX + 1) * (maximumY - minimumY + 1) * (maximumZ - minimumZ + 1)
end

local function addChunkToIndex(cells: { [string]: { number } }, globalIndices: { number }, chunk: StoredChunk)
	local minimumX = cellCoordinate(chunk.minimum.X)
	local maximumX = cellCoordinate(chunk.maximum.X)
	local minimumY = cellCoordinate(chunk.minimum.Y)
	local maximumY = cellCoordinate(chunk.maximum.Y)
	local minimumZ = cellCoordinate(chunk.minimum.Z)
	local maximumZ = cellCoordinate(chunk.maximum.Z)
	if cellCount(minimumX, maximumX, minimumY, maximumY, minimumZ, maximumZ) > MAXIMUM_CELLS_PER_CHUNK then
		table.insert(globalIndices, chunk.index)
		return
	end
	for x = minimumX, maximumX do
		for y = minimumY, maximumY do
			for z = minimumZ, maximumZ do
				local key = cellKey(x, y, z)
				local indices = cells[key]
				if not indices then
					indices = {}
					cells[key] = indices
				end
				table.insert(indices, chunk.index)
			end
		end
	end
end

function PlayerClipDomain.Create(chunksValue: unknown): (Domain?, string?)
	if type(chunksValue) ~= "table" then
		return nil, "chunks-not-array"
	end
	local source = chunksValue :: { [unknown]: unknown }
	local count, countError = denseArrayLength(source)
	if count == nil then
		return nil, countError
	end

	local ids: { [string]: boolean } = {}
	local chunks: { StoredChunk } = {}
	local cells: { [string]: { number } } = {}
	local globalIndices: { number } = {}
	for index = 1, count do
		local value = source[index]
		if type(value) ~= "table" then
			return nil, string.format("chunk-%d:not-table", index)
		end
		local raw = value :: { [unknown]: unknown }
		if not hasExactChunkKeys(raw) then
			return nil, string.format("chunk-%d:invalid-shape", index)
		end
		if not isValidId(raw.id) then
			return nil, string.format("chunk-%d:invalid-id", index)
		end
		local id = raw.id :: string
		if ids[id] then
			return nil, string.format("chunk-%d:duplicate-id", index)
		end
		if not isBoundedVector(raw.position, MAXIMUM_COORDINATE) then
			return nil, string.format("chunk-%d:invalid-position", index)
		end
		if not isValidSize(raw.size) then
			return nil, string.format("chunk-%d:invalid-size", index)
		end
		local position = raw.position :: Vector3
		local size = raw.size :: Vector3
		if not geometryFitsWithinWorld(position, size) then
			return nil, string.format("chunk-%d:out-of-bounds", index)
		end

		ids[id] = true
		local occupant: Occupant = {}
		table.freeze(occupant)
		local body: SweptAABB.Body = {
			userId = index,
			origin = position,
			size = size,
			centerOffset = Vector3.zero,
			active = true,
		}
		table.freeze(body)
		local half = size * 0.5
		local chunk: StoredChunk = {
			id = id,
			index = index,
			minimum = position - half,
			maximum = position + half,
			body = body,
			occupant = occupant,
		}
		table.freeze(chunk)
		table.insert(chunks, chunk)
		addChunkToIndex(cells, globalIndices, chunk)
	end

	for _, indices in cells do
		table.freeze(indices)
	end
	table.freeze(cells)
	table.freeze(globalIndices)
	table.freeze(chunks)
	local handle: Domain = table.freeze({})
	records[handle] = {
		chunks = chunks,
		cells = cells,
		globalIndices = globalIndices,
	}
	return handle, nil
end

local function resolve(value: unknown): DomainRecord?
	if type(value) ~= "table" then
		return nil
	end
	local record = records[value :: Domain]
	if not record or not table.isfrozen(value :: any) then
		return nil
	end
	return record
end

function PlayerClipDomain.IsCurrent(value: unknown): boolean
	return resolve(value) ~= nil
end

function PlayerClipDomain.Count(value: unknown): number?
	local record = resolve(value)
	return if record then #record.chunks else nil
end

local function candidateIndices(record: DomainRecord, minimum: Vector3, maximum: Vector3): { number }
	local minimumX = cellCoordinate(minimum.X)
	local maximumX = cellCoordinate(maximum.X)
	local minimumY = cellCoordinate(minimum.Y)
	local maximumY = cellCoordinate(maximum.Y)
	local minimumZ = cellCoordinate(minimum.Z)
	local maximumZ = cellCoordinate(maximum.Z)
	if cellCount(minimumX, maximumX, minimumY, maximumY, minimumZ, maximumZ) > MAXIMUM_CELLS_PER_QUERY then
		local all: { number } = {}
		for index = 1, #record.chunks do
			table.insert(all, index)
		end
		return all
	end

	local seen: { [number]: boolean } = {}
	local indices: { number } = {}
	local function include(index: number)
		if not seen[index] then
			seen[index] = true
			table.insert(indices, index)
		end
	end
	for _, index in record.globalIndices do
		include(index)
	end
	for x = minimumX, maximumX do
		for y = minimumY, maximumY do
			for z = minimumZ, maximumZ do
				local cell = record.cells[cellKey(x, y, z)]
				if cell then
					for _, index in cell do
						include(index)
					end
				end
			end
		end
	end
	table.sort(indices)
	return indices
end

local function validQuery(origin: unknown, displacement: unknown, size: unknown, centerOffset: unknown): boolean
	return isBoundedVector(origin, MAXIMUM_COORDINATE)
		and isBoundedVector(displacement, MAXIMUM_COORDINATE * 2)
		and isValidSize(size)
		and isBoundedVector(centerOffset, MAXIMUM_GEOMETRY_SIZE)
end

function PlayerClipDomain.QueryBody(
	domainValue: unknown,
	originValue: unknown,
	sizeValue: unknown,
	centerOffsetValue: unknown
): ({ Occupant }?, string?)
	local record = resolve(domainValue)
	if not record then
		return nil, "invalid-domain"
	end
	if
		not isBoundedVector(originValue, MAXIMUM_COORDINATE)
		or not isValidSize(sizeValue)
		or not isBoundedVector(centerOffsetValue, MAXIMUM_GEOMETRY_SIZE)
	then
		return nil, "invalid-query"
	end
	local origin = originValue :: Vector3
	local size = sizeValue :: Vector3
	local centerOffset = centerOffsetValue :: Vector3
	local center = origin + centerOffset
	if not isBoundedVector(center, MAXIMUM_COORDINATE) then
		return nil, "query-out-of-bounds"
	end
	local skin = Constants.CollisionSkin * 2
	local querySize = Vector3.new(
		math.max(size.X - skin, MINIMUM_GEOMETRY_SIZE),
		math.max(size.Y - skin, MINIMUM_GEOMETRY_SIZE),
		math.max(size.Z - skin, MINIMUM_GEOMETRY_SIZE)
	)
	local half = querySize * 0.5
	local minimum = center - half
	local maximum = center + half
	local occupants: { Occupant } = {}
	for _, index in candidateIndices(record, minimum, maximum) do
		local chunk = record.chunks[index]
		if
			minimum.X < chunk.maximum.X - OVERLAP_EPSILON
			and maximum.X > chunk.minimum.X + OVERLAP_EPSILON
			and minimum.Y < chunk.maximum.Y - OVERLAP_EPSILON
			and maximum.Y > chunk.minimum.Y + OVERLAP_EPSILON
			and minimum.Z < chunk.maximum.Z - OVERLAP_EPSILON
			and maximum.Z > chunk.minimum.Z + OVERLAP_EPSILON
		then
			table.insert(occupants, chunk.occupant)
		end
	end
	return occupants, nil
end

function PlayerClipDomain.Trace(
	domainValue: unknown,
	originValue: unknown,
	displacementValue: unknown,
	sizeValue: unknown,
	centerOffsetValue: unknown
): (TraceResult?, string?)
	local record = resolve(domainValue)
	if not record then
		return nil, "invalid-domain"
	end
	if not validQuery(originValue, displacementValue, sizeValue, centerOffsetValue) then
		return nil, "invalid-query"
	end
	local origin = originValue :: Vector3
	local displacement = displacementValue :: Vector3
	local size = sizeValue :: Vector3
	local centerOffset = centerOffsetValue :: Vector3
	local start = origin + centerOffset
	local finish = start + displacement
	if not isBoundedVector(start, MAXIMUM_COORDINATE) or not isBoundedVector(finish, MAXIMUM_COORDINATE) then
		return nil, "trace-out-of-bounds"
	end
	local inset = Constants.StaticWorldSweepInset * 2
	local castSize = Vector3.new(
		math.max(size.X - inset, MINIMUM_GEOMETRY_SIZE),
		math.max(size.Y - inset, MINIMUM_GEOMETRY_SIZE),
		math.max(size.Z - inset, MINIMUM_GEOMETRY_SIZE)
	)
	local half = castSize * 0.5
	local minimum = Vector3.new(
		math.min(start.X, finish.X) - half.X,
		math.min(start.Y, finish.Y) - half.Y,
		math.min(start.Z, finish.Z) - half.Z
	)
	local maximum = Vector3.new(
		math.max(start.X, finish.X) + half.X,
		math.max(start.Y, finish.Y) + half.Y,
		math.max(start.Z, finish.Z) + half.Z
	)
	local bodies: { SweptAABB.Body } = {}
	for _, index in candidateIndices(record, minimum, maximum) do
		table.insert(bodies, record.chunks[index].body)
	end
	return SweptAABB.TraceBodies(origin, displacement, castSize, centerOffset, bodies), nil
end

PlayerClipDomain.MaximumChunks = MAXIMUM_CHUNKS
PlayerClipDomain.MaximumCoordinate = MAXIMUM_COORDINATE
PlayerClipDomain.MaximumGeometrySize = MAXIMUM_GEOMETRY_SIZE

return table.freeze(PlayerClipDomain)
