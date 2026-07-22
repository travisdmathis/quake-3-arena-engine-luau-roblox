--!strict

-- Dependency-free invariants shared by the Persistent collision verifier and
-- the client presentation layer. Keeping these checks outside the map
-- rendering stack lets pure movement kernels load collision contracts without
-- importing asset catalogs or MapSchema.

local StaticWorldPartPolicy = {}

local LARGE_MAP_CHUNK_THRESHOLD = 4096
local LARGE_MAP_MINIMUM_SHADOW_FACE_AREA = 128
local MANAGED_TEXTURE_ATTRIBUTE = "Q3EngineManagedStaticTexture"
local MANAGED_TEXTURE_FACE_ATTRIBUTE = "Q3EngineManagedTextureFace"
local MANAGED_TEXTURE_NAME_PREFIX = "Q3EngineMaterialTexture_"

local TEXTURE_STUDS_PER_TILE: { [string]: number } = table.freeze({
	Wall = 8,
	Header = 8,
	Trim = 6,
	Floor = 10,
	Ceiling = 10,
	Reveal = 6,
	Accent = 6,
	Grate = 8,
})

local VALID_TEXTURE_FACES: { [string]: boolean } = table.freeze({
	Left = true,
	Right = true,
	Front = true,
	Back = true,
	Top = true,
	Bottom = true,
})

function StaticWorldPartPolicy.IsManagedTexture(value: Instance): boolean
	if not value:IsA("Texture") or value:GetAttribute(MANAGED_TEXTURE_ATTRIBUTE) ~= true then
		return false
	end
	local texture = value :: Texture
	local face = texture.Face.Name
	local role = texture:GetAttribute("Q3EngineMaterialRole")
	if
		VALID_TEXTURE_FACES[face] ~= true
		or type(role) ~= "string"
		or texture.Name ~= MANAGED_TEXTURE_NAME_PREFIX .. face
		or texture:GetAttribute(MANAGED_TEXTURE_FACE_ATTRIBUTE) ~= face
		or texture:GetAttribute("Q3EngineVisualOnly") ~= true
		or type(texture:GetAttribute("Q3EngineTextureAssetKey")) ~= "string"
		or texture.Texture == ""
		or texture.Color3 ~= Color3.new(1, 1, 1)
		or texture.Transparency ~= 0
	then
		return false
	end
	local studsPerTile = TEXTURE_STUDS_PER_TILE[role]
	return studsPerTile ~= nil and texture.StudsPerTileU == studsPerTile and texture.StudsPerTileV == studsPerTile
end

function StaticWorldPartPolicy.ShouldCastShadow(chunk: any, staticChunkCount: number): boolean
	if chunk.visual ~= true then
		return false
	end
	if staticChunkCount < LARGE_MAP_CHUNK_THRESHOLD then
		return true
	end
	local size = chunk.size
	local maximumFaceArea = math.max(size.X * size.Y, size.X * size.Z, size.Y * size.Z)
	return maximumFaceArea >= LARGE_MAP_MINIMUM_SHADOW_FACE_AREA
end

StaticWorldPartPolicy.LargeMapChunkThreshold = LARGE_MAP_CHUNK_THRESHOLD
StaticWorldPartPolicy.LargeMapMinimumShadowFaceArea = LARGE_MAP_MINIMUM_SHADOW_FACE_AREA
StaticWorldPartPolicy.ManagedTextureAttribute = MANAGED_TEXTURE_ATTRIBUTE
StaticWorldPartPolicy.ManagedTextureFaceAttribute = MANAGED_TEXTURE_FACE_ATTRIBUTE
StaticWorldPartPolicy.ManagedTextureNamePrefix = MANAGED_TEXTURE_NAME_PREFIX
StaticWorldPartPolicy.TextureStudsPerTile = TEXTURE_STUDS_PER_TILE

return table.freeze(StaticWorldPartPolicy)
