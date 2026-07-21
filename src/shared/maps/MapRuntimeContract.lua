--!strict

local FlagDefinitions = require(script.Parent.Parent.ctf.FlagDefinitions)
local ModeIds = require(script.Parent.Parent.match.ModeIds)
local WorldPointContents = require(script.Parent.Parent.simulation.WorldPointContents)
local MapCapabilities = require(script.Parent.MapCapabilities)
local MapSchema = require(script.Parent.MapSchema)

local MapRuntimeContract = {}

export type Capability = MapCapabilities.Capability
export type CapabilitySet = MapCapabilities.CapabilitySet
export type TeamSpawnCounts = {
	Red: number,
	Blue: number,
}
export type FlagBaseMap = { [string]: BasePart }
export type Inspection = {
	capabilities: CapabilitySet,
	spawnCount: number,
	teamSpawnCounts: TeamSpawnCounts,
	flagBases: FlagBaseMap,
	waterVolumes: { WorldPointContents.WaterVolume },
	noDropVolumes: { WorldPointContents.NoDropVolume },
	diagnostics: { string },
}
export type RuntimeMap = {
	capabilities: CapabilitySet,
	spawnCount: number,
	teamSpawnCounts: TeamSpawnCounts,
	flagBases: FlagBaseMap,
	diagnostics: { string },
	mapId: string,
	revision: number,
	displayName: string,
	bounds: MapSchema.Bounds,
	killVolumes: { MapSchema.KillVolume },
	waterVolumes: { WorldPointContents.WaterVolume },
	noDropVolumes: { WorldPointContents.NoDropVolume },
	supportedModeIds: { string },
}
export type PointContentsSnapshot = {
	waterVolumes: { WorldPointContents.WaterVolume },
	noDropVolumes: { WorldPointContents.NoDropVolume },
}

local Capabilities = MapCapabilities.Values
local CapabilityOrder = MapCapabilities.Order

local function isFiniteVector3(value: unknown): boolean
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

local function isTeamId(value: unknown): boolean
	return value == FlagDefinitions.TeamIds.Red or value == FlagDefinitions.TeamIds.Blue
end

local function schemaWaterContents(contents: MapSchema.WaterContent): number
	if contents == MapSchema.WaterContents.Water then
		return WorldPointContents.Contents.Water
	elseif contents == MapSchema.WaterContents.Slime then
		return WorldPointContents.Contents.Slime
	end
	assert(contents == MapSchema.WaterContents.Lava, "validated water contents disappeared")
	return WorldPointContents.Contents.Lava
end

local function expectedWaterVolumes(map: MapSchema.ValidatedMap): { WorldPointContents.WaterVolume }
	local source = {}
	for _, volume in map.Definition.waterVolumes do
		local rotation = volume.rotationDegrees
		table.insert(source, {
			id = volume.id,
			cframe = CFrame.new(volume.position)
				* CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z)),
			size = volume.size,
			contents = schemaWaterContents(volume.contents),
		})
	end
	local definitions, definitionError = WorldPointContents.ValidateAndOrderWaterVolumes(source)
	assert(definitions, definitionError or "validated schema produced invalid water volumes")
	return definitions
end

local function expectedNoDropVolumes(map: MapSchema.ValidatedMap): { WorldPointContents.NoDropVolume }
	local source = {}
	for _, volume in map.Definition.noDropVolumes do
		local rotation = volume.rotationDegrees
		table.insert(source, {
			id = volume.id,
			cframe = CFrame.new(volume.position)
				* CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z)),
			size = volume.size,
			contents = WorldPointContents.Contents.NoDrop,
		})
	end
	local definitions, definitionError = WorldPointContents.ValidateAndOrderNoDropVolumes(source)
	assert(definitions, definitionError or "validated schema produced invalid no-drop volumes")
	return definitions
end

