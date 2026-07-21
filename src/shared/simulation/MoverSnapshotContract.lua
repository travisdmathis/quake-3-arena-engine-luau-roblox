--[[
SPDX-License-Identifier: GPL-2.0-or-later

Bounded mover snapshot and replay boundary translated from Quake III Arena:
  code/cgame/cg_predict.c (snapshot serverTime/cg.physicsTime prediction)
  code/cgame/cg_ents.c (CG_AdjustPositionForMover)
  code/game/bg_misc.c (BG_EvaluateTrajectory)
  code/game/g_mover.c (G_MoverTeam blocked-team trTime rebase)

Q3 evaluates mover collision from the authoritative snapshot time, then applies
only the ground mover's translation after command replay. the Roblox Luau port carries
that time as a server-owned fixed-clock revision and step. The redundant wire
time is validation evidence only: it must equal MoverClock.TimeForStep(step),
and no API here accepts a client-authored evaluation time.

Legacy blocked mover teams advance every member's trajectory start by one
identical server-time delta. Their runtime definitions may therefore differ
from trusted map definitions only by a bounded nonnegative start offset. V2
binary movers instead carry only MoverBinaryState Runtime records; endpoint
geometry and trajectories are materialized from trusted Programs after the
wire runtime is canonicalized. The two domains must remain globally disjoint
in mover ID, source order, and team ID before their collision frame is merged.

This contract intentionally contains no body-push input or resolution API.
Side pushes remain authoritative-server work. Carrier adjustment returns a new
presentation record and cannot mutate the predicted simulation state.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local MapMoverContract = require(script.Parent.Parent.maps.MapMoverContract)
local MoverBinaryState = require(script.Parent.MoverBinaryState)
local MoverClock = require(script.Parent.MoverClock)
local MoverCollisionFrame = require(script.Parent.MoverCollisionFrame)
local MoverPushRules = require(script.Parent.MoverPushRules)
local MoverTrajectory = require(script.Parent.MoverTrajectory)

export type WireDefinition = {
	id: string,
	teamId: string,
	sourceOrder: number,
	shape: MoverPushRules.Shape,
	cframe: CFrame,
	size: Vector3,
	trajectory: MoverTrajectory.Trajectory,
	angularTrajectory: MoverTrajectory.Trajectory,
	moverStop: boolean,
}

export type WireBinaryMemberState = {
	id: string,
	state: MoverTrajectory.BinaryState,
	effectiveStartTimeMilliseconds: number,
	nextThinkTimeMilliseconds: number,
}

export type WireBinaryTeamState = {
	teamId: string,
	captainMoverId: string,
	members: { WireBinaryMemberState },
}

export type WireBinaryRuntime = {
	revision: number,
	teams: { WireBinaryTeamState },
}

export type WireSnapshot = {
	schemaVersion: number,
	clockRevision: number,
	clockStep: number,
	clockTimeMilliseconds: number,
	definitions: { WireDefinition },
	binaryRuntime: WireBinaryRuntime?,
}

export type ValidatedSnapshot = {
	schemaVersion: number,
	clock: MoverClock.Snapshot,
	timeMilliseconds: number,
	definitions: { MoverPushRules.Definition },
	binaryRuntime: MoverBinaryState.Runtime?,
	frame: MoverCollisionFrame.Frame,
	_token: unknown,
}

export type CarrierPresentation = {
	kind: "TranslationOnly",
	moverId: string?,
	clockRevision: number,
	fromStep: number,
	toStep: number,
	simulationPosition: Vector3,
	presentationPosition: Vector3,
	translation: Vector3,
}

local MoverSnapshotContract = {}

local LEGACY_SCHEMA_VERSION = 1
local BINARY_SCHEMA_VERSION = 2
local VALIDATED_TOKEN = table.freeze({})

local SNAPSHOT_V1_KEYS: { [string]: boolean } = {
	schemaVersion = true,
	clockRevision = true,
	clockStep = true,
	clockTimeMilliseconds = true,
	definitions = true,
}
table.freeze(SNAPSHOT_V1_KEYS)

local SNAPSHOT_V2_KEYS: { [string]: boolean } = {
	schemaVersion = true,
	clockRevision = true,
	clockStep = true,
	clockTimeMilliseconds = true,
	definitions = true,
	binaryRuntime = true,
}
table.freeze(SNAPSHOT_V2_KEYS)

local CARRIER_KEYS: { [string]: boolean } = {
	kind = true,
	moverId = true,
	clockRevision = true,
	fromStep = true,
	toStep = true,
	simulationPosition = true,
	presentationPosition = true,
	translation = true,
}
table.freeze(CARRIER_KEYS)

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

local function isBoundedInteger(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function copyTrajectory(trajectory: MoverTrajectory.Trajectory): MoverTrajectory.Trajectory
	local copied: MoverTrajectory.Trajectory = {
		kind = trajectory.kind,
		startTimeMilliseconds = trajectory.startTimeMilliseconds,
		durationMilliseconds = trajectory.durationMilliseconds,
		base = trajectory.base,
		delta = trajectory.delta,
	}
	table.freeze(copied)
	return copied
end

local function copyDefinition(definition: MoverPushRules.Definition): WireDefinition
	local copied: WireDefinition = {
		id = definition.id,
		teamId = definition.teamId,
		sourceOrder = definition.sourceOrder,
		shape = definition.shape,
		cframe = definition.cframe,
		size = definition.size,
		trajectory = copyTrajectory(definition.trajectory),
		angularTrajectory = copyTrajectory(definition.angularTrajectory),
		moverStop = definition.moverStop,
	}
	table.freeze(copied)
	return copied
end

local function copyDefinitions(definitions: { MoverPushRules.Definition }): { WireDefinition }
	local copies: { WireDefinition } = table.create(#definitions)
	for _, definition in definitions do
		table.insert(copies, copyDefinition(definition))
	end
	table.freeze(copies)
	return copies
end

local function copyBinaryRuntime(runtime: MoverBinaryState.Runtime): WireBinaryRuntime
	local teams: { WireBinaryTeamState } = table.create(#runtime.teams)
	for _, runtimeTeam in runtime.teams do
		local members: { WireBinaryMemberState } = table.create(#runtimeTeam.members)
		for _, runtimeMember in runtimeTeam.members do
			local member: WireBinaryMemberState = {
				id = runtimeMember.id,
				state = runtimeMember.state,
				effectiveStartTimeMilliseconds = runtimeMember.effectiveStartTimeMilliseconds,
				nextThinkTimeMilliseconds = runtimeMember.nextThinkTimeMilliseconds,
			}
			table.freeze(member)
			table.insert(members, member)
		end
		table.freeze(members)
		local team: WireBinaryTeamState = {
			teamId = runtimeTeam.teamId,
			captainMoverId = runtimeTeam.captainMoverId,
			members = members,
		}
		table.freeze(team)
		table.insert(teams, team)
	end
	table.freeze(teams)
	local copied: WireBinaryRuntime = {
		revision = runtime.revision,
		teams = teams,
	}
	table.freeze(copied)
	return copied
end

local function trajectoryMismatch(left: MoverTrajectory.Trajectory, right: MoverTrajectory.Trajectory): string?
	if left.kind ~= right.kind then
		return "trajectory.kind"
	elseif left.durationMilliseconds ~= right.durationMilliseconds then
		return "trajectory.durationMilliseconds"
	elseif left.base ~= right.base then
		return "trajectory.base"
	elseif left.delta ~= right.delta then
		return "trajectory.delta"
	end
	return nil
end

local function definitionMismatch(actual: MoverPushRules.Definition, expected: MoverPushRules.Definition): string?
	if actual.teamId ~= expected.teamId then
		return "teamId"
	elseif actual.sourceOrder ~= expected.sourceOrder then
		return "sourceOrder"
	elseif actual.shape ~= expected.shape then
		return "shape"
	elseif actual.cframe ~= expected.cframe then
		return "cframe"
	elseif actual.size ~= expected.size then
		return "size"
	elseif actual.moverStop ~= expected.moverStop then
		return "moverStop"
	end
	local positionMismatch = trajectoryMismatch(actual.trajectory, expected.trajectory)
	if positionMismatch then
		return positionMismatch
	end
	local angularMismatch = trajectoryMismatch(actual.angularTrajectory, expected.angularTrajectory)
	return if angularMismatch then "angular." .. angularMismatch else nil
end

local function runtimeDefinitionsMatchTrusted(
	runtimeDefinitions: { MoverPushRules.Definition },
	trustedDefinitions: { MoverPushRules.Definition },
	maximumStartOffsetMilliseconds: number
): string?
	local trustedById: { [string]: MoverPushRules.Definition } = {}
	for _, definition in trustedDefinitions do
		trustedById[definition.id] = definition
	end

	local teamStartOffsets: { [string]: number } = {}
	for _, runtimeDefinition in runtimeDefinitions do
		local trusted = trustedById[runtimeDefinition.id]
		if not trusted then
			return "unknown-mover-id:" .. runtimeDefinition.id
		end
		local mismatch = definitionMismatch(runtimeDefinition, trusted)
		if mismatch then
			return string.format("mover-definition-mismatch:%s:%s", runtimeDefinition.id, mismatch)
		end

		local startOffset = runtimeDefinition.trajectory.startTimeMilliseconds
			- trusted.trajectory.startTimeMilliseconds
		if startOffset < 0 then
			return "mover-start-time-offset-negative:" .. runtimeDefinition.id
		end
		if not isBoundedInteger(startOffset, 0, maximumStartOffsetMilliseconds) then
			return "mover-start-time-offset-after-clock:" .. runtimeDefinition.id
		end
		local angularStartOffset = runtimeDefinition.angularTrajectory.startTimeMilliseconds
			- trusted.angularTrajectory.startTimeMilliseconds
		if angularStartOffset ~= startOffset then
			return "mover-angular-start-time-offset-mismatch:" .. runtimeDefinition.id
		end

		local teamStartOffset = teamStartOffsets[trusted.teamId]
		if teamStartOffset == nil then
			teamStartOffsets[trusted.teamId] = startOffset
		elseif teamStartOffset ~= startOffset then
			return "mover-team-start-time-offset-mismatch:" .. trusted.teamId
		end
		trustedById[runtimeDefinition.id] = nil
	end

	for _, definition in trustedDefinitions do
		if trustedById[definition.id] ~= nil then
			return "missing-mover-id:" .. definition.id
		end
	end
	return nil
end

local function validateTrustedDefinitions(
	definitionsValue: unknown,
	boundsValue: unknown
): ({ MoverPushRules.Definition }?, string?)
	local definitions, definitionsError = MapMoverContract.ValidateAndOrder(definitionsValue, boundsValue)
	if not definitions then
		return nil, "invalid-trusted-definitions:" .. (definitionsError or "invalid")
	end
	return definitions, nil
end

local function validateTrustedBinaryPrograms(
	programsValue: unknown,
	boundsValue: unknown
): ({ MoverBinaryState.Program }?, string?)
	local programs, programsError = MoverBinaryState.ValidateAndOrderPrograms(programsValue)
	if not programs then
		return nil, "invalid-trusted-binary-programs:" .. (programsError or "invalid")
	end

	-- Binary trTime may be signed at runtime, so MapMoverContract cannot validate
	-- a materialized state directly. Validate an authored zero-time Pos1 -> Pos2
	-- span instead; its hull covers both immutable endpoints for every state.
	local spans: { MoverPushRules.Definition } = table.create(#programs)
	for _, program in programs do
		local positionTrajectory = MoverTrajectory.SetBinaryState(
			program.position1,
			program.position2,
			program.durationMilliseconds,
			MoverTrajectory.BinaryStates.OneToTwo,
			0
		)
		table.insert(spans, {
			id = program.id,
			teamId = program.teamId,
			sourceOrder = program.sourceOrder,
			shape = program.shape,
			cframe = program.cframe,
			size = program.size,
			trajectory = positionTrajectory,
			moverStop = program.moverStop,
		})
	end
	local _, boundsError = MapMoverContract.ValidateAndOrder(spans, boundsValue)
	if boundsError then
		return nil, "invalid-trusted-binary-program-bounds:" .. boundsError
	end
	return programs, nil
end

local function validatePublishableBinaryRuntime(
	programsValue: unknown,
	runtimeValue: unknown,
	boundsValue: unknown
): (
	{ MoverBinaryState.Program }?,
	MoverBinaryState.Runtime?,
	{ MoverPushRules.Definition }?,
	string?
)
	-- Publishable runtimes are current authority-bound tokens with no unfinished
	-- physical boundary. Revalidating the Program array would sever that
	-- capability, so inspect the existing token without reconstructing it.
	local runtime, runtimeError = MoverBinaryState.InspectPublishableRuntime(programsValue, runtimeValue)
	if not runtime then
		return nil, nil, nil, "invalid-publishable-binary-runtime:" .. (runtimeError or "invalid")
	end
	local programs = programsValue :: { MoverBinaryState.Program }
	if #programs == 0 then
		return nil, nil, nil, "binary-runtime-for-empty-programs"
	end

	local checkedPrograms, programsError = validateTrustedBinaryPrograms(programs, boundsValue)
	if not checkedPrograms then
		return nil, nil, nil, programsError
	end
	-- validateTrustedBinaryPrograms returns an equivalent fresh program context;
	-- materialization must retain the original authority-bound context.
	local definitions, definitionsError = MoverBinaryState.MaterializeDefinitions(programs, runtime)
	if not definitions then
		return nil, nil, nil, "invalid-publishable-binary-definitions:" .. (definitionsError or "invalid")
	end
	return programs, runtime, definitions, nil
end

local function validateWireBinaryRuntime(
	programsValue: unknown,
	runtimeValue: unknown,
	boundsValue: unknown
): (
	{ MoverBinaryState.Program }?,
	MoverBinaryState.Runtime?,
	{ MoverPushRules.Definition }?,
	string?
)
	local programs, programsError = validateTrustedBinaryPrograms(programsValue, boundsValue)
	if not programs then
		return nil, nil, nil, programsError
	end
	if #programs == 0 then
		return nil, nil, nil, "trusted-binary-programs-empty-for-v2"
	end
	local runtime, runtimeError = MoverBinaryState.ValidateRuntime(programs, runtimeValue)
	if not runtime then
		return nil, nil, nil, "invalid-wire-binary-runtime:" .. (runtimeError or "invalid")
	end
	local definitions, definitionsError = MoverBinaryState.MaterializeDefinitions(programs, runtime)
	if not definitions then
		return nil, nil, nil, "invalid-wire-binary-definitions:" .. (definitionsError or "invalid")
	end
	return programs, runtime, definitions, nil
end

local function mergeDefinitionDomains(
	legacyDefinitions: { MoverPushRules.Definition },
	binaryDefinitions: { MoverPushRules.Definition }
): ({ MoverPushRules.Definition }?, string?)
	local legacyIds: { [string]: boolean } = {}
	local legacySourceOrders: { [number]: boolean } = {}
	local legacyTeamIds: { [string]: boolean } = {}
	local mergedInput: { MoverPushRules.Definition } = table.create(#legacyDefinitions + #binaryDefinitions)
	for _, definition in legacyDefinitions do
		legacyIds[definition.id] = true
		legacySourceOrders[definition.sourceOrder] = true
		legacyTeamIds[definition.teamId] = true
		table.insert(mergedInput, definition)
	end
	for _, definition in binaryDefinitions do
		if legacyIds[definition.id] then
			return nil, "mover-domain-id-collision:" .. definition.id
		elseif legacySourceOrders[definition.sourceOrder] then
			return nil, "mover-domain-source-order-collision:" .. tostring(definition.sourceOrder)
		elseif legacyTeamIds[definition.teamId] then
			return nil, "mover-domain-team-mixing:" .. definition.teamId
		end
		table.insert(mergedInput, definition)
	end

	local merged, mergeError = MoverPushRules.ValidateAndOrderDefinitions(mergedInput)
	if not merged then
		return nil, "invalid-merged-definitions:" .. (mergeError or "invalid")
	end
	return merged, nil
end

local function validateSnapshotShape(value: unknown): ({ [unknown]: unknown }?, string?)
	if type(value) ~= "table" then
		return nil, "snapshot-not-table"
	end
	local source = value :: { [unknown]: unknown }
	if source.schemaVersion == nil then
		return nil, "invalid-snapshot-shape"
	elseif source.schemaVersion ~= LEGACY_SCHEMA_VERSION and source.schemaVersion ~= BINARY_SCHEMA_VERSION then
		return nil, "unsupported-schema-version"
	end
	local validShape = if source.schemaVersion == LEGACY_SCHEMA_VERSION
		then hasExactKeys(source, SNAPSHOT_V1_KEYS, 5)
		else hasExactKeys(source, SNAPSHOT_V2_KEYS, 6)
	if not validShape then
		return nil, "invalid-snapshot-shape"
	end
	return source, nil
end

local function validatedSnapshot(value: unknown): (ValidatedSnapshot?, string?)
	if type(value) ~= "table" then
		return nil, "validated-snapshot-not-table"
	end
	local snapshot = value :: ValidatedSnapshot
	if snapshot._token ~= VALIDATED_TOKEN or not table.isfrozen(snapshot) then
		return nil, "invalid-validated-snapshot"
	end
	return snapshot, nil
end

local function definitionsAreSourceOrdered(sourceValue: unknown, ordered: { MoverPushRules.Definition }): boolean
	if type(sourceValue) ~= "table" then
		return false
	end
	local source = sourceValue :: { [unknown]: unknown }
	for index, definition in ordered do
		local sourceDefinition = source[index]
		if type(sourceDefinition) ~= "table" then
			return false
		end
		if (sourceDefinition :: any).id ~= definition.id then
			return false
		end
	end
	return true
end

function MoverSnapshotContract.SerializeServerSnapshot(
	clockValue: unknown,
	runtimeDefinitionsValue: unknown,
	boundsValue: unknown,
	trustedDefinitionsValue: unknown,
	trustedBinaryProgramsValue: unknown?,
	authoritativeBinaryRuntimeValue: unknown?
): (WireSnapshot?, string?)
	local clock, clockError = MoverClock.ValidateSnapshot(clockValue)
	if not clock then
		return nil, "invalid-clock:" .. (clockError or "invalid")
	end
	local runtimeDefinitions, definitionsError = validateTrustedDefinitions(runtimeDefinitionsValue, boundsValue)
	if not runtimeDefinitions then
		return nil, definitionsError
	end
	local trustedDefinitions, trustedError = validateTrustedDefinitions(trustedDefinitionsValue, boundsValue)
	if not trustedDefinitions then
		return nil, trustedError
	end
	local clockTime = MoverClock.TimeForStep(clock.step) :: number
	local runtimeMismatch = runtimeDefinitionsMatchTrusted(runtimeDefinitions, trustedDefinitions, clockTime)
	if runtimeMismatch then
		return nil, runtimeMismatch
	end

	local schemaVersion = LEGACY_SCHEMA_VERSION
	local frameDefinitions = runtimeDefinitions
	local binaryRuntime: MoverBinaryState.Runtime? = nil
	if authoritativeBinaryRuntimeValue ~= nil then
		if trustedBinaryProgramsValue == nil then
			return nil, "trusted-binary-programs-required"
		end
		local _, checkedRuntime, binaryDefinitions, binaryError =
			validatePublishableBinaryRuntime(trustedBinaryProgramsValue, authoritativeBinaryRuntimeValue, boundsValue)
		if not checkedRuntime or not binaryDefinitions then
			return nil, binaryError
		end
		local merged, mergeError = mergeDefinitionDomains(runtimeDefinitions, binaryDefinitions)
		if not merged then
			return nil, mergeError
		end
		schemaVersion = BINARY_SCHEMA_VERSION
		frameDefinitions = merged
		binaryRuntime = checkedRuntime
	elseif trustedBinaryProgramsValue ~= nil then
		local programs, programsError = validateTrustedBinaryPrograms(trustedBinaryProgramsValue, boundsValue)
		if not programs then
			return nil, programsError
		end
		if #programs > 0 then
			return nil, "authoritative-binary-runtime-required"
		end
	end

	local frame, frameError = MoverCollisionFrame.Build(frameDefinitions, clock)
	if not frame then
		return nil, "invalid-frame:" .. (frameError or "invalid")
	end

	local snapshot: WireSnapshot = {
		schemaVersion = schemaVersion,
		clockRevision = clock.revision,
		clockStep = clock.step,
		clockTimeMilliseconds = frame.timeMilliseconds,
		-- V2 deliberately carries only the legacy runtime domain. Binary geometry
		-- is reconstructed from trusted Programs plus the narrow runtime below.
		definitions = copyDefinitions(runtimeDefinitions),
		binaryRuntime = if binaryRuntime then copyBinaryRuntime(binaryRuntime) else nil,
	}
	table.freeze(snapshot)
	return snapshot, nil
end

function MoverSnapshotContract.ValidateServerSnapshot(
	snapshotValue: unknown,
	trustedDefinitionsValue: unknown,
	boundsValue: unknown,
	trustedBinaryProgramsValue: unknown?
): (ValidatedSnapshot?, string?)
	local source, sourceError = validateSnapshotShape(snapshotValue)
	if not source then
		return nil, sourceError
	end

	local clock, clockError = MoverClock.ValidateSnapshot({
		revision = source.clockRevision,
		step = source.clockStep,
	})
	if not clock then
		return nil, "invalid-clock:" .. (clockError or "invalid")
	end
	local expectedTime = MoverClock.TimeForStep(clock.step) :: number
	if
		not isBoundedInteger(source.clockTimeMilliseconds, 0, MapMoverContract.MaximumClockTimeMilliseconds)
		or source.clockTimeMilliseconds ~= expectedTime
	then
		return nil, "clock-time-step-mismatch"
	end

	local trustedDefinitions, trustedError = validateTrustedDefinitions(trustedDefinitionsValue, boundsValue)
	if not trustedDefinitions then
		return nil, trustedError
	end
	local snapshotDefinitions, snapshotDefinitionsError =
		MapMoverContract.ValidateAndOrder(source.definitions, boundsValue)
	if not snapshotDefinitions then
		return nil, "invalid-snapshot-definitions:" .. (snapshotDefinitionsError or "invalid")
	end
	if not definitionsAreSourceOrdered(source.definitions, snapshotDefinitions) then
		return nil, "snapshot-definitions-not-source-ordered"
	end

	local runtimeMismatch = runtimeDefinitionsMatchTrusted(snapshotDefinitions, trustedDefinitions, expectedTime)
	if runtimeMismatch then
		return nil, runtimeMismatch
	end

	local frameDefinitions = snapshotDefinitions
	local binaryRuntime: MoverBinaryState.Runtime? = nil
	if source.schemaVersion == LEGACY_SCHEMA_VERSION then
		if trustedBinaryProgramsValue ~= nil then
			local programs, programsError = validateTrustedBinaryPrograms(trustedBinaryProgramsValue, boundsValue)
			if not programs then
				return nil, programsError
			end
			if #programs > 0 then
				return nil, "v1-snapshot-rejected-for-binary-programs"
			end
		end
	else
		if trustedBinaryProgramsValue == nil then
			return nil, "trusted-binary-programs-required"
		end
		local _, checkedRuntime, binaryDefinitions, binaryError =
			validateWireBinaryRuntime(trustedBinaryProgramsValue, source.binaryRuntime, boundsValue)
		if not checkedRuntime or not binaryDefinitions then
			return nil, binaryError
		end
		local merged, mergeError = mergeDefinitionDomains(snapshotDefinitions, binaryDefinitions)
		if not merged then
			return nil, mergeError
		end
		frameDefinitions = merged
		binaryRuntime = checkedRuntime
	end

	local frame, frameError = MoverCollisionFrame.Build(frameDefinitions, clock)
	if not frame then
		return nil, "invalid-frame:" .. (frameError or "invalid")
	end
	if frame.timeMilliseconds ~= source.clockTimeMilliseconds then
		return nil, "frame-time-step-mismatch"
	end

	local validated: ValidatedSnapshot = {
		schemaVersion = source.schemaVersion :: number,
		clock = clock,
		timeMilliseconds = frame.timeMilliseconds,
		definitions = frame.definitions,
		binaryRuntime = binaryRuntime,
		frame = frame,
		_token = VALIDATED_TOKEN,
	}
	table.freeze(validated)
	return validated, nil
end

function MoverSnapshotContract.CarrierPresentationForClock(
	snapshotValue: unknown,
	targetClockValue: unknown,
	groundMoverIdValue: unknown,
	simulationPositionValue: unknown
): (CarrierPresentation?, string?)
	local snapshot, snapshotError = validatedSnapshot(snapshotValue)
	if not snapshot then
		return nil, snapshotError
	end
	local targetClock, targetClockError = MoverClock.ValidateSnapshot(targetClockValue)
	if not targetClock then
		return nil, "invalid-target-clock:" .. (targetClockError or "invalid")
	end
	if targetClock.revision ~= snapshot.clock.revision then
		return nil, "target-clock-revision-mismatch"
	end

	local presentationPosition, adjustmentError = MoverCollisionFrame.AdjustGroundPosition(
		snapshot.frame,
		groundMoverIdValue,
		targetClock.step,
		simulationPositionValue
	)
	if not presentationPosition then
		return nil, adjustmentError
	end
	local simulationPosition = simulationPositionValue :: Vector3
	local moverId = groundMoverIdValue :: string?
	local carrier: CarrierPresentation = {
		kind = "TranslationOnly",
		moverId = moverId,
		clockRevision = snapshot.clock.revision,
		fromStep = snapshot.clock.step,
		toStep = targetClock.step,
		simulationPosition = simulationPosition,
		presentationPosition = presentationPosition,
		translation = presentationPosition - simulationPosition,
	}
	-- Keep the returned record's shape intentionally narrow. In particular it
	-- cannot write velocity, ground identity, or an authoritative side push.
	assert(hasExactKeys(carrier :: any, CARRIER_KEYS, if moverId == nil then 7 else 8))
	table.freeze(carrier)
	return carrier, nil
end

MoverSnapshotContract.SchemaVersion = BINARY_SCHEMA_VERSION
MoverSnapshotContract.LegacySchemaVersion = LEGACY_SCHEMA_VERSION
MoverSnapshotContract.MaximumDefinitions = MapMoverContract.MaximumMovers

return table.freeze(MoverSnapshotContract)
