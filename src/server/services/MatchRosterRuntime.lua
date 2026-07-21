--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local MatchRulesCore = require(sharedRoot.match.MatchRulesCore)

export type Participation = "Active" | "Spectator"
export type TeamId = "Red" | "Blue"
export type Record = {
	joinOrder: number,
	participation: Participation,
	teamId: TeamId?,
	roundEligible: boolean,
	eliminatedCurrentLife: boolean,
}
export type Records = { [Player]: Record }
export type SourceOrderResolver = (player: Player) -> number?

local MatchRosterRuntime = {}

function MatchRosterRuntime.GetOrderedPlayers(records: Records): { Player }
	local ordered: { Player } = {}
	for player in records do
		table.insert(ordered, player)
	end
	table.sort(ordered, function(left: Player, right: Player): boolean
		local leftRecord = records[left]
		local rightRecord = records[right]
		if leftRecord.joinOrder ~= rightRecord.joinOrder then
			return leftRecord.joinOrder < rightRecord.joinOrder
		end
		if left.UserId ~= right.UserId then
			return left.UserId < right.UserId
		end
		return left.Name < right.Name
	end)
	return ordered
end

function MatchRosterRuntime.GetSourceOrderedPlayers(
	records: Records,
	resolveSourceOrder: SourceOrderResolver
): { Player }
	local ordered = MatchRosterRuntime.GetOrderedPlayers(records)
	table.sort(ordered, function(left: Player, right: Player): boolean
		local leftSourceOrder = resolveSourceOrder(left)
		local rightSourceOrder = resolveSourceOrder(right)
		if leftSourceOrder ~= nil and rightSourceOrder ~= nil then
			if leftSourceOrder ~= rightSourceOrder then
				return leftSourceOrder < rightSourceOrder
			end
		elseif leftSourceOrder ~= nil then
			return true
		elseif rightSourceOrder ~= nil then
			return false
		end
		local leftRecord = records[left]
		local rightRecord = records[right]
		if leftRecord.joinOrder ~= rightRecord.joinOrder then
			return leftRecord.joinOrder < rightRecord.joinOrder
		end
		return left.UserId < right.UserId
	end)
	return ordered
end

function MatchRosterRuntime.GetPlayerCount(records: Records): number
	local count = 0
	for _ in records do
		count += 1
	end
	return count
end

function MatchRosterRuntime.GetActivePlayerCount(records: Records): number
	local count = 0
	for _, record in records do
		if record.participation == "Active" then
			count += 1
		end
	end
	return count
end

function MatchRosterRuntime.GetTeamPlayerCount(records: Records, teamId: TeamId, eligibleOnly: boolean): number
	local count = 0
	for _, record in records do
		if
			record.participation == "Active"
			and record.teamId == teamId
			and (not eligibleOnly or record.roundEligible)
		then
			count += 1
		end
	end
	return count
end

function MatchRosterRuntime.ChooseBalancedTeam(records: Records): TeamId
	local redCount = MatchRosterRuntime.GetTeamPlayerCount(records, "Red", false)
	local blueCount = MatchRosterRuntime.GetTeamPlayerCount(records, "Blue", false)
	return MatchRulesCore.ChooseBalancedTeam(redCount, blueCount) :: TeamId
end

function MatchRosterRuntime.BuildRulesRoster(records: Records): { MatchRulesCore.RosterEntry }
	local roster: { MatchRulesCore.RosterEntry } = {}
	for _, player in MatchRosterRuntime.GetOrderedPlayers(records) do
		local record = records[player]
		table.insert(roster, {
			userId = player.UserId,
			joinOrder = record.joinOrder,
			participation = record.participation,
			teamId = record.teamId,
			roundEligible = record.roundEligible,
		})
	end
	return roster
end

function MatchRosterRuntime.ApplyDeathmatchActiveLimit(records: Records, activePlayerLimit: number): { Player }
	local selected =
		MatchRulesCore.SelectFreeForAllActiveUserIds(MatchRosterRuntime.BuildRulesRoster(records), activePlayerLimit)
	local selectedByUserId: { [number]: boolean } = {}
	local promoted: { Player } = {}
	for _, userId in selected do
		selectedByUserId[userId] = true
	end
	for player, record in records do
		local isActive = selectedByUserId[player.UserId] == true
		if isActive and record.participation ~= "Active" then
			table.insert(promoted, player)
		end
		record.participation = if isActive then "Active" else "Spectator"
		record.teamId = nil
		record.roundEligible = isActive
		if not isActive then
			record.eliminatedCurrentLife = false
		end
	end
	return promoted
end

return table.freeze(MatchRosterRuntime)
