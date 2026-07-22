--!strict

local FlagDefinitions = require(script.Parent.Parent.ctf.FlagDefinitions)
local ItemDefs = require(script.Parent.Parent.items.ItemDefs)
local ModeIds = require(script.Parent.Parent.match.ModeIds)
local Constants = require(script.Parent.Parent.simulation.Constants)
local MoverBinaryPolicy = require(script.Parent.Parent.simulation.MoverBinaryPolicy)
local PlayerClipDomain = require(script.Parent.Parent.simulation.PlayerClipDomain)
local WorldPointContents = require(script.Parent.Parent.simulation.WorldPointContents)
local WorldTriggerRules = require(script.Parent.Parent.simulation.WorldTriggerRules)
local MapCapabilities = require(script.Parent.MapCapabilities)
local JumpPadPresentationRules = require(script.Parent.JumpPadPresentationRules)
local MapMoverContract = require(script.Parent.MapMoverContract)
local TeleporterPresentationRules = require(script.Parent.TeleporterPresentationRules)

local MapSchema = {}

export type SurfaceKind = "Normal" | "Slick"
export type SpawnClass = "Deathmatch" | "Initial" | "TeamRed" | "TeamBlue"
export type ChunkShape = "Block" | "Wedge"
export type WaterContent = "Water" | "Slime" | "Lava"
export type TextureFace = "Left" | "Right" | "Front" | "Back" | "Top" | "Bottom"

export type Bounds = {
	minimum: Vector3,
	maximum: Vector3,
}

export type SurfaceMetadata = {
	kind: SurfaceKind,
	noDamage: boolean,
	noImpact: boolean,
}

export type StaticTextureFaceRole = {
	face: TextureFace,
	materialRole: string,
}

export type StaticChunk = {
	id: string,
	shape: ChunkShape,
	position: Vector3,
	rotationDegrees: Vector3,
	size: Vector3,
	collision: boolean,
	visual: boolean,
	styleId: string,
	skinId: string?,
	materialRole: string?,
	textureFaceRoles: { StaticTextureFaceRole }?,
	surface: SurfaceMetadata,
}

-- PlayerClip is a movement-only contents domain. Unlike StaticChunk it has no
-- visual, material, surface, or Workspace collision fields by construction.
export type PlayerClipChunk = PlayerClipDomain.Chunk

export type VisualPiece = {
	id: string,
	kitPieceId: string,
	skinId: string,
	position: Vector3,
	rotationDegrees: Vector3,
	size: Vector3,
	roleStyleOverrides: { [string]: string },
}

export type LayoutRightsStatus = "Original" | "ClearanceRequired"

export type LayoutAttribution = {
	designerCredit: string,
	referenceName: string,
	notice: string,
	officialAffiliation: boolean,
	rightsStatus: LayoutRightsStatus,
}

export type SpawnMarker = {
	id: string,
	position: Vector3,
	facing: Vector3,
	spawnClass: SpawnClass,
}

export type FlagBase = {
	id: string,
	teamId: string,
	position: Vector3,
	facing: Vector3,
}

export type PickupPlacement = {
	id: string,
	itemId: string,
	position: Vector3,
}

export type Target = {
	id: string,
	position: Vector3,
	facing: Vector3,
}

export type JumpPad = {
	id: string,
	position: Vector3,
	size: Vector3,
	targetId: string,
	visualSurface: JumpPadPresentationRules.VisualSurface?,
	visualSuppressed: boolean?,
}

export type Teleporter = {
	id: string,
	position: Vector3,
	size: Vector3,
	targetId: string,
	visualNormal: Vector3,
	visualSurface: TeleporterPresentationRules.VisualSurface?,
}

export type KillVolume = {
	id: string,
	position: Vector3,
	size: Vector3,
}

export type WaterVolume = {
	id: string,
	position: Vector3,
	size: Vector3,
	rotationDegrees: Vector3,
	contents: WaterContent,
}

export type NoDropVolume = {
	id: string,
	position: Vector3,
	size: Vector3,
	rotationDegrees: Vector3,
}

export type Mover = MapMoverContract.Definition
export type BinaryMover = MapMoverContract.BinaryProgram
export type BinaryMoverPolicy = MoverBinaryPolicy.Policy

export type Definition = {
	schemaVersion: number,
	mapId: string,
	revision: number,
	displayName: string,
	supportedModes: { string },
	bounds: Bounds,
	staticChunks: { StaticChunk },
	playerClipChunks: { PlayerClipChunk }?,
	visualPieces: { VisualPiece },
	layoutAttribution: LayoutAttribution,
	spawns: { SpawnMarker },
	flagBases: { FlagBase },
	pickups: { PickupPlacement },
	targets: { Target },
	jumpPads: { JumpPad },
	teleporters: { Teleporter },
	killVolumes: { KillVolume },
	waterVolumes: { WaterVolume },
	noDropVolumes: { NoDropVolume },
	movers: { Mover },
	binaryMovers: { BinaryMover },
	binaryMoverPolicies: { BinaryMoverPolicy },
	rocketArenaSpawnPartition: boolean?,
	assetRefs: { string },
}

export type Validation = {
	ok: boolean,
	errors: { string },
	map: ValidatedMap?,
}

export type ValidatedMap = {
	Definition: Definition,
	MapId: string,
	Revision: number,
	DisplayName: string,
	Capabilities: MapCapabilities.CapabilitySet,
	DerivedModeIds: { string },
	SupportedModeIds: { string },
	PlayerClipChunks: { PlayerClipChunk },
	TargetsById: { [string]: Target },
	TriggerDefinitions: { WorldTriggerRules.Definition },
	MoverDefinitions: { Mover },
	MoverBinaryPrograms: { BinaryMover },
	MoverBinaryPolicies: { BinaryMoverPolicy },
	InitialMoverDefinitions: { Mover },
}

