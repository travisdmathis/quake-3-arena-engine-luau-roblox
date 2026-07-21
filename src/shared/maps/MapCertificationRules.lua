--!strict

local MapSchema = require(script.Parent.MapSchema)
local MapSpatialRules = require(script.Parent.MapSpatialRules)

local MapCertificationRules = {}

export type RouteEvidence = {
	routeId: string,
	distanceStuds: number,
	nominalTravelSeconds: number,
}

export type Report = {
	ok: boolean,
	errors: { string },
	mapId: string?,
	maximumPlayers: number?,
	teamSize: number?,
	routes: { RouteEvidence },
}

local function contains(values: { string }, expected: string): boolean
	for _, value in values do
		if value == expected then
			return true
		end
	end
	return false
end

local function closeVector(left: Vector3, right: Vector3, epsilon: number): boolean
	return (left - right).Magnitude <= epsilon
end

local function denseArray(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	local maximumIndex = 0
	for key in value :: any do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return false
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
	end
	return count == maximumIndex
end

local function flagPositions(definition: MapSchema.Definition): (Vector3?, Vector3?)
	local red: Vector3? = nil
	local blue: Vector3? = nil
	for _, flag in definition.flagBases do
		if flag.teamId == "Red" then
			red = flag.position
		elseif flag.teamId == "Blue" then
			blue = flag.position
		end
	end
	return red, blue
end

local function routeDistance(points: { Vector3 }): number
	local distance = 0
	for index = 2, #points do
		distance += (points[index] - points[index - 1]).Magnitude
	end
	return distance
end

function MapCertificationRules.Validate(mapValue: unknown, profileValue: unknown): Report
	local errors: { string } = {}
	if type(mapValue) ~= "table" or type((mapValue :: any).Definition) ~= "table" then
		return table.freeze({
			ok = false,
			errors = table.freeze({ "Map:MustBeValidatedMap" }),
			mapId = nil,
			maximumPlayers = nil,
			teamSize = nil,
			routes = table.freeze({}),
		})
	end
	if type(profileValue) ~= "table" then
		return table.freeze({
			ok = false,
			errors = table.freeze({ "Profile:MustBeTable" }),
			mapId = nil,
			maximumPlayers = nil,
			teamSize = nil,
			routes = table.freeze({}),
		})
	end
	local map = mapValue :: MapSchema.ValidatedMap
	local definition = map.Definition
	local profile = profileValue :: any
	if profile.mapId ~= map.MapId then
		table.insert(errors, "Profile:MapIdMismatch")
	end
	if
		type(profile.maximumPlayers) ~= "number"
		or profile.maximumPlayers % 1 ~= 0
		or profile.maximumPlayers < 2
		or profile.maximumPlayers > #definition.spawns
	then
		table.insert(errors, "Profile:MaximumPlayersInvalid")
	end
	if not denseArray(profile.modes) or #profile.modes == 0 then
		table.insert(errors, "Profile:ModesInvalid")
	else
		local claimed: { [string]: boolean } = {}
		for _, modeId in profile.modes do
			if type(modeId) ~= "string" or not contains(map.SupportedModeIds, modeId) then
				table.insert(errors, "Profile:ModeUnsupported:" .. tostring(modeId))
			elseif claimed[modeId] then
				table.insert(errors, "Profile:ModeDuplicate:" .. modeId)
			else
				claimed[modeId] = true
			end
		end
	end
	if #definition.staticChunks == 0 then
		table.insert(errors, "Map:MissingCollision")
	end
	if #definition.visualPieces == 0 then
		table.insert(errors, "Map:MissingArenaKitVisuals")
	end
	local maximumRouteSegmentStuds = profile.maximumRouteSegmentStuds
	if type(maximumRouteSegmentStuds) ~= "number" or maximumRouteSegmentStuds <= 0 then
		table.insert(errors, "Profile:MaximumRouteSegmentInvalid")
		maximumRouteSegmentStuds = math.huge
	end
	local maximumPairedRouteDeltaStuds = profile.maximumPairedRouteDeltaStuds
	if type(maximumPairedRouteDeltaStuds) ~= "number" or maximumPairedRouteDeltaStuds < 0 then
		table.insert(errors, "Profile:MaximumPairedRouteDeltaInvalid")
		maximumPairedRouteDeltaStuds = 0
	end
	local nominalTravelSpeedStudsPerSecond = profile.nominalTravelSpeedStudsPerSecond
	if type(nominalTravelSpeedStudsPerSecond) ~= "number" or nominalTravelSpeedStudsPerSecond <= 0 then
		table.insert(errors, "Profile:NominalTravelSpeedInvalid")
		nominalTravelSpeedStudsPerSecond = 1
	end
	for _, chunk in definition.staticChunks do
		if not chunk.collision then
			table.insert(errors, "Map:StaticChunkNotAuthoritative:" .. chunk.id)
		end
	end

	local teamSize = profile.teamSize
	local redFlag, blueFlag = flagPositions(definition)
	if teamSize ~= nil then
		if type(teamSize) ~= "number" or teamSize % 1 ~= 0 or teamSize < 1 then
			table.insert(errors, "Profile:TeamSizeInvalid")
		else
			local redSpawns = 0
			local blueSpawns = 0
			for _, spawn in definition.spawns do
				if spawn.spawnClass == MapSchema.SpawnClasses.TeamRed then
					redSpawns += 1
					local mirrored = false
					for _, candidate in definition.spawns do
						if
							candidate.spawnClass == MapSchema.SpawnClasses.TeamBlue
							and closeVector(
								candidate.position,
								Vector3.new(-spawn.position.X, spawn.position.Y, spawn.position.Z),
								0.01
							)
						then
							mirrored = true
							break
						end
					end
					if not mirrored then
						table.insert(errors, "Map:TeamSpawnNotMirrored:" .. spawn.id)
					end
				elseif spawn.spawnClass == MapSchema.SpawnClasses.TeamBlue then
					blueSpawns += 1
				end
			end
			if redSpawns < teamSize or blueSpawns < teamSize then
				table.insert(errors, "Map:InsufficientTeamSpawns")
			end
		end
		if not redFlag or not blueFlag then
			table.insert(errors, "Map:MissingFlagBases")
		elseif not closeVector(blueFlag, Vector3.new(-redFlag.X, redFlag.Y, redFlag.Z), 0.01) then
			table.insert(errors, "Map:FlagBasesNotMirrored")
		end
	end

	local routeReports: { RouteEvidence } = {}
	local routeDistanceById: { [string]: number } = {}
	if not denseArray(profile.routes) then
		table.insert(errors, "Profile:RoutesInvalid")
	else
		if teamSize ~= nil and #profile.routes < 3 then
			table.insert(errors, "Profile:MissingCompleteFlagRoutes")
		end
		local limits = { bounds = definition.bounds, killVolumes = definition.killVolumes }
		for index, route in profile.routes do
			local routePath = string.format("Route[%d]", index)
			if type(route) ~= "table" or type(route.id) ~= "string" or route.id == "" then
				table.insert(errors, routePath .. ":Invalid")
				continue
			end
			if routeDistanceById[route.id] then
				table.insert(errors, routePath .. ":DuplicateId")
				continue
			end
			if not denseArray(route.points) or #route.points < 2 then
				table.insert(errors, routePath .. ":PointsInvalid")
				continue
			end
			if redFlag and not closeVector(route.points[1], redFlag, 0.01) then
				table.insert(errors, routePath .. ":MustStartAtRedFlag")
			end
			if blueFlag and not closeVector(route.points[#route.points], blueFlag, 0.01) then
				table.insert(errors, routePath .. ":MustEndAtBlueFlag")
			end
			for pointIndex, point in route.points do
				if typeof(point) ~= "Vector3" then
					table.insert(errors, string.format("%s:Point%dInvalid", routePath, pointIndex))
					continue
				end
				local classification = MapSpatialRules.ClassifyBox(point, Vector3.one * 0.1, limits)
				if classification ~= MapSpatialRules.Classifications.Playable then
					table.insert(errors, string.format("%s:Point%dNotPlayable", routePath, pointIndex))
				end
				if pointIndex > 1 then
					local segment = (point - route.points[pointIndex - 1]).Magnitude
					if segment > maximumRouteSegmentStuds then
						table.insert(errors, string.format("%s:Segment%dTooLong", routePath, pointIndex - 1))
					end
				end
			end
			local distance = routeDistance(route.points)
			routeDistanceById[route.id] = distance
			table.insert(
				routeReports,
				table.freeze({
					routeId = route.id,
					distanceStuds = distance,
					nominalTravelSeconds = distance / nominalTravelSpeedStudsPerSecond,
				})
			)
		end
	end
	if not denseArray(profile.balancedRoutePairs) then
		table.insert(errors, "Profile:BalancedRoutePairsInvalid")
	else
		for index, pair in profile.balancedRoutePairs do
			local left = if type(pair) == "table" then routeDistanceById[pair.leftRouteId] else nil
			local right = if type(pair) == "table" then routeDistanceById[pair.rightRouteId] else nil
			if not left or not right then
				table.insert(errors, string.format("BalancedRoutePair[%d]:MissingRoute", index))
			elseif math.abs(left - right) > maximumPairedRouteDeltaStuds then
				table.insert(errors, string.format("BalancedRoutePair[%d]:TravelDeltaExceeded", index))
			end
		end
	end

	table.sort(errors)
	table.freeze(errors)
	table.freeze(routeReports)
	return table.freeze({
		ok = #errors == 0,
		errors = errors,
		mapId = map.MapId,
		maximumPlayers = profile.maximumPlayers,
		teamSize = teamSize,
		routes = routeReports,
	})
end

return table.freeze(MapCertificationRules)
