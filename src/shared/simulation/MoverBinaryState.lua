--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure server-owned binary mover state translated from Quake III Arena:
  code/game/g_mover.c (SetMoverState, MatchTeam, ReturnToPos1,
  Reached_BinaryMover, Use_BinaryMover, G_MoverTeam)
  code/game/g_main.c (G_FindTeams)

Authored endpoints/geometry remain immutable programs. Runtime records carry
only per-member Q3 mover state, signed integer trTime, and nextthink deadlines;
collision definitions are always derived through MoverTrajectory.SetBinaryState.
Opaque single-lineage capabilities bind blocked/reached/think processing to
source-ordered physical team boundaries and reject stale or forged callbacks.
This prevents a runtime or snapshot from inventing geometry, timing, or order.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local MoverClock = require(script.Parent.MoverClock)
local MoverPushRules = require(script.Parent.MoverPushRules)
local MoverTrajectory = require(script.Parent.MoverTrajectory)

export type Program = {
	id: string,
	teamId: string,
	sourceOrder: number,
	shape: "Block",
	cframe: CFrame,
	size: Vector3,
	position1: Vector3,
	position2: Vector3,
	durationMilliseconds: number,
	waitMilliseconds: number,
	moverStop: boolean,
}

export type MemberState = {
	id: string,
	state: MoverTrajectory.BinaryState,
	effectiveStartTimeMilliseconds: number,
	nextThinkTimeMilliseconds: number,
}

export type TeamState = {
	teamId: string,
	captainMoverId: string,
	members: { MemberState },
}

export type Runtime = {
	revision: number,
	teams: { TeamState },
}

export type UseOutcome = "Activated" | "HeldPos2" | "Reversed"
export type ReachedOutcome = "ReachedPos1" | "ReachedPos2"
export type ReachedEvent = {
	teamId: string,
	moverId: string,
	outcome: ReachedOutcome,
	atTimeMilliseconds: number,
}
export type ReachedEffect = {
	runtime: Runtime?,
	bodyMutations: { MoverPushRules.BodyMutation }?,
}
export type ReachedCallback = (event: ReachedEvent, runtime: Runtime) -> ReachedEffect?
export type BlockedEvent = {
	teamId: string,
	captainMoverId: string,
	blockedMoverId: string,
	blockedByBodyId: string,
	atTimeMilliseconds: number,
}
export type BlockedCallback = (event: BlockedEvent, runtime: Runtime) -> ReachedEffect?

local MoverBinaryState = {}

local MAXIMUM_PROGRAMS = MoverPushRules.MaximumDefinitions
local MAXIMUM_TIME = MoverTrajectory.MaximumTimeMilliseconds
local MAXIMUM_REVISION = 9_007_199_254_740_991

local PROGRAM_KEYS: { [string]: boolean } = table.freeze({
	id = true,
	teamId = true,
	sourceOrder = true,
	shape = true,
	cframe = true,
	size = true,
	position1 = true,
	position2 = true,
	durationMilliseconds = true,
	waitMilliseconds = true,
	moverStop = true,
})

local RUNTIME_KEYS: { [string]: boolean } = table.freeze({
	revision = true,
	teams = true,
})

local TEAM_KEYS: { [string]: boolean } = table.freeze({
	teamId = true,
	captainMoverId = true,
	members = true,
})

local MEMBER_KEYS: { [string]: boolean } = table.freeze({
	id = true,
	state = true,
	effectiveStartTimeMilliseconds = true,
	nextThinkTimeMilliseconds = true,
})

type TeamProgram = {
	teamId: string,
	captainMoverId: string,
	captainDurationMilliseconds: number,
	members: { Program },
}

type ProgramContext = {
	programs: { Program },
	programById: { [string]: Program },
	teams: { TeamProgram },
	teamById: { [string]: TeamProgram },
	teamByMemberId: { [string]: TeamProgram },
}

type PhysicalBoundaryPhase = "NeedsBlockedCallback" | "NeedsThink" | "Complete"

type RuntimeCapability = {
	context: ProgramContext,
	authoritative: boolean,
	current: boolean,
	lineage: unknown?,
	useChainBaseRevision: number?,
	useChainTimeMilliseconds: number?,
	physicalFrameLineage: unknown?,
	physicalClockRevision: number?,
	physicalFrameFromStep: number?,
	physicalFrameToStep: number?,
	physicalFrameFromTimeMilliseconds: number?,
	physicalFrameToTimeMilliseconds: number?,
	lastBinaryBoundaryIndex: number?,
	finalBinaryBoundaryIndex: number?,
	physicalBoundaryPhase: PhysicalBoundaryPhase?,
}

local PROGRAM_CONTEXTS: { [{ Program }]: ProgramContext } = setmetatable({}, { __mode = "k" })
local RUNTIME_CAPABILITIES: { [Runtime]: RuntimeCapability } = setmetatable({}, { __mode = "k" })

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and math.abs(value :: number) < math.huge
end

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return isFiniteNumber(value)
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isSignedTime(value: unknown): boolean
	return isIntegerInRange(value, -MAXIMUM_TIME, MAXIMUM_TIME)
end

local function isClockTime(value: unknown): boolean
	return isIntegerInRange(value, 0, MAXIMUM_TIME)
end