local SCHEMA_VERSION = 10
local MAXIMUM_IDENTIFIER_LENGTH = 64
local MAXIMUM_DISPLAY_NAME_LENGTH = 80
local MAXIMUM_ATTRIBUTION_NOTICE_LENGTH = 320
local MAXIMUM_VISUAL_PIECES = 512
local MAXIMUM_ROLE_STYLE_OVERRIDES = 8
local MAXIMUM_STATIC_TEXTURE_FACE_ROLES = 6
local MAXIMUM_WATER_VOLUMES = WorldPointContents.MaximumWaterVolumes
local MAXIMUM_NO_DROP_VOLUMES = WorldPointContents.MaximumNoDropVolumes
local MAXIMUM_MOVERS = MapMoverContract.MaximumMovers

local ModeOrder: { string } = {
	ModeIds.Deathmatch,
	ModeIds.OneShot,
	ModeIds.Duel,
	ModeIds.TeamDeathmatch,
	ModeIds.CaptureTheFlag,
	ModeIds.ArenaElimination,
}
table.freeze(ModeOrder)

local modeIds: { [string]: boolean } = {}
for _, modeId in ModeOrder do
	modeIds[modeId] = true
end
table.freeze(modeIds)

local SpawnClasses = table.freeze({
	Deathmatch = "Deathmatch" :: SpawnClass,
	Initial = "Initial" :: SpawnClass,
	TeamRed = "TeamRed" :: SpawnClass,
	TeamBlue = "TeamBlue" :: SpawnClass,
})

local SurfaceKinds = table.freeze({
	Normal = "Normal" :: SurfaceKind,
	Slick = "Slick" :: SurfaceKind,
})

local ChunkShapes = table.freeze({
	Block = "Block" :: ChunkShape,
	Wedge = "Wedge" :: ChunkShape,
})

local TextureFaces = table.freeze({
	Left = "Left" :: TextureFace,
	Right = "Right" :: TextureFace,
	Front = "Front" :: TextureFace,
	Back = "Back" :: TextureFace,
	Top = "Top" :: TextureFace,
	Bottom = "Bottom" :: TextureFace,
})

local validTextureFaces: { [string]: boolean } = {}
for _, face in TextureFaces do
	validTextureFaces[face] = true
end
table.freeze(validTextureFaces)

local function validMaterialRole(value: unknown): boolean
	return validId(value)
end

local WaterContents = table.freeze({
	Water = "Water" :: WaterContent,
	Slime = "Slime" :: WaterContent,
	Lava = "Lava" :: WaterContent,
})

local function deepFreeze(value: any, seen: { [table]: boolean }?): any
	if type(value) ~= "table" then
		return value
	end
	local visited = seen or {}
	if visited[value] then
		return value
	end
	visited[value] = true
	for key, child in value do
		deepFreeze(key, visited)
		deepFreeze(child, visited)
	end
	-- table.freeze is shallow. A caller may supply a shallow-frozen root whose
	-- descendants are still mutable, so traverse first even when this table was
	-- already frozen.
	if not table.isfrozen(value) then
		table.freeze(value)
	end
	return value
end

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function isFiniteVector3(value: unknown): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	local vector = value :: Vector3
	return isFiniteNumber(vector.X) and isFiniteNumber(vector.Y) and isFiniteNumber(vector.Z)
end

local function isPositiveVector3(value: unknown): boolean
	return isFiniteVector3(value) and (value :: Vector3).X > 0 and (value :: Vector3).Y > 0 and (value :: Vector3).Z > 0
end

