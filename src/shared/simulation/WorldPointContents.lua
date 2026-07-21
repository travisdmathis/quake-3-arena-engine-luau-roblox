--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox point-contents adapter for Quake III world queries from:
  code/game/surfaceflags.h (CONTENTS_SOLID, CONTENTS_LAVA,
  CONTENTS_SLIME, CONTENTS_WATER, CONTENTS_NODROP)
  code/game/bg_public.h (MASK_WATER)
  code/qcommon/cm_test.c (CM_PointContents, CM_TransformedPointContents)
  code/server/sv_world.c (SV_PointContents overlap union)

The bounded authored-volume representation, immutable startup collection, and
unparented exact solid probe are original the Roblox Luau port adaptations shared by
server authority and client prediction.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Workspace = game:GetService("Workspace")

local PersistentStaticSolidDomain = require(script.Parent.PersistentStaticSolidDomain)

export type WaterVolume = {
	id: string,
	cframe: CFrame,
	size: Vector3,
	contents: number,
}
export type NoDropVolume = WaterVolume

export type PointContentsFunction = (point: Vector3) -> number

local WorldPointContents = {}

-- Preserve the engine bit values so the same masks and overlap-union behavior
-- can be translated directly from Q3 movement and presentation code.
local Contents = table.freeze({
	Solid = 1,
	Lava = 8,
	Slime = 16,
	Water = 32,
	NoDrop = 2_147_483_648,
})

local EMPTY = 0
local MASK_WATER = bit32.bor(Contents.Water, Contents.Slime, Contents.Lava)
local MAXIMUM_WATER_VOLUMES = 256
local MAXIMUM_NO_DROP_VOLUMES = 256
local MAXIMUM_COORDINATE = 100_000
local MAXIMUM_VOLUME_SIZE = 10_000
local MINIMUM_VOLUME_SIZE = 0.001
local POINT_EPSILON = 1e-6
local SOLID_PROBE_SIZE = Vector3.one * 0.001
local FAIL_CLOSED_CONTENTS = bit32.bor(Contents.Solid, Contents.NoDrop)

local Attributes = table.freeze({
	Marker = "ArenaWaterVolume",
	NoDropMarker = "ArenaNoDropVolume",
	EntityId = "ArenaMapEntityId",
	Contents = "ArenaPointContents",
	WaterVolumeCount = "ArenaWaterVolumeCount",
	NoDropVolumeCount = "ArenaNoDropVolumeCount",
})

local DEFINITION_KEYS: { [string]: boolean } = {
	id = true,
	cframe = true,
	size = true,
	contents = true,
}
table.freeze(DEFINITION_KEYS)

