--[[
SPDX-License-Identifier: GPL-2.0-or-later

Data-only oriented Block trace boundary derived from:
  code/qcommon/cm_trace.c (box trace, startsolid, allsolid, brush planes)
  code/game/g_mover.c (rotated bmodel linking and G_TestEntityPosition)
  code/server/sv_world.c (source-ordered dynamic entity trace composition)

the Roblox Luau port represents one authored rectangular mover brush as an oriented
Block. Continuous SAT over the three world axes, three Block axes, and nine
cross axes is the exact collision adapter for a translating world-axis-aligned
body hull against that fixed oriented Block pose. Stable axis and source order,
strict boundary contact, bounded immutable inputs, and CFrame validation are
original the Roblox Luau port adaptations.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

export type OrderedBlock = {
	id: string,
	sourceOrder: number,
	cframe: CFrame,
	size: Vector3,
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

local SweptAABBOrientedBlock = {}

local EPSILON = 1e-7
local AXIS_EPSILON = 1e-10
local MAXIMUM_BLOCKS = 512
local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_GEOMETRY_SIZE = 10_000
local MAXIMUM_SOURCE_ORDER = 2_147_483_647
local MAXIMUM_CONTENTS_MASK = 4_294_967_295
local MINIMUM_GEOMETRY_SIZE = 0.001

local BLOCK_KEYS: { [string]: boolean } = table.freeze({
	id = true,
	sourceOrder = true,
	cframe = true,
	size = true,
	contents = true,
	active = true,
})

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return isFiniteNumber(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isBoundedVector(value: unknown, maximum: number): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFiniteNumber(vector.X)
		and isFiniteNumber(vector.Y)
		and isFiniteNumber(vector.Z)
		and math.abs(vector.X) <= maximum
		and math.abs(vector.Y) <= maximum
		and math.abs(vector.Z) <= maximum
end

local function isValidSize(value: unknown): boolean
	if not isBoundedVector(value, MAXIMUM_GEOMETRY_SIZE) then
		return false
	end
	local size = value :: Vector3
	return size.X >= MINIMUM_GEOMETRY_SIZE and size.Y >= MINIMUM_GEOMETRY_SIZE and size.Z >= MINIMUM_GEOMETRY_SIZE
end

local function isFiniteCFrame(value: unknown): boolean
	if typeof(value) ~= "CFrame" then
		return false
	end
	for _, component in { (value :: CFrame):GetComponents() } do
		if not isFiniteNumber(component) then
			return false
		end
	end
	return isBoundedVector((value :: CFrame).Position, MAXIMUM_COORDINATE)
end

local function isValidId(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function hasExactKeys(value: { [unknown]: unknown }): boolean
	local count = 0
	for key in value do
		if type(key) ~= "string" or BLOCK_KEYS[key] ~= true then
			return false
		end
		count += 1
	end
	return count == 6
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

local function validateBlock(value: unknown): (OrderedBlock?, string?)
	if type(value) ~= "table" then
		return nil, "block-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not hasExactKeys(source) then
		return nil, "invalid-block-shape"
	end
	if not isValidId(source.id) then
		return nil, "invalid-block-id"
	end
	if not isIntegerInRange(source.sourceOrder, 1, MAXIMUM_SOURCE_ORDER) then
		return nil, "invalid-block-source-order"
	end
	if not isFiniteCFrame(source.cframe) then
		return nil, "invalid-block-cframe"
	end
	if not isValidSize(source.size) then
		return nil, "invalid-block-size"
	end
	if not isIntegerInRange(source.contents, 0, MAXIMUM_CONTENTS_MASK) then
		return nil, "invalid-block-contents"
	end
	if type(source.active) ~= "boolean" then
		return nil, "invalid-block-active"
	end
	local radius = ((source.size :: Vector3) * 0.5).Magnitude
	local center = (source.cframe :: CFrame).Position
	if
		math.abs(center.X) + radius > MAXIMUM_COORDINATE
		or math.abs(center.Y) + radius > MAXIMUM_COORDINATE
		or math.abs(center.Z) + radius > MAXIMUM_COORDINATE
	then
		return nil, "block-out-of-bounds"
	end
	local block: OrderedBlock = {
		id = source.id :: string,
		sourceOrder = source.sourceOrder :: number,
		cframe = source.cframe :: CFrame,
		size = source.size :: Vector3,
		contents = source.contents :: number,
		active = source.active :: boolean,
	}
	table.freeze(block)
	return block, nil
end

function SweptAABBOrientedBlock.ValidateAndOrderBlocks(value: unknown): ({ OrderedBlock }?, string?)
	if type(value) ~= "table" then
		return nil, "blocks-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local count, countError = denseArrayLength(source)
	if not count then
		return nil, countError
	end
	local blocks: { OrderedBlock } = {}
	local ids: { [string]: boolean } = {}
	local sourceOrders: { [number]: boolean } = {}
	for index = 1, count do
		local block, blockError = validateBlock(source[index])
		if not block then
			return nil, string.format("block-%d:%s", index, blockError or "invalid")
		end
		if ids[block.id] then
			return nil, string.format("block-%d:duplicate-block-id", index)
		end
		if sourceOrders[block.sourceOrder] then
			return nil, string.format("block-%d:duplicate-source-order", index)
		end
		ids[block.id] = true
		sourceOrders[block.sourceOrder] = true
		table.insert(blocks, block)
	end
	table.sort(blocks, function(left, right): boolean
		return left.sourceOrder < right.sourceOrder
	end)
	table.freeze(blocks)
	return blocks, nil
end

local function axesFor(cframe: CFrame): { Vector3 }
	local blockAxes = { cframe.XVector, cframe.YVector, cframe.ZVector }
	local worldAxes = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }
	local axes: { Vector3 } = table.create(15)
	for _, axis in worldAxes do
		table.insert(axes, axis)
	end
	for _, axis in blockAxes do
		table.insert(axes, axis)
	end
	for _, worldAxis in worldAxes do
		for _, blockAxis in blockAxes do
			local cross = worldAxis:Cross(blockAxis)
			if cross.Magnitude > AXIS_EPSILON then
				table.insert(axes, cross.Unit)
			end
		end
	end
	return axes
end

local function projectionRadius(half: Vector3, axes: { Vector3 }, axis: Vector3): number
	return half.X * math.abs(axes[1]:Dot(axis))
		+ half.Y * math.abs(axes[2]:Dot(axis))
		+ half.Z * math.abs(axes[3]:Dot(axis))
end

local function traceBlock(
	start: Vector3,
	displacement: Vector3,
	movingHalf: Vector3,
	block: OrderedBlock
): OrderedResult
	local worldAxes = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }
	local blockAxes = { block.cframe.XVector, block.cframe.YVector, block.cframe.ZVector }
	local blockHalf = block.size * 0.5
	local relativeStart = start - block.cframe.Position
	local axes = axesFor(block.cframe)
	local startSolid = true
	local endSolid = true
	local enter = 0
	local exit = 1
	local normal = Vector3.zero
	for _, axis in axes do
		local radius = projectionRadius(movingHalf, worldAxes, axis) + projectionRadius(blockHalf, blockAxes, axis)
		local strictRadius = math.max(radius - EPSILON, 0)
		local coordinate = relativeStart:Dot(axis)
		local delta = displacement:Dot(axis)
		if math.abs(coordinate) >= strictRadius then
			startSolid = false
		end
		if math.abs(coordinate + delta) >= strictRadius then
			endSolid = false
		end
		if math.abs(delta) <= EPSILON then
			if math.abs(coordinate) >= strictRadius then
				return {
					hit = false,
					fraction = 1,
					normal = Vector3.yAxis,
					startSolid = false,
					allSolid = false,
					contact = nil,
				}
			end
			continue
		end
		local first = (-radius - coordinate) / delta
		local second = (radius - coordinate) / delta
		local entryNormal = -axis
		if first > second then
			first, second = second, first
			entryNormal = axis
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
				contact = nil,
			}
		end
	end
	local contact: OrderedContact = table.freeze({
		id = block.id,
		sourceOrder = block.sourceOrder,
		contents = block.contents,
	})
	if startSolid then
		return {
			hit = endSolid,
			fraction = if endSolid then 0 else 1,
			normal = Vector3.yAxis,
			startSolid = true,
			allSolid = endSolid,
			contact = contact,
		}
	end
	if enter < 0 or enter > 1 or normal.Magnitude <= EPSILON then
		return {
			hit = false,
			fraction = 1,
			normal = Vector3.yAxis,
			startSolid = false,
			allSolid = false,
			contact = nil,
		}
	end
	return {
		hit = true,
		fraction = math.clamp(enter, 0, 1),
		normal = normal,
		startSolid = false,
		allSolid = false,
		contact = contact,
	}
end

local function validateQuery(
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
	local size = movingSizeValue :: Vector3
	local centerOffset = movingCenterOffsetValue :: Vector3
	local start = origin + centerOffset
	local finish = start + displacement
	local radius = (size * 0.5).Magnitude
	if
		not isBoundedVector(start, MAXIMUM_COORDINATE)
		or not isBoundedVector(finish, MAXIMUM_COORDINATE)
		or math.abs(start.X) + radius > MAXIMUM_COORDINATE
		or math.abs(start.Y) + radius > MAXIMUM_COORDINATE
		or math.abs(start.Z) + radius > MAXIMUM_COORDINATE
		or math.abs(finish.X) + radius > MAXIMUM_COORDINATE
		or math.abs(finish.Y) + radius > MAXIMUM_COORDINATE
		or math.abs(finish.Z) + radius > MAXIMUM_COORDINATE
	then
		return nil, nil, nil, nil, nil, "trace-out-of-bounds"
	end
	return origin, displacement, size, centerOffset, clipMaskValue :: number, nil
end

local function frozenResult(result: OrderedResult): OrderedResult
	if result.contact and not table.isfrozen(result.contact) then
		table.freeze(result.contact)
	end
	table.freeze(result)
	return result
end

function SweptAABBOrientedBlock.TraceOrderedBlocks(
	originValue: unknown,
	displacementValue: unknown,
	movingSizeValue: unknown,
	movingCenterOffsetValue: unknown,
	blocksValue: unknown,
	clipMaskValue: unknown
): (OrderedResult?, string?)
	local origin, displacement, movingSize, centerOffset, clipMask, queryError =
		validateQuery(originValue, displacementValue, movingSizeValue, movingCenterOffsetValue, clipMaskValue)
	if not origin then
		return nil, queryError
	end
	local blocks, blocksError = SweptAABBOrientedBlock.ValidateAndOrderBlocks(blocksValue)
	if not blocks then
		return nil, blocksError
	end
	local best: OrderedResult = {
		hit = false,
		fraction = 1,
		normal = Vector3.yAxis,
		startSolid = false,
		allSolid = false,
		contact = nil,
	}
	local startSolid = false
	for _, block in blocks do
		if not block.active or bit32.band(clipMask :: number, block.contents) == 0 then
			continue
		end
		local candidate = traceBlock(
			(origin :: Vector3) + (centerOffset :: Vector3),
			displacement :: Vector3,
			(movingSize :: Vector3) * 0.5,
			block
		)
		if candidate.startSolid then
			startSolid = true
		end
		if candidate.allSolid then
			return frozenResult(candidate), nil
		end
		if candidate.hit and candidate.fraction < best.fraction then
			best = candidate
		end
	end
	best.startSolid = startSolid
	return frozenResult(best), nil
end

function SweptAABBOrientedBlock.PointContentsOrderedBlocks(
	blocksValue: unknown,
	pointValue: unknown
): (number?, string?)
	if not isBoundedVector(pointValue, MAXIMUM_COORDINATE) then
		return nil, "invalid-point"
	end
	local blocks, blocksError = SweptAABBOrientedBlock.ValidateAndOrderBlocks(blocksValue)
	if not blocks then
		return nil, blocksError
	end
	local point = pointValue :: Vector3
	local contents = 0
	for _, block in blocks do
		if not block.active then
			continue
		end
		local localPoint = block.cframe:PointToObjectSpace(point)
		local half = block.size * 0.5
		if
			math.abs(localPoint.X) < half.X - EPSILON
			and math.abs(localPoint.Y) < half.Y - EPSILON
			and math.abs(localPoint.Z) < half.Z - EPSILON
		then
			contents = bit32.bor(contents, block.contents)
		end
	end
	return contents, nil
end

SweptAABBOrientedBlock.MaximumOrderedBlocks = MAXIMUM_BLOCKS
SweptAABBOrientedBlock.MaximumCoordinate = MAXIMUM_COORDINATE
SweptAABBOrientedBlock.MaximumGeometrySize = MAXIMUM_GEOMETRY_SIZE
SweptAABBOrientedBlock.MaximumSourceOrder = MAXIMUM_SOURCE_ORDER

return table.freeze(SweptAABBOrientedBlock)
