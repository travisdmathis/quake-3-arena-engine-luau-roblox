--[[
SPDX-License-Identifier: GPL-2.0-or-later

Prepared server composition of base-Q3 EV_USE_ITEM1 ordering from:
  code/game/g_active.c (drop carried flag, SelectSpawnPoint, TeleportPlayer)
  code/game/g_misc.c (TeleportPlayer)
  code/game/g_utils.c (G_KillBox)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local FlagService = require(script.Parent.FlagService)
local MovementService = require(script.Parent.MovementService)

export type Prepared = {}
export type Summary = {
	read player: Player,
	read flag: FlagService.PreparedPersonalTeleporterDropSummary,
	read movement: MovementService.PreparedPersonalTeleportSummary,
}

local CombatPersonalTeleporterCoordinator = {}
local capabilities: { [Prepared]: any } = setmetatable({}, { __mode = "k" })

function CombatPersonalTeleporterCoordinator.Prepare(player: Player): (Prepared?, Summary?, string?)
	local flagPrepared, flagSummary, flagError = FlagService.PreparePersonalTeleporterDrop(player)
	if not flagPrepared or not flagSummary then
		return nil, nil, flagError or "personal-teleporter-flag-prepare-failed"
	end
	local movementPrepared, movementSummary, movementError = MovementService.PreparePersonalTeleport(player)
	if not movementPrepared or not movementSummary then
		FlagService.AbortPreparedPersonalTeleporterDrop(flagPrepared)
		return nil, nil, movementError or "personal-teleporter-movement-prepare-failed"
	end
	local summary: Summary = table.freeze({
		player = player,
		flag = flagSummary,
		movement = movementSummary,
	})
	local prepared: Prepared = table.freeze({})
	capabilities[prepared] = {
		status = "Prepared",
		flagPrepared = flagPrepared,
		movementPrepared = movementPrepared,
		summary = summary,
	}
	return prepared, summary, nil
end

function CombatPersonalTeleporterCoordinator.CanApply(value: unknown): (boolean, string?)
	local capability = if type(value) == "table" then capabilities[value :: Prepared] else nil
	if not capability or capability.status ~= "Prepared" then
		return false, "invalid-personal-teleporter-composite"
	end
	local flagCurrent, flagError = FlagService.CanApplyPreparedPersonalTeleporterDrop(capability.flagPrepared)
	if not flagCurrent then
		return false, flagError
	end
	local movementCurrent, movementError = MovementService.CanApplyPreparedPersonalTeleport(capability.movementPrepared)
	if not movementCurrent then
		return false, movementError
	end
	return true, nil
end

function CombatPersonalTeleporterCoordinator.Apply(value: unknown): boolean
	local prepared = if type(value) == "table" then value :: Prepared else nil
	local capability = if prepared then capabilities[prepared] else nil
	if not capability or select(1, CombatPersonalTeleporterCoordinator.CanApply(prepared)) ~= true then
		return false
	end
	assert(
		FlagService.ApplyPreparedPersonalTeleporterDrop(capability.flagPrepared),
		"prepared Personal Teleporter flag drop failed after preflight"
	)
	assert(
		MovementService.ApplyPreparedPersonalTeleport(capability.movementPrepared),
		"prepared Personal Teleporter movement failed after flag drop"
	)
	capability.status = "Applied"
	capabilities[prepared] = nil
	return true
end

function CombatPersonalTeleporterCoordinator.Abort(value: unknown): boolean
	local prepared = if type(value) == "table" then value :: Prepared else nil
	local capability = if prepared then capabilities[prepared] else nil
	if not capability or capability.status ~= "Prepared" then
		return false
	end
	local movementAborted = MovementService.AbortPreparedPersonalTeleport(capability.movementPrepared)
	local flagAborted = FlagService.AbortPreparedPersonalTeleporterDrop(capability.flagPrepared)
	if not movementAborted or not flagAborted then
		return false
	end
	capability.status = "Aborted"
	capabilities[prepared] = nil
	return true
end

return table.freeze(CombatPersonalTeleporterCoordinator)
