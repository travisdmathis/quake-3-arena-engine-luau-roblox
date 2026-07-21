--[[
SPDX-License-Identifier: GPL-2.0-or-later

Data-only Roblox/Luau adaptation of player-solid box trace behavior from:
  code/qcommon/cm_trace.c (box sweep/startsolid concepts)
  code/game/bg_slidemove.c (startsolid/allsolid consumers)
  code/game/bg_public.h (MASK_PLAYERSOLID / CONTENTS_BODY)

The slab implementation and stable user-id tie break are original the Roblox Luau port
adaptations used identically by server movement and client prediction. The
strict frozen ordered-block boundary extends that same primitive to bounded
dynamic geometry without changing the existing player-body API.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

export type Body = {
	userId: number,
	origin: Vector3,
	size: Vector3,
	centerOffset: Vector3,
	active: boolean,
}

export type Result = {
	hit: boolean,
	fraction: number,
	normal: Vector3,
	startSolid: boolean,
	allSolid: boolean,
	userId: number?,
}

export type OrderedBlock = {
	id: string,
	sourceOrder: number,
	origin: Vector3,
	size: Vector3,
	centerOffset: Vector3,
	contents: number,
	active: boolean,
}

export type OrderedContact = {
	id: string,
	sourceOrder: number,
	contents: number,
}

export type OrderedResult = {
	hit: boolean,
	fraction: number,
	normal: Vector3,
	startSolid: boolean,
	allSolid: boolean,
	contact: OrderedContact?,
}

local SweptAABB = {}
local EPSILON = 1e-7
local MAXIMUM_BLOCKS = 512
local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_GEOMETRY_SIZE = 10_000
local MAXIMUM_SOURCE_ORDER = 2_147_483_647
local MAXIMUM_CONTENTS_MASK = 4_294_967_295
local MINIMUM_GEOMETRY_SIZE = 0.001

local ORDERED_BLOCK_KEYS: { [string]: boolean } = {
	id = true,
	sourceOrder = true,
	origin = true,
	size = true,
	centerOffset = true,
	contents = true,
	active = true,
}
table.freeze(ORDERED_BLOCK_KEYS)

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return isFiniteNumber(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
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

local function geometryFitsWithinWorld(center: Vector3, size: Vector3): boolean
	local half = size * 0.5
	return math.abs(center.X) + half.X <= MAXIMUM_COORDINATE
		and math.abs(center.Y) + half.Y <= MAXIMUM_COORDINATE
		and math.abs(center.Z) + half.Z <= MAXIMUM_COORDINATE
end

local function isValidId(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function hasExactOrderedBlockKeys(value: { [unknown]: unknown }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or ORDERED_BLOCK_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 7
end

local function denseArrayLength(value: { [unknown]: unknown }): (number?, string?)
	local count = 0
	local maximumIndex = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "blocks-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > MAXIMUM_BLOCKS or maximumIndex > MAXIMUM_BLOCKS then
			return nil, "too-many-blocks"
		end
	end
	if maximumIndex ~= count then
		return nil, "blocks-not-dense-array"
	end
	return count, nil
end

local function validateOrderedBlock(value: unknown): (OrderedBlock?, string?)
	if type(value) ~= "table" then
		return nil, "block-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not hasExactOrderedBlockKeys(source) then
		return nil, "invalid-block-shape"
	end
	if not isValidId(source.id) then
		return nil, "invalid-block-id"
	end
	if not isIntegerInRange(source.sourceOrder, 1, MAXIMUM_SOURCE_ORDER) then
		return nil, "invalid-block-source-order"
	end
	if not isBoundedVector(source.origin, MAXIMUM_COORDINATE) then
		return nil, "invalid-block-origin"
	end
	if not isValidSize(source.size) then
		return nil, "invalid-block-size"
	end
	if not isBoundedVector(source.centerOffset, MAXIMUM_GEOMETRY_SIZE) then
		return nil, "invalid-block-center-offset"
	end
	if not isIntegerInRange(source.contents, 0, MAXIMUM_CONTENTS_MASK) then
		return nil, "invalid-block-contents"
	end
	if type(source.active) ~= "boolean" then
		return nil, "invalid-block-active"
	end
	local center = (source.origin :: Vector3) + (source.centerOffset :: Vector3)
	if
		not isBoundedVector(center, MAXIMUM_COORDINATE) or not geometryFitsWithinWorld(center, source.size :: Vector3)
	then
		return nil, "block-center-out-of-bounds"
	end

	local block: OrderedBlock = {
		id = source.id :: string,
		sourceOrder = source.sourceOrder :: number,
		origin = source.origin :: Vector3,
		size = source.size :: Vector3,
		centerOffset = source.centerOffset :: Vector3,
		contents = source.contents :: number,
		active = source.active :: boolean,
	}
	table.freeze(block)
	return block, nil
end

local function strictlyInside(point: Vector3, minimum: Vector3, maximum: Vector3): boolean
	return point.X > minimum.X + EPSILON
		and point.X < maximum.X - EPSILON
		and point.Y > minimum.Y + EPSILON
		and point.Y < maximum.Y - EPSILON
		and point.Z > minimum.Z + EPSILON
		and point.Z < maximum.Z - EPSILON
end

local function traceBody(
	origin: Vector3,
	displacement: Vector3,
	movingSize: Vector3,
	movingCenterOffset: Vector3,
	body: Body
): Result
	local start = origin + movingCenterOffset
	local targetCenter = body.origin + body.centerOffset
	local expandedHalf = (movingSize + body.size) * 0.5
	local minimum = targetCenter - expandedHalf
	local maximum = targetCenter + expandedHalf
	local startSolid = strictlyInside(start, minimum, maximum)
	if startSolid then
		local allSolid = strictlyInside(start + displacement, minimum, maximum)
		return {
			hit = allSolid,
			fraction = if allSolid then 0 else 1,
			normal = Vector3.yAxis,
			startSolid = true,
			allSolid = allSolid,
			userId = body.userId,
		}
	end

	local enter = 0
	local exit = 1
	local normal = Vector3.zero
	local axes = {
		{ start.X, displacement.X, minimum.X, maximum.X, Vector3.xAxis },
		{ start.Y, displacement.Y, minimum.Y, maximum.Y, Vector3.yAxis },
		{ start.Z, displacement.Z, minimum.Z, maximum.Z, Vector3.zAxis },
	}
	for _, axis in axes do
		local coordinate = axis[1]
		local delta = axis[2]
		local low = axis[3]
		local high = axis[4]
		local direction = axis[5]
		if math.abs(delta) <= EPSILON then
			if coordinate <= low + EPSILON or coordinate >= high - EPSILON then
				return {
					hit = false,
					fraction = 1,
					normal = Vector3.yAxis,
					startSolid = false,
					allSolid = false,
					userId = nil,
				}
			end
			continue
		end

		local first = (low - coordinate) / delta
		local second = (high - coordinate) / delta
		local entryNormal = -direction
		if first > second then
			first, second = second, first
			entryNormal = direction
		end
		if first > enter or (math.abs(first - enter) <= EPSILON and normal.Magnitude <= EPSILON) then
			enter = first
			normal = entryNormal
		end
		exit = math.min(exit, second)
		if enter > exit then
			return {
				hit = false,
				fraction = 1,
				normal = Vector3.yAxis,
				startSolid = false,
				allSolid = false,
				userId = nil,
			}
		end
	end

	if enter < 0 or enter > 1 or normal.Magnitude <= EPSILON then
		return {
			hit = false,
			fraction = 1,
			normal = Vector3.yAxis,
			startSolid = false,
			allSolid = false,
			userId = nil,
		}
	end
	return {
		hit = true,
		fraction = math.clamp(enter, 0, 1),
		normal = normal,
		startSolid = false,
		allSolid = false,
		userId = body.userId,
	}
end

function SweptAABB.TraceBodies(
	origin: Vector3,
	displacement: Vector3,
	movingSize: Vector3,
	movingCenterOffset: Vector3,
	bodies: { Body }
): Result
	local best: Result = {
		hit = false,
		fraction = 1,
		normal = Vector3.yAxis,
		startSolid = false,
		allSolid = false,
		userId = nil,
	}
	local startSolid = false
	local startSolidUserId: number? = nil
	local allSolid: Result? = nil
	for _, body in bodies do
		if not body.active then
			continue
		end
		local candidate = traceBody(origin, displacement, movingSize, movingCenterOffset, body)
		if candidate.startSolid then
			startSolid = true
			if startSolidUserId == nil or body.userId < startSolidUserId then
				startSolidUserId = body.userId
			end
		end
		if candidate.allSolid then
			if not allSolid or body.userId < (allSolid.userId or math.huge) then
				allSolid = candidate
			end
			continue
		end
		if
			candidate.hit
			and (
				candidate.fraction < best.fraction
				or (
					candidate.fraction == best.fraction
					and (best.userId == nil or (candidate.userId or math.huge) < best.userId)
				)
			)
		then
			best = candidate
		end
	end
	if allSolid then
		return {
			hit = true,
			fraction = 0,
			normal = allSolid.normal,
			startSolid = true,
			allSolid = true,
			userId = allSolid.userId,
		}
	end
	return {
		hit = best.hit,
		fraction = best.fraction,
		normal = best.normal,
		startSolid = startSolid,
		allSolid = false,
		userId = best.userId or startSolidUserId,
	}
end

function SweptAABB.ValidateAndOrderBlocks(value: unknown): ({ OrderedBlock }?, string?)
	if type(value) ~= "table" then
		return nil, "blocks-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local count, arrayError = denseArrayLength(source)
	if not count then
		return nil, arrayError
	end

	local blocks: { OrderedBlock } = {}
	local observedIds: { [string]: boolean } = {}
	local observedSourceOrders: { [number]: boolean } = {}
	for index = 1, count do
		local block, blockError = validateOrderedBlock(source[index])
		if not block then
			return nil, string.format("block-%d:%s", index, blockError or "invalid")
		end
		if observedIds[block.id] then
			return nil, string.format("block-%d:duplicate-block-id", index)
		end
		if observedSourceOrders[block.sourceOrder] then
			return nil, string.format("block-%d:duplicate-source-order", index)
		end
		observedIds[block.id] = true
		observedSourceOrders[block.sourceOrder] = true
		table.insert(blocks, block)
	end
	table.sort(blocks, function(left, right): boolean
		return left.sourceOrder < right.sourceOrder
	end)
	table.freeze(blocks)
	return blocks, nil
end

local function validateOrderedTraceQuery(
	originValue: unknown,
	displacementValue: unknown,
	movingSizeValue: unknown,
	movingCenterOffsetValue: unknown,
	clipMaskValue: unknown
): (Vector3?, Vector3?, Vector3?, Vector3?, number?, string?)
	if not isBoundedVector(originValue, MAXIMUM_COORDINATE) then
		return nil, nil, nil, nil, nil, "invalid-trace-origin"
	end
	if not isBoundedVector(displacementValue, MAXIMUM_COORDINATE * 2) then
		return nil, nil, nil, nil, nil, "invalid-trace-displacement"
	end
	if not isValidSize(movingSizeValue) then
		return nil, nil, nil, nil, nil, "invalid-trace-size"
	end
	if not isBoundedVector(movingCenterOffsetValue, MAXIMUM_GEOMETRY_SIZE) then
		return nil, nil, nil, nil, nil, "invalid-trace-center-offset"
	end
	if not isIntegerInRange(clipMaskValue, 0, MAXIMUM_CONTENTS_MASK) then
		return nil, nil, nil, nil, nil, "invalid-trace-clip-mask"
	end

	local origin = originValue :: Vector3
	local displacement = displacementValue :: Vector3
	local movingSize = movingSizeValue :: Vector3
	local movingCenterOffset = movingCenterOffsetValue :: Vector3
	local startCenter = origin + movingCenterOffset
	local endCenter = startCenter + displacement
	if
		not isBoundedVector(startCenter, MAXIMUM_COORDINATE)
		or not isBoundedVector(endCenter, MAXIMUM_COORDINATE)
		or not geometryFitsWithinWorld(startCenter, movingSize)
		or not geometryFitsWithinWorld(endCenter, movingSize)
	then
		return nil, nil, nil, nil, nil, "trace-out-of-bounds"
	end
	return origin, displacement, movingSize, movingCenterOffset, clipMaskValue :: number, nil
end

local function frozenContact(block: OrderedBlock): OrderedContact
	local contact: OrderedContact = {
		id = block.id,
		sourceOrder = block.sourceOrder,
		contents = block.contents,
	}
	table.freeze(contact)
	return contact
end

local function frozenOrderedResult(
	hit: boolean,
	fraction: number,
	normal: Vector3,
	startSolid: boolean,
	allSolid: boolean,
	contact: OrderedContact?
): OrderedResult
	local result: OrderedResult = {
		hit = hit,
		fraction = fraction,
		normal = normal,
		startSolid = startSolid,
		allSolid = allSolid,
		contact = contact,
	}
	table.freeze(result)
	return result
end

function SweptAABB.TraceOrderedBlocks(
	originValue: unknown,
	displacementValue: unknown,
	movingSizeValue: unknown,
	movingCenterOffsetValue: unknown,
	blocksValue: unknown,
	clipMaskValue: unknown
): (OrderedResult?, string?)
	local origin, displacement, movingSize, movingCenterOffset, clipMask, queryError = validateOrderedTraceQuery(
		originValue,
		displacementValue,
		movingSizeValue,
		movingCenterOffsetValue,
		clipMaskValue
	)
	if not origin then
		return nil, queryError
	end
	local blocks, blocksError = SweptAABB.ValidateAndOrderBlocks(blocksValue)
	if not blocks then
		return nil, blocksError
	end

	local best = frozenOrderedResult(false, 1, Vector3.yAxis, false, false, nil)
	local startSolid = false
	for _, block in blocks do
		if not block.active or bit32.band(clipMask :: number, block.contents) == 0 then
			continue
		end
		local candidate = traceBody(
			origin :: Vector3,
			displacement :: Vector3,
			movingSize :: Vector3,
			movingCenterOffset :: Vector3,
			{
				userId = block.sourceOrder,
				origin = block.origin,
				size = block.size,
				centerOffset = block.centerOffset,
				active = true,
			}
		)
		startSolid = startSolid or candidate.startSolid
		if candidate.allSolid then
			return frozenOrderedResult(true, 0, candidate.normal, true, true, frozenContact(block)), nil
		end
		-- Inputs are sorted by explicit source order. Q3 replaces a dynamic
		-- trace only for a strictly smaller fraction, so equal-time contacts
		-- deliberately retain the first source entity.
		if candidate.hit and candidate.fraction < best.fraction then
			best = frozenOrderedResult(true, candidate.fraction, candidate.normal, false, false, frozenContact(block))
		end
	end

	return frozenOrderedResult(best.hit, best.fraction, best.normal, startSolid, false, best.contact), nil
end

function SweptAABB.PointContentsOrderedBlocks(blocksValue: unknown, pointValue: unknown): (number?, string?)
	if not isBoundedVector(pointValue, MAXIMUM_COORDINATE) then
		return nil, "invalid-point"
	end
	local blocks, blocksError = SweptAABB.ValidateAndOrderBlocks(blocksValue)
	if not blocks then
		return nil, blocksError
	end

	local point = pointValue :: Vector3
	local contents = 0
	for _, block in blocks do
		if not block.active then
			continue
		end
		local center = block.origin + block.centerOffset
		local half = block.size * 0.5
		if strictlyInside(point, center - half, center + half) then
			contents = bit32.bor(contents, block.contents)
		end
	end
	return contents, nil
end

SweptAABB.MaximumOrderedBlocks = MAXIMUM_BLOCKS
SweptAABB.MaximumCoordinate = MAXIMUM_COORDINATE
SweptAABB.MaximumGeometrySize = MAXIMUM_GEOMETRY_SIZE
SweptAABB.MaximumSourceOrder = MAXIMUM_SOURCE_ORDER

return table.freeze(SweptAABB)
