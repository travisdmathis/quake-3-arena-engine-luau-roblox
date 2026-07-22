--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local MatchConfig = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchConfig"))

local MatchStandingsRuntime = {}

export type Participation = "Active" | "Spectator"
export type Record = {
	score: number,
	deaths: number,
	roundWins: number,
	roundEligible: boolean,
	participation: Participation,
	teamId: MatchConfig.TeamId?,
}
export type ScoreRow = {
	userId: number,
	name: string,
	displayName: string,
	score: number,
	deaths: number,
	roundWins: number,
	participation: Participation,
	teamId: MatchConfig.TeamId?,
	roundEligible: boolean,
}
export type TeamRow = {
	teamId: MatchConfig.TeamId,
	displayName: string,
	score: number,
	roundWins: number,
	playerCount: number,
	eligiblePlayerCount: number,
}

local function recordRoundWins(
	record: Record,
	rules: MatchConfig.Rules,
	teamRoundWins: { [string]: number }
): number
	local teamId = record.teamId
	if rules.TeamMode and teamId then
		return teamRoundWins[teamId] or 0
	end
	return record.roundWins
end

function MatchStandingsRuntime.BuildScoreRows(
	orderedPlayers: { Player },
	records: { [Player]: Record },
	rules: MatchConfig.Rules,
	teamRoundWins: { [string]: number },
	activeParticipation: Participation
): { ScoreRow }
	local rows: { ScoreRow } = {}
	for _, player in orderedPlayers do
		local record = records[player]
		table.insert(rows, {
			userId = player.UserId,
			name = player.Name,
			displayName = player.DisplayName,
			score = record.score,
			deaths = record.deaths,
			roundWins = recordRoundWins(record, rules, teamRoundWins),
			participation = record.participation,
			teamId = record.teamId,
			roundEligible = record.participation == activeParticipation and record.roundEligible,
		})
	end

	table.sort(rows, function(left: ScoreRow, right: ScoreRow): boolean
		if left.participation ~= right.participation then
			return left.participation == activeParticipation
		end
		if rules.ScoreType == "RoundWins" and left.roundWins ~= right.roundWins then
			return left.roundWins > right.roundWins
		end
		if left.score ~= right.score then
			return left.score > right.score
		end
		if left.deaths ~= right.deaths then
			return left.deaths < right.deaths
		end
		return left.userId < right.userId
	end)
	return rows
end

function MatchStandingsRuntime.BuildTeamRows(
	teamOrder: { MatchConfig.TeamId },
	records: { [Player]: Record },
	rules: MatchConfig.Rules,
	teamScores: { [string]: number },
	teamRoundWins: { [string]: number },
	activeParticipation: Participation
): { TeamRow }
	local rows: { TeamRow } = {}
	if not rules.TeamMode then
		return rows
	end
	for _, teamId in teamOrder do
		local playerCount = 0
		local eligiblePlayerCount = 0
		for _, record in records do
			if record.participation == activeParticipation and record.teamId == teamId then
				playerCount += 1
				if record.roundEligible then
					eligiblePlayerCount += 1
				end
			end
		end
		local definition = MatchConfig.Teams[teamId]
		table.insert(rows, {
			teamId = teamId,
			displayName = definition.DisplayName,
			score = teamScores[teamId] or 0,
			roundWins = teamRoundWins[teamId] or 0,
			playerCount = playerCount,
			eligiblePlayerCount = eligiblePlayerCount,
		})
	end
	return rows
end

function MatchStandingsRuntime.BuildParticipationUserIds(
	orderedPlayers: { Player },
	records: { [Player]: Record },
	participation: Participation
): { number }
	local userIds: { number } = {}
	for _, player in orderedPlayers do
		if records[player].participation == participation then
			table.insert(userIds, player.UserId)
		end
	end
	return userIds
end

function MatchStandingsRuntime.CloneNumberMap(source: { [string]: number }): { [string]: number }
	return table.clone(source)
end

return table.freeze(MatchStandingsRuntime)