local function isValidId(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= 64 and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function hasExactKeys(
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

local function denseArrayLength(value: { [unknown]: unknown }, maximum: number, label: string): (number?, string?)
	local count = 0
	local maximumIndex = 0
	for key in value do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil, label .. "-not-dense-array"
		end
		count += 1
		maximumIndex = math.max(maximumIndex, key)
		if count > maximum or maximumIndex > maximum then
			return nil, "too-many-" .. label
		end
	end
	if maximumIndex ~= count then
		return nil, label .. "-not-dense-array"
	end
	return count, nil
end

local function isBinaryState(value: unknown): boolean
	return value == MoverTrajectory.BinaryStates.Pos1
		or value == MoverTrajectory.BinaryStates.Pos2
		or value == MoverTrajectory.BinaryStates.OneToTwo
		or value == MoverTrajectory.BinaryStates.TwoToOne
end

local function validateStateDefinition(
	source: { [unknown]: unknown },
	position1: Vector3,
	position2: Vector3,
	durationMilliseconds: number,
	state: MoverTrajectory.BinaryState
): string?
	local trajectoryOk, trajectoryValue =
		pcall(MoverTrajectory.SetBinaryState, position1, position2, durationMilliseconds, state, 0)
	if not trajectoryOk then
		return "invalid-binary-trajectory"
	end
	local trajectory = trajectoryValue :: MoverTrajectory.Trajectory
	local definitions, definitionsError = MoverPushRules.ValidateAndOrderDefinitions({
		{
			id = source.id,
			teamId = source.teamId,
			sourceOrder = source.sourceOrder,
			shape = source.shape,
			cframe = if state == MoverTrajectory.BinaryStates.Pos1 then source.cframe else CFrame.new(trajectory.base),
			size = source.size,
			trajectory = trajectory,
			moverStop = source.moverStop,
		},
	})
	if not definitions then
		return definitionsError or "invalid-endpoint"
	end
	return nil
end

local function validateProgram(value: unknown): (Program?, string?)
	if type(value) ~= "table" then
		return nil, "program-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not hasExactKeys(source, PROGRAM_KEYS, 11) then
		return nil, "invalid-program-shape"
	end
	if not isIntegerInRange(source.durationMilliseconds, 1, MAXIMUM_TIME) then
		return nil, "invalid-binary-duration"
	end
	if not isSignedTime(source.waitMilliseconds) then
		return nil, "invalid-binary-wait"
	end
	if typeof(source.position1) ~= "Vector3" or typeof(source.position2) ~= "Vector3" then
		return nil, "invalid-binary-endpoint"
	end
	local position1 = source.position1 :: Vector3
	local position2 = source.position2 :: Vector3
	local durationMilliseconds = source.durationMilliseconds :: number
	local endpoint1Error =
		validateStateDefinition(source, position1, position2, durationMilliseconds, MoverTrajectory.BinaryStates.Pos1)
	if endpoint1Error then
		return nil, "invalid-position1:" .. endpoint1Error
	end
	if (source.cframe :: CFrame).Position ~= position1 then
		return nil, "cframe-position1-mismatch"
	end
	local endpoint2Error =
		validateStateDefinition(source, position1, position2, durationMilliseconds, MoverTrajectory.BinaryStates.Pos2)
	if endpoint2Error then
		return nil, "invalid-position2:" .. endpoint2Error
	end
	local forwardError = validateStateDefinition(
		source,
		position1,
		position2,
		durationMilliseconds,
		MoverTrajectory.BinaryStates.OneToTwo
	)
	if forwardError then
		return nil, "invalid-one-to-two:" .. forwardError
	end
	local backwardError = validateStateDefinition(
		source,
		position1,
		position2,
		durationMilliseconds,
		MoverTrajectory.BinaryStates.TwoToOne
	)
	if backwardError then
		return nil, "invalid-two-to-one:" .. backwardError
	end

	local program: Program = {
		id = source.id :: string,
		teamId = source.teamId :: string,
		sourceOrder = source.sourceOrder :: number,
		shape = "Block",
		cframe = source.cframe :: CFrame,
		size = source.size :: Vector3,
		position1 = position1,
		position2 = position2,
		durationMilliseconds = durationMilliseconds,
		waitMilliseconds = source.waitMilliseconds :: number,
		moverStop = source.moverStop :: boolean,
	}
	table.freeze(program)
	return program, nil
end

local function buildContext(programs: { Program }): (ProgramContext?, string?)
	local programById: { [string]: Program } = {}
	local observedOrders: { [number]: boolean } = {}
	for _, program in programs do
		if programById[program.id] then
			return nil, "duplicate-program-id:" .. program.id
		end
		if observedOrders[program.sourceOrder] then
			return nil, "duplicate-program-source-order"
		end
		programById[program.id] = program
		observedOrders[program.sourceOrder] = true
	end

	local teams: { TeamProgram } = {}
	local teamById: { [string]: TeamProgram } = {}
	local teamByMemberId: { [string]: TeamProgram } = {}
	for _, program in programs do
		local team = teamById[program.teamId]
		if not team then
			team = {
				teamId = program.teamId,
				captainMoverId = program.id,
				captainDurationMilliseconds = program.durationMilliseconds,
				members = {},
			}
			teamById[program.teamId] = team
			table.insert(teams, team)
			table.insert(team.members, program)
		else
			-- G_FindTeams prepends every later source entity after the captain.
			-- Q3 shares state/start across the chain but retains each member's own
			-- duration; reversal progress deliberately uses the captain's duration.
			table.insert(team.members, 2, program)
		end
		teamByMemberId[program.id] = team
	end
	for _, team in teams do
		table.freeze(team.members)
		table.freeze(team)
	end
	table.freeze(teams)
	table.freeze(programById)
	table.freeze(teamById)
	table.freeze(teamByMemberId)
	return {
		programs = programs,
		programById = programById,
		teams = teams,
		teamById = teamById,
		teamByMemberId = teamByMemberId,
	},
		nil
end

function MoverBinaryState.ValidateAndOrderPrograms(value: unknown): ({ Program }?, string?)
	if type(value) ~= "table" then
		return nil, "programs-not-array"
	end
	local source = value :: { [unknown]: unknown }
	local count, countError = denseArrayLength(source, MAXIMUM_PROGRAMS, "programs")
	if not count then
		return nil, countError
	end
	local programs: { Program } = table.create(count)
	for index = 1, count do
		local program, programError = validateProgram(source[index])
		if not program then
			return nil, string.format("program-%d:%s", index, programError or "invalid")
		end
		table.insert(programs, program)
	end
	table.sort(programs, function(left, right): boolean
		return left.sourceOrder < right.sourceOrder
	end)
	table.freeze(programs)
	local context, contextError = buildContext(programs)
	if not context then
		return nil, contextError
	end
	PROGRAM_CONTEXTS[programs] = context
	return programs, nil
end

local function programContext(value: unknown): (ProgramContext?, string?)
	if type(value) ~= "table" then
		return nil, "programs-not-validated"
	end
	local context = PROGRAM_CONTEXTS[value :: { Program }]
	if not context then
		return nil, "programs-not-validated"
	end
	return context, nil
end

local function copyMember(member: MemberState): MemberState
	return {
		id = member.id,
		state = member.state,
		effectiveStartTimeMilliseconds = member.effectiveStartTimeMilliseconds,
		nextThinkTimeMilliseconds = member.nextThinkTimeMilliseconds,
	}
end

local function copyTeams(teams: { TeamState }): { TeamState }
	local output: { TeamState } = table.create(#teams)
	for _, team in teams do
		local members: { MemberState } = table.create(#team.members)
		for _, member in team.members do
			table.insert(members, copyMember(member))
		end
		table.insert(output, {
			teamId = team.teamId,
			captainMoverId = team.captainMoverId,
			members = members,
		})
	end
	return output
end

local function validateRuntimeValue(context: ProgramContext, value: unknown): (Runtime?, string?)
	if type(value) ~= "table" then
		return nil, "runtime-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not hasExactKeys(source, RUNTIME_KEYS, 2) then
		return nil, "invalid-runtime-shape"
	end
	if not isIntegerInRange(source.revision, 1, MAXIMUM_REVISION) then
		return nil, "invalid-runtime-revision"
	end
	if type(source.teams) ~= "table" then
		return nil, "teams-not-array"
	end
	local rawTeams = source.teams :: { [unknown]: unknown }
	local teamCount, teamCountError = denseArrayLength(rawTeams, MAXIMUM_PROGRAMS, "teams")
	if not teamCount then
		return nil, teamCountError
	end
	if teamCount ~= #context.teams then
		return nil, "runtime-team-count-mismatch"
	end

	local teams: { TeamState } = table.create(teamCount)
	for teamIndex, expectedTeam in context.teams do
		local rawTeamValue = rawTeams[teamIndex]
		if type(rawTeamValue) ~= "table" then
			return nil, string.format("team-%d:not-table", teamIndex)
		end
		local rawTeam = rawTeamValue :: { [unknown]: unknown }
		if not hasExactKeys(rawTeam, TEAM_KEYS, 3) then
			return nil, string.format("team-%d:invalid-shape", teamIndex)
		end
		if rawTeam.teamId ~= expectedTeam.teamId then
			return nil, "runtime-teams-not-source-ordered"
		end
		if rawTeam.captainMoverId ~= expectedTeam.captainMoverId then
			return nil, "runtime-captain-mismatch:" .. expectedTeam.teamId
		end
		if type(rawTeam.members) ~= "table" then
			return nil, "runtime-members-not-array:" .. expectedTeam.teamId
		end
		local rawMembers = rawTeam.members :: { [unknown]: unknown }
		local memberCount, memberCountError = denseArrayLength(rawMembers, MAXIMUM_PROGRAMS, "members")
		if not memberCount then
			return nil, memberCountError
		end
		if memberCount ~= #expectedTeam.members then
			return nil, "runtime-member-count-mismatch:" .. expectedTeam.teamId
		end
		local members: { MemberState } = table.create(memberCount)
		for memberIndex, expectedProgram in expectedTeam.members do
			local rawMemberValue = rawMembers[memberIndex]
			if type(rawMemberValue) ~= "table" then
				return nil, string.format("member-%d:not-table", memberIndex)
			end
			local rawMember = rawMemberValue :: { [unknown]: unknown }
			if not hasExactKeys(rawMember, MEMBER_KEYS, 4) then
				return nil, string.format("member-%d:invalid-shape", memberIndex)
			end
			if rawMember.id ~= expectedProgram.id then
				return nil, "runtime-members-not-teamchain-ordered:" .. expectedTeam.teamId
			end
			if not isBinaryState(rawMember.state) then
				return nil, "invalid-member-state:" .. expectedProgram.id
			end
			if not isSignedTime(rawMember.effectiveStartTimeMilliseconds) then
				return nil, "invalid-member-start-time:" .. expectedProgram.id
			end
			if not isSignedTime(rawMember.nextThinkTimeMilliseconds) then
				return nil, "invalid-member-think-time:" .. expectedProgram.id
			end
			local member: MemberState = {
				id = expectedProgram.id,
				state = rawMember.state :: MoverTrajectory.BinaryState,
				effectiveStartTimeMilliseconds = rawMember.effectiveStartTimeMilliseconds :: number,
				nextThinkTimeMilliseconds = rawMember.nextThinkTimeMilliseconds :: number,
			}
			table.freeze(member)
			table.insert(members, member)
		end
		table.freeze(members)
		local team: TeamState = {
			teamId = expectedTeam.teamId,
			captainMoverId = expectedTeam.captainMoverId,
			members = members,
		}
		table.freeze(team)
		table.insert(teams, team)
	end
	table.freeze(teams)
	local runtime: Runtime = {
		revision = source.revision :: number,
		teams = teams,
	}
	table.freeze(runtime)
	RUNTIME_CAPABILITIES[runtime] = {
		context = context,
		authoritative = false,
		current = false,
		lineage = nil,
		useChainBaseRevision = nil,
		useChainTimeMilliseconds = nil,
		physicalFrameLineage = nil,
		physicalClockRevision = nil,
		physicalFrameFromStep = nil,
		physicalFrameToStep = nil,
		physicalFrameFromTimeMilliseconds = nil,
		physicalFrameToTimeMilliseconds = nil,
		lastBinaryBoundaryIndex = nil,
		finalBinaryBoundaryIndex = nil,
		physicalBoundaryPhase = nil,
	}
	return runtime, nil
end

function MoverBinaryState.ValidateRuntime(programsValue: unknown, runtimeValue: unknown): (Runtime?, string?)
	local context, contextError = programContext(programsValue)
	if not context then
		return nil, contextError
	end
	if type(runtimeValue) == "table" then
		local existing = runtimeValue :: Runtime
		local capability = RUNTIME_CAPABILITIES[existing]
		if capability and capability.context == context then
			return existing, nil
		end
	end
	return validateRuntimeValue(context, runtimeValue)
end

function MoverBinaryState.Create(programsValue: unknown, revisionValue: unknown?): (Runtime?, string?)
	local context, contextError = programContext(programsValue)
	if not context then
		return nil, contextError
	end
	local revision = if revisionValue == nil then 1 else revisionValue
	if not isIntegerInRange(revision, 1, MAXIMUM_REVISION) then
		return nil, "invalid-runtime-revision"
	end
	local teams: { TeamState } = table.create(#context.teams)
	for _, teamProgram in context.teams do
		local members: { MemberState } = table.create(#teamProgram.members)
		for _, memberProgram in teamProgram.members do
			table.insert(members, {
				id = memberProgram.id,
				state = MoverTrajectory.BinaryStates.Pos1,
				effectiveStartTimeMilliseconds = 0,
				nextThinkTimeMilliseconds = 0,
			})
		end
		table.insert(teams, {
			teamId = teamProgram.teamId,
			captainMoverId = teamProgram.captainMoverId,
			members = members,
		})
	end
	local runtime, runtimeError = validateRuntimeValue(context, {
		revision = revision,
		teams = teams,
	})
	if not runtime then
		return nil, runtimeError
	end
	local capability = RUNTIME_CAPABILITIES[runtime]
	assert(capability, "new binary runtime capability missing")
	capability.authoritative = true
	capability.current = true
	capability.lineage = table.freeze({})
	capability.useChainBaseRevision = nil
	capability.useChainTimeMilliseconds = nil
	capability.physicalFrameLineage = nil
	capability.physicalClockRevision = nil
	capability.physicalFrameFromStep = nil
	capability.physicalFrameToStep = nil
	capability.physicalFrameFromTimeMilliseconds = nil
	capability.physicalFrameToTimeMilliseconds = nil
	capability.lastBinaryBoundaryIndex = nil
	capability.finalBinaryBoundaryIndex = nil
	capability.physicalBoundaryPhase = nil
	return runtime, nil
end

local function validatedRuntime(programsValue: unknown, runtimeValue: unknown): (ProgramContext?, Runtime?, string?)
	local context, contextError = programContext(programsValue)
	if not context then
		return nil, nil, contextError
	end
	if type(runtimeValue) ~= "table" then
		return nil, nil, "runtime-not-validated"
	end
	local runtime = runtimeValue :: Runtime
	local capability = RUNTIME_CAPABILITIES[runtime]
	if not capability or capability.context ~= context then
		return nil, nil, "runtime-not-validated"
	end
	return context, runtime, nil
end

local function authoritativeRuntime(programsValue: unknown, runtimeValue: unknown): (ProgramContext?, Runtime?, string?)
	local context, runtime, validationError = validatedRuntime(programsValue, runtimeValue)
	if not context or not runtime then
		return nil, nil, validationError
	end
	local capability = RUNTIME_CAPABILITIES[runtime]
	assert(capability, "validated binary runtime capability missing")
	if not capability.authoritative then
		return nil, nil, "runtime-not-authoritative"
	end
	if not capability.current then
		return nil, nil, "runtime-not-current"
	end
	return context, runtime, nil
end

function MoverBinaryState.InspectAuthoritativeRuntime(
	programsValue: unknown,
	runtimeValue: unknown
): (Runtime?, string?)
	local _, runtime, authenticationError = authoritativeRuntime(programsValue, runtimeValue)
	if not runtime then
		return nil, authenticationError
	end
	return runtime, nil
end

function MoverBinaryState.InspectPublishableRuntime(programsValue: unknown, runtimeValue: unknown): (Runtime?, string?)
	local _, runtime, authenticationError = authoritativeRuntime(programsValue, runtimeValue)
	if not runtime then
		return nil, authenticationError
	end
	local capability = RUNTIME_CAPABILITIES[runtime]
	assert(capability, "authoritative binary runtime capability missing")
	local phase = capability.physicalBoundaryPhase
	if phase == "NeedsBlockedCallback" or phase == "NeedsThink" then
		return nil, "runtime-physical-boundary-pending:" .. phase
	end
	if capability.physicalFrameLineage ~= nil then
		if
			phase ~= "Complete"
			or capability.lastBinaryBoundaryIndex == nil
			or capability.finalBinaryBoundaryIndex == nil
			or capability.lastBinaryBoundaryIndex ~= capability.finalBinaryBoundaryIndex
		then
			return nil, "runtime-binary-frame-incomplete"
		end
	elseif phase ~= nil or capability.lastBinaryBoundaryIndex ~= nil or capability.finalBinaryBoundaryIndex ~= nil then
		return nil, "runtime-binary-frame-incomplete"
	end
	return runtime, nil
end

local function commitTransition(
	context: ProgramContext,
	previousRuntime: Runtime,
	nextRuntime: Runtime,
	useTransitionTimeMilliseconds: number?
): Runtime
	local previousCapability = RUNTIME_CAPABILITIES[previousRuntime]
	local nextCapability = RUNTIME_CAPABILITIES[nextRuntime]
	assert(
		previousCapability
			and previousCapability.context == context
			and previousCapability.authoritative
			and previousCapability.current,
		"binary runtime transition source lost authority"
	)
	assert(nextCapability and nextCapability.context == context, "binary runtime transition output invalid")
	previousCapability.current = false
	nextCapability.authoritative = true
	nextCapability.current = true
	nextCapability.lineage = previousCapability.lineage
	nextCapability.physicalFrameLineage = previousCapability.physicalFrameLineage
	nextCapability.physicalClockRevision = previousCapability.physicalClockRevision
	nextCapability.physicalFrameFromStep = previousCapability.physicalFrameFromStep
	nextCapability.physicalFrameToStep = previousCapability.physicalFrameToStep
	nextCapability.physicalFrameFromTimeMilliseconds = previousCapability.physicalFrameFromTimeMilliseconds
	nextCapability.physicalFrameToTimeMilliseconds = previousCapability.physicalFrameToTimeMilliseconds
	nextCapability.lastBinaryBoundaryIndex = previousCapability.lastBinaryBoundaryIndex
	nextCapability.finalBinaryBoundaryIndex = previousCapability.finalBinaryBoundaryIndex
	nextCapability.physicalBoundaryPhase = previousCapability.physicalBoundaryPhase
	if useTransitionTimeMilliseconds ~= nil then
		if
			previousCapability.useChainTimeMilliseconds == useTransitionTimeMilliseconds
			and previousCapability.useChainBaseRevision ~= nil
		then
			nextCapability.useChainBaseRevision = previousCapability.useChainBaseRevision
		else
			nextCapability.useChainBaseRevision = previousRuntime.revision
		end
		nextCapability.useChainTimeMilliseconds = useTransitionTimeMilliseconds
	else
		nextCapability.useChainBaseRevision = nil
		nextCapability.useChainTimeMilliseconds = nil
	end
	return nextRuntime
end

local function runtimeMemberById(runtime: Runtime): { [string]: MemberState }
	local output: { [string]: MemberState } = {}
	for _, team in runtime.teams do
		for _, member in team.members do
			output[member.id] = member
		end
	end
	return output
end

function MoverBinaryState.MaterializeDefinitions(
	programsValue: unknown,
	runtimeValue: unknown
): ({ MoverPushRules.Definition }?, string?)
	local context, runtime, authenticationError = validatedRuntime(programsValue, runtimeValue)
	if not context or not runtime then
		return nil, authenticationError
	end
	local members = runtimeMemberById(runtime)
	local definitions: { MoverPushRules.Definition } = table.create(#context.programs)
	for _, program in context.programs do
		local member = members[program.id]
		local trajectory = MoverTrajectory.SetBinaryState(
			program.position1,
			program.position2,
			program.durationMilliseconds,
			member.state,
			member.effectiveStartTimeMilliseconds
		)
		table.insert(definitions, {
			id = program.id,
			teamId = program.teamId,
			sourceOrder = program.sourceOrder,
			shape = program.shape,
			cframe = CFrame.new(trajectory.base),
			size = program.size,
			trajectory = trajectory,
			moverStop = program.moverStop,
		})
	end
	local validated, validationError = MoverPushRules.ValidateAndOrderDefinitions(definitions)
	if not validated then
		return nil, "materialized-definitions-invalid:" .. (validationError or "invalid")
	end
	return validated, nil
end

local function nextRevision(runtime: Runtime): (number?, string?)
	if runtime.revision >= MAXIMUM_REVISION then
		return nil, "runtime-revision-overflow"
	end
	return runtime.revision + 1, nil
end

local function resolveTeamSelector(context: ProgramContext, selector: unknown): (TeamProgram?, string?)
	if not isValidId(selector) then
		return nil, "invalid-team-selector"
	end
	local id = selector :: string
	local byTeam = context.teamById[id]
	local byMember = context.teamByMemberId[id]
	if byTeam and byMember and byTeam ~= byMember then
		return nil, "ambiguous-team-selector"
	end
	local team = byTeam or byMember
	if not team then
		return nil, "unknown-team-selector:" .. id
	end
	return team, nil
end

local function findRuntimeTeam(runtime: Runtime, teamId: string): (number, TeamState)
	for index, team in runtime.teams do
		if team.teamId == teamId then
			return index, team
		end
	end
	error("validated runtime is missing a team")
end

local function matchTeam(
	context: ProgramContext,
	runtime: Runtime,
	teamProgram: TeamProgram,
	state: MoverTrajectory.BinaryState,
	startTimeMilliseconds: number,
	captainThinkTimeMilliseconds: number?,
	useTransitionTimeMilliseconds: number?
): (Runtime?, string?)
	if not isSignedTime(startTimeMilliseconds) then
		return nil, "binary-start-time-overflow"
	end
	local revision, revisionError = nextRevision(runtime)
	if not revision then
		return nil, revisionError
	end
	local teams = copyTeams(runtime.teams)
	local teamIndex, team = findRuntimeTeam(runtime, teamProgram.teamId)
	local nextMembers: { MemberState } = table.create(#team.members)
	for memberIndex, member in team.members do
		table.insert(nextMembers, {
			id = member.id,
			state = state,
			effectiveStartTimeMilliseconds = startTimeMilliseconds,
			nextThinkTimeMilliseconds = if memberIndex == 1 and captainThinkTimeMilliseconds ~= nil
				then captainThinkTimeMilliseconds
				else member.nextThinkTimeMilliseconds,
		})
	end
	teams[teamIndex].members = nextMembers
	local nextRuntime, validationError = validateRuntimeValue(context, {
		revision = revision,
		teams = teams,
	})
	if not nextRuntime then
		return nil, validationError
	end
	return commitTransition(context, runtime, nextRuntime, useTransitionTimeMilliseconds), nil
end

local function scheduleCaptainThink(
	context: ProgramContext,
	runtime: Runtime,
	teamProgram: TeamProgram,
	nextThinkTimeMilliseconds: number,
	useTimeMilliseconds: number
): (Runtime?, string?)
	if not isSignedTime(nextThinkTimeMilliseconds) then
		return nil, "binary-think-time-overflow:" .. teamProgram.captainMoverId
	end
	local revision, revisionError = nextRevision(runtime)
	if not revision then
		return nil, revisionError
	end
	local teams = copyTeams(runtime.teams)
	local teamIndex, team = findRuntimeTeam(runtime, teamProgram.teamId)
	local captain = team.members[1]
	teams[teamIndex].members[1] = {
		id = captain.id,
		state = captain.state,
		effectiveStartTimeMilliseconds = captain.effectiveStartTimeMilliseconds,
		nextThinkTimeMilliseconds = nextThinkTimeMilliseconds,
	}
	local nextRuntime, validationError = validateRuntimeValue(context, {
		revision = revision,
		teams = teams,
	})
	if not nextRuntime then
		return nil, validationError
	end
	return commitTransition(context, runtime, nextRuntime, useTimeMilliseconds), nil
end

function MoverBinaryState.UseTeam(
	programsValue: unknown,
	runtimeValue: unknown,
	teamOrMemberIdValue: unknown,
	atTimeMillisecondsValue: unknown
): (Runtime?, UseOutcome?, string?)
	local context, runtime, authenticationError = authoritativeRuntime(programsValue, runtimeValue)
	if not context or not runtime then
		return nil, nil, authenticationError
	end
	if not isClockTime(atTimeMillisecondsValue) then
		return nil, nil, "invalid-use-time"
	end
	local atTime = atTimeMillisecondsValue :: number
	local teamProgram, selectorError = resolveTeamSelector(context, teamOrMemberIdValue)
	if not teamProgram then
		return nil, nil, selectorError
	end
	local _, team = findRuntimeTeam(runtime, teamProgram.teamId)
	local captain = team.members[1]
	local nextState: MoverTrajectory.BinaryState
	local nextStart: number
	local outcome: UseOutcome
	if captain.state == MoverTrajectory.BinaryStates.Pos1 then
		nextState = MoverTrajectory.BinaryStates.OneToTwo
		nextStart = atTime + MoverTrajectory.BinaryActivationDelayMilliseconds
		outcome = "Activated"
	elseif captain.state == MoverTrajectory.BinaryStates.Pos2 then
		local captainProgram = context.programById[teamProgram.captainMoverId]
		assert(captainProgram, "validated binary captain program missing")
		local scheduledRuntime, scheduleError =
			scheduleCaptainThink(context, runtime, teamProgram, atTime + captainProgram.waitMilliseconds, atTime)
		if not scheduledRuntime then
			return nil, nil, scheduleError
		end
		return scheduledRuntime, "HeldPos2", nil
	elseif captain.state == MoverTrajectory.BinaryStates.OneToTwo then
		nextState = MoverTrajectory.BinaryStates.TwoToOne
		nextStart = MoverTrajectory.ReversedStartTime(
			captain.effectiveStartTimeMilliseconds,
			teamProgram.captainDurationMilliseconds,
			atTime
		)
		outcome = "Reversed"
	else
		nextState = MoverTrajectory.BinaryStates.OneToTwo
		nextStart = MoverTrajectory.ReversedStartTime(
			captain.effectiveStartTimeMilliseconds,
			teamProgram.captainDurationMilliseconds,
			atTime
		)
		outcome = "Reversed"
	end
	local nextRuntime, transitionError = matchTeam(context, runtime, teamProgram, nextState, nextStart, nil, atTime)
	if not nextRuntime then
		return nil, nil, transitionError
	end
	return nextRuntime, outcome, nil
end

function MoverBinaryState.ReturnTeam(
	programsValue: unknown,
	runtimeValue: unknown,
	teamOrMemberIdValue: unknown,
	atTimeMillisecondsValue: unknown
): (Runtime?, string?)
	local context, runtime, authenticationError = authoritativeRuntime(programsValue, runtimeValue)
	if not context or not runtime then
		return nil, authenticationError
	end
	if not isClockTime(atTimeMillisecondsValue) then
		return nil, "invalid-return-time"
	end
	local teamProgram, selectorError = resolveTeamSelector(context, teamOrMemberIdValue)
	if not teamProgram then
		return nil, selectorError
	end
	local _, team = findRuntimeTeam(runtime, teamProgram.teamId)
	local nextThinkTime = team.members[1].nextThinkTimeMilliseconds
	if nextThinkTime <= 0 then
		return nil, "binary-return-think-disabled"
	end
	if nextThinkTime > (atTimeMillisecondsValue :: number) then
		return nil, "binary-return-think-not-due"
	end
	return matchTeam(
		context,
		runtime,
		teamProgram,
		MoverTrajectory.BinaryStates.TwoToOne,
		atTimeMillisecondsValue :: number,
		0,
		nil
	)
end

function MoverBinaryState.ReachedMember(
	programsValue: unknown,
	runtimeValue: unknown,
	moverIdValue: unknown,
	atTimeMillisecondsValue: unknown
): (Runtime?, ReachedOutcome?, string?)
	local context, runtime, authenticationError = authoritativeRuntime(programsValue, runtimeValue)
	if not context or not runtime then
		return nil, nil, authenticationError
	end
	if not isValidId(moverIdValue) or not isClockTime(atTimeMillisecondsValue) then
		return nil, nil, "invalid-reached-input"
	end
	local moverId = moverIdValue :: string
	local teamProgram = context.teamByMemberId[moverId]
	local program = context.programById[moverId]
	if not teamProgram or not program then
		return nil, nil, "unknown-reached-mover:" .. moverId
	end
	local teamIndex, team = findRuntimeTeam(runtime, teamProgram.teamId)
	local memberIndex: number? = nil
	local member: MemberState? = nil
	for index, candidate in team.members do
		if candidate.id == moverId then
			memberIndex = index
			member = candidate
			break
		end
	end
	assert(memberIndex and member, "validated runtime member lookup failed")
	if
		member.state ~= MoverTrajectory.BinaryStates.OneToTwo
		and member.state ~= MoverTrajectory.BinaryStates.TwoToOne
	then
		return nil, nil, "binary-member-not-moving:" .. moverId
	end
	local atTime = atTimeMillisecondsValue :: number
	if atTime < member.effectiveStartTimeMilliseconds + program.durationMilliseconds then
		return nil, nil, "binary-member-not-reached:" .. moverId
	end
	local nextState = if member.state == MoverTrajectory.BinaryStates.OneToTwo
		then MoverTrajectory.BinaryStates.Pos2
		else MoverTrajectory.BinaryStates.Pos1
	local outcome: ReachedOutcome = if nextState == MoverTrajectory.BinaryStates.Pos2
		then "ReachedPos2"
		else "ReachedPos1"
	local nextThinkTime = member.nextThinkTimeMilliseconds
	if nextState == MoverTrajectory.BinaryStates.Pos2 then
		nextThinkTime = atTime + program.waitMilliseconds
		if not isSignedTime(nextThinkTime) then
			return nil, nil, "binary-think-time-overflow:" .. moverId
		end
	end
	local revision, revisionError = nextRevision(runtime)
	if not revision then
		return nil, nil, revisionError
	end
	local teams = copyTeams(runtime.teams)
	teams[teamIndex].members[memberIndex :: number] = {
		id = moverId,
		state = nextState,
		effectiveStartTimeMilliseconds = atTime,
		nextThinkTimeMilliseconds = nextThinkTime,
	}
	local nextRuntime, validationError = validateRuntimeValue(context, {
		revision = revision,
		teams = teams,
	})
	if not nextRuntime then
		return nil, nil, validationError
	end
	return commitTransition(context, runtime, nextRuntime, nil), outcome, nil
end

local WINDOW_KEYS: { [string]: boolean } = table.freeze({
	revision = true,
	fromStep = true,
	toStep = true,
	fromTimeMilliseconds = true,
	toTimeMilliseconds = true,
})

local function validateWindow(value: unknown): (MoverClock.Window?, string?)
	if type(value) ~= "table" then
		return nil, "window-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if not hasExactKeys(source, WINDOW_KEYS, 5) then
		return nil, "invalid-window-shape"
	end
	local clock, clockError = MoverClock.ValidateSnapshot({
		revision = source.revision,
		step = source.fromStep,
	})
	if not clock then
		return nil, "invalid-window-clock:" .. (clockError or "invalid")
	end
	local expected, expectedError = MoverClock.WindowFor(clock)
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

local function trajectoriesEqual(left: MoverTrajectory.Trajectory, right: MoverTrajectory.Trajectory): boolean
	return left.kind == right.kind
		and left.startTimeMilliseconds == right.startTimeMilliseconds
		and left.durationMilliseconds == right.durationMilliseconds
		and left.base == right.base
		and left.delta == right.delta
end

local function definitionsEqual(left: MoverPushRules.Definition, right: MoverPushRules.Definition): boolean
	return left.id == right.id
		and left.teamId == right.teamId
		and left.sourceOrder == right.sourceOrder
		and left.shape == right.shape
		and left.cframe == right.cframe
		and left.size == right.size
		and left.moverStop == right.moverStop
		and trajectoriesEqual(left.trajectory, right.trajectory)
end

local function materializeCompleteBoundaryDefinitions(
	context: ProgramContext,
	programsValue: unknown,
	runtime: Runtime,
	boundary: MoverPushRules.TeamBoundary,
	label: string
): ({ MoverPushRules.Definition }?, string?)
	local materialized, materializedError = MoverBinaryState.MaterializeDefinitions(programsValue, runtime)
	if not materialized then
		return nil, materializedError
	end
	if #materialized ~= #context.programs then
		return nil, label .. "-binary-program-count-mismatch"
	end

	local replacementById: { [string]: MoverPushRules.Definition } = {}
	for _, definition in materialized do
		local program = context.programById[definition.id]
		if not program then
			return nil, label .. "-untrusted-binary-definition:" .. definition.id
		end
		if replacementById[definition.id] then
			return nil, label .. "-duplicate-binary-program:" .. definition.id
		end
		if definition.teamId ~= program.teamId or definition.sourceOrder ~= program.sourceOrder then
			return nil, label .. "-materialized-binary-topology-mismatch:" .. definition.id
		end
		replacementById[definition.id] = definition
	end

	-- The physical continuation owns the complete source-ordered definition
	-- array. Replace each trusted binary slot in place and carry every unrelated
	-- definition through verbatim; dropping to the binary-only materialization
	-- would erase generic teams that run before, between, or after binary teams.
	local merged: { MoverPushRules.Definition } = table.create(#boundary.definitions)
	local observedBinaryIds: { [string]: boolean } = {}
	for _, definition in boundary.definitions do
		local program = context.programById[definition.id]
		if program then
			if observedBinaryIds[definition.id] then
				return nil, label .. "-duplicate-boundary-binary-program:" .. definition.id
			end
			if definition.teamId ~= program.teamId or definition.sourceOrder ~= program.sourceOrder then
				return nil, label .. "-binary-id-team-topology-mismatch:" .. definition.id
			end
			local replacement = replacementById[definition.id]
			if not replacement then
				return nil, label .. "-missing-materialized-binary-program:" .. definition.id
			end
			observedBinaryIds[definition.id] = true
			table.insert(merged, replacement)
		elseif context.teamById[definition.teamId] then
			return nil, label .. "-binary-team-topology-mixing:" .. definition.id
		else
			table.insert(merged, definition)
		end
	end
	for _, program in context.programs do
		if not observedBinaryIds[program.id] then
			return nil, label .. "-missing-boundary-binary-program:" .. program.id
		end
		if not replacementById[program.id] then
			return nil, label .. "-missing-materialized-binary-program:" .. program.id
		end
	end

	local validated, validationError = MoverPushRules.ValidateAndOrderDefinitions(merged)
	if not validated then
		return nil, label .. "-complete-definitions-invalid:" .. (validationError or "invalid")
	end
	if #validated ~= #boundary.definitions then
		return nil, label .. "-complete-definition-count-mismatch"
	end
	for index, current in boundary.definitions do
		local candidate = validated[index]
		if
			candidate.id ~= current.id
			or candidate.teamId ~= current.teamId
			or candidate.sourceOrder ~= current.sourceOrder
		then
			return nil, label .. "-complete-source-order-mismatch"
		end
		if not context.programById[current.id] and not definitionsEqual(current, candidate) then
			return nil, label .. "-unrelated-definition-mutation:" .. current.id
		end
	end
	return validated, nil
end

local function validateBoundaryRuntimeTeam(
	context: ProgramContext,
	programsValue: unknown,
	runtime: Runtime,
	boundary: MoverPushRules.TeamBoundary,
	label: string
): (TeamProgram?, string?)
	local teamProgram = context.teamById[boundary.teamId]
	if not teamProgram then
		return nil, label .. "-team-not-binary:" .. boundary.teamId
	end
	if
		boundary.captainMoverId ~= teamProgram.captainMoverId
		or boundary.teamResult.captainMoverId ~= teamProgram.captainMoverId
	then
		return nil, label .. "-captain-mismatch:" .. boundary.teamId
	end
	if #boundary.memberMoverIds ~= #teamProgram.members then
		return nil, label .. "-member-count-mismatch:" .. boundary.teamId
	end
	for index, program in teamProgram.members do
		if boundary.memberMoverIds[index] ~= program.id then
			return nil, label .. "-teamchain-mismatch:" .. boundary.teamId
		end
	end

	local materialized, materializedError = MoverBinaryState.MaterializeDefinitions(programsValue, runtime)
	if not materialized then
		return nil, materializedError
	end
	local expectedById: { [string]: MoverPushRules.Definition } = {}
	for _, definition in materialized do
		expectedById[definition.id] = definition
	end
	local boundaryById: { [string]: MoverPushRules.Definition } = {}
	for _, definition in boundary.definitions do
		local program = context.programById[definition.id]
		if program then
			if boundaryById[definition.id] then
				return nil, label .. "-duplicate-binary-program:" .. definition.id
			end
			if definition.teamId ~= program.teamId or definition.sourceOrder ~= program.sourceOrder then
				return nil, label .. "-binary-id-team-topology-mismatch:" .. definition.id
			end
		elseif context.teamById[definition.teamId] then
			return nil, label .. "-binary-team-topology-mixing:" .. definition.id
		end
		boundaryById[definition.id] = definition
	end
	for _, program in context.programs do
		local expected = expectedById[program.id]
		local observed = boundaryById[program.id]
		if not expected or not observed or not definitionsEqual(expected, observed) then
			return nil, label .. "-runtime-mismatch:" .. program.id
		end
	end
	return teamProgram, nil
end

local function binaryBoundaryIndices(context: ProgramContext, boundary: MoverPushRules.TeamBoundary): { number }
	local indices: { number } = {}
	local observedTeams: { [string]: boolean } = {}
	local teamIndex = 0
	for _, definition in boundary.definitions do
		if not observedTeams[definition.teamId] then
			observedTeams[definition.teamId] = true
			teamIndex += 1
			if context.teamById[definition.teamId] then
				table.insert(indices, teamIndex)
			end
		end
	end
	return indices
end

local function claimPhysicalBoundary(
	context: ProgramContext,
	runtime: Runtime,
	boundary: MoverPushRules.TeamBoundary,
	window: MoverClock.Window,
	nextPhase: PhysicalBoundaryPhase
): string?
	local capability = RUNTIME_CAPABILITIES[runtime]
	assert(
		capability and capability.authoritative and capability.current,
		"physical binary boundary lost runtime authority"
	)
	local frameLineage, lineageError = MoverPushRules.InspectContinuationLineage(boundary)
	if frameLineage == nil then
		return "physical-boundary-lineage-invalid:" .. (lineageError or "invalid")
	end
	local indices = binaryBoundaryIndices(context, boundary)
	local finalIndex = indices[#indices]
	if not finalIndex then
		return "physical-boundary-has-no-binary-team"
	end
	local expectedIndex: number? = nil
	local priorLineage = capability.physicalFrameLineage
	if priorLineage == nil then
		expectedIndex = indices[1]
	else
		if capability.physicalBoundaryPhase ~= "Complete" then
			return "prior-binary-boundary-phase-incomplete:" .. tostring(capability.physicalBoundaryPhase)
		end
		if frameLineage == priorLineage then
			if
				capability.physicalClockRevision ~= window.revision
				or capability.physicalFrameFromStep ~= window.fromStep
				or capability.physicalFrameToStep ~= window.toStep
				or capability.physicalFrameFromTimeMilliseconds ~= window.fromTimeMilliseconds
				or capability.physicalFrameToTimeMilliseconds ~= window.toTimeMilliseconds
			then
				return "physical-boundary-frame-window-mismatch"
			end

			local lastIndex = capability.lastBinaryBoundaryIndex or 0
			for _, index in indices do
				if index > lastIndex then
					expectedIndex = index
					break
				end
			end
		else
			if capability.lastBinaryBoundaryIndex ~= capability.finalBinaryBoundaryIndex then
				return "prior-frame-binary-boundary-incomplete"
			end
			if capability.physicalClockRevision ~= window.revision then
				return "physical-boundary-clock-revision-mismatch"
			end
			if
				capability.physicalFrameToStep ~= window.fromStep
				or capability.physicalFrameToTimeMilliseconds ~= window.fromTimeMilliseconds
			then
				return "physical-boundary-clock-discontinuity"
			end
			expectedIndex = indices[1]
		end
	end
	if expectedIndex == nil then
		return "physical-boundary-binary-teams-exhausted"
	end
	if boundary.nextTeamIndex ~= expectedIndex then
		return "physical-boundary-out-of-order"
	end
	capability.physicalFrameLineage = frameLineage
	capability.physicalClockRevision = window.revision
	capability.physicalFrameFromStep = window.fromStep
	capability.physicalFrameToStep = window.toStep
	capability.physicalFrameFromTimeMilliseconds = window.fromTimeMilliseconds
	capability.physicalFrameToTimeMilliseconds = window.toTimeMilliseconds
	capability.lastBinaryBoundaryIndex = boundary.nextTeamIndex
	capability.finalBinaryBoundaryIndex = finalIndex
	capability.physicalBoundaryPhase = nextPhase
	return nil
end

local function verifyClaimedPhysicalBoundary(
	runtime: Runtime,
	boundary: MoverPushRules.TeamBoundary,
	expectedPhase: PhysicalBoundaryPhase
): string?
	local capability = RUNTIME_CAPABILITIES[runtime]
	assert(
		capability and capability.authoritative and capability.current,
		"claimed binary boundary lost runtime authority"
	)
	local frameLineage, lineageError = MoverPushRules.InspectContinuationLineage(boundary)
	if frameLineage == nil then
		return "binary-boundary-lineage-invalid:" .. (lineageError or "invalid")
	end
	if
		capability.physicalFrameLineage ~= frameLineage
		or capability.physicalFrameFromTimeMilliseconds ~= boundary.fromTimeMilliseconds
		or capability.physicalFrameToTimeMilliseconds ~= boundary.toTimeMilliseconds
		or capability.lastBinaryBoundaryIndex ~= boundary.nextTeamIndex
	then
		return "binary-boundary-not-claimed"
	end
	if capability.physicalBoundaryPhase ~= expectedPhase then
		return "binary-boundary-phase-mismatch:" .. tostring(capability.physicalBoundaryPhase)
	end
	return nil
end

local function setPhysicalBoundaryPhase(runtime: Runtime, phase: PhysicalBoundaryPhase)
	local capability = RUNTIME_CAPABILITIES[runtime]
	assert(
		capability and capability.authoritative and capability.current,
		"binary boundary phase lost runtime authority"
	)
	capability.physicalBoundaryPhase = phase
end

local REACHED_EFFECT_KEYS: { [string]: boolean } = table.freeze({
	runtime = true,
	bodyMutations = true,
})

local function committedBoundaryFailStop(message: string)
	error("binary-committed-boundary-fail-stop:" .. message, 3)
end

function MoverBinaryState.ProcessCommittedBoundary(
	programsValue: unknown,
	runtimeValue: unknown,
	boundaryValue: unknown,
	windowValue: unknown,
	reachedCallbackValue: unknown?
): (Runtime?, MoverPushRules.TeamBoundary?, { ReachedEvent }?, string?)
	local context, runtime, authenticationError = authoritativeRuntime(programsValue, runtimeValue)
	if not context or not runtime then
		return nil, nil, nil, authenticationError
	end
	if reachedCallbackValue ~= nil and type(reachedCallbackValue) ~= "function" then
		return nil, nil, nil, "reached-callback-invalid"
	end
	local callback = reachedCallbackValue :: ReachedCallback?
	local window, windowError = validateWindow(windowValue)
	if not window then
		return nil, nil, nil, windowError
	end
	local boundary, boundaryError = MoverPushRules.InspectTeamBoundary(boundaryValue)
	if not boundary then
		return nil, nil, nil, "invalid-committed-boundary:" .. (boundaryError or "invalid")
	end
	if not isClockTime(boundary.toTimeMilliseconds) then
		return nil, nil, nil, "invalid-committed-boundary-time"
	end
	if
		boundary.fromTimeMilliseconds ~= window.fromTimeMilliseconds
		or boundary.toTimeMilliseconds ~= window.toTimeMilliseconds
	then
		return nil, nil, nil, "committed-boundary-window-mismatch"
	end
	if boundary.teamResult.disposition ~= "Committed" then
		return nil, nil, nil, "binary-boundary-not-committed"
	end
	local teamProgram, teamError =
		validateBoundaryRuntimeTeam(context, programsValue, runtime, boundary, "committed-boundary")
	if not teamProgram then
		return nil, nil, nil, teamError
	end
	local claimError = claimPhysicalBoundary(context, runtime, boundary, window, "NeedsThink")
	if claimError then
		return nil, nil, nil, claimError
	end
	local events: { ReachedEvent } = {}
	if not boundary.ranMoverTeam then
		table.freeze(events)
		return runtime, boundary, events, nil
	end

	local initialCapability = RUNTIME_CAPABILITIES[runtime]
	assert(initialCapability and initialCapability.lineage, "authoritative binary lineage missing")
	local lineage = initialCapability.lineage
	local currentRuntime = runtime
	local currentBoundary = boundary
	for _, program in teamProgram.members do
		local _, runtimeTeam = findRuntimeTeam(currentRuntime, teamProgram.teamId)
		local member: MemberState? = nil
		for _, candidate in runtimeTeam.members do
			if candidate.id == program.id then
				member = candidate
				break
			end
		end
		assert(member, "validated binary boundary member is missing")
		local moving = member.state == MoverTrajectory.BinaryStates.OneToTwo
			or member.state == MoverTrajectory.BinaryStates.TwoToOne
		if
			not moving
			or currentBoundary.toTimeMilliseconds
				< member.effectiveStartTimeMilliseconds + program.durationMilliseconds
		then
			continue
		end

		local reachedRuntime, outcome, reachedError = MoverBinaryState.ReachedMember(
			programsValue,
			currentRuntime,
			program.id,
			currentBoundary.toTimeMilliseconds
		)
		if not reachedRuntime or not outcome then
			committedBoundaryFailStop(reachedError or "binary-reached-transition-failed")
		end
		currentRuntime = reachedRuntime
		local reachedDefinitions, definitionError =
			materializeCompleteBoundaryDefinitions(context, programsValue, currentRuntime, currentBoundary, "reached")
		if not reachedDefinitions then
			committedBoundaryFailStop(definitionError or "reached-definitions-invalid")
		end
		local reachedBoundary, updateError = MoverPushRules.ApplyBoundaryUpdate(currentBoundary, {
			definitions = reachedDefinitions,
		})
		if not reachedBoundary then
			committedBoundaryFailStop("reached-boundary-update-failed:" .. (updateError or "invalid"))
		end
		currentBoundary = reachedBoundary
		local event: ReachedEvent = {
			teamId = teamProgram.teamId,
			moverId = program.id,
			outcome = outcome,
			atTimeMilliseconds = currentBoundary.toTimeMilliseconds,
		}
		table.freeze(event)
		table.insert(events, event)

		if callback then
			local callbackBaseRuntime = currentRuntime
			local callbackSucceeded, effectValue = pcall(callback, event, currentRuntime)
			if not callbackSucceeded then
				committedBoundaryFailStop("reached-callback-failed:" .. program.id)
			end
			if effectValue ~= nil then
				if type(effectValue) ~= "table" then
					committedBoundaryFailStop("reached-effect-not-table:" .. program.id)
				end
				local effect = effectValue :: { [unknown]: unknown }
				local expectedKeys = (if effect.runtime == nil then 0 else 1)
					+ (if effect.bodyMutations == nil then 0 else 1)
				if expectedKeys == 0 then
					committedBoundaryFailStop("reached-effect-empty:" .. program.id)
				end
				if not hasExactKeys(effect, REACHED_EFFECT_KEYS, expectedKeys) then
					committedBoundaryFailStop("invalid-reached-effect-shape:" .. program.id)
				end
				local effectRuntimeValue = if effect.runtime == nil then currentRuntime else effect.runtime
				local _, effectRuntime, effectRuntimeError = authoritativeRuntime(programsValue, effectRuntimeValue)
				if not effectRuntime then
					committedBoundaryFailStop(
						"invalid-reached-effect-runtime:" .. program.id .. ":" .. (effectRuntimeError or "invalid")
					)
				end
				local effectCapability = RUNTIME_CAPABILITIES[effectRuntime]
				assert(effectCapability, "validated reached effect capability missing")
				if effectCapability.lineage ~= lineage then
					committedBoundaryFailStop("reached-effect-lineage-mismatch:" .. program.id)
				end
				if
					effectRuntime ~= callbackBaseRuntime
					and (
						effectCapability.useChainBaseRevision ~= callbackBaseRuntime.revision
						or effectCapability.useChainTimeMilliseconds ~= currentBoundary.toTimeMilliseconds
					)
				then
					committedBoundaryFailStop("reached-effect-transition-not-boundary-use:" .. program.id)
				end
				local effectDefinitions, effectDefinitionError = materializeCompleteBoundaryDefinitions(
					context,
					programsValue,
					effectRuntime,
					currentBoundary,
					"reached-effect"
				)
				if not effectDefinitions then
					committedBoundaryFailStop(effectDefinitionError or "reached-effect-definitions-invalid")
				end
				local boundaryUpdate: MoverPushRules.BoundaryUpdate = {
					definitions = effectDefinitions,
					bodyMutations = effect.bodyMutations :: { MoverPushRules.BodyMutation }?,
				}
				local effectBoundary, effectBoundaryError =
					MoverPushRules.ApplyBoundaryUpdate(currentBoundary, boundaryUpdate)
				if not effectBoundary then
					committedBoundaryFailStop(
						"reached-effect-boundary-update-failed:"
							.. program.id
							.. ":"
							.. (effectBoundaryError or "invalid")
					)
				end
				currentRuntime = effectRuntime
				currentBoundary = effectBoundary
			else
				local _, _, callbackRuntimeError = authoritativeRuntime(programsValue, currentRuntime)
				if callbackRuntimeError then
					committedBoundaryFailStop("reached-callback-runtime-not-returned:" .. program.id)
				end
			end
		end
	end
	table.freeze(events)
	return currentRuntime, currentBoundary, events, nil
end

local function blockedBoundaryFailStop(message: string)
	error("binary-blocked-boundary-fail-stop:" .. message, 3)
end

function MoverBinaryState.ProcessBlockedCallback(
	programsValue: unknown,
	runtimeValue: unknown,
	boundaryValue: unknown,
	blockedCallbackValue: unknown?
): (Runtime?, MoverPushRules.TeamBoundary?, BlockedEvent?, string?)
	local context, runtime, authenticationError = authoritativeRuntime(programsValue, runtimeValue)
	if not context or not runtime then
		return nil, nil, nil, authenticationError
	end
	if blockedCallbackValue ~= nil and type(blockedCallbackValue) ~= "function" then
		return nil, nil, nil, "blocked-callback-invalid"
	end
	local callback = blockedCallbackValue :: BlockedCallback?
	local boundary, boundaryError = MoverPushRules.InspectTeamBoundary(boundaryValue)
	if not boundary then
		return nil, nil, nil, "invalid-blocked-callback-boundary:" .. (boundaryError or "invalid")
	end
	if boundary.teamResult.disposition ~= "BlockedRollback" then
		return nil, nil, nil, "binary-boundary-not-blocked"
	end
	local teamProgram, teamError =
		validateBoundaryRuntimeTeam(context, programsValue, runtime, boundary, "blocked-callback-boundary")
	if not teamProgram then
		return nil, nil, nil, teamError
	end
	local claimError = verifyClaimedPhysicalBoundary(runtime, boundary, "NeedsBlockedCallback")
	if claimError then
		return nil, nil, nil, claimError
	end
	local blockedMoverId = boundary.teamResult.blockedMoverId
	local blockedByBodyId = boundary.teamResult.blockedByBodyId
	assert(blockedMoverId and blockedByBodyId, "validated blocked boundary lacks obstacle identity")
	local event: BlockedEvent = {
		teamId = teamProgram.teamId,
		captainMoverId = teamProgram.captainMoverId,
		blockedMoverId = blockedMoverId,
		blockedByBodyId = blockedByBodyId,
		atTimeMilliseconds = boundary.toTimeMilliseconds,
	}
	table.freeze(event)
	if not callback then
		setPhysicalBoundaryPhase(runtime, "NeedsThink")
		return runtime, boundary, event, nil
	end

	local baseRuntime = runtime
	local callbackSucceeded, effectValue = pcall(callback, event, runtime)
	if not callbackSucceeded then
		blockedBoundaryFailStop("blocked-callback-failed:" .. teamProgram.captainMoverId)
	end
	if effectValue == nil then
		local _, _, callbackRuntimeError = authoritativeRuntime(programsValue, baseRuntime)
		if callbackRuntimeError then
			blockedBoundaryFailStop("blocked-callback-runtime-not-returned:" .. teamProgram.captainMoverId)
		end
		setPhysicalBoundaryPhase(baseRuntime, "NeedsThink")
		return baseRuntime, boundary, event, nil
	end
	if type(effectValue) ~= "table" then
		blockedBoundaryFailStop("blocked-effect-not-table:" .. teamProgram.captainMoverId)
	end
	local effect = effectValue :: { [unknown]: unknown }
	local expectedKeys = (if effect.runtime == nil then 0 else 1) + (if effect.bodyMutations == nil then 0 else 1)
	if expectedKeys == 0 then
		blockedBoundaryFailStop("blocked-effect-empty:" .. teamProgram.captainMoverId)
	end
	if not hasExactKeys(effect, REACHED_EFFECT_KEYS, expectedKeys) then
		blockedBoundaryFailStop("invalid-blocked-effect-shape:" .. teamProgram.captainMoverId)
	end
	local effectRuntimeValue = if effect.runtime == nil then baseRuntime else effect.runtime
	local _, effectRuntime, effectRuntimeError = authoritativeRuntime(programsValue, effectRuntimeValue)
	if not effectRuntime then
		blockedBoundaryFailStop(
			"invalid-blocked-effect-runtime:" .. teamProgram.captainMoverId .. ":" .. (effectRuntimeError or "invalid")
		)
	end
	local baseCapability = RUNTIME_CAPABILITIES[baseRuntime]
	local effectCapability = RUNTIME_CAPABILITIES[effectRuntime]
	assert(baseCapability and effectCapability, "validated blocked effect capability missing")
	if effectCapability.lineage ~= baseCapability.lineage then
		blockedBoundaryFailStop("blocked-effect-lineage-mismatch:" .. teamProgram.captainMoverId)
	end
	if
		effectRuntime ~= baseRuntime
		and (
			effectCapability.useChainBaseRevision ~= baseRuntime.revision
			or effectCapability.useChainTimeMilliseconds ~= boundary.toTimeMilliseconds
		)
	then
		blockedBoundaryFailStop("blocked-effect-transition-not-boundary-use:" .. teamProgram.captainMoverId)
	end
	local effectDefinitions, definitionError =
		materializeCompleteBoundaryDefinitions(context, programsValue, effectRuntime, boundary, "blocked-effect")
	if not effectDefinitions then
		blockedBoundaryFailStop(definitionError or "blocked-effect-definitions-invalid")
	end
	local boundaryUpdate: MoverPushRules.BoundaryUpdate = {
		definitions = effectDefinitions,
		bodyMutations = effect.bodyMutations :: { MoverPushRules.BodyMutation }?,
	}
	local effectBoundary, effectBoundaryError = MoverPushRules.ApplyBoundaryUpdate(boundary, boundaryUpdate)
	if not effectBoundary then
		blockedBoundaryFailStop(
			"blocked-effect-boundary-update-failed:"
				.. teamProgram.captainMoverId
				.. ":"
				.. (effectBoundaryError or "invalid")
		)
	end
	setPhysicalBoundaryPhase(effectRuntime, "NeedsThink")
	return effectRuntime, effectBoundary, event, nil
end

function MoverBinaryState.ProcessCaptainThink(
	programsValue: unknown,
	runtimeValue: unknown,
	boundaryValue: unknown
): (Runtime?, MoverPushRules.TeamBoundary?, boolean?, string?)
	local context, runtime, authenticationError = authoritativeRuntime(programsValue, runtimeValue)
	if not context or not runtime then
		return nil, nil, nil, authenticationError
	end
	local boundary, boundaryError = MoverPushRules.InspectTeamBoundary(boundaryValue)
	if not boundary then
		return nil, nil, nil, "invalid-think-boundary:" .. (boundaryError or "invalid")
	end
	local teamProgram, teamError =
		validateBoundaryRuntimeTeam(context, programsValue, runtime, boundary, "think-boundary")
	if not teamProgram then
		return nil, nil, nil, teamError
	end
	local claimError = verifyClaimedPhysicalBoundary(runtime, boundary, "NeedsThink")
	if claimError then
		return nil, nil, nil, claimError
	end
	local _, team = findRuntimeTeam(runtime, teamProgram.teamId)
	local nextThinkTime = team.members[1].nextThinkTimeMilliseconds
	if nextThinkTime <= 0 or nextThinkTime > boundary.toTimeMilliseconds then
		setPhysicalBoundaryPhase(runtime, "Complete")
		return runtime, boundary, false, nil
	end
	local returnedRuntime, returnError =
		MoverBinaryState.ReturnTeam(programsValue, runtime, teamProgram.captainMoverId, boundary.toTimeMilliseconds)
	if not returnedRuntime then
		committedBoundaryFailStop(returnError or "captain-return-think-failed")
	end
	local definitions, definitionError =
		materializeCompleteBoundaryDefinitions(context, programsValue, returnedRuntime, boundary, "captain-return")
	if not definitions then
		committedBoundaryFailStop(definitionError or "captain-return-definitions-invalid")
	end
	local returnedBoundary, updateError = MoverPushRules.ApplyBoundaryUpdate(boundary, {
		definitions = definitions,
	})
	if not returnedBoundary then
		committedBoundaryFailStop("captain-return-boundary-update-failed:" .. (updateError or "invalid"))
	end
	setPhysicalBoundaryPhase(returnedRuntime, "Complete")
	return returnedRuntime, returnedBoundary, true, nil
end

function MoverBinaryState.ApplyBlockedBoundaryRebase(
	programsValue: unknown,
	runtimeValue: unknown,
	boundaryValue: unknown,
	windowValue: unknown
): (Runtime?, MoverPushRules.TeamBoundary?, string?)
	local context, runtime, authenticationError = authoritativeRuntime(programsValue, runtimeValue)
	if not context or not runtime then
		return nil, nil, authenticationError
	end
	local boundary, boundaryError = MoverPushRules.InspectTeamBoundary(boundaryValue)
	if not boundary then
		return nil, nil, "invalid-blocked-boundary:" .. (boundaryError or "invalid")
	end
	local window, windowError = validateWindow(windowValue)
	if not window then
		return nil, nil, windowError
	end
	if
		boundary.fromTimeMilliseconds ~= window.fromTimeMilliseconds
		or boundary.toTimeMilliseconds ~= window.toTimeMilliseconds
	then
		return nil, nil, "blocked-boundary-window-mismatch"
	end
	if boundary.teamResult.disposition ~= "BlockedRollback" then
		return nil, nil, "binary-boundary-not-blocked"
	end
	local teamProgram, teamError =
		validateBoundaryRuntimeTeam(context, programsValue, runtime, boundary, "blocked-boundary")
	if not teamProgram then
		return nil, nil, teamError
	end

	local teamIndex, team = findRuntimeTeam(runtime, teamProgram.teamId)
	local captain = team.members[1]
	if captain.state == MoverTrajectory.BinaryStates.Pos1 or captain.state == MoverTrajectory.BinaryStates.Pos2 then
		return nil, nil, "blocked-stationary-binary-team:" .. team.teamId
	end
	local delta = window.toTimeMilliseconds - window.fromTimeMilliseconds
	local teams = copyTeams(runtime.teams)
	for memberIndex, member in team.members do
		local shifted = member.effectiveStartTimeMilliseconds + delta
		if not isSignedTime(shifted) then
			return nil, nil, "blocked-binary-start-time-overflow:" .. member.id
		end
		teams[teamIndex].members[memberIndex].effectiveStartTimeMilliseconds = shifted
	end
	local revision, revisionError = nextRevision(runtime)
	if not revision then
		return nil, nil, revisionError
	end
	local nextRuntime, validationError = validateRuntimeValue(context, {
		revision = revision,
		teams = teams,
	})
	if not nextRuntime then
		return nil, nil, validationError
	end
	local definitions, definitionError =
		materializeCompleteBoundaryDefinitions(context, programsValue, nextRuntime, boundary, "blocked-rebase")
	if not definitions then
		return nil, nil, definitionError
	end
	local claimError = claimPhysicalBoundary(context, runtime, boundary, window, "NeedsBlockedCallback")
	if claimError then
		return nil, nil, claimError
	end
	local rebasedBoundary, updateError = MoverPushRules.ApplyBoundaryUpdate(boundary, {
		definitions = definitions,
	})
	if not rebasedBoundary then
		blockedBoundaryFailStop("blocked-rebase-boundary-update-failed:" .. (updateError or "invalid"))
	end
	return commitTransition(context, runtime, nextRuntime, nil), rebasedBoundary, nil
end

MoverBinaryState.MaximumPrograms = MAXIMUM_PROGRAMS
MoverBinaryState.MaximumTimeMilliseconds = MAXIMUM_TIME
MoverBinaryState.MaximumRevision = MAXIMUM_REVISION

return table.freeze(MoverBinaryState)
