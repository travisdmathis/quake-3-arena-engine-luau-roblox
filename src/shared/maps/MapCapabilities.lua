--!strict

local MapCapabilities = {}

export type Capability = "CombatSpawns" | "TeamSpawns" | "FlagBases"
export type CapabilitySet = { [string]: boolean }

local Values = table.freeze({
	CombatSpawns = "CombatSpawns" :: Capability,
	TeamSpawns = "TeamSpawns" :: Capability,
	FlagBases = "FlagBases" :: Capability,
})

local Order: { Capability } = {
	Values.CombatSpawns,
	Values.TeamSpawns,
	Values.FlagBases,
}
table.freeze(Order)

local ids: { [string]: boolean } = {}
for _, capability in Order do
	ids[capability] = true
end
table.freeze(ids)

function MapCapabilities.IsCapability(value: unknown): boolean
	return type(value) == "string" and ids[value] == true
end

MapCapabilities.Values = Values
MapCapabilities.Order = Order

return table.freeze(MapCapabilities)
