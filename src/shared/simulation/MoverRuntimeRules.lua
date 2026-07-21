--[[
SPDX-License-Identifier: GPL-2.0-or-later

Blocked mover-team runtime rebasing translated from Quake III Arena:
  code/game/g_mover.c (G_MoverTeam)
  code/game/bg_misc.c (BG_EvaluateTrajectory)

When one Q3 mover team is blocked, G_MoverTeam rolls that team back and adds
level.time - level.previousTime to every team member's trajectory start time.
Other teams remain committed and the global level clock continues advancing.
At the new time, the rebased blocked trajectories therefore evaluate to their
exact previous-time poses.

This pure boundary validates complete source-ordered team-result coverage and
returns only recursively immutable definitions. It does not hold or mutate a
MoverClock, resolve body pushes, or invoke blocked/crush callbacks.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local MoverClock = require(script.Parent.MoverClock)
local MoverPushRules = require(script.Parent.MoverPushRules)
local MoverTrajectory = require(script.Parent.MoverTrajectory)

export type Definition = MoverPushRules.Definition
export type TeamResult = MoverPushRules.TeamResult
export type TeamBoundary = MoverPushRules.TeamBoundary

local MoverRuntimeRules = {}

local MAXIMUM_RESULTS = MoverPushRules.MaximumDefinitions
local MAXIMUM_TIME_MILLISECONDS = MoverTrajectory.MaximumTimeMilliseconds

local WINDOW_KEYS: { [string]: boolean } = {
	revision = true,
	fromStep = true,
	toStep = true,
	fromTimeMilliseconds = true,
	toTimeMilliseconds = true,
}
table.freeze(WINDOW_KEYS)

local TEAM_RESULT_KEYS: { [string]: boolean } = {
	teamId = true,
	captainMoverId = true,
	disposition = true,
	blockedMoverId = true,
	blockedByBodyId = true,
}
table.freeze(TEAM_RESULT_KEYS)

type TeamGroup = {
	teamId: string,
	captainMoverId: string,
	memberIds: { [string]: boolean },
	teamchainIds: { string },
}

-- A continuation boundary may be updated several times before it is closed.
-- Key consumption by the stable TeamResult identity prevents the same physical
-- team boundary from receiving the Q3 frame-time shift twice through successor
-- boundary capabilities.
local rebasedBoundaryResults = setmetatable({}, { __mode = "k" }) :: { [table]: boolean }

local function hasAllowedKeysAndCount(
	value: { [unknown]: unknown },
	allowed: { [string]: boolean },
	expectedCount: number
): boolean
	local observed = 0
	for key in value do
		if type(key) ~= "string" or allowed[key] ~= true then
			return false
		end
		observed += 1
	end
	return observed == expectedCount
end

local function isValidId(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function denseArrayLength(
	value: { [unknown]: unknown },
	maximumLength: number,
	arrayName: string
): (number?, string?)
	local count = 0
	local maximumIndex = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, arrayName .. "-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > maximumLength or maximumIndex > maximumLength then
			return nil, "too-many-" .. arrayName
		end
	end
	if maximumIndex ~= count then
		return nil, arrayName .. "-not-dense-array"
	end
	return count, nil
end

local function validateWindow(value: unknown): (MoverClock.Window?, string?)
	if type(value) ~= "table" then
		return nil, "window-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not hasAllowedKeysAndCount(source, WINDOW_KEYS, 5) then
		return nil, "invalid-window-shape"
	end
	local fromClock, fromClockError = MoverClock.ValidateSnapshot({
		revision = source.revision,
		step = source.fromStep,
	})
	if not fromClock then
		return nil, "invalid-window-clock:" .. (fromClockError or "invalid")
	end
	local expected, expectedError = MoverClock.WindowFor(fromClock)
	if not expected then
		return nil, "invalid-window-clock:" .. (expectedError or "invalid")
	end
	if
		source.toStep ~= expected.toStep
		or source.fromTimeMilliseconds ~= expected.fromTimeMilliseconds
		or source.toTimeMilliseconds ~= expected.toTimeMilliseconds
	then
		return nil, "window-clock-mismatch"
	end
	return expected, nil
end

local function definitionsAreSourceOrdered(source: { [unknown]: unknown }, ordered: { Definition }): boolean
	for index, definition in ordered do
		local raw = source[index]
		if type(raw) ~= "table" or (raw :: any).id ~= definition.id then
			return false
		end
	end
	return true
end

local function trajectoryTimeIsInClockDomain(trajectory: MoverTrajectory.Trajectory): boolean
	if trajectory.startTimeMilliseconds < 0 then
		return false
	end
	local endTime = trajectory.startTimeMilliseconds + trajectory.durationMilliseconds
	return endTime <= MAXIMUM_TIME_MILLISECONDS
end

local function validateOrderedDefinitions(value: unknown): ({ Definition }?, string?)
	if type(value) ~= "table" then
		return nil, "definitions-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local definitions, definitionsError = MoverPushRules.ValidateAndOrderDefinitions(source)
	if not definitions then
		return nil, "invalid-definitions:" .. (definitionsError or "invalid")
	end
	if not definitionsAreSourceOrdered(source, definitions) then
		return nil, "definitions-not-source-ordered"
	end
	return definitions, nil
end

local function validateDefinitions(value: unknown): ({ Definition }?, string?)
	local definitions, definitionsError = validateOrderedDefinitions(value)
	if not definitions then
		return nil, definitionsError
	end
	for _, definition in definitions do
		if
			not trajectoryTimeIsInClockDomain(definition.trajectory)
			or not trajectoryTimeIsInClockDomain(definition.angularTrajectory)
		then
			return nil, "mover-" .. definition.id .. ":trajectory-time-out-of-bounds"
		end
	end
	return definitions, nil
end

local function buildTeamGroups(definitions: { Definition }): ({ TeamGroup }, { [string]: TeamGroup })
	local groups: { TeamGroup } = {}
	local byId: { [string]: TeamGroup } = {}
	for _, definition in definitions do
		local group = byId[definition.teamId]
		if not group then
			group = {
				teamId = definition.teamId,
				captainMoverId = definition.id,
				memberIds = {},
				teamchainIds = {},
			}
			byId[definition.teamId] = group
			table.insert(groups, group)
			table.insert(group.teamchainIds, definition.id)
		else
			-- G_FindTeams prepends every later source entity after the captain.
			table.insert(group.teamchainIds, 2, definition.id)
		end
		group.memberIds[definition.id] = true
	end
	return groups, byId
end

local function validateTeamResults(
	value: unknown,
	groups: { TeamGroup },
	groupsById: { [string]: TeamGroup },
	definitionsById: { [string]: Definition }
): ({ TeamResult }?, { [string]: TeamResult }?, string?)
	if type(value) ~= "table" then
		return nil, nil, "team-results-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local count, countError = denseArrayLength(source, MAXIMUM_RESULTS, "team-results")
	if not count then
		return nil, nil, countError
	end

	local results: { TeamResult } = table.create(count)
	local byTeamId: { [string]: TeamResult } = {}
	for index = 1, count do
		local rawValue = source[index]
		if type(rawValue) ~= "table" then
			return nil, nil, string.format("team-result-%d:not-table", index)
		end
		local raw = rawValue :: { [unknown]: unknown }
		if raw.disposition ~= "Committed" and raw.disposition ~= "BlockedRollback" then
			return nil, nil, string.format("team-result-%d:invalid-disposition", index)
		end
		local blocked = raw.disposition == "BlockedRollback"
		if not hasAllowedKeysAndCount(raw, TEAM_RESULT_KEYS, if blocked then 5 else 3) then
			return nil, nil, string.format("team-result-%d:invalid-shape", index)
		end
		if not isValidId(raw.teamId) then
			return nil, nil, string.format("team-result-%d:invalid-team-id", index)
		end
		local teamId = raw.teamId :: string
		if byTeamId[teamId] ~= nil then
			return nil, nil, "duplicate-team-result:" .. teamId
		end
		local group = groupsById[teamId]
		if not group then
			return nil, nil, "unknown-team-result:" .. teamId
		end
		local expectedGroup = groups[index]
		if expectedGroup == nil or expectedGroup.teamId ~= teamId then
			return nil, nil, "team-results-not-source-ordered"
		end
		if raw.captainMoverId ~= group.captainMoverId then
			return nil, nil, "captain-mover-mismatch:" .. teamId
		end

		local result: TeamResult
		if blocked then
			if not isValidId(raw.blockedMoverId) then
				return nil, nil, "invalid-blocked-mover-id:" .. teamId
			end
			local blockedMoverId = raw.blockedMoverId :: string
			if definitionsById[blockedMoverId] == nil then
				return nil, nil, "unknown-blocked-mover-id:" .. blockedMoverId
			end
			if group.memberIds[blockedMoverId] ~= true then
				return nil, nil, "blocked-mover-team-mismatch:" .. blockedMoverId
			end
			if not isValidId(raw.blockedByBodyId) then
				return nil, nil, "invalid-blocking-body-id:" .. teamId
			end
			local captain = definitionsById[group.captainMoverId]
			if
				captain.trajectory.kind == MoverTrajectory.Kinds.Stationary
				and captain.angularTrajectory.kind == MoverTrajectory.Kinds.Stationary
			then
				return nil, nil, "blocked-stationary-team:" .. teamId
			end
			local blockedMover = definitionsById[blockedMoverId]
			if
				blockedMover.trajectory.kind == MoverTrajectory.Kinds.Sine
				or blockedMover.angularTrajectory.kind == MoverTrajectory.Kinds.Sine
			then
				return nil, nil, "sine-mover-cannot-block:" .. blockedMoverId
			end
			result = {
				teamId = teamId,
				captainMoverId = group.captainMoverId,
				disposition = "BlockedRollback",
				blockedMoverId = blockedMoverId,
				blockedByBodyId = raw.blockedByBodyId :: string,
			}
		else
			result = {
				teamId = teamId,
				captainMoverId = group.captainMoverId,
				disposition = "Committed",
				blockedMoverId = nil,
				blockedByBodyId = nil,
			}
		end
		table.freeze(result)
		table.insert(results, result)
		byTeamId[teamId] = result
	end

	for _, group in groups do
		if byTeamId[group.teamId] == nil then
			return nil, nil, "missing-team-result:" .. group.teamId
		end
	end
	table.freeze(results)
	table.freeze(byTeamId)
	return results, byTeamId, nil
end

local function rebaseDefinition(definition: Definition, deltaMilliseconds: number): (Definition?, string?)
	local function rebaseTrajectory(trajectory: MoverTrajectory.Trajectory): (MoverTrajectory.Trajectory?, string?)
		return MoverTrajectory.Validate({
			kind = trajectory.kind,
			startTimeMilliseconds = trajectory.startTimeMilliseconds + deltaMilliseconds,
			durationMilliseconds = trajectory.durationMilliseconds,
			base = trajectory.base,
			delta = trajectory.delta,
		})
	end
	local rebasedTrajectory, trajectoryError = rebaseTrajectory(definition.trajectory)
	if not rebasedTrajectory or not trajectoryTimeIsInClockDomain(rebasedTrajectory) then
		return nil,
			"mover-" .. definition.id .. ":trajectory-time-out-of-bounds:" .. (trajectoryError or "clock-domain")
	end
	local rebasedAngularTrajectory, angularTrajectoryError = rebaseTrajectory(definition.angularTrajectory)
	if not rebasedAngularTrajectory or not trajectoryTimeIsInClockDomain(rebasedAngularTrajectory) then
		return nil,
			"mover-"
				.. definition.id
				.. ":angular-trajectory-time-out-of-bounds:"
				.. (angularTrajectoryError or "clock-domain")
	end
	local rebased: Definition = {
		id = definition.id,
		teamId = definition.teamId,
		sourceOrder = definition.sourceOrder,
		shape = definition.shape,
		cframe = definition.cframe,
		size = definition.size,
		trajectory = rebasedTrajectory,
		angularTrajectory = rebasedAngularTrajectory,
		moverStop = definition.moverStop,
	}
	table.freeze(rebased)
	return rebased, nil
end

local function trajectoryEquals(left: MoverTrajectory.Trajectory, right: MoverTrajectory.Trajectory): boolean
	return left.kind == right.kind
		and left.startTimeMilliseconds == right.startTimeMilliseconds
		and left.durationMilliseconds == right.durationMilliseconds
		and left.base == right.base
		and left.delta == right.delta
end

local function definitionEquals(left: Definition, right: Definition): boolean
	return left.id == right.id
		and left.teamId == right.teamId
		and left.sourceOrder == right.sourceOrder
		and left.shape == right.shape
		and left.cframe == right.cframe
		and left.size == right.size
		and left.moverStop == right.moverStop
		and trajectoryEquals(left.trajectory, right.trajectory)
		and trajectoryEquals(left.angularTrajectory, right.angularTrajectory)
end

local function validateBoundaryDefinitionMatch(definitions: { Definition }, boundary: TeamBoundary): string?
	if #definitions ~= #boundary.definitions then
		return "boundary-definition-count-mismatch"
	end
	for index, definition in definitions do
		local boundaryDefinition = boundary.definitions[index]
		if not boundaryDefinition or not definitionEquals(definition, boundaryDefinition) then
			return "boundary-definition-mismatch:" .. definition.id
		end
	end
	return nil
end

local function validateBoundaryTeamchain(
	groups: { TeamGroup },
	groupsById: { [string]: TeamGroup },
	boundary: TeamBoundary
): (TeamGroup?, string?)
	if boundary.teamCount ~= #groups then
		return nil, "boundary-team-count-mismatch"
	end
	local group = groupsById[boundary.teamId]
	if not group then
		return nil, "boundary-team-not-in-definitions:" .. boundary.teamId
	end
	local indexedGroup = groups[boundary.nextTeamIndex]
	if indexedGroup ~= group then
		return nil, "boundary-team-index-mismatch:" .. boundary.teamId
	end
	if boundary.captainMoverId ~= group.captainMoverId then
		return nil, "boundary-captain-mismatch:" .. boundary.teamId
	end
	if #boundary.memberMoverIds ~= #group.teamchainIds then
		return nil, "boundary-teamchain-count-mismatch:" .. boundary.teamId
	end
	for index, moverId in group.teamchainIds do
		if boundary.memberMoverIds[index] ~= moverId then
			return nil, "boundary-teamchain-mismatch:" .. boundary.teamId
		end
	end
	local result = boundary.teamResult
	if result.teamId ~= group.teamId or result.captainMoverId ~= group.captainMoverId then
		return nil, "boundary-team-result-mismatch:" .. boundary.teamId
	end
	return group, nil
end

function MoverRuntimeRules.ApplyBlockedBoundaryRebase(
	definitionsValue: unknown,
	boundaryValue: unknown,
	windowValue: unknown
): ({ Definition }?, string?)
	local boundary, boundaryError = MoverPushRules.InspectTeamBoundary(boundaryValue)
	if not boundary then
		return nil, "invalid-team-boundary:" .. (boundaryError or "invalid")
	end
	if rebasedBoundaryResults[boundary.teamResult :: table] then
		return nil, "boundary-rebase-already-applied"
	end

	local window, windowError = validateWindow(windowValue)
	if not window then
		return nil, windowError
	end
	if
		boundary.fromTimeMilliseconds ~= window.fromTimeMilliseconds
		or boundary.toTimeMilliseconds ~= window.toTimeMilliseconds
	then
		return nil, "boundary-window-mismatch"
	end

	-- A complete continuation can contain binary materializations whose signed
	-- trTime is legal in the Q3 trajectory domain but deliberately outside this
	-- legacy adapter's nonnegative clock domain. Authenticate every definition
	-- against the opaque boundary, then constrain only the legacy team whose
	-- blocked start times this function owns and changes.
	local definitions, definitionsError = validateOrderedDefinitions(definitionsValue)
	if not definitions then
		return nil, definitionsError
	end
	local definitionMatchError = validateBoundaryDefinitionMatch(definitions, boundary)
	if definitionMatchError then
		return nil, definitionMatchError
	end

	local groups, groupsById = buildTeamGroups(definitions)
	local group, teamchainError = validateBoundaryTeamchain(groups, groupsById, boundary)
	if not group then
		return nil, teamchainError
	end
	for _, definition in definitions do
		if
			definition.teamId == group.teamId
			and (
				not trajectoryTimeIsInClockDomain(definition.trajectory)
				or not trajectoryTimeIsInClockDomain(definition.angularTrajectory)
			)
		then
			return nil, "mover-" .. definition.id .. ":trajectory-time-out-of-bounds"
		end
	end
	if boundary.teamResult.disposition ~= "BlockedRollback" then
		return nil, "boundary-team-not-blocked:" .. boundary.teamId
	end
	if not boundary.ranMoverTeam then
		return nil, "boundary-team-did-not-run:" .. boundary.teamId
	end
	local blockedMoverId = boundary.teamResult.blockedMoverId
	if blockedMoverId == nil or group.memberIds[blockedMoverId] ~= true then
		return nil, "boundary-blocked-mover-mismatch:" .. boundary.teamId
	end

	local definitionsById: { [string]: Definition } = {}
	for _, definition in definitions do
		definitionsById[definition.id] = definition
	end
	local captain = definitionsById[group.captainMoverId]
	if
		captain.trajectory.kind == MoverTrajectory.Kinds.Stationary
		and captain.angularTrajectory.kind == MoverTrajectory.Kinds.Stationary
	then
		return nil, "blocked-stationary-team:" .. group.teamId
	end
	local blockedMover = definitionsById[blockedMoverId]
	if
		blockedMover.trajectory.kind == MoverTrajectory.Kinds.Sine
		or blockedMover.angularTrajectory.kind == MoverTrajectory.Kinds.Sine
	then
		return nil, "sine-mover-cannot-block:" .. blockedMoverId
	elseif
		blockedMover.trajectory.kind == MoverTrajectory.Kinds.Stationary
		and blockedMover.angularTrajectory.kind == MoverTrajectory.Kinds.Stationary
	then
		return nil, "stationary-mover-cannot-block:" .. blockedMoverId
	end

	local deltaMilliseconds = window.toTimeMilliseconds - window.fromTimeMilliseconds
	local output: { Definition } = table.create(#definitions)
	for _, definition in definitions do
		if definition.teamId == group.teamId then
			local rebased, rebaseError = rebaseDefinition(definition, deltaMilliseconds)
			if not rebased then
				return nil, rebaseError
			end
			table.insert(output, rebased)
		else
			table.insert(output, definition)
		end
	end
	table.freeze(output)
	rebasedBoundaryResults[boundary.teamResult :: table] = true
	return output, nil
end

function MoverRuntimeRules.ApplyBlockedTimeRebase(
	definitionsValue: unknown,
	teamResultsValue: unknown,
	windowValue: unknown
): ({ Definition }?, string?)
	local window, windowError = validateWindow(windowValue)
	if not window then
		return nil, windowError
	end
	local definitions, definitionsError = validateDefinitions(definitionsValue)
	if not definitions then
		return nil, definitionsError
	end

	local groups, groupsById = buildTeamGroups(definitions)
	local definitionsById: { [string]: Definition } = {}
	for _, definition in definitions do
		definitionsById[definition.id] = definition
	end
	local _, resultsByTeamId, resultError = validateTeamResults(teamResultsValue, groups, groupsById, definitionsById)
	if not resultsByTeamId then
		return nil, resultError
	end

	local deltaMilliseconds = window.toTimeMilliseconds - window.fromTimeMilliseconds
	local output: { Definition } = table.create(#definitions)
	for _, definition in definitions do
		local teamResult = resultsByTeamId[definition.teamId]
		if teamResult.disposition == "BlockedRollback" then
			local rebased, rebaseError = rebaseDefinition(definition, deltaMilliseconds)
			if not rebased then
				return nil, rebaseError
			end
			table.insert(output, rebased)
		else
			-- The validated definition is already recursively frozen. Preserve it
			-- exactly for committed teams; only blocked teams receive new records.
			table.insert(output, definition)
		end
	end
	table.freeze(output)
	return output, nil
end

MoverRuntimeRules.MaximumTeamResults = MAXIMUM_RESULTS

return table.freeze(MoverRuntimeRules)
