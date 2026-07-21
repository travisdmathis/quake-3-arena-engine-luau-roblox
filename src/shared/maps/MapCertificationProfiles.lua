--!strict

local ModeIds = require(script.Parent.Parent.match.ModeIds)

local MapCertificationProfiles = {}

export type Route = {
	id: string,
	points: { Vector3 },
}

export type RoutePair = {
	leftRouteId: string,
	rightRouteId: string,
}

export type Profile = {
	mapId: string,
	maximumPlayers: number,
	teamSize: number?,
	modes: { string },
	routes: { Route },
	balancedRoutePairs: { RoutePair },
	maximumRouteSegmentStuds: number,
	maximumPairedRouteDeltaStuds: number,
	nominalTravelSpeedStudsPerSecond: number,
}

local aerowalk: Profile = {
	mapId = "aerowalk_layout_v1",
	maximumPlayers = 4,
	teamSize = nil,
	modes = {
		ModeIds.Deathmatch,
		ModeIds.OneShot,
		ModeIds.Duel,
	},
	routes = {},
	balancedRoutePairs = {},
	maximumRouteSegmentStuds = 96,
	maximumPairedRouteDeltaStuds = 0.25,
	nominalTravelSpeedStudsPerSecond = 32,
}

-- Queue composition owns the 2v2 team size. The map profile records the
-- shared four-player capacity without coupling map certification to a queue.
local bloodRun: Profile = {
	mapId = "blood_run_layout_v1",
	maximumPlayers = 4,
	teamSize = nil,
	modes = {
		ModeIds.Deathmatch,
		ModeIds.Duel,
		ModeIds.TeamDeathmatch,
	},
	routes = {},
	balancedRoutePairs = {},
	maximumRouteSegmentStuds = 96,
	maximumPairedRouteDeltaStuds = 0.25,
	nominalTravelSpeedStudsPerSecond = 32,
}

-- The supplied dm17duel readme identifies the layout as a 1v1 / two-to-four
-- player arena. One-Shot itself supports up to eight active players, but this
-- map's certification intentionally retains the narrower authored capacity.
local dm17Duel: Profile = {
	mapId = "dm17_duel_layout_v1",
	maximumPlayers = 4,
	teamSize = nil,
	modes = {
		ModeIds.OneShot,
	},
	routes = {},
	balancedRoutePairs = {},
	maximumRouteSegmentStuds = 96,
	maximumPairedRouteDeltaStuds = 0.25,
	nominalTravelSpeedStudsPerSecond = 32,
}

-- Blood Covenant's neutral starts remain available to FFA/Duel/One-Shot.
-- Arena Elimination consumes an additional explicit local team-spawn overlay;
-- it is not source-authored CTF data and therefore has no flag-route profile.
local bloodCovenant: Profile = {
	mapId = "blood_covenant_layout_v1",
	maximumPlayers = 8,
	teamSize = nil,
	modes = {
		ModeIds.OneShot,
		ModeIds.ArenaElimination,
		ModeIds.Deathmatch,
		ModeIds.Duel,
	},
	routes = {},
	balancedRoutePairs = {},
	maximumRouteSegmentStuds = 96,
	maximumPairedRouteDeltaStuds = 0.25,
	nominalTravelSpeedStudsPerSecond = 32,
}

local redFlag = Vector3.new(-106, 2.5, 0)
local blueFlag = Vector3.new(106, 2.5, 0)
local foundry: Profile = {
	mapId = "foundry_divide_v1",
	maximumPlayers = 8,
	teamSize = 4,
	modes = {
		ModeIds.TeamDeathmatch,
		ModeIds.CaptureTheFlag,
	},
	routes = {
		{
			id = "center_route",
			points = {
				redFlag,
				Vector3.new(-78, 2.5, 0),
				Vector3.new(-53, 2.5, 0),
				Vector3.new(-40, 5, 0),
				Vector3.new(-26, 11, 0),
				Vector3.new(0, 12.5, 0),
				Vector3.new(26, 11, 0),
				Vector3.new(40, 5, 0),
				Vector3.new(53, 2.5, 0),
				Vector3.new(78, 2.5, 0),
				blueFlag,
			},
		},
		{
			id = "north_route",
			points = {
				redFlag,
				Vector3.new(-100, 2.5, -40),
				Vector3.new(-94, 3.5, -58),
				Vector3.new(-80, 9.5, -58),
				Vector3.new(0, 9.5, -58),
				Vector3.new(80, 9.5, -58),
				Vector3.new(94, 3.5, -58),
				Vector3.new(100, 2.5, -40),
				blueFlag,
			},
		},
		{
			id = "south_route",
			points = {
				redFlag,
				Vector3.new(-100, 2.5, 40),
				Vector3.new(-94, 3.5, 58),
				Vector3.new(-80, 9.5, 58),
				Vector3.new(0, 9.5, 58),
				Vector3.new(80, 9.5, 58),
				Vector3.new(94, 3.5, 58),
				Vector3.new(100, 2.5, 40),
				blueFlag,
			},
		},
	},
	balancedRoutePairs = {
		{ leftRouteId = "north_route", rightRouteId = "south_route" },
	},
	maximumRouteSegmentStuds = 82,
	maximumPairedRouteDeltaStuds = 0.05,
	nominalTravelSpeedStudsPerSecond = 32,
}

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
	table.freeze(value)
	return value
end

deepFreeze(aerowalk)
deepFreeze(bloodRun)
deepFreeze(dm17Duel)
deepFreeze(bloodCovenant)
deepFreeze(foundry)

local byId: { [string]: Profile } = {
	[aerowalk.mapId] = aerowalk,
	[bloodRun.mapId] = bloodRun,
	[dm17Duel.mapId] = dm17Duel,
	[bloodCovenant.mapId] = bloodCovenant,
	[foundry.mapId] = foundry,
}
table.freeze(byId)

function MapCertificationProfiles.Get(mapId: string): Profile?
	return byId[mapId]
end

MapCertificationProfiles.ById = byId
MapCertificationProfiles.All = table.freeze({ aerowalk, bloodRun, dm17Duel, bloodCovenant, foundry })

return table.freeze(MapCertificationProfiles)