local function isFinite(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isBoundedVector(value: unknown, maximumComponent: number): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFinite(vector.X)
		and isFinite(vector.Y)
		and isFinite(vector.Z)
		and math.abs(vector.X) <= maximumComponent
		and math.abs(vector.Y) <= maximumComponent
		and math.abs(vector.Z) <= maximumComponent
end

local function isValidSize(value: unknown): boolean
	if not isBoundedVector(value, MAXIMUM_VOLUME_SIZE) then
		return false
	end
	local size = value :: Vector3
	return size.X >= MINIMUM_VOLUME_SIZE and size.Y >= MINIMUM_VOLUME_SIZE and size.Z >= MINIMUM_VOLUME_SIZE
end

local function isValidCFrame(value: unknown): boolean
	if typeof(value) ~= "CFrame" then
		return false
	end
	local components = { (value :: CFrame):GetComponents() }
	for index, component in components do
		if not isFinite(component) then
			return false
		end
		if index <= 3 and math.abs(component :: number) > MAXIMUM_COORDINATE then
			return false
		end
		if index > 3 and math.abs(component :: number) > 1 + POINT_EPSILON then
			return false
		end
	end
	return true
end

local function isValidId(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function isWaterContentBit(value: unknown): boolean
	return value == Contents.Water or value == Contents.Slime or value == Contents.Lava
end

local function hasExactDefinitionKeys(value: { [unknown]: unknown }): boolean
	local observed = 0
	for key in value do
		if type(key) ~= "string" or DEFINITION_KEYS[key] ~= true then
			return false
		end
		observed += 1
	end
	return observed == 4
end

local function denseArrayLength(value: { [unknown]: unknown }, maximumVolumes: number): (number?, string?)
	local count = 0
	local maximumIndex = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, "volumes-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > maximumVolumes or maximumIndex > maximumVolumes then
			return nil, "too-many-volumes"
		end
	end
	if maximumIndex ~= count then
		return nil, "volumes-not-dense-array"
	end
	return count, nil
end

local function validateVolume(value: unknown, validateContents: (unknown) -> boolean): (WaterVolume?, string?)
	if type(value) ~= "table" then
		return nil, "volume-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not hasExactDefinitionKeys(source) then
		return nil, "invalid-volume-shape"
	end
	if not isValidId(source.id) then
		return nil, "invalid-volume-id"
	end
	if not isValidCFrame(source.cframe) then
		return nil, "invalid-volume-cframe"
	end
	if not isValidSize(source.size) then
		return nil, "invalid-volume-size"
	end
	if not validateContents(source.contents) then
		return nil, "invalid-volume-contents"
	end

	local volume: WaterVolume = {
		id = source.id :: string,
		cframe = source.cframe :: CFrame,
		size = source.size :: Vector3,
		contents = source.contents :: number,
	}
	return table.freeze(volume), nil
end

function WorldPointContents.ValidateAndOrderWaterVolumes(value: unknown): ({ WaterVolume }?, string?)
	if type(value) ~= "table" then
		return nil, "volumes-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local count, arrayError = denseArrayLength(source, MAXIMUM_WATER_VOLUMES)
	if not count then
		return nil, arrayError
	end

	local volumes: { WaterVolume } = {}
	local observedIds: { [string]: boolean } = {}
	for index = 1, count do
		local volume, volumeError = validateVolume(source[index], isWaterContentBit)
		if not volume then
			return nil, string.format("volume-%d:%s", index, volumeError or "invalid")
		end
		if observedIds[volume.id] then
			return nil, string.format("volume-%d:duplicate-volume-id", index)
		end
		observedIds[volume.id] = true
		table.insert(volumes, volume)
	end

	table.sort(volumes, function(left, right)
		return left.id < right.id
	end)
	return table.freeze(volumes), nil
end

function WorldPointContents.ValidateAndOrderNoDropVolumes(value: unknown): ({ NoDropVolume }?, string?)
	if type(value) ~= "table" then
		return nil, "volumes-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local count, arrayError = denseArrayLength(source, MAXIMUM_NO_DROP_VOLUMES)
	if not count then
		return nil, arrayError
	end

	local volumes: { NoDropVolume } = {}
	local observedIds: { [string]: boolean } = {}
	for index = 1, count do
		local volume, volumeError = validateVolume(source[index], function(contents: unknown): boolean
			return contents == Contents.NoDrop
		end)
		if not volume then
			return nil, string.format("volume-%d:%s", index, volumeError or "invalid")
		end
		if observedIds[volume.id] then
			return nil, string.format("volume-%d:duplicate-volume-id", index)
		end
		observedIds[volume.id] = true
		table.insert(volumes, volume)
	end

	table.sort(volumes, function(left, right)
		return left.id < right.id
	end)
	return table.freeze(volumes), nil
end

function WorldPointContents.PointInsideVolume(volume: WaterVolume, point: Vector3): boolean
	if not isBoundedVector(point, MAXIMUM_COORDINATE) then
		return false
	end
	local localPoint = volume.cframe:PointToObjectSpace(point)
	local half = volume.size * 0.5
	return math.abs(localPoint.X) <= half.X + POINT_EPSILON
		and math.abs(localPoint.Y) <= half.Y + POINT_EPSILON
		and math.abs(localPoint.Z) <= half.Z + POINT_EPSILON
end

function WorldPointContents.WaterContentsAtPoint(volumes: { WaterVolume }, point: Vector3): number
	if not isBoundedVector(point, MAXIMUM_COORDINATE) then
		return EMPTY
	end
	local contents = EMPTY
	for _, volume in volumes do
		if WorldPointContents.PointInsideVolume(volume, point) then
			contents = bit32.bor(contents, volume.contents)
		end
	end
	return contents
end

function WorldPointContents.NoDropContentsAtPoint(volumes: { NoDropVolume }, point: Vector3): number
	if not isBoundedVector(point, MAXIMUM_COORDINATE) then
		return EMPTY
	end
	local contents = EMPTY
	for _, volume in volumes do
		if WorldPointContents.PointInsideVolume(volume, point) then
			contents = bit32.bor(contents, volume.contents)
		end
	end
	return contents
end

local function collectMarkedVolumes(
	root: Instance,
	markerAttribute: string,
	maximumVolumes: number
): ({ any }?, string?)
	if typeof(root) ~= "Instance" then
		return nil, "root-not-instance"
	end

	local collected: { any } = {}
	for _, descendant in root:GetDescendants() do
		if descendant:GetAttribute(markerAttribute) ~= true then
			continue
		end
		if #collected >= maximumVolumes then
			return nil, "too-many-volumes"
		end
		if not descendant:IsA("BasePart") then
			return nil, "marker-not-basepart"
		end
		if
			not descendant.Anchored
			or descendant.CanCollide
			or descendant.CanQuery
			or descendant.CanTouch
			or descendant.Transparency ~= 1
		then
			return nil, "marker-participates-in-world"
		end
		table.insert(collected, {
			id = descendant:GetAttribute(Attributes.EntityId),
			cframe = descendant.CFrame,
			size = descendant.Size,
			contents = descendant:GetAttribute(Attributes.Contents),
		})
	end
	return collected, nil
end

function WorldPointContents.CollectWaterVolumes(root: Instance): ({ WaterVolume }?, string?)
	local collected, collectionError = collectMarkedVolumes(root, Attributes.Marker, MAXIMUM_WATER_VOLUMES)
	if not collected then
		return nil, collectionError
	end
	return WorldPointContents.ValidateAndOrderWaterVolumes(collected)
end

function WorldPointContents.CollectNoDropVolumes(root: Instance): ({ NoDropVolume }?, string?)
	local collected, collectionError = collectMarkedVolumes(root, Attributes.NoDropMarker, MAXIMUM_NO_DROP_VOLUMES)
	if not collected then
		return nil, collectionError
	end
	return WorldPointContents.ValidateAndOrderNoDropVolumes(collected)
end

function WorldPointContents.IsWater(contents: number): boolean
	return bit32.band(contents, MASK_WATER) ~= 0
end

function WorldPointContents.IsNoDrop(contents: number): boolean
	return bit32.band(contents, Contents.NoDrop) ~= 0
end

local function declaredCountMatches(root: Folder, attributeName: string, actualCount: number): boolean
	local declared = root:GetAttribute(attributeName)
	return declared == nil
		or (
			type(declared) == "number"
			and declared == declared
			and math.abs(declared) < math.huge
			and declared % 1 == 0
			and declared >= 0
			and declared == actualCount
		)
end

local function createBoundPointContents(
	staticRoot: Instance,
	waterVolumes: { WaterVolume },
	noDropVolumes: { NoDropVolume },
	authoredVolumesAvailable: boolean,
	currentCheck: (() -> boolean)?
): (PointContentsFunction, boolean)
	local parameters = OverlapParams.new()
	parameters.FilterType = Enum.RaycastFilterType.Include
	parameters.FilterDescendantsInstances = { staticRoot }
	parameters.RespectCanCollide = true
	parameters.MaxParts = 1

	local probe = Instance.new("Part")
	probe.Name = "ArenaUnparentedPointContentsProbe"
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanTouch = false
	probe.CanQuery = false
	probe.CastShadow = false
	probe.Transparency = 1
	probe.Size = SOLID_PROBE_SIZE

	local exactGeometryAvailable = authoredVolumesAvailable
		and staticRoot:IsDescendantOf(Workspace)
		and (currentCheck == nil or currentCheck())
		and pcall(function()
			Workspace:GetPartsInPart(probe, parameters)
		end)

	local function pointContents(point: Vector3): number
		if
			not exactGeometryAvailable
			or (currentCheck ~= nil and not currentCheck())
			or not isBoundedVector(point, MAXIMUM_COORDINATE)
		then
			return FAIL_CLOSED_CONTENTS
		end
		local contents = WorldPointContents.WaterContentsAtPoint(waterVolumes, point)
		contents = bit32.bor(contents, WorldPointContents.NoDropContentsAtPoint(noDropVolumes, point))
		probe.CFrame = CFrame.new(point)
		if #Workspace:GetPartsInPart(probe, parameters) > 0 then
			contents = bit32.bor(contents, Contents.Solid)
		end
		return contents
	end

	return pointContents, exactGeometryAvailable
end

-- Q3's world point-contents function unions transformed entity contents with
-- static world contents. Authored content brushes are immutable for one map
-- revision: validate them once here, before gameplay, rather than allocating,
-- sorting, or traversing the Instance tree inside every Pmove point sample.
-- Dynamic mover contents are composed separately through the revisioned
-- MoverCollisionFrame. If startup capabilities are unavailable or malformed,
-- callers receive an inexact capability and a conservative SOLID|NODROP result.
function WorldPointContents.CreateBound(
	staticSolidDomain: PersistentStaticSolidDomain.Domain,
	waterVolumesValue: unknown,
	noDropVolumesValue: unknown
): (PointContentsFunction, boolean)
	local staticRoot = PersistentStaticSolidDomain.Resolve(staticSolidDomain)
	if not staticRoot then
		return function(_point: Vector3): number
			return FAIL_CLOSED_CONTENTS
		end, false
	end
	local waterVolumes = select(1, WorldPointContents.ValidateAndOrderWaterVolumes(waterVolumesValue))
	local noDropVolumes = select(1, WorldPointContents.ValidateAndOrderNoDropVolumes(noDropVolumesValue))
	local available = waterVolumes ~= nil and noDropVolumes ~= nil
	return createBoundPointContents(
		staticRoot,
		waterVolumes or table.freeze({}),
		noDropVolumes or table.freeze({}),
		available,
		function(): boolean
			return PersistentStaticSolidDomain.IsCurrent(staticSolidDomain)
		end
	)
end

-- Explicit fixture path: unlike production CreateBound, a locally complete
-- Studio folder is not evidence that a streaming client has a complete world.
function WorldPointContents.CreateFixtureBound(
	staticRoot: Instance,
	waterVolumesValue: unknown,
	noDropVolumesValue: unknown
): (PointContentsFunction, boolean)
	local waterVolumes = select(1, WorldPointContents.ValidateAndOrderWaterVolumes(waterVolumesValue))
	local noDropVolumes = select(1, WorldPointContents.ValidateAndOrderNoDropVolumes(noDropVolumesValue))
	local available = waterVolumes ~= nil and noDropVolumes ~= nil
	return createBoundPointContents(
		staticRoot,
		waterVolumes or table.freeze({}),
		noDropVolumes or table.freeze({}),
		available,
		nil
	)
end

-- Marker collection is retained only for server build verification and
-- isolated fixtures. Production clients never scan spatial marker Parts.
function WorldPointContents.CreateFixtureFromMarkers(worldFolder: Folder): (PointContentsFunction, boolean)
	local waterVolumes, waterVolumeError = WorldPointContents.CollectWaterVolumes(worldFolder)
	local noDropVolumes, noDropVolumeError = WorldPointContents.CollectNoDropVolumes(worldFolder)
	local waterCountMatches = if waterVolumes
		then declaredCountMatches(worldFolder, Attributes.WaterVolumeCount, #waterVolumes)
		else false
	local noDropCountMatches = if noDropVolumes
		then declaredCountMatches(worldFolder, Attributes.NoDropVolumeCount, #noDropVolumes)
		else false
	local available = waterVolumeError == nil and noDropVolumeError == nil and waterCountMatches and noDropCountMatches
	return createBoundPointContents(
		worldFolder,
		waterVolumes or table.freeze({}),
		noDropVolumes or table.freeze({}),
		available,
		nil
	)
end

WorldPointContents.Contents = Contents
WorldPointContents.Empty = EMPTY
WorldPointContents.MaskWater = MASK_WATER
WorldPointContents.Attributes = Attributes
WorldPointContents.MaximumWaterVolumes = MAXIMUM_WATER_VOLUMES
WorldPointContents.MaximumNoDropVolumes = MAXIMUM_NO_DROP_VOLUMES

return table.freeze(WorldPointContents)