local function validId(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= MAXIMUM_IDENTIFIER_LENGTH
		and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function validLabel(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= MAXIMUM_DISPLAY_NAME_LENGTH
end

local function validBoundedText(value: unknown, maximumLength: number): boolean
	return type(value) == "string" and #value >= 1 and #value <= maximumLength
end

local function denseArray(value: unknown, path: string, errors: { string }, maximumCount: number?): { any }
	if type(value) ~= "table" then
		table.insert(errors, path .. ":MustBeArray")
		return {}
	end

	local count = 0
	local maximumIndex = 0
	for key in value :: any do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			table.insert(errors, path .. ":MustBeDenseArray")
			return {}
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if maximumCount and (count > maximumCount or maximumIndex > maximumCount) then
			table.insert(errors, path .. ":TooManyEntries")
			return {}
		end
	end
	if maximumIndex ~= count then
		table.insert(errors, path .. ":MustBeDenseArray")
		return {}
	end
	return value :: { any }
end

local function insideBounds(position: Vector3, bounds: Bounds): boolean
	return position.X >= bounds.minimum.X
		and position.Y >= bounds.minimum.Y
		and position.Z >= bounds.minimum.Z
		and position.X <= bounds.maximum.X
		and position.Y <= bounds.maximum.Y
		and position.Z <= bounds.maximum.Z
end

local function boxesOverlap(
	leftMinimum: Vector3,
	leftMaximum: Vector3,
	rightMinimum: Vector3,
	rightMaximum: Vector3
): boolean
	return leftMinimum.X <= rightMaximum.X
		and leftMaximum.X >= rightMinimum.X
		and leftMinimum.Y <= rightMaximum.Y
		and leftMaximum.Y >= rightMinimum.Y
		and leftMinimum.Z <= rightMaximum.Z
		and leftMaximum.Z >= rightMinimum.Z
end

local function validatePlayerHull(
	origin: Vector3,
	crouched: boolean,
	path: string,
	bounds: Bounds,
	killVolumes: { KillVolume },
	errors: { string }
)
	local posture = if crouched then "Crouched" else "Standing"
	local center = origin + Constants.ColliderCenterOffsetFor(crouched)
	local half = Constants.ColliderSizeFor(crouched) * 0.5
	local minimum = center - half
	local maximum = center + half
	if not insideBounds(minimum, bounds) or not insideBounds(maximum, bounds) then
		table.insert(errors, path .. ":" .. posture .. "HullOutsideBounds")
	end
	for _, volume in killVolumes do
		local volumeHalf = volume.size * 0.5
		if boxesOverlap(minimum, maximum, volume.position - volumeHalf, volume.position + volumeHalf) then
			table.insert(errors, path .. ":" .. posture .. "HullIntersectsKillVolume:" .. volume.id)
		end
	end
end

local function validatePoint(value: unknown, path: string, bounds: Bounds?, errors: { string }): boolean
	if not isFiniteVector3(value) then
		table.insert(errors, path .. ":MustBeFiniteVector3")
		return false
	end
	if bounds and not insideBounds(value :: Vector3, bounds) then
		table.insert(errors, path .. ":OutOfBounds")
		return false
	end
	return true
end

local function validateFacing(value: unknown, path: string, errors: { string }): boolean
	if not isFiniteVector3(value) then
		table.insert(errors, path .. ":MustBeFiniteVector3")
		return false
	end
	local facing = value :: Vector3
	if Vector3.new(facing.X, 0, facing.Z).Magnitude <= 0.0001 then
		table.insert(errors, path .. ":MustHaveHorizontalDirection")
		return false
	end
	return true
end

local function validateBox(position: unknown, size: unknown, path: string, bounds: Bounds?, errors: { string }): boolean
	local validPosition = validatePoint(position, path .. ".position", nil, errors)
	local validSize = isPositiveVector3(size)
	if not validSize then
		table.insert(errors, path .. ".size:MustBePositiveFiniteVector3")
	end
	if not validPosition or not validSize or not bounds then
		return validPosition and validSize
	end
	local center = position :: Vector3
	local half = (size :: Vector3) * 0.5
	if not insideBounds(center - half, bounds) or not insideBounds(center + half, bounds) then
		table.insert(errors, path .. ":OutOfBounds")
		return false
	end
	return true
end

local function validateRotatedBox(
	position: unknown,
	rotationDegrees: unknown,
	size: unknown,
	path: string,
	bounds: Bounds?,
	errors: { string }
): boolean
	local validBox = validateBox(position, size, path, nil, errors)
	if not isFiniteVector3(rotationDegrees) then
		table.insert(errors, path .. ".rotationDegrees:MustBeFiniteVector3")
		return false
	end
	if not validBox or not bounds then
		return validBox
	end

	local rotation = rotationDegrees :: Vector3
	local transform = CFrame.new(position :: Vector3)
		* CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))
	local half = (size :: Vector3) * 0.5
	for x = -1, 1, 2 do
		for y = -1, 1, 2 do
			for z = -1, 1, 2 do
				local corner = transform:PointToWorldSpace(Vector3.new(half.X * x, half.Y * y, half.Z * z))
				if not insideBounds(corner, bounds) then
					table.insert(errors, path .. ":OutOfBounds")
					return false
				end
			end
		end
	end
	return true
end

local function orientedBoxInsideBounds(cframe: CFrame, size: Vector3, bounds: Bounds): boolean
	local half = size * 0.5
	for x = -1, 1, 2 do
		for y = -1, 1, 2 do
			for z = -1, 1, 2 do
				local corner = cframe:PointToWorldSpace(Vector3.new(half.X * x, half.Y * y, half.Z * z))
				if not insideBounds(corner, bounds) then
					return false
				end
			end
		end
	end
	return true
end

local function teamForSpawnClass(spawnClass: unknown): string?
	if spawnClass == SpawnClasses.TeamRed then
		return FlagDefinitions.TeamIds.Red
	elseif spawnClass == SpawnClasses.TeamBlue then
		return FlagDefinitions.TeamIds.Blue
	end
	return nil
end

local function supportsMode(capabilities: MapCapabilities.CapabilitySet, modeId: string): boolean
	if modeId == ModeIds.ArenaElimination then
		return capabilities.CombatSpawns == true and capabilities.TeamSpawns == true
	elseif modeId == ModeIds.CaptureTheFlag then
		return capabilities.CombatSpawns == true and capabilities.TeamSpawns == true and capabilities.FlagBases == true
	end
	return capabilities.CombatSpawns == true
end

local function missingCapabilities(
	capabilities: MapCapabilities.CapabilitySet,
	modeId: string
): { MapCapabilities.Capability }
	local required: { MapCapabilities.Capability } = {
		MapCapabilities.Values.CombatSpawns,
	}
	if modeId == ModeIds.ArenaElimination or modeId == ModeIds.CaptureTheFlag then
		table.insert(required, MapCapabilities.Values.TeamSpawns)
	end
	if modeId == ModeIds.CaptureTheFlag then
		table.insert(required, MapCapabilities.Values.FlagBases)
	end

	local missing: { MapCapabilities.Capability } = {}
	for _, capability in required do
		if capabilities[capability] ~= true then
			table.insert(missing, capability)
		end
	end
	return missing
end

function MapSchema.Freeze<T>(value: T): T
	return deepFreeze(value) :: T
end