local function appendWaterVolumeDiagnostics(
	diagnostics: { string },
	live: { WorldPointContents.WaterVolume },
	expected: { WorldPointContents.WaterVolume }
)
	local liveById: { [string]: WorldPointContents.WaterVolume } = {}
	for _, volume in live do
		liveById[volume.id] = volume
	end
	local expectedById: { [string]: WorldPointContents.WaterVolume } = {}
	for _, volume in expected do
		expectedById[volume.id] = volume
	end

	if #live == #expected then
		for index, expectedVolume in expected do
			local liveVolume = live[index]
			if liveVolume.id ~= expectedVolume.id then
				table.insert(
					diagnostics,
					string.format("SchemaWaterVolumeIdMismatch:%d:%s:%s", index, expectedVolume.id, liveVolume.id)
				)
			end
		end
	end

	for _, expectedVolume in expected do
		local liveVolume = liveById[expectedVolume.id]
		if not liveVolume then
			table.insert(diagnostics, "SchemaWaterVolumeMissing:" .. expectedVolume.id)
			continue
		end
		if liveVolume.cframe ~= expectedVolume.cframe then
			table.insert(diagnostics, "SchemaWaterVolumeCFrameMismatch:" .. expectedVolume.id)
		end
		if liveVolume.size ~= expectedVolume.size then
			table.insert(diagnostics, "SchemaWaterVolumeSizeMismatch:" .. expectedVolume.id)
		end
		if liveVolume.contents ~= expectedVolume.contents then
			table.insert(diagnostics, "SchemaWaterVolumeContentsMismatch:" .. expectedVolume.id)
		end
	end
	for _, liveVolume in live do
		if not expectedById[liveVolume.id] then
			table.insert(diagnostics, "SchemaWaterVolumeExtra:" .. liveVolume.id)
		end
	end
end

local function appendNoDropVolumeDiagnostics(
	diagnostics: { string },
	live: { WorldPointContents.NoDropVolume },
	expected: { WorldPointContents.NoDropVolume }
)
	local liveById: { [string]: WorldPointContents.NoDropVolume } = {}
	for _, volume in live do
		liveById[volume.id] = volume
	end
	local expectedById: { [string]: WorldPointContents.NoDropVolume } = {}
	for _, volume in expected do
		expectedById[volume.id] = volume
	end

	if #live == #expected then
		for index, expectedVolume in expected do
			local liveVolume = live[index]
			if liveVolume.id ~= expectedVolume.id then
				table.insert(
					diagnostics,
					string.format("SchemaNoDropVolumeIdMismatch:%d:%s:%s", index, expectedVolume.id, liveVolume.id)
				)
			end
		end
	end

	for _, expectedVolume in expected do
		local liveVolume = liveById[expectedVolume.id]
		if not liveVolume then
			table.insert(diagnostics, "SchemaNoDropVolumeMissing:" .. expectedVolume.id)
			continue
		end
		if liveVolume.cframe ~= expectedVolume.cframe then
			table.insert(diagnostics, "SchemaNoDropVolumeCFrameMismatch:" .. expectedVolume.id)
		end
		if liveVolume.size ~= expectedVolume.size then
			table.insert(diagnostics, "SchemaNoDropVolumeSizeMismatch:" .. expectedVolume.id)
		end
		if liveVolume.contents ~= expectedVolume.contents then
			table.insert(diagnostics, "SchemaNoDropVolumeContentsMismatch:" .. expectedVolume.id)
		end
	end
	for _, liveVolume in live do
		if not expectedById[liveVolume.id] then
			table.insert(diagnostics, "SchemaNoDropVolumeExtra:" .. liveVolume.id)
		end
	end
end

function MapRuntimeContract.GetPointContentsSnapshot(map: MapSchema.ValidatedMap): PointContentsSnapshot
	assert(type(map) == "table", "point-contents snapshot requires a validated map")
	return table.freeze({
		waterVolumes = expectedWaterVolumes(map),
		noDropVolumes = expectedNoDropVolumes(map),
	})
end

local function sortedDescendants(root: Instance): { Instance }
	local descendants = root:GetDescendants()
	table.sort(descendants, function(left, right)
		local leftName = left:GetFullName()
		local rightName = right:GetFullName()
		if leftName == rightName then
			return left.ClassName < right.ClassName
		end
		return leftName < rightName
	end)
	return descendants
end

local function flagTeamFor(part: BasePart, diagnostics: { string }): string?
	local attribute = part:GetAttribute(FlagDefinitions.MarkerTeamAttribute)
	if attribute ~= nil then
		if not isTeamId(attribute) then
			table.insert(diagnostics, string.format("InvalidFlagTeam:%s", part:GetFullName()))
			return nil
		end
		return attribute :: string
	end

	for _, teamId in FlagDefinitions.TeamOrder do
		if part.Name == FlagDefinitions.MarkerNames[teamId] then
			return teamId
		end
	end
	return nil
end

function MapRuntimeContract.IsCapability(value: unknown): boolean
	return MapCapabilities.IsCapability(value)
end

function MapRuntimeContract.ValidateRequirements(value: unknown): (boolean, string?)
	if type(value) ~= "table" then
		return false, "RequirementsMustBeArray"
	end

	local seen: { [string]: boolean } = {}
	local count = 0
	local maximumIndex = 0
	for key, capability in value :: any do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return false, "RequirementsMustBeDenseArray"
		end
		if not MapRuntimeContract.IsCapability(capability) then
			return false, string.format("UnknownCapability:%s", tostring(capability))
		end
		if seen[capability] then
			return false, string.format("DuplicateCapability:%s", capability)
		end
		seen[capability] = true
		count += 1
		maximumIndex = math.max(maximumIndex, key)
	end
	if count == 0 then
		return false, "RequirementsMustNotBeEmpty"
	end
	if maximumIndex ~= count then
		return false, "RequirementsMustBeDenseArray"
	end
	return true, nil
end

function MapRuntimeContract.Supports(
	capabilities: CapabilitySet,
	requiredCapabilities: { Capability }
): (boolean, { Capability })
	local valid, validationError = MapRuntimeContract.ValidateRequirements(requiredCapabilities)
	assert(valid, validationError or "Invalid map capability requirements")

	local required: { [string]: boolean } = {}
	for _, capability in requiredCapabilities do
		required[capability] = true
	end

	local missing: { Capability } = {}
	for _, capability in CapabilityOrder do
		if required[capability] and capabilities[capability] ~= true then
			table.insert(missing, capability)
		end
	end
	table.freeze(missing)
	return #missing == 0, missing
end

function MapRuntimeContract.AllowsMode(runtimeMap: RuntimeMap, modeId: string): boolean
	for _, supportedModeId in runtimeMap.supportedModeIds do
		if supportedModeId == modeId then
			return true
		end
	end
	return false
end