function MapSchema.Validate(value: unknown): Validation
	local errors: { string } = {}
	if type(value) ~= "table" then
		return table.freeze({
			ok = false,
			errors = table.freeze({ "Map:MustBeTable" }),
			map = nil,
		})
	end
	local definition = value :: any

	if definition.schemaVersion ~= SCHEMA_VERSION then
		table.insert(errors, string.format("SchemaVersion:Expected:%d", SCHEMA_VERSION))
	end
	if not validId(definition.mapId) then
		table.insert(errors, "MapId:Invalid")
	end
	if not isFiniteNumber(definition.revision) or definition.revision % 1 ~= 0 or definition.revision < 1 then
		table.insert(errors, "Revision:MustBePositiveInteger")
	end
	if not validLabel(definition.displayName) then
		table.insert(errors, "DisplayName:Invalid")
	end
	if type(definition.layoutAttribution) ~= "table" then
		table.insert(errors, "LayoutAttribution:MustBeTable")
	else
		local attribution = definition.layoutAttribution
		if not validLabel(attribution.designerCredit) then
			table.insert(errors, "LayoutAttribution.designerCredit:Invalid")
		end
		if not validLabel(attribution.referenceName) then
			table.insert(errors, "LayoutAttribution.referenceName:Invalid")
		end
		if not validBoundedText(attribution.notice, MAXIMUM_ATTRIBUTION_NOTICE_LENGTH) then
			table.insert(errors, "LayoutAttribution.notice:Invalid")
		end
		if type(attribution.officialAffiliation) ~= "boolean" then
			table.insert(errors, "LayoutAttribution.officialAffiliation:MustBeBoolean")
		end
		if attribution.rightsStatus ~= "Original" and attribution.rightsStatus ~= "ClearanceRequired" then
			table.insert(errors, "LayoutAttribution.rightsStatus:Invalid")
		end
	end

	local bounds: Bounds? = nil
	if type(definition.bounds) ~= "table" then
		table.insert(errors, "Bounds:MustBeTable")
	elseif
		validatePoint(definition.bounds.minimum, "Bounds.minimum", nil, errors)
		and validatePoint(definition.bounds.maximum, "Bounds.maximum", nil, errors)
	then
		local minimum = definition.bounds.minimum :: Vector3
		local maximum = definition.bounds.maximum :: Vector3
		if minimum.X >= maximum.X or minimum.Y >= maximum.Y or minimum.Z >= maximum.Z then
			table.insert(errors, "Bounds:MinimumMustBeLessThanMaximum")
		else
			bounds = definition.bounds :: Bounds
		end
	end

	local entityIds: { [string]: string } = {}
	local function registerId(id: unknown, path: string): boolean
		if not validId(id) then
			table.insert(errors, path .. ".id:Invalid")
			return false
		end
		local stringId = id :: string
		local priorPath = entityIds[stringId]
		if priorPath then
			table.insert(errors, string.format("DuplicateEntityId:%s:%s:%s", stringId, priorPath, path))
			return false
		end
		entityIds[stringId] = path
		return true
	end

	local targetsById: { [string]: Target } = {}
	for index, entry in denseArray(definition.targets, "Targets", errors) do
		local path = string.format("Targets[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			continue
		end
		local valid = registerId(entry.id, path)
		valid = validatePoint(entry.position, path .. ".position", bounds, errors) and valid
		valid = validateFacing(entry.facing, path .. ".facing", errors) and valid
		if valid then
			targetsById[entry.id] = entry :: Target
		end
	end

	local collisionChunkCount = 0
	local visualChunkCount = 0
	for index, entry in denseArray(definition.staticChunks, "StaticChunks", errors) do
		local path = string.format("StaticChunks[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			continue
		end
		registerId(entry.id, path)
		validateRotatedBox(entry.position, entry.rotationDegrees, entry.size, path, bounds, errors)
		if entry.shape ~= ChunkShapes.Block and entry.shape ~= ChunkShapes.Wedge then
			table.insert(errors, path .. ".shape:Invalid")
		end
		if type(entry.collision) ~= "boolean" then
			table.insert(errors, path .. ".collision:MustBeBoolean")
		elseif entry.collision then
			collisionChunkCount += 1
		end
		if type(entry.visual) ~= "boolean" then
			table.insert(errors, path .. ".visual:MustBeBoolean")
		elseif entry.visual then
			visualChunkCount += 1
		end
		if entry.collision ~= true and entry.visual ~= true then
			table.insert(errors, path .. ":MustBeCollisionOrVisual")
		end
		if not validId(entry.styleId) then
			table.insert(errors, path .. ".styleId:Invalid")
		end
		local hasSkin = entry.skinId ~= nil
		local hasMaterialRole = entry.materialRole ~= nil
		if hasSkin ~= hasMaterialRole then
			table.insert(errors, path .. ":SkinAndMaterialRoleMustBePaired")
		elseif hasSkin then
			if not validId(entry.skinId) then
				table.insert(errors, path .. ".skinId:Invalid")
			elseif not validMaterialRole(entry.materialRole) then
				table.insert(errors, path .. ".materialRole:Invalid")
			end
			if entry.visual ~= true then
				table.insert(errors, path .. ":TexturedChunkMustBeVisual")
			end
		end
		if entry.textureFaceRoles ~= nil then
			local faceRoles = denseArray(
				entry.textureFaceRoles,
				path .. ".textureFaceRoles",
				errors,
				MAXIMUM_STATIC_TEXTURE_FACE_ROLES
			)
			if #faceRoles == 0 then
				table.insert(errors, path .. ".textureFaceRoles:MustNotBeEmpty")
			end
			if not hasSkin then
				table.insert(errors, path .. ".textureFaceRoles:RequiresSkin")
			end
			if entry.visual ~= true then
				table.insert(errors, path .. ".textureFaceRoles:RequiresVisualChunk")
			end
			if entry.shape ~= ChunkShapes.Block then
				table.insert(errors, path .. ".textureFaceRoles:BlockOnly")
			end
			local seenFaces: { [string]: boolean } = {}
			for faceIndex, faceRole in faceRoles do
				local facePath = string.format("%s.textureFaceRoles[%d]", path, faceIndex)
				if type(faceRole) ~= "table" then
					table.insert(errors, facePath .. ":MustBeTable")
					continue
				end
				local keyCount = 0
				for key in faceRole do
					keyCount += 1
					if key ~= "face" and key ~= "materialRole" then
						table.insert(errors, facePath .. ":UnexpectedField:" .. tostring(key))
					end
				end
				if keyCount ~= 2 then
					table.insert(errors, facePath .. ":MustHaveExactFields")
				end
				if type(faceRole.face) ~= "string" or not validTextureFaces[faceRole.face] then
					table.insert(errors, facePath .. ".face:Invalid")
				elseif seenFaces[faceRole.face] then
					table.insert(errors, facePath .. ".face:Duplicate:" .. faceRole.face)
				else
					seenFaces[faceRole.face] = true
				end
				if not validMaterialRole(faceRole.materialRole) then
					table.insert(errors, facePath .. ".materialRole:Invalid")
				end
			end
		end
		if type(entry.surface) ~= "table" then
			table.insert(errors, path .. ".surface:MustBeTable")
		else
			if entry.surface.kind ~= SurfaceKinds.Normal and entry.surface.kind ~= SurfaceKinds.Slick then
				table.insert(errors, path .. ".surface.kind:Invalid")
			end
			if type(entry.surface.noDamage) ~= "boolean" then
				table.insert(errors, path .. ".surface.noDamage:MustBeBoolean")
			end
			if type(entry.surface.noImpact) ~= "boolean" then
				table.insert(errors, path .. ".surface.noImpact:MustBeBoolean")
			end
		end
	end
	if collisionChunkCount == 0 then
		table.insert(errors, "StaticChunks:MissingCollisionChunk")
	end

	local playerClipChunks: { PlayerClipChunk } = {}
	if definition.playerClipChunks ~= nil then
		local values =
			denseArray(definition.playerClipChunks, "PlayerClipChunks", errors, PlayerClipDomain.MaximumChunks)
		for index, entry in values do
			local path = string.format("PlayerClipChunks[%d]", index)
			if type(entry) ~= "table" then
				table.insert(errors, path .. ":MustBeTable")
				continue
			end
			local keyCount = 0
			for key in entry do
				keyCount += 1
				if key ~= "id" and key ~= "position" and key ~= "size" then
					table.insert(errors, path .. ":UnexpectedField:" .. tostring(key))
				end
			end
			if keyCount ~= 3 then
				table.insert(errors, path .. ":MustHaveExactFields")
			end
			registerId(entry.id, path)
			validateBox(entry.position, entry.size, path, bounds, errors)
		end
		playerClipChunks = values :: { PlayerClipChunk }
	end

	local visualPieceCount = 0
	for index, entry in denseArray(definition.visualPieces, "VisualPieces", errors, MAXIMUM_VISUAL_PIECES) do
		local path = string.format("VisualPieces[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			continue
		end
		registerId(entry.id, path)
		local validBox = validateRotatedBox(entry.position, entry.rotationDegrees, entry.size, path, bounds, errors)
		if not validId(entry.kitPieceId) then
			table.insert(errors, path .. ".kitPieceId:Invalid")
		end
		if not validId(entry.skinId) then
			table.insert(errors, path .. ".skinId:Invalid")
		end
		if type(entry.roleStyleOverrides) ~= "table" then
			table.insert(errors, path .. ".roleStyleOverrides:MustBeTable")
		else
			local overrideCount = 0
			for role, styleId in entry.roleStyleOverrides do
				overrideCount += 1
				if overrideCount > MAXIMUM_ROLE_STYLE_OVERRIDES then
					table.insert(errors, path .. ".roleStyleOverrides:TooManyEntries")
					break
				end
				if not validId(role) then
					table.insert(errors, path .. ".roleStyleOverrides:RoleInvalid:" .. tostring(role))
				end
				if not validId(styleId) then
					table.insert(errors, path .. ".roleStyleOverrides:StyleInvalid:" .. tostring(styleId))
				end
			end
		end
		if validBox and validId(entry.kitPieceId) and validId(entry.skinId) then
			visualPieceCount += 1
		end
	end
	if visualChunkCount == 0 and visualPieceCount == 0 then
		table.insert(errors, "Visuals:MissingVisualChunkOrPiece")
	end

	local validatedMoverDefinitions = table.freeze({}) :: { Mover }
	local validatedMoverBinaryPrograms = table.freeze({}) :: { BinaryMover }
	local validatedMoverBinaryPolicies = table.freeze({}) :: { BinaryMoverPolicy }
	local initialMoverDefinitions = table.freeze({}) :: { Mover }
	local moverValues = denseArray(definition.movers, "Movers", errors, MAXIMUM_MOVERS)
	local canValidateMovers = moverValues == definition.movers and bounds ~= nil
	for index, entry in moverValues do
		local path = string.format("Movers[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			canValidateMovers = false
		else
			registerId(entry.id, path)
		end
	end
	local legacyMoversValid = false
	if canValidateMovers then
		local definitions, moverError = MapMoverContract.ValidateAndOrder(definition.movers, bounds)
		if not definitions then
			table.insert(errors, "Movers:" .. (moverError or "Invalid"))
		else
			validatedMoverDefinitions = definitions
			legacyMoversValid = true
		end
	end

	local binaryMoverValues = denseArray(definition.binaryMovers, "BinaryMovers", errors, MAXIMUM_MOVERS)
	local canValidateBinaryMovers = binaryMoverValues == definition.binaryMovers and bounds ~= nil
	for index, entry in binaryMoverValues do
		local path = string.format("BinaryMovers[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			canValidateBinaryMovers = false
		else
			registerId(entry.id, path)
		end
	end
	local binaryMoversValid = false
	if canValidateBinaryMovers then
		local programs, binaryMoverError =
			MapMoverContract.ValidateAndOrderBinaryPrograms(definition.binaryMovers, bounds)
		if not programs then
			table.insert(errors, "BinaryMovers:" .. (binaryMoverError or "Invalid"))
		else
			validatedMoverBinaryPrograms = programs
			binaryMoversValid = true
		end
	end
	local binaryMoverPolicyValues =
		denseArray(definition.binaryMoverPolicies, "BinaryMoverPolicies", errors, MAXIMUM_MOVERS)
	local canValidateBinaryMoverPolicies = binaryMoverPolicyValues == definition.binaryMoverPolicies
	if binaryMoversValid and canValidateBinaryMoverPolicies then
		local policies, binaryMoverPolicyError =
			MoverBinaryPolicy.ValidateAndOrder(validatedMoverBinaryPrograms, definition.binaryMoverPolicies)
		if not policies then
			table.insert(errors, "BinaryMoverPolicies:" .. (binaryMoverPolicyError or "Invalid"))
		else
			validatedMoverBinaryPolicies = policies
		end
	end
	if legacyMoversValid and binaryMoversValid then
		local domains, domainError =
			MapMoverContract.ComposeDomains(validatedMoverDefinitions, validatedMoverBinaryPrograms)
		if not domains then
			table.insert(errors, "MoverDomains:" .. (domainError or "Invalid"))
		else
			validatedMoverDefinitions = domains.legacyDefinitions
			validatedMoverBinaryPrograms = domains.binaryPrograms
			initialMoverDefinitions = domains.initialDefinitions
		end
	end

	for index, entry in denseArray(definition.waterVolumes, "WaterVolumes", errors, MAXIMUM_WATER_VOLUMES) do
		local path = string.format("WaterVolumes[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			continue
		end
		local validWaterId = validId(entry.id)
		registerId(entry.id, path)
		local validWaterBox =
			validateRotatedBox(entry.position, entry.rotationDegrees, entry.size, path, bounds, errors)
		local pointContentsValue: number? = nil
		if entry.contents == WaterContents.Water then
			pointContentsValue = WorldPointContents.Contents.Water
		elseif entry.contents == WaterContents.Slime then
			pointContentsValue = WorldPointContents.Contents.Slime
		elseif entry.contents == WaterContents.Lava then
			pointContentsValue = WorldPointContents.Contents.Lava
		else
			table.insert(errors, path .. ".contents:Invalid")
		end
		-- ArenaWorldService converts the authored box into this exact runtime
		-- contract. Reject it here too so a schema-valid map cannot later fail the
		-- deterministic world-build assertion on adapter-specific bounds.
		if validWaterId and validWaterBox and pointContentsValue then
			local rotation = entry.rotationDegrees :: Vector3
			local _validatedVolumes, pointContentsError = WorldPointContents.ValidateAndOrderWaterVolumes({
				{
					id = entry.id,
					cframe = CFrame.new(entry.position)
						* CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z)),
					size = entry.size,
					contents = pointContentsValue,
				},
			})
			if pointContentsError then
				table.insert(errors, path .. ":PointContents:" .. pointContentsError)
			end
		end
	end

	for index, entry in denseArray(definition.noDropVolumes, "NoDropVolumes", errors, MAXIMUM_NO_DROP_VOLUMES) do
		local path = string.format("NoDropVolumes[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			continue
		end
		local validNoDropId = validId(entry.id)
		registerId(entry.id, path)
		local validNoDropBox =
			validateRotatedBox(entry.position, entry.rotationDegrees, entry.size, path, bounds, errors)
		if validNoDropId and validNoDropBox then
			local rotation = entry.rotationDegrees :: Vector3
			local _validatedVolumes, pointContentsError = WorldPointContents.ValidateAndOrderNoDropVolumes({
				{
					id = entry.id,
					cframe = CFrame.new(entry.position)
						* CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z)),
					size = entry.size,
					contents = WorldPointContents.Contents.NoDrop,
				},
			})
			if pointContentsError then
				table.insert(errors, path .. ":PointContents:" .. pointContentsError)
			end
		end
	end

	local spawnCount = 0
	local redSpawnCount = 0
	local blueSpawnCount = 0
	local spatialSpawns: { { index: number, position: Vector3 } } = {}
	for index, entry in denseArray(definition.spawns, "Spawns", errors) do
		local path = string.format("Spawns[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			continue
		end
		registerId(entry.id, path)
		local validPosition = validatePoint(entry.position, path .. ".position", bounds, errors)
		local validFacing = validateFacing(entry.facing, path .. ".facing", errors)
		if validPosition then
			table.insert(spatialSpawns, {
				index = index,
				position = entry.position :: Vector3,
			})
		end
		local spawnClass = entry.spawnClass
		if
			spawnClass ~= SpawnClasses.Deathmatch
			and spawnClass ~= SpawnClasses.Initial
			and spawnClass ~= SpawnClasses.TeamRed
			and spawnClass ~= SpawnClasses.TeamBlue
		then
			table.insert(errors, path .. ".spawnClass:Invalid")
		elseif validPosition and validFacing then
			spawnCount += 1
			local teamId = teamForSpawnClass(spawnClass)
			if teamId == FlagDefinitions.TeamIds.Red then
				redSpawnCount += 1
			elseif teamId == FlagDefinitions.TeamIds.Blue then
				blueSpawnCount += 1
			end
		end
	end
	if definition.rocketArenaSpawnPartition ~= nil and definition.rocketArenaSpawnPartition ~= true then
		table.insert(errors, "RocketArenaSpawnPartition:MustBeTrueOrNil")
	end
	if definition.rocketArenaSpawnPartition == true and (redSpawnCount < 1 or blueSpawnCount < 1) then
		table.insert(errors, "RocketArenaSpawnPartition:MissingMeasuredHalves")
	end

	local redFlagCount = 0
	local blueFlagCount = 0
	for index, entry in denseArray(definition.flagBases, "FlagBases", errors) do
		local path = string.format("FlagBases[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			continue
		end
		registerId(entry.id, path)
		local validPosition = validatePoint(entry.position, path .. ".position", bounds, errors)
		local validFacing = validateFacing(entry.facing, path .. ".facing", errors)
		if entry.teamId == FlagDefinitions.TeamIds.Red then
			if validPosition and validFacing then
				redFlagCount += 1
			end
		elseif entry.teamId == FlagDefinitions.TeamIds.Blue then
			if validPosition and validFacing then
				blueFlagCount += 1
			end
		else
			table.insert(errors, path .. ".teamId:Invalid")
		end
	end
	if redFlagCount > 1 then
		table.insert(errors, "FlagBases:DuplicateTeam:Red")
	end
	if blueFlagCount > 1 then
		table.insert(errors, "FlagBases:DuplicateTeam:Blue")
	end

	for index, entry in denseArray(definition.pickups, "Pickups", errors) do
		local path = string.format("Pickups[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			continue
		end
		registerId(entry.id, path)
		validatePoint(entry.position, path .. ".position", bounds, errors)
		local itemDefinition = if type(entry.itemId) == "string" then ItemDefs.ById[entry.itemId] else nil
		if itemDefinition == nil then
			table.insert(errors, path .. ".itemId:Unknown")
		elseif itemDefinition.worldPickupEligible == false then
			table.insert(errors, path .. ".itemId:NotWorldPickup")
		end
	end

	local function validateTrigger(entry: any, path: string): (boolean, Target?)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			return false, nil
		end
		local valid = registerId(entry.id, path)
		valid = validateBox(entry.position, entry.size, path, bounds, errors) and valid
		local target: Target? = nil
		if not validId(entry.targetId) then
			table.insert(errors, path .. ".targetId:Invalid")
			valid = false
		elseif targetsById[entry.targetId] == nil then
			table.insert(errors, path .. ".targetId:Missing:" .. entry.targetId)
			valid = false
		else
			target = targetsById[entry.targetId]
		end
		return valid, target
	end

	local runtimeTriggerDefinitions: { any } = {}
	local validatedTriggerDefinitions = table.freeze({}) :: { WorldTriggerRules.Definition }
	local spatialTeleporterExits: { { index: number, position: Vector3 } } = {}
	local canPreflightRuntimeTriggers = true
	local triggerId = 0
	for index, entry in denseArray(definition.jumpPads, "JumpPads", errors) do
		triggerId += 1
		local path = string.format("JumpPads[%d]", index)
		local valid, target = validateTrigger(entry, path)
		local validVisualSurface = true
		if type(entry) == "table" and entry.visualSuppressed ~= nil and entry.visualSuppressed ~= true then
			table.insert(errors, path .. ".visualSuppressed:MustBeTrueOrNil")
			validVisualSurface = false
		end
		if type(entry) == "table" and entry.visualSuppressed == true and entry.visualSurface ~= nil then
			table.insert(errors, path .. ".visualSurface:ConflictsWithVisualSuppressed")
			validVisualSurface = false
		elseif type(entry) == "table" and entry.visualSurface ~= nil then
			local presentationValid, presentationError =
				JumpPadPresentationRules.ValidateVisualSurface(entry.visualSurface)
			validVisualSurface = presentationValid
			if not presentationValid then
				table.insert(errors, path .. ".visualSurface:" .. (presentationError or "Invalid"))
			elseif
				not validatePoint(entry.visualSurface.position, path .. ".visualSurface.position", bounds, errors)
			then
				validVisualSurface = false
			elseif valid and bounds then
				local surfacePlan, surfacePlanError =
					JumpPadPresentationRules.BuildSurfacePlan(entry.position, entry.size, entry.visualSurface)
				if not surfacePlan then
					table.insert(errors, path .. ".visualSurface:" .. (surfacePlanError or "PresentationPlanInvalid"))
					validVisualSurface = false
				elseif not orientedBoxInsideBounds(surfacePlan.cframe, surfacePlan.size, bounds) then
					table.insert(errors, path .. ".visualSurface:OutOfBounds")
					validVisualSurface = false
				end
			end
		end
		if valid and validVisualSurface and target then
			local launchVelocity =
				WorldTriggerRules.AimAtTarget((entry :: JumpPad).position, target.position, Constants.Gravity)
			if launchVelocity then
				table.insert(runtimeTriggerDefinitions, {
					id = triggerId,
					kind = "JumpPad",
					cframe = CFrame.new((entry :: JumpPad).position),
					size = (entry :: JumpPad).size,
					launchVelocity = launchVelocity,
				})
			else
				table.insert(errors, path .. ":InvalidLaunchTarget")
				canPreflightRuntimeTriggers = false
			end
		else
			canPreflightRuntimeTriggers = false
		end
	end
	for index, entry in denseArray(definition.teleporters, "Teleporters", errors) do
		triggerId += 1
		local path = string.format("Teleporters[%d]", index)
		local valid, target = validateTrigger(entry, path)
		local validPresentation = false
		if type(entry) == "table" and isPositiveVector3(entry.size) then
			local presentationValid, presentationError =
				TeleporterPresentationRules.ValidateVisualNormal(entry.visualNormal, entry.size, entry.visualSurface)
			if not presentationValid then
				table.insert(errors, path .. ".visualNormal:" .. (presentationError or "Invalid"))
			else
				local validVisualSurface = true
				if entry.visualSurface ~= nil then
					local surfaceValid, surfaceError =
						TeleporterPresentationRules.ValidateVisualSurface(entry.visualSurface)
					validVisualSurface = surfaceValid
					if not surfaceValid then
						table.insert(errors, path .. ".visualSurface:" .. (surfaceError or "Invalid"))
					elseif
						not validatePoint(
							entry.visualSurface.position,
							path .. ".visualSurface.position",
							bounds,
							errors
						)
					then
						validVisualSurface = false
					end
				end
				if validVisualSurface then
					local surfacePlan, surfacePlanError = TeleporterPresentationRules.BuildSurfacePlan(
						entry.position,
						entry.size,
						entry.visualNormal,
						entry.visualSurface
					)
					if not surfacePlan then
						table.insert(
							errors,
							path .. ".visualSurface:" .. (surfacePlanError or "PresentationPlanInvalid")
						)
					elseif bounds and not orientedBoxInsideBounds(surfacePlan.cframe, surfacePlan.size, bounds) then
						table.insert(errors, path .. ".visualSurface:OutOfBounds")
					else
						validPresentation = true
					end
				end
			end
		end
		if valid and validPresentation and target then
			table.insert(runtimeTriggerDefinitions, {
				id = triggerId,
				kind = "Teleporter",
				cframe = CFrame.new((entry :: Teleporter).position),
				size = (entry :: Teleporter).size,
				destinationPosition = target.position,
				destinationLook = target.facing,
			})
			table.insert(spatialTeleporterExits, {
				index = index,
				position = target.position + Vector3.yAxis * WorldTriggerRules.TeleportVerticalOffset,
			})
		else
			canPreflightRuntimeTriggers = false
		end
	end
	if canPreflightRuntimeTriggers then
		local definitions, runtimeTriggerError =
			WorldTriggerRules.ValidateAndOrderDefinitions(runtimeTriggerDefinitions)
		if runtimeTriggerError then
			table.insert(errors, "WorldTriggers:" .. runtimeTriggerError)
		elseif definitions then
			validatedTriggerDefinitions = definitions
		end
	end

	local validatedKillVolumes: { KillVolume } = {}
	for index, entry in denseArray(definition.killVolumes, "KillVolumes", errors) do
		local path = string.format("KillVolumes[%d]", index)
		if type(entry) ~= "table" then
			table.insert(errors, path .. ":MustBeTable")
			continue
		end
		local valid = registerId(entry.id, path)
		valid = validateBox(entry.position, entry.size, path, bounds, errors) and valid
		if valid then
			table.insert(validatedKillVolumes, entry :: KillVolume)
		end
	end

	if bounds then
		for _, spawn in spatialSpawns do
			local path = string.format("Spawns[%d]", spawn.index)
			validatePlayerHull(spawn.position, false, path, bounds, validatedKillVolumes, errors)
			validatePlayerHull(spawn.position, true, path, bounds, validatedKillVolumes, errors)
		end
		for _, exit in spatialTeleporterExits do
			local path = string.format("Teleporters[%d].exit", exit.index)
			validatePlayerHull(exit.position, false, path, bounds, validatedKillVolumes, errors)
			validatePlayerHull(exit.position, true, path, bounds, validatedKillVolumes, errors)
		end
	end

	local seenAssetRefs: { [string]: boolean } = {}
	for index, assetRef in denseArray(definition.assetRefs, "AssetRefs", errors) do
		local path = string.format("AssetRefs[%d]", index)
		if not validId(assetRef) then
			table.insert(errors, path .. ":Invalid")
		elseif seenAssetRefs[assetRef] then
			table.insert(errors, path .. ":Duplicate:" .. assetRef)
		else
			seenAssetRefs[assetRef] = true
		end
	end

	local capabilities: MapCapabilities.CapabilitySet = {
		[MapCapabilities.Values.CombatSpawns] = spawnCount >= 2,
		[MapCapabilities.Values.TeamSpawns] = redSpawnCount >= 1 and blueSpawnCount >= 1,
		[MapCapabilities.Values.FlagBases] = redFlagCount == 1 and blueFlagCount == 1,
	}

	local derivedModeIds: { string } = {}
	for _, modeId in ModeOrder do
		if supportsMode(capabilities, modeId) then
			table.insert(derivedModeIds, modeId)
		end
	end

	local claimedModes: { [string]: boolean } = {}
	local supportedModeValues = denseArray(definition.supportedModes, "SupportedModes", errors)
	if #supportedModeValues == 0 then
		table.insert(errors, "SupportedModes:MustNotBeEmpty")
	end
	for index, modeId in supportedModeValues do
		local path = string.format("SupportedModes[%d]", index)
		if type(modeId) ~= "string" or modeIds[modeId] ~= true then
			table.insert(errors, path .. ":Unknown:" .. tostring(modeId))
		elseif claimedModes[modeId] then
			table.insert(errors, path .. ":Duplicate:" .. modeId)
		else
			claimedModes[modeId] = true
			if not supportsMode(capabilities, modeId) then
				local missing = missingCapabilities(capabilities, modeId)
				table.insert(
					errors,
					string.format("SupportedModes:Incompatible:%s:%s", modeId, table.concat(missing, ","))
				)
			end
		end
	end

	local supportedModeIds: { string } = {}
	for _, modeId in ModeOrder do
		if claimedModes[modeId] then
			table.insert(supportedModeIds, modeId)
		end
	end

	table.sort(errors)
	table.freeze(errors)
	if #errors > 0 then
		return table.freeze({
			ok = false,
			errors = errors,
			map = nil,
		})
	end

	local frozenDefinition = deepFreeze(definition) :: Definition
	deepFreeze(capabilities)
	deepFreeze(derivedModeIds)
	deepFreeze(supportedModeIds)
	deepFreeze(playerClipChunks)
	deepFreeze(targetsById)
	local validated: ValidatedMap = {
		Definition = frozenDefinition,
		MapId = frozenDefinition.mapId,
		Revision = frozenDefinition.revision,
		DisplayName = frozenDefinition.displayName,
		Capabilities = capabilities,
		DerivedModeIds = derivedModeIds,
		SupportedModeIds = supportedModeIds,
		PlayerClipChunks = playerClipChunks,
		TargetsById = targetsById,
		TriggerDefinitions = validatedTriggerDefinitions,
		MoverDefinitions = validatedMoverDefinitions,
		MoverBinaryPrograms = validatedMoverBinaryPrograms,
		MoverBinaryPolicies = validatedMoverBinaryPolicies,
		InitialMoverDefinitions = initialMoverDefinitions,
	}
	deepFreeze(validated)
	return table.freeze({
		ok = true,
		errors = errors,
		map = validated,
	})
end

MapSchema.SchemaVersion = SCHEMA_VERSION
MapSchema.ModeOrder = ModeOrder
MapSchema.SpawnClasses = SpawnClasses
MapSchema.SurfaceKinds = SurfaceKinds
MapSchema.ChunkShapes = ChunkShapes
MapSchema.TextureFaces = TextureFaces
MapSchema.WaterContents = WaterContents
MapSchema.MaximumWaterVolumes = MAXIMUM_WATER_VOLUMES
MapSchema.MaximumNoDropVolumes = MAXIMUM_NO_DROP_VOLUMES
MapSchema.MaximumMovers = MAXIMUM_MOVERS
MapSchema.MaximumVisualPieces = MAXIMUM_VISUAL_PIECES
MapSchema.MaximumPlayerClipChunks = PlayerClipDomain.MaximumChunks
MapSchema.MaximumStaticTextureFaceRoles = MAXIMUM_STATIC_TEXTURE_FACE_ROLES

return table.freeze(MapSchema)