function MapRuntimeContract.Inspect(root: Instance): Inspection
	assert(typeof(root) == "Instance", "MapRuntimeContract.Inspect requires an Instance")

	local diagnostics: { string } = {}
	local spawnCount = 0
	local teamSpawnCounts: TeamSpawnCounts = {
		Red = 0,
		Blue = 0,
	}
	local flagCandidates: { [string]: { BasePart } } = {
		[FlagDefinitions.TeamIds.Red] = {},
		[FlagDefinitions.TeamIds.Blue] = {},
	}

	for _, descendant in sortedDescendants(root) do
		local spawnOrigin = descendant:GetAttribute("ArenaSpawnOrigin")
		if spawnOrigin ~= nil then
			if isFiniteVector3(spawnOrigin) then
				spawnCount += 1
				local spawnTeam = descendant:GetAttribute("ArenaSpawnTeam")
				if isTeamId(spawnTeam) then
					teamSpawnCounts[spawnTeam :: string] += 1
				elseif spawnTeam ~= nil then
					table.insert(diagnostics, string.format("InvalidSpawnTeam:%s", descendant:GetFullName()))
				end
			else
				table.insert(diagnostics, string.format("InvalidSpawnOrigin:%s", descendant:GetFullName()))
			end
		end

		if descendant:IsA("BasePart") then
			local teamId = flagTeamFor(descendant, diagnostics)
			if teamId then
				table.insert(flagCandidates[teamId], descendant)
			end
		end
	end

	local flagBases: FlagBaseMap = {}
	for _, teamId in FlagDefinitions.TeamOrder do
		local candidates = flagCandidates[teamId]
		if #candidates == 1 then
			flagBases[teamId] = candidates[1]
		elseif #candidates > 1 then
			table.insert(diagnostics, string.format("DuplicateFlagBase:%s:%d", teamId, #candidates))
		end
	end

	local capabilities: CapabilitySet = {
		[Capabilities.CombatSpawns] = spawnCount >= 2,
		[Capabilities.TeamSpawns] = teamSpawnCounts.Red >= 1 and teamSpawnCounts.Blue >= 1,
		[Capabilities.FlagBases] = flagBases.Red ~= nil and flagBases.Blue ~= nil,
	}
	local waterVolumes, waterVolumeError = WorldPointContents.CollectWaterVolumes(root)
	if not waterVolumes then
		table.insert(diagnostics, "WaterVolumes:" .. (waterVolumeError or "Invalid"))
		waterVolumes = table.freeze({}) :: { WorldPointContents.WaterVolume }
	end
	local noDropVolumes, noDropVolumeError = WorldPointContents.CollectNoDropVolumes(root)
	if not noDropVolumes then
		table.insert(diagnostics, "NoDropVolumes:" .. (noDropVolumeError or "Invalid"))
		noDropVolumes = table.freeze({}) :: { WorldPointContents.NoDropVolume }
	end

	table.freeze(capabilities)
	table.freeze(teamSpawnCounts)
	table.freeze(flagBases)
	table.freeze(diagnostics)
	return table.freeze({
		capabilities = capabilities,
		spawnCount = spawnCount,
		teamSpawnCounts = teamSpawnCounts,
		flagBases = flagBases,
		waterVolumes = waterVolumes,
		noDropVolumes = noDropVolumes,
		diagnostics = diagnostics,
	})
end

local function supportsMode(capabilities: CapabilitySet, modeId: string): boolean
	if modeId == ModeIds.ArenaElimination then
		return capabilities.CombatSpawns == true and capabilities.TeamSpawns == true
	elseif modeId == ModeIds.CaptureTheFlag then
		return capabilities.CombatSpawns == true and capabilities.TeamSpawns == true and capabilities.FlagBases == true
	end
	return capabilities.CombatSpawns == true
end

function MapRuntimeContract.BindSchema(inspection: Inspection, map: MapSchema.ValidatedMap): RuntimeMap
	assert(type(inspection) == "table", "MapRuntimeContract.BindSchema requires an inspection")
	assert(type(map) == "table", "MapRuntimeContract.BindSchema requires a validated map")

	local diagnostics: { string } = {}
	for _, diagnostic in inspection.diagnostics do
		table.insert(diagnostics, diagnostic)
	end
	for _, capability in CapabilityOrder do
		if inspection.capabilities[capability] ~= map.Capabilities[capability] then
			table.insert(diagnostics, "SchemaCapabilityMismatch:" .. capability)
		end
	end
	appendWaterVolumeDiagnostics(diagnostics, inspection.waterVolumes, expectedWaterVolumes(map))
	appendNoDropVolumeDiagnostics(diagnostics, inspection.noDropVolumes, expectedNoDropVolumes(map))
	table.sort(diagnostics)
	table.freeze(diagnostics)

	-- Authored declarations are already schema-validated, but the live Instance
	-- tree remains authoritative. A mode is exported only when both agree.
	local supportedModeIds: { string } = {}
	for _, modeId in map.SupportedModeIds do
		if supportsMode(inspection.capabilities, modeId) then
			table.insert(supportedModeIds, modeId)
		end
	end
	table.freeze(supportedModeIds)

	return table.freeze({
		capabilities = inspection.capabilities,
		spawnCount = inspection.spawnCount,
		teamSpawnCounts = inspection.teamSpawnCounts,
		flagBases = inspection.flagBases,
		diagnostics = diagnostics,
		mapId = map.MapId,
		revision = map.Revision,
		displayName = map.DisplayName,
		bounds = map.Definition.bounds,
		killVolumes = map.Definition.killVolumes,
		waterVolumes = inspection.waterVolumes,
		noDropVolumes = inspection.noDropVolumes,
		supportedModeIds = supportedModeIds,
	})
end

MapRuntimeContract.Capabilities = Capabilities
MapRuntimeContract.CapabilityOrder = CapabilityOrder

return table.freeze(MapRuntimeContract)
