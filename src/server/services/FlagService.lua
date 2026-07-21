--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-authoritative Roblox adaptation of Capture the Flag behavior from:
  code/game/g_team.c (flag pickup, recovery, capture, and reset)
  code/game/g_items.c (LaunchItem 30-second dropped-flag think)
  code/game/g_main.c (integer level.time entity-think deadline checks)
  code/game/g_team.h (unused 40-second CTF_FLAG_RETURN_TIME declaration)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local FlagDefinitions = require(sharedRoot:WaitForChild("ctf"):WaitForChild("FlagDefinitions"))
local MatchFrameRules = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchFrameRules"))
local MatchRulesCore = require(sharedRoot:WaitForChild("match"):WaitForChild("MatchRulesCore"))
local CtfBonusRules = require(sharedRoot:WaitForChild("match"):WaitForChild("CtfBonusRules"))
local DroppedWeaponRules = require(sharedRoot:WaitForChild("items"):WaitForChild("DroppedWeaponRules"))
local MoverItemFlagParticipantRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("MoverItemFlagParticipantRules"))
local WorldPointContents = require(sharedRoot:WaitForChild("simulation"):WaitForChild("WorldPointContents"))
local AuthoritativeFrameService = require(script.Parent.AuthoritativeFrameService)
local EntitySlotService = require(script.Parent.EntitySlotService)
local DroppedFlagService = require(script.Parent.DroppedFlagService)
local MoverParticipantReleaseBrokerService = require(script.Parent.MoverParticipantReleaseBrokerService)

local FlagService = {}

type TeamId = FlagDefinitions.TeamId
type FlagState = FlagDefinitions.FlagState
type EventKind = FlagDefinitions.EventKind
type Snapshot = FlagDefinitions.Snapshot

type ItemState = {
	alive: boolean,
	position: Vector3,
	look: Vector3,
	lifeSequence: number,
}

type ObjectiveResult = {
	accepted: boolean,
	matchEnded: boolean,
	teamScore: number,
}

export type MatchServiceDependency = {
	GetModeId: () -> string,
	GetState: () -> string,
	GetPlayerTeam: (player: Player) -> TeamId?,
	CanPlayerFight: (player: Player) -> boolean,
	ReportTeamObjective: (teamId: TeamId, points: number, reason: string?, actor: Player?) -> ObjectiveResult,
	AwardObjectiveBonus: (player: Player, points: number, reason: string) -> boolean,
	OnStateChanged: (callback: (snapshot: unknown) -> ()) -> RBXScriptConnection,
	OnModeChanged: (callback: (modeId: unknown, rules: unknown) -> ()) -> RBXScriptConnection,
	OnEliminationRecorded: (
		callback: (victim: Player, attacker: Player?, means: string, result: unknown) -> ()
	) -> RBXScriptConnection,
}

export type CombatServiceDependency = {
	GetItemState: (player: Player) -> ItemState?,
	HasWorldVisibility: (origin: Vector3, targetPosition: Vector3) -> boolean,
	OnPlayerDamaged: (
		callback: (victim: Player, attacker: Player, damage: number, levelTimeMilliseconds: number) -> ()
	) -> RBXScriptConnection,
}

export type Services = {
	MatchService: MatchServiceDependency,
	CombatService: CombatServiceDependency,
	GetPointContents: (position: Vector3) -> number,
}

export type RuntimeMapData = {
	capabilities: { [string]: boolean },
	flagBases: { [string]: BasePart },
}

export type PreparedPersonalTeleporterDrop = {}
export type PreparedPersonalTeleporterDropSummary = {
	read player: Player,
	read teamId: TeamId?,
	read baseRevision: number?,
	read position: Vector3?,
}
export type PersonalTeleporterDropReceipt = {
	read player: Player,
	read droppedTeamId: TeamId?,
}

type FlagRecord = {
	teamId: TeamId,
	marker: BasePart,
	basePosition: Vector3,
	state: FlagState,
	carrier: Player?,
	lastPosition: Vector3,
	droppedPosition: Vector3?,
	returnAtMilliseconds: number?,
	revision: number,
	mapRegistration: EntitySlotService.MapRegistration,
}

type FlagMoverRecord = {
	teamId: TeamId,
	registration: EntitySlotService.Registration,
	participant: MoverItemFlagParticipantRules.Participant,
}

type FlagMoverAuthority = {
	revision: number,
	recordsByTeamId: { [string]: FlagMoverRecord },
	order: { FlagMoverRecord },
}

export type PreparedMoverParticipantUpdate = {}
export type MoverParticipantUpdateReceipt = {}
export type MoverParticipantUpdateAdapter = {
	read Collect: () -> MoverItemFlagParticipantRules.Collection,
	read ResolveSine: (bodyId: string) -> MoverItemFlagParticipantRules.SynchronousCrushEffect,
	read ResolveBlockedDoor: (bodyId: string) -> MoverItemFlagParticipantRules.Transition,
	read Prepare: (finalBodies: unknown) -> (PreparedMoverParticipantUpdate?, string?),
	read CanApply: (prepared: unknown) -> (boolean, string?),
	read Apply: (prepared: unknown) -> MoverParticipantUpdateReceipt,
	read Flush: (receipt: unknown) -> boolean,
	read Abort: (prepared: unknown) -> boolean,
}

type PreparedCapability = {
	status: "Prepared" | "Applied" | "Flushed" | "Aborted",
	preflightPassCount: number,
	baseAuthority: FlagMoverAuthority,
	nextAuthority: FlagMoverAuthority,
	changedRecords: { FlagMoverRecord },
	returnedTeamIds: { [string]: boolean },
	prepared: PreparedMoverParticipantUpdate,
	receipt: MoverParticipantUpdateReceipt,
}

type Candidate = {
	player: Player,
	teamId: TeamId,
	position: Vector3,
}

type EliminationIntent = {
	means: string,
	attacker: Player?,
}
type PendingSynchronousMoverDrop = {
	record: FlagRecord,
	position: Vector3,
	levelTimeMilliseconds: number,
	removedByMover: boolean,
}

type PlayerBonusState = {
	lastReturnedFlagMilliseconds: number?,
	lastFraggedCarrierMilliseconds: number?,
	lastHurtCarrierMilliseconds: number?,
	assists: number,
	defends: number,
	captures: number,
	rewardKind: string?,
	rewardUntilMilliseconds: number?,
}

local started = false
local dependencies: Services?
local snapshotRemote: RemoteEvent?
local eventRemote: RemoteEvent?
local flags: { [string]: FlagRecord } = {}
local EMPTY_FLAG_MOVER_RECORDS: { [string]: FlagMoverRecord } = table.freeze({})
local EMPTY_FLAG_MOVER_ORDER: { FlagMoverRecord } = table.freeze({})
local flagMoverAuthority: FlagMoverAuthority = table.freeze({
	revision = 0,
	recordsByTeamId = EMPTY_FLAG_MOVER_RECORDS,
	order = EMPTY_FLAG_MOVER_ORDER,
})
local activePreparedMoverParticipantUpdate: PreparedMoverParticipantUpdate? = nil
local preparedMoverCapabilities: { [PreparedMoverParticipantUpdate]: PreparedCapability } = setmetatable(
	{},
	{ __mode = "k" }
) :: any
local moverReceiptCapabilities: { [MoverParticipantUpdateReceipt]: PreparedCapability } = setmetatable(
	{},
	{ __mode = "k" }
) :: any

local basesAvailable = false
local objectiveActive = false
local studioFixtureObjectiveOverride = false
local currentModeId = "Unknown"
local currentMatchState = "Unknown"
local snapshotSequence = 0
local eventSequence = 0
local session = 0
local lastProcessedFrameLevelTimeMilliseconds = -1
local lastFrameLevelTimeMilliseconds = 0
local lastFrameServerTimeSeconds = 0
local activeAuthoritativeFrame: AuthoritativeFrameService.Frame? = nil
local activeAuthoritativeFrameSummary: AuthoritativeFrameService.Summary? = nil
local pendingFramePublicationCallbacks: { () -> () } = {}
local pendingFramePublicationOwner: AuthoritativeFrameService.Frame? = nil
local publicationQuarantined = false
local nextScanAtMilliseconds: number? = nil
local nextSnapshotAtMilliseconds: number? = nil
local pendingFlowReason: string? = "Start"
local pendingInitialBroadcast = true
local pendingSnapshotTargets: { [Player]: boolean } = {}
local pendingEliminations: { [Player]: EliminationIntent } = {}
local pendingSynchronousMoverDrops: { [Player]: PendingSynchronousMoverDrop } = {}
local pendingStudioFixtureCarriers: { [Player]: FlagRecord } = {}
local pendingDepartures: { [Player]: boolean } = {}
local bonusStateByPlayer: { [Player]: PlayerBonusState } = {}
local preparedPersonalTeleporterDrops: { [PreparedPersonalTeleporterDrop]: any } = setmetatable({}, { __mode = "k" })

local function activeLevelTimeMilliseconds(): number
	return assert(activeAuthoritativeFrameSummary, "Flag authority requires an open authoritative frame").currentTimeMilliseconds
end

local function publishOutward(callback: () -> ())
	assert(not publicationQuarantined, "Flag outward publication is permanently quarantined")
	if activeAuthoritativeFrame ~= nil then
		table.insert(pendingFramePublicationCallbacks, callback)
	else
		callback()
	end
end

local function bonusState(player: Player): PlayerBonusState
	local existing = bonusStateByPlayer[player]
	if existing then
		return existing
	end
	local created: PlayerBonusState = {
		lastReturnedFlagMilliseconds = nil,
		lastFraggedCarrierMilliseconds = nil,
		lastHurtCarrierMilliseconds = nil,
		assists = 0,
		defends = 0,
		captures = 0,
		rewardKind = nil,
		rewardUntilMilliseconds = nil,
	}
	bonusStateByPlayer[player] = created
	return created
end

local function currentPresentationBasis(): (number, number)
	local summary = activeAuthoritativeFrameSummary
	if summary then
		return summary.currentTimeMilliseconds, summary.currentServerTimeSeconds
	end
	return lastFrameLevelTimeMilliseconds, lastFrameServerTimeSeconds
end

local function presentationTimeForLevel(levelTimeMilliseconds: number): number
	local basisLevelTime, basisServerTime = currentPresentationBasis()
	return assert(
		MatchFrameRules.PresentationTimeForLevel(basisLevelTime, basisServerTime, levelTimeMilliseconds),
		"Flag level time could not map to presentation time"
	)
end

local function durationMilliseconds(seconds: number): number
	return assert(
		MatchFrameRules.DurationMilliseconds(seconds),
		"Flag duration must resolve to exact bounded integer milliseconds"
	)
end

local function deadlineMilliseconds(startMilliseconds: number, durationSeconds: number): number
	return assert(
		MatchFrameRules.DeadlineMilliseconds(startMilliseconds, durationSeconds),
		"Flag deadline exceeded the authoritative integer clock"
	)
end

local function requireDependencies(): Services
	return assert(dependencies, "FlagService dependencies are unavailable before Start")
end

local function awardBonus(player: Player, points: number, reason: string): boolean
	return requireDependencies().MatchService.AwardObjectiveBonus(player, points, reason)
end

local function setReward(player: Player, kind: string)
	local state = bonusState(player)
	state.rewardKind = kind
	state.rewardUntilMilliseconds = activeLevelTimeMilliseconds() + CtfBonusRules.RewardSpriteMilliseconds
	local rewardEndsAt = presentationTimeForLevel(state.rewardUntilMilliseconds)
	publishOutward(function()
		player:SetAttribute("ArenaCtfRewardKind", kind)
		player:SetAttribute("ArenaCtfRewardEndsAt", rewardEndsAt)
	end)
end

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing:IsA("Folder"), string.format("%s must be a Folder", name))
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function ensureRemote(parent: Instance, name: string): RemoteEvent
	local existing = parent:FindFirstChild(name)
	if existing then
		assert(existing:IsA("RemoteEvent"), string.format("%s must be a RemoteEvent", name))
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = parent
	return remote
end

local function markerTeam(marker: BasePart): TeamId?
	local attribute = marker:GetAttribute(FlagDefinitions.MarkerTeamAttribute)
	if attribute ~= nil then
		return if FlagDefinitions.IsTeamId(attribute) then attribute :: TeamId else nil
	end

	for _, teamId in FlagDefinitions.TeamOrder do
		if marker.Name == FlagDefinitions.MarkerNames[teamId] then
			return teamId
		end
	end
	return nil
end

local function discoverMarkers(worldFolder: Folder): { [string]: BasePart }
	local markers: { [string]: BasePart } = {}
	local counts: { [string]: number } = {}
	for _, descendant in worldFolder:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		local teamId = markerTeam(descendant)
		if not teamId then
			continue
		end
		local count = (counts[teamId] or 0) + 1
		counts[teamId] = count
		if count == 1 then
			markers[teamId] = descendant
		else
			markers[teamId] = nil
		end
	end
	return markers
end

local function validateCompleteMarkers(worldFolder: Folder, candidates: any): { [string]: BasePart }?
	if type(candidates) ~= "table" then
		return nil
	end

	local markers: { [string]: BasePart } = {}
	for _, teamId in FlagDefinitions.TeamOrder do
		local marker = candidates[teamId]
		if typeof(marker) ~= "Instance" or not marker:IsA("BasePart") or not marker:IsDescendantOf(worldFolder) then
			return nil
		end
		markers[teamId] = marker
	end
	if markers[FlagDefinitions.TeamIds.Red] == markers[FlagDefinitions.TeamIds.Blue] then
		return nil
	end
	return markers
end

local function resolveMarkers(worldFolder: Folder, runtimeMapData: RuntimeMapData?): { [string]: BasePart }?
	if runtimeMapData == nil then
		return validateCompleteMarkers(worldFolder, discoverMarkers(worldFolder))
	end
	if
		type(runtimeMapData) ~= "table"
		or type(runtimeMapData.capabilities) ~= "table"
		or runtimeMapData.capabilities.FlagBases ~= true
	then
		return nil
	end
	return validateCompleteMarkers(worldFolder, runtimeMapData.flagBases)
end

local function getFlagPosition(record: FlagRecord): Vector3
	if record.state == FlagDefinitions.States.AtBase then
		return record.basePosition
	end
	if record.state == FlagDefinitions.States.Dropped then
		return record.droppedPosition or record.lastPosition
	end
	return record.lastPosition
end

local function preparedMoverParticipantUpdateBlocksAuthority(): boolean
	local prepared = activePreparedMoverParticipantUpdate
	if not prepared then
		return false
	end
	for _, capability in moverReceiptCapabilities do
		if capability.prepared == prepared then
			return capability.status ~= "Applied"
		end
	end
	return true
end

local function replaceFlagMoverRecord(record: FlagRecord, participant: MoverItemFlagParticipantRules.Participant)
	assert(not preparedMoverParticipantUpdateBlocksAuthority(), "flag changed during mover prepare")
	local baseAuthority = flagMoverAuthority
	local nextRecord: FlagMoverRecord = table.freeze({
		teamId = record.teamId,
		registration = record.mapRegistration.registration,
		participant = participant,
	})
	local nextRecordsByTeamId = table.clone(baseAuthority.recordsByTeamId)
	nextRecordsByTeamId[record.teamId] = nextRecord
	table.freeze(nextRecordsByTeamId)
	local nextOrder: { FlagMoverRecord } = {}
	for _, current in baseAuthority.order do
		if current.teamId ~= record.teamId then
			table.insert(nextOrder, current)
		end
	end
	table.insert(nextOrder, nextRecord)
	table.sort(nextOrder, function(left, right)
		return left.registration.sourceOrder < right.registration.sourceOrder
	end)
	table.freeze(nextOrder)
	flagMoverAuthority = table.freeze({
		revision = baseAuthority.revision + 1,
		recordsByTeamId = nextRecordsByTeamId,
		order = nextOrder,
	})
end

local function setBaseParticipantActive(record: FlagRecord, active: boolean)
	local moverRecord = flagMoverAuthority.recordsByTeamId[record.teamId]
	if not moverRecord then
		return
	end
	local currentlyActive = moverRecord.participant.lifecycle == "ActiveLinked"
	if currentlyActive == active then
		return
	end
	local transition: MoverItemFlagParticipantRules.Transition? = nil
	local transitionError: string? = nil
	if active then
		transition, transitionError = MoverItemFlagParticipantRules.Respawn(moverRecord.participant)
	else
		transition, transitionError =
			MoverItemFlagParticipantRules.ResolveTouch(moverRecord.participant, "BaseFlagTaken")
	end
	assert(transition, transitionError or "base flag mover lifecycle transition failed")
	replaceFlagMoverRecord(record, transition.participant)
end

local function buildSnapshot(): Snapshot
	local _, serverTime = currentPresentationBasis()
	local snapshotFlags: { [string]: FlagDefinitions.FlagSnapshotEntry } = {}
	for _, teamId in FlagDefinitions.TeamOrder do
		local record = flags[teamId]
		if not record then
			continue
		end
		snapshotFlags[teamId] = {
			teamId = teamId,
			state = record.state,
			revision = record.revision,
			carrierUserId = if record.carrier then record.carrier.UserId else nil,
			position = getFlagPosition(record),
			basePosition = record.basePosition,
			returnAt = if record.returnAtMilliseconds ~= nil
				then presentationTimeForLevel(record.returnAtMilliseconds)
				else nil,
		}
	end

	return {
		protocolVersion = FlagDefinitions.ProtocolVersion,
		sequence = snapshotSequence,
		session = session,
		active = objectiveActive,
		modeId = currentModeId,
		matchState = currentMatchState,
		serverTime = serverTime,
		flags = snapshotFlags,
	}
end

local function publishSnapshot(target: Player?): Snapshot
	local nowMilliseconds = activeLevelTimeMilliseconds()
	snapshotSequence += 1
	nextSnapshotAtMilliseconds = deadlineMilliseconds(nowMilliseconds, FlagDefinitions.SnapshotIntervalSeconds)
	local snapshot = buildSnapshot()
	local remote = assert(snapshotRemote, "Flag snapshot remote is not initialized")
	publishOutward(function()
		if target then
			remote:FireClient(target, snapshot)
		else
			remote:FireAllClients(snapshot)
		end
	end)
	return snapshot
end

local function publishEvent(
	kind: EventKind,
	flagTeamId: TeamId?,
	scoringTeamId: TeamId?,
	actor: Player?,
	position: Vector3?,
	reason: string?,
	teamScore: number?,
	matchEnded: boolean?
)
	local snapshot = publishSnapshot()
	pendingInitialBroadcast = false
	eventSequence += 1
	local payload: FlagDefinitions.Event = {
		protocolVersion = FlagDefinitions.ProtocolVersion,
		sequence = eventSequence,
		eventId = string.format("ctf:%d:%d", session, eventSequence),
		kind = kind,
		flagTeamId = flagTeamId,
		scoringTeamId = scoringTeamId,
		actorUserId = if actor then actor.UserId else nil,
		position = position,
		reason = reason,
		teamScore = teamScore,
		matchEnded = matchEnded,
		serverTime = snapshot.serverTime,
	}
	local remote = assert(eventRemote, "Flag event remote is not initialized")
	publishOutward(function()
		remote:FireAllClients(payload)
	end)
end

local function setAtBase(record: FlagRecord): boolean
	local changed = record.state ~= FlagDefinitions.States.AtBase
		or record.carrier ~= nil
		or record.droppedPosition ~= nil
		or record.returnAtMilliseconds ~= nil
	record.state = FlagDefinitions.States.AtBase
	record.carrier = nil
	record.lastPosition = record.basePosition
	record.droppedPosition = nil
	record.returnAtMilliseconds = nil
	setBaseParticipantActive(record, true)
	if changed then
		record.revision += 1
	end
	return changed
end

local function forceResetFlags()
	for _, teamId in FlagDefinitions.TeamOrder do
		local record = flags[teamId]
		if not record then
			continue
		end
		if not setAtBase(record) then
			record.revision += 1
		end
	end
end

local function readFlow(): boolean
	local match = requireDependencies().MatchService
	local modeOk, modeId = pcall(match.GetModeId)
	local stateOk, matchState = pcall(match.GetState)
	currentModeId = if modeOk and type(modeId) == "string" then modeId else "Unknown"
	currentMatchState = if stateOk and type(matchState) == "string" then matchState else "Unknown"
	return basesAvailable and FlagDefinitions.IsActiveFlow(currentModeId, currentMatchState)
end

local function reconcileFlow(reason: string)
	local nextActive = studioFixtureObjectiveOverride or readFlow()
	if nextActive == objectiveActive then
		return
	end
	objectiveActive = nextActive
	session += 1
	bonusStateByPlayer = {}
	for _, player in Players:GetPlayers() do
		publishOutward(function()
			player:SetAttribute("ArenaCtfAssists", 0)
			player:SetAttribute("ArenaCtfDefends", 0)
			player:SetAttribute("ArenaCtfCaptures", 0)
			player:SetAttribute("ArenaCtfRewardKind", nil)
			player:SetAttribute("ArenaCtfRewardEndsAt", nil)
		end)
	end
	forceResetFlags()
	publishEvent(FlagDefinitions.Events.Reset, nil, nil, nil, nil, if nextActive then reason else "FlowEnded", nil, nil)
end

local function queueFlowReconcile(reason: string)
	if pendingFlowReason == nil then
		pendingFlowReason = reason
	end
end

local function safePlayerTeam(player: Player): TeamId?
	local ok, value = pcall(requireDependencies().MatchService.GetPlayerTeam, player)
	if ok and FlagDefinitions.IsTeamId(value) then
		return value :: TeamId
	end
	return nil
end

local function safeCanFight(player: Player): boolean
	local ok, value = pcall(requireDependencies().MatchService.CanPlayerFight, player)
	return ok and value == true
end

local function safeItemState(player: Player): ItemState?
	local ok, value = pcall(requireDependencies().CombatService.GetItemState, player)
	if not ok or type(value) ~= "table" then
		return nil
	end
	local itemState = value :: any
	if
		type(itemState.alive) ~= "boolean"
		or not FlagDefinitions.IsFiniteVector3(itemState.position)
		or not FlagDefinitions.IsFiniteVector3(itemState.look)
		or type(itemState.lifeSequence) ~= "number"
		or itemState.lifeSequence % 1 ~= 0
		or itemState.lifeSequence < 1
	then
		return nil
	end
	return {
		alive = itemState.alive,
		position = itemState.position,
		look = itemState.look,
		lifeSequence = itemState.lifeSequence,
	}
end

local function visibleFrom(origin: Vector3, target: Vector3): boolean
	local ok, visible = pcall(requireDependencies().CombatService.HasWorldVisibility, origin, target)
	return ok and visible == true
end

local function collectCandidates(): ({ Candidate }, { [Player]: Candidate })
	local candidates: { Candidate } = {}
	local byPlayer: { [Player]: Candidate } = {}
	for _, player in Players:GetPlayers() do
		local teamId = safePlayerTeam(player)
		local itemState = safeItemState(player)
		local canFight = safeCanFight(player)
		if not teamId or not itemState or not itemState.alive or not canFight then
			continue
		end
		local candidate: Candidate = {
			player = player,
			teamId = teamId,
			position = itemState.position,
		}
		table.insert(candidates, candidate)
		byPlayer[player] = candidate
	end
	table.sort(candidates, function(left: Candidate, right: Candidate): boolean
		return MatchRulesCore.UserIdPrecedes(left.player.UserId, right.player.UserId)
	end)
	return candidates, byPlayer
end

local function isWithinBase(position: Vector3, record: FlagRecord): boolean
	local relative = record.marker.CFrame:PointToObjectSpace(position)
	local padding = FlagDefinitions.BaseTouchPadding
	local halfSize = record.marker.Size * 0.5
	return math.abs(relative.X) <= halfSize.X + padding
		and math.abs(relative.Y) <= halfSize.Y + padding
		and math.abs(relative.Z) <= halfSize.Z + padding
end

local function isTouchingFlag(position: Vector3, record: FlagRecord): boolean
	if record.state == FlagDefinitions.States.AtBase then
		return isWithinBase(position, record)
	end
	if record.state == FlagDefinitions.States.Dropped then
		return FlagDefinitions.IsWithinRadius(
			position,
			record.droppedPosition or record.lastPosition,
			FlagDefinitions.FlagTouchRadius
		)
	end
	return false
end

local function returnFlag(record: FlagRecord, reason: string, actor: Player?)
	if record.state == FlagDefinitions.States.Dropped then
		DroppedFlagService.MarkReturn(record.teamId, reason)
	end
	if not setAtBase(record) then
		return
	end
	publishEvent(FlagDefinitions.Events.Returned, record.teamId, nil, actor, record.basePosition, reason, nil, nil)
end

local function dropFlag(record: FlagRecord, position: Vector3, reason: string, actor: Player?)
	if record.state ~= FlagDefinitions.States.Carried then
		return
	end
	local safePosition = if FlagDefinitions.IsFiniteVector3(position) then position else record.lastPosition
	local itemState = if actor then safeItemState(actor) else nil
	local look = if itemState then itemState.look else Vector3.zAxis
	local lifeSequence = if itemState then itemState.lifeSequence else record.revision + 1
	local seed =
		DroppedWeaponRules.MakeSeed(string.format("flag:%d", session), if actor then actor.UserId else 0, lifeSequence)
	local velocity = DroppedWeaponRules.LaunchVelocity(look, seed)
	local openFrame = AuthoritativeFrameService.GetOpenFrame()
	local openSummary = if openFrame then AuthoritativeFrameService.InspectFrame(openFrame) else nil
	if not openSummary then
		return nil, "synchronous-mover-flag-frame-unavailable"
	end
	local levelTimeMilliseconds = openSummary.currentTimeMilliseconds
	local spawned, spawnError = DroppedFlagService.Spawn(
		record.teamId,
		safePosition,
		velocity,
		levelTimeMilliseconds,
		math.max(eventSequence + 1, 1),
		string.format("flag_%s_%d_%d", string.lower(record.teamId), session, record.revision + 1)
	)
	assert(spawned, spawnError or "dropped flag entity insertion failed")
	record.state = FlagDefinitions.States.Dropped
	record.carrier = nil
	record.lastPosition = safePosition
	record.droppedPosition = safePosition
	record.returnAtMilliseconds = deadlineMilliseconds(levelTimeMilliseconds, FlagDefinitions.DroppedReturnSeconds)
	record.revision += 1
	publishEvent(FlagDefinitions.Events.Dropped, record.teamId, nil, actor, safePosition, reason, nil, nil)
end

function FlagService.StageSynchronousMoverCarrierDrop(
	player: Player,
	position: Vector3,
	operationOrder: number
): ({ MoverItemFlagParticipantRules.Body }?, string?)
	local empty: { MoverItemFlagParticipantRules.Body } = table.freeze({})
	if RunService:IsStudio() then
		player:SetAttribute("ArenaStudioMoverFlagStage", "Entered")
	end
	local queuedStudioRecord = pendingStudioFixtureCarriers[player]
	if queuedStudioRecord then
		pendingStudioFixtureCarriers[player] = nil
		if flags[queuedStudioRecord.teamId] == nil then
			flags[queuedStudioRecord.teamId] = queuedStudioRecord
		end
		studioFixtureObjectiveOverride = true
		objectiveActive = true
		queuedStudioRecord.state = FlagDefinitions.States.Carried
		queuedStudioRecord.carrier = player
		queuedStudioRecord.lastPosition = position
		queuedStudioRecord.droppedPosition = nil
		queuedStudioRecord.returnAtMilliseconds = nil
		queuedStudioRecord.revision += 1
		player:SetAttribute("ArenaStudioMoverFlagStage", "CarrierInjected")
	end
	if (not objectiveActive and not studioFixtureObjectiveOverride) or pendingSynchronousMoverDrops[player] then
		return empty, nil
	end
	local carried: FlagRecord? = nil
	for _, teamId in FlagDefinitions.TeamOrder do
		local record = flags[teamId]
		if record and record.state == FlagDefinitions.States.Carried and record.carrier == player then
			carried = record
			break
		end
	end
	if not carried then
		if RunService:IsStudio() then
			player:SetAttribute("ArenaStudioMoverFlagStage", "NoCarrier")
		end
		return empty, nil
	end
	if RunService:IsStudio() then
		player:SetAttribute("ArenaStudioMoverFlagStage", "CarrierResolved")
	end
	local contentsOk, contents = pcall(requireDependencies().GetPointContents, position)
	if not contentsOk or type(contents) ~= "number" or WorldPointContents.IsNoDrop(contents) then
		return empty, nil
	end
	if RunService:IsStudio() then
		player:SetAttribute("ArenaStudioMoverFlagStage", "ContentsResolved")
	end
	local itemState = safeItemState(player)
	local look = if itemState then itemState.look else Vector3.zAxis
	local lifeSequence = if itemState then itemState.lifeSequence else carried.revision + 1
	local seed = DroppedWeaponRules.MakeSeed(string.format("flag:%d", session), player.UserId, lifeSequence)
	local velocity = DroppedWeaponRules.LaunchVelocity(look, seed)
	local brokerToken = MoverParticipantReleaseBrokerService.GetActiveToken()
	local levelTimeMilliseconds = if brokerToken
		then MoverParticipantReleaseBrokerService.GetStepTime(brokerToken)
		else nil
	if levelTimeMilliseconds == nil then
		return nil, "synchronous-mover-flag-clock-unavailable"
	end
	if RunService:IsStudio() then
		player:SetAttribute("ArenaStudioMoverFlagStage", "Launching")
	end
	local body, stageError = DroppedFlagService.StageSynchronousMoverInsertion(
		carried.teamId,
		position,
		velocity,
		levelTimeMilliseconds,
		operationOrder,
		string.format("flag_%s_%d_%d", string.lower(carried.teamId), session, carried.revision + 1)
	)
	if not body then
		if RunService:IsStudio() then
			player:SetAttribute("ArenaStudioMoverFlagStage", stageError or "StageFailed")
		end
		return nil, stageError
	end
	if RunService:IsStudio() then
		player:SetAttribute("ArenaStudioMoverFlagStage", "Staged")
	end
	pendingSynchronousMoverDrops[player] = {
		record = carried,
		position = position,
		levelTimeMilliseconds = levelTimeMilliseconds,
		removedByMover = false,
	}
	return table.freeze({ body }), nil
end

function FlagService.PreparePersonalTeleporterDrop(player: Player): (
	PreparedPersonalTeleporterDrop?,
	PreparedPersonalTeleporterDropSummary?,
	string?
)
	if
		not started
		or not activeAuthoritativeFrame
		or not activeAuthoritativeFrameSummary
		or player.Parent ~= Players
	then
		return nil, nil, "personal-teleporter-flag-prepare-unavailable"
	end
	local carried: FlagRecord? = nil
	for _, teamId in FlagDefinitions.TeamOrder do
		local record = flags[teamId]
		if record and record.state == FlagDefinitions.States.Carried and record.carrier == player then
			carried = record
			break
		end
	end
	local itemState = if carried then safeItemState(player) else nil
	if carried and not itemState then
		return nil, nil, "personal-teleporter-carrier-position-unavailable"
	end
	local summary: PreparedPersonalTeleporterDropSummary = table.freeze({
		player = player,
		teamId = if carried then carried.teamId else nil,
		baseRevision = if carried then carried.revision else nil,
		position = if itemState then itemState.position else nil,
	})
	local prepared: PreparedPersonalTeleporterDrop = table.freeze({})
	preparedPersonalTeleporterDrops[prepared] = {
		status = "Prepared",
		frame = activeAuthoritativeFrame,
		frameSummary = activeAuthoritativeFrameSummary,
		record = carried,
		summary = summary,
	}
	return prepared, summary, nil
end

function FlagService.InspectPreparedPersonalTeleporterDrop(value: unknown): PreparedPersonalTeleporterDropSummary?
	local capability = if type(value) == "table"
		then preparedPersonalTeleporterDrops[value :: PreparedPersonalTeleporterDrop]
		else nil
	return if capability and capability.status == "Prepared" then capability.summary else nil
end

function FlagService.CanApplyPreparedPersonalTeleporterDrop(value: unknown): (boolean, string?)
	local capability = if type(value) == "table"
		then preparedPersonalTeleporterDrops[value :: PreparedPersonalTeleporterDrop]
		else nil
	if not capability or capability.status ~= "Prepared" then
		return false, "invalid-personal-teleporter-flag-prepared"
	end
	local summary = capability.summary
	local record = capability.record
	if
		activeAuthoritativeFrame ~= capability.frame
		or activeAuthoritativeFrameSummary ~= capability.frameSummary
		or summary.player.Parent ~= Players
		or (
			record ~= nil
			and (
				record.state ~= FlagDefinitions.States.Carried
				or record.carrier ~= summary.player
				or record.teamId ~= summary.teamId
				or record.revision ~= summary.baseRevision
			)
		)
	then
		return false, "stale-personal-teleporter-flag-prepared"
	end
	return true, nil
end

function FlagService.ApplyPreparedPersonalTeleporterDrop(value: unknown): PersonalTeleporterDropReceipt?
	local prepared = if type(value) == "table" then value :: PreparedPersonalTeleporterDrop else nil
	local capability = if prepared then preparedPersonalTeleporterDrops[prepared] else nil
	if not capability or select(1, FlagService.CanApplyPreparedPersonalTeleporterDrop(prepared)) ~= true then
		return nil
	end
	local summary = capability.summary
	if capability.record then
		dropFlag(
			capability.record,
			assert(summary.position, "prepared flag drop requires a carrier position"),
			"PersonalTeleporter",
			summary.player
		)
	end
	capability.status = "Applied"
	preparedPersonalTeleporterDrops[prepared] = nil
	return table.freeze({
		player = summary.player,
		droppedTeamId = summary.teamId,
	})
end

function FlagService.AbortPreparedPersonalTeleporterDrop(value: unknown): boolean
	local prepared = if type(value) == "table" then value :: PreparedPersonalTeleporterDrop else nil
	local capability = if prepared then preparedPersonalTeleporterDrops[prepared] else nil
	if not capability or capability.status ~= "Prepared" then
		return false
	end
	capability.status = "Aborted"
	preparedPersonalTeleporterDrops[prepared] = nil
	return true
end

local function pickupFlag(record: FlagRecord, candidate: Candidate)
	if record.state == FlagDefinitions.States.Carried or candidate.teamId == record.teamId then
		return
	end
	local previousState = record.state
	if previousState == FlagDefinitions.States.Dropped then
		assert(
			DroppedFlagService.MarkTaken(record.teamId, activeLevelTimeMilliseconds()),
			"dropped flag entity did not enter its pickup event"
		)
	end
	record.state = FlagDefinitions.States.Carried
	record.carrier = candidate.player
	record.lastPosition = candidate.position
	record.droppedPosition = nil
	record.returnAtMilliseconds = nil
	record.revision += 1
	setBaseParticipantActive(record, false)
	publishEvent(
		FlagDefinitions.Events.PickedUp,
		record.teamId,
		nil,
		candidate.player,
		candidate.position,
		if previousState == FlagDefinitions.States.Dropped then "RecoveredByEnemy" else "EnemyPickup",
		nil,
		nil
	)
end

function FlagService.ForceStudioFixtureCarrier(player: Player): boolean
	local world = Workspace:FindFirstChild("Q3EngineWorld")
	local teamId = requireDependencies().MatchService.GetPlayerTeam(player)
	if not teamId and RunService:IsStudio() then
		local playerIndex = table.find(Players:GetPlayers(), player) or 1
		teamId = if playerIndex % 2 == 1 then FlagDefinitions.TeamIds.Red else FlagDefinitions.TeamIds.Blue
	end
	if not RunService:IsStudio() or not world or world:GetAttribute("ArenaStudioMoverFixture") == nil or not teamId then
		return false
	end
	local enemyTeamId = FlagDefinitions.OtherTeam(teamId)
	local record = flags[enemyTeamId]
	if not record then
		local marker = Instance.new("Part")
		marker.Name = "__StudioFlagBase_" .. enemyTeamId
		marker.Anchored = true
		marker.CanCollide = false
		marker.CanQuery = false
		marker.CanTouch = false
		marker.Transparency = 1
		marker.Position = Vector3.new(0, -100, 0)
		marker:SetAttribute("ArenaSystemFixture", true)
		record = {
			teamId = enemyTeamId,
			marker = marker,
			basePosition = marker.Position,
			state = FlagDefinitions.States.AtBase,
			carrier = nil,
			lastPosition = marker.Position,
			droppedPosition = nil,
			returnAtMilliseconds = nil,
			revision = 1,
		}
	end
	local itemState = safeItemState(player)
	if not record or not itemState or record.state ~= FlagDefinitions.States.AtBase then
		return false
	end
	pendingStudioFixtureCarriers[player] = record
	return true
end

local function captureFlag(record: FlagRecord, candidate: Candidate)
	if record.state ~= FlagDefinitions.States.Carried or record.carrier ~= candidate.player then
		return
	end
	local match = requireDependencies().MatchService
	local ok, result = pcall(match.ReportTeamObjective, candidate.teamId, 1, "FlagCapture", candidate.player)
	if not ok then
		warn(string.format("FlagService objective report failed: %s", tostring(result)))
		return
	end
	if type(result) ~= "table" or result.accepted ~= true then
		return
	end
	assert(
		awardBonus(candidate.player, CtfBonusRules.Bonuses.Capture, "FlagCaptureBonus"),
		"accepted CTF capture rejected its personal capture bonus"
	)
	local carrierBonusState = bonusState(candidate.player)
	carrierBonusState.captures += 1
	local captures = carrierBonusState.captures
	publishOutward(function()
		candidate.player:SetAttribute("ArenaCtfCaptures", captures)
	end)
	setReward(candidate.player, "Capture")
	local nowMilliseconds = activeLevelTimeMilliseconds()
	for _, teammate in Players:GetPlayers() do
		if safePlayerTeam(teammate) == candidate.teamId then
			local teammateState = bonusState(teammate)
			local assistKind = CtfBonusRules.AssistKind(
				teammateState.lastReturnedFlagMilliseconds,
				teammateState.lastFraggedCarrierMilliseconds,
				nowMilliseconds
			)
			if assistKind then
				local points = if assistKind == "Return"
					then CtfBonusRules.Bonuses.ReturnAssist
					else CtfBonusRules.Bonuses.FragCarrierAssist
				assert(awardBonus(teammate, points, assistKind .. "Assist"))
				teammateState.assists += 1
				local assists = teammateState.assists
				publishOutward(function()
					teammate:SetAttribute("ArenaCtfAssists", assists)
				end)
				setReward(teammate, "Assist")
			end
		end
	end

	setAtBase(record)
	publishEvent(
		FlagDefinitions.Events.Captured,
		record.teamId,
		candidate.teamId,
		candidate.player,
		record.basePosition,
		"FlagCapture",
		if type(result.teamScore) == "number" then result.teamScore else nil,
		result.matchEnded == true
	)
end

local function validateCarriers(byPlayer: { [Player]: Candidate })
	for _, teamId in FlagDefinitions.TeamOrder do
		local record = flags[teamId]
		if not record then
			continue
		end
		if record.state ~= FlagDefinitions.States.Carried then
			continue
		end
		local carrier = record.carrier
		if not carrier then
			returnFlag(record, "MissingCarrier", nil)
			continue
		end
		local candidate = byPlayer[carrier]
		if candidate and candidate.teamId ~= record.teamId then
			record.lastPosition = candidate.position
			continue
		end

		if carrier.Parent ~= Players or safePlayerTeam(carrier) ~= FlagDefinitions.OtherTeam(teamId) then
			returnFlag(record, "CarrierIneligible", carrier)
		else
			local itemState = safeItemState(carrier)
			dropFlag(
				record,
				if itemState then itemState.position else record.lastPosition,
				"CarrierEliminated",
				carrier
			)
		end
	end
end

local function processTimeouts(nowMilliseconds: number)
	for _, teamId in FlagDefinitions.TeamOrder do
		local record = flags[teamId]
		if not record then
			continue
		end
		if
			record.state == FlagDefinitions.States.Dropped
			and record.returnAtMilliseconds ~= nil
			and nowMilliseconds >= record.returnAtMilliseconds
		then
			returnFlag(record, "Timeout", nil)
		end
	end
end

local function processCaptures(candidates: { Candidate })
	for _, candidate in candidates do
		local ownFlag = flags[candidate.teamId]
		local enemyFlag = flags[FlagDefinitions.OtherTeam(candidate.teamId)]
		if not ownFlag or not enemyFlag then
			continue
		end
		if
			enemyFlag.state == FlagDefinitions.States.Carried
			and enemyFlag.carrier == candidate.player
			and ownFlag.state == FlagDefinitions.States.AtBase
			and isWithinBase(candidate.position, ownFlag)
		then
			captureFlag(enemyFlag, candidate)
		end
	end
end

local function processTouches(candidates: { Candidate })
	for _, candidate in candidates do
		local ownFlag = flags[candidate.teamId]
		local enemyFlag = flags[FlagDefinitions.OtherTeam(candidate.teamId)]
		if not ownFlag or not enemyFlag then
			continue
		end
		if
			MatchRulesCore.ResolveFlagTouchAction(candidate.teamId, ownFlag.teamId, ownFlag.state)
				== "Return"
			and isTouchingFlag(candidate.position, ownFlag)
		then
			returnFlag(ownFlag, "TeammateReturn", candidate.player)
			assert(
				awardBonus(candidate.player, CtfBonusRules.Bonuses.Recovery, "FlagRecovery"),
				"accepted CTF recovery rejected its personal bonus"
			)
			bonusState(candidate.player).lastReturnedFlagMilliseconds = activeLevelTimeMilliseconds()
		end

		local enemyAction = MatchRulesCore.ResolveFlagTouchAction(candidate.teamId, enemyFlag.teamId, enemyFlag.state)
		if enemyAction == "Pickup" and isTouchingFlag(candidate.position, enemyFlag) then
			pickupFlag(enemyFlag, candidate)
		end
	end
end

local function scanObjective()
	if not objectiveActive then
		return
	end
	if studioFixtureObjectiveOverride then
		return
	end

	local candidates, byPlayer = collectCandidates()
	validateCarriers(byPlayer)
	processCaptures(candidates)
	if not readFlow() then
		reconcileFlow("FlowEnded")
		return
	end
	processTouches(candidates)
end

local function processElimination(victim: Player, intent: EliminationIntent)
	if not objectiveActive and not studioFixtureObjectiveOverride then
		return
	end
	local carriedRecord: FlagRecord? = nil
	for _, teamId in FlagDefinitions.TeamOrder do
		local record = flags[teamId]
		if record.state == FlagDefinitions.States.Carried and record.carrier == victim then
			carriedRecord = record
			break
		end
	end
	local attacker = intent.attacker
	local attackerTeam = if attacker and attacker ~= victim then safePlayerTeam(attacker) else nil
	local victimTeam = safePlayerTeam(victim)
	if attacker and attackerTeam and victimTeam and attackerTeam ~= victimTeam then
		local fraggedCarrier = carriedRecord ~= nil and attackerTeam == carriedRecord.teamId
		if fraggedCarrier then
			assert(
				awardBonus(attacker, CtfBonusRules.Bonuses.FragCarrier, "FragCarrier"),
				"accepted carrier frag rejected its personal bonus"
			)
			bonusState(attacker).lastFraggedCarrierMilliseconds = activeLevelTimeMilliseconds()
		else
			local victimState = safeItemState(victim)
			local attackerState = safeItemState(attacker)
			if victimState and attackerState then
				local ownFlag = flags[attackerTeam]
				local enemyFlag = flags[FlagDefinitions.OtherTeam(attackerTeam)]
				local baseProtected = (
					(victimState.position - ownFlag.basePosition).Magnitude < CtfBonusRules.ProtectRadiusStuds
					and visibleFrom(ownFlag.basePosition, victimState.position)
				)
					or (
						(attackerState.position - ownFlag.basePosition).Magnitude < CtfBonusRules.ProtectRadiusStuds
						and visibleFrom(ownFlag.basePosition, attackerState.position)
					)
				local teamCarrier = enemyFlag.carrier
				local carrierState = if teamCarrier then safeItemState(teamCarrier) else nil
				local carrierProtected = teamCarrier ~= nil
					and teamCarrier ~= attacker
					and carrierState ~= nil
					and (
						(
							(victimState.position - carrierState.position).Magnitude
								< CtfBonusRules.ProtectRadiusStuds
							and visibleFrom(carrierState.position, victimState.position)
						)
						or (
							(attackerState.position - carrierState.position).Magnitude
								< CtfBonusRules.ProtectRadiusStuds
							and visibleFrom(carrierState.position, attackerState.position)
						)
					)
				local victimBonusState = bonusState(victim)
				local lastHurtCarrier = victimBonusState.lastHurtCarrierMilliseconds
				local carrierDanger = lastHurtCarrier ~= nil
					and activeLevelTimeMilliseconds() - lastHurtCarrier < CtfBonusRules.CarrierDangerTimeoutMilliseconds
					and flags[victimTeam].carrier ~= attacker
				local defenseKind = CtfBonusRules.DefenseKind(false, carrierDanger, baseProtected, carrierProtected)
				if defenseKind then
					local points = if defenseKind == "CarrierDanger"
						then CtfBonusRules.Bonuses.CarrierDangerProtect
						else if defenseKind == "Base"
							then CtfBonusRules.Bonuses.FlagDefense
							else CtfBonusRules.Bonuses.CarrierProtect
					assert(
						awardBonus(attacker, points, defenseKind .. "Defense"),
						"accepted CTF defense rejected its personal bonus"
					)
					local state = bonusState(attacker)
					state.defends += 1
					local defends = state.defends
					publishOutward(function()
						attacker:SetAttribute("ArenaCtfDefends", defends)
					end)
					setReward(attacker, "Defend")
					if defenseKind == "CarrierDanger" then
						victimBonusState.lastHurtCarrierMilliseconds = nil
					end
				end
			end
		end
	end
	if carriedRecord then
		local staged = pendingSynchronousMoverDrops[victim]
		if staged and staged.record == carriedRecord then
			pendingSynchronousMoverDrops[victim] = nil
			if staged.removedByMover then
				returnFlag(carriedRecord, "BlockedDoor", victim)
				return
			end
			carriedRecord.state = FlagDefinitions.States.Dropped
			carriedRecord.carrier = nil
			carriedRecord.lastPosition = staged.position
			carriedRecord.droppedPosition = staged.position
			carriedRecord.returnAtMilliseconds =
				deadlineMilliseconds(staged.levelTimeMilliseconds, FlagDefinitions.DroppedReturnSeconds)
			carriedRecord.revision += 1
			publishEvent(
				FlagDefinitions.Events.Dropped,
				carriedRecord.teamId,
				nil,
				victim,
				staged.position,
				"Eliminated",
				nil,
				nil
			)
			return
		end
		local itemState = safeItemState(victim)
		local carrierPosition = if itemState then itemState.position else carriedRecord.lastPosition
		local contentsOk, contents = pcall(requireDependencies().GetPointContents, carrierPosition)
		if
			intent.means == "Void"
			or intent.means == "Suicide"
			or not contentsOk
			or type(contents) ~= "number"
			or WorldPointContents.IsNoDrop(contents)
		then
			returnFlag(carriedRecord, if intent.means == "Suicide" then "Suicide" else "NoDropVolume", victim)
			return
		end
		dropFlag(carriedRecord, carrierPosition, "Eliminated", victim)
	end
end

local function processDeparture(player: Player)
	if not objectiveActive then
		return
	end
	for _, teamId in FlagDefinitions.TeamOrder do
		local record = flags[teamId]
		if not record then
			continue
		end
		if record.state == FlagDefinitions.States.Carried and record.carrier == player then
			returnFlag(record, "CarrierLeft", player)
		end
	end
end

local function pendingPlayers(pending: { [Player]: any }): { Player }
	local ordered: { Player } = {}
	for player in pending do
		table.insert(ordered, player)
	end
	table.sort(ordered, function(left: Player, right: Player): boolean
		return MatchRulesCore.UserIdPrecedes(left.UserId, right.UserId)
	end)
	return ordered
end

local function flushPendingCarrierIntents()
	for _, player in pendingPlayers(pendingEliminations) do
		local intent = pendingEliminations[player]
		pendingEliminations[player] = nil
		if intent ~= nil then
			processElimination(player, intent)
		end
	end
	for _, player in pendingPlayers(pendingDepartures) do
		pendingDepartures[player] = nil
		processDeparture(player)
	end
end

local function onPlayerDamaged(victim: Player, attacker: Player, _damage: number, levelTimeMilliseconds: number)
	if not objectiveActive or victim == attacker or safePlayerTeam(victim) == safePlayerTeam(attacker) then
		return
	end
	for _, teamId in FlagDefinitions.TeamOrder do
		local record = flags[teamId]
		if record.state == FlagDefinitions.States.Carried and record.carrier == victim then
			bonusState(attacker).lastHurtCarrierMilliseconds = levelTimeMilliseconds
			return
		end
	end
end

local function onElimination(victim: Player, attacker: Player?, means: string)
	local existing = pendingEliminations[victim]
	if not existing or existing.means ~= "Void" then
		pendingEliminations[victim] = table.freeze({
			means = means,
			attacker = attacker,
		})
	end
end

local function onPlayerRemoving(player: Player)
	pendingSnapshotTargets[player] = nil
	bonusStateByPlayer[player] = nil
	pendingDepartures[player] = true
end

local function nextCadenceDeadline(
	previousDeadlineMilliseconds: number?,
	currentMilliseconds: number,
	intervalSeconds: number
): number
	local intervalMilliseconds = durationMilliseconds(intervalSeconds)
	assert(intervalMilliseconds > 0, "Flag cadence interval must be positive")
	if previousDeadlineMilliseconds == nil then
		return deadlineMilliseconds(currentMilliseconds, intervalSeconds)
	end
	if previousDeadlineMilliseconds > currentMilliseconds then
		return previousDeadlineMilliseconds
	end
	local missedIntervals = math.floor((currentMilliseconds - previousDeadlineMilliseconds) / intervalMilliseconds) + 1
	local nextDeadline = previousDeadlineMilliseconds + missedIntervals * intervalMilliseconds
	assert(
		nextDeadline <= MatchFrameRules.MaximumLevelTimeMilliseconds,
		"Flag cadence exceeded the authoritative integer clock"
	)
	return nextDeadline
end

local function publishPendingTargetSnapshots()
	for _, player in pendingPlayers(pendingSnapshotTargets) do
		pendingSnapshotTargets[player] = nil
		if player.Parent == Players then
			publishSnapshot(player)
		end
	end
end

local function validateDependency(container: any, name: string)
	assert(type(container[name]) == "function", string.format("FlagService requires %s", name))
end

function FlagService.HandleAuthoritativeFrame(frameValue: unknown)
	assert(started, "FlagService must start before its authoritative frame phase")
	assert(
		activeAuthoritativeFrame == nil and activeAuthoritativeFrameSummary == nil,
		"FlagService already has an open authoritative frame"
	)
	local openFrame = AuthoritativeFrameService.GetOpenFrame()
	assert(openFrame ~= nil and frameValue == openFrame, "FlagService requires the open frame")
	local summary = AuthoritativeFrameService.InspectFrame(frameValue)
	assert(summary, "FlagService received a stale authoritative frame")
	assert(
		AuthoritativeFrameService.ValidateFrameDependency(frameValue, summary),
		"FlagService authoritative frame dependency is invalid"
	)
	assert(
		MatchFrameRules.ShouldRunFrame(lastProcessedFrameLevelTimeMilliseconds, summary.currentTimeMilliseconds),
		"FlagService authoritative frame ran twice"
	)

	activeAuthoritativeFrame = frameValue :: AuthoritativeFrameService.Frame
	activeAuthoritativeFrameSummary = summary
	assert(
		pendingFramePublicationOwner == nil and #pendingFramePublicationCallbacks == 0,
		"Flag publication callbacks survived into the next frame"
	)
	local currentMilliseconds = summary.currentTimeMilliseconds
	local flowReason = pendingFlowReason
	pendingFlowReason = nil
	reconcileFlow(flowReason or "AuthoritativeFrame")
	flushPendingCarrierIntents()
	for player, state in bonusStateByPlayer do
		if state.rewardUntilMilliseconds ~= nil and currentMilliseconds > state.rewardUntilMilliseconds then
			state.rewardKind = nil
			state.rewardUntilMilliseconds = nil
			publishOutward(function()
				player:SetAttribute("ArenaCtfRewardKind", nil)
				player:SetAttribute("ArenaCtfRewardEndsAt", nil)
			end)
		end
	end

	if nextScanAtMilliseconds == nil or currentMilliseconds >= nextScanAtMilliseconds then
		scanObjective()
		nextScanAtMilliseconds =
			nextCadenceDeadline(nextScanAtMilliseconds, currentMilliseconds, FlagDefinitions.ScanIntervalSeconds)
	end
	-- Q3's G_RunThink executes Team_DroppedFlagThink on the first frame whose
	-- integer level.time reaches nextthink. Keep that deadline frame-granular;
	-- the lower-frequency spatial touch scan is a separate Roblox adaptation.
	if objectiveActive then
		processTimeouts(currentMilliseconds)
	end

	publishPendingTargetSnapshots()
	if pendingInitialBroadcast then
		pendingInitialBroadcast = false
		publishSnapshot()
	elseif nextSnapshotAtMilliseconds == nil or currentMilliseconds >= nextSnapshotAtMilliseconds then
		publishSnapshot()
	end

	lastProcessedFrameLevelTimeMilliseconds = currentMilliseconds
	lastFrameLevelTimeMilliseconds = currentMilliseconds
	lastFrameServerTimeSeconds = summary.currentServerTimeSeconds
	pendingFramePublicationOwner = activeAuthoritativeFrame
	activeAuthoritativeFrame = nil
	activeAuthoritativeFrameSummary = nil
	return function()
		FlagService.FlushAuthoritativeFramePublications(frameValue)
	end
end

function FlagService.FlushAuthoritativeFramePublications(frameValue: unknown)
	assert(
		pendingFramePublicationOwner ~= nil and frameValue == pendingFramePublicationOwner,
		"Flag publication flush received another frame"
	)
	local callbacks = pendingFramePublicationCallbacks
	pendingFramePublicationCallbacks = {}
	pendingFramePublicationOwner = nil
	local failed = false
	for _, callback in callbacks do
		if not pcall(callback) then
			failed = true
		end
	end
	assert(not failed, "Flag outward publication callback failed")
end

function FlagService.HandleSimulationFault()
	if publicationQuarantined then
		return
	end
	publicationQuarantined = true
	pendingFramePublicationCallbacks = {}
	pendingFramePublicationOwner = nil
	activeAuthoritativeFrame = nil
	activeAuthoritativeFrameSummary = nil
end

function FlagService.GetSnapshot(): Snapshot
	assert(started, "FlagService must be started before GetSnapshot")
	return buildSnapshot()
end

function FlagService.CollectMoverParticipants(): MoverItemFlagParticipantRules.Collection
	assert(started, "FlagService must start before mover collection")
	assert(activePreparedMoverParticipantUpdate == nil, "flag mover collection crossed prepare")
	local participants: { MoverItemFlagParticipantRules.Participant } = {}
	for _, record in flagMoverAuthority.order do
		table.insert(participants, record.participant)
	end
	local collection, collectionError = MoverItemFlagParticipantRules.Collect(participants)
	return assert(collection, collectionError)
end

local function flagMoverRecordForBodyId(bodyId: string): FlagMoverRecord
	for _, record in flagMoverAuthority.order do
		if record.participant.body.id == bodyId then
			return record
		end
	end
	error("flag mover participant body is stale")
end

function FlagService.ResolveMoverSine(bodyId: string): MoverItemFlagParticipantRules.SynchronousCrushEffect
	return assert(MoverItemFlagParticipantRules.ResolveSineCrush(flagMoverRecordForBodyId(bodyId).participant))
end

function FlagService.ResolveMoverBlockedDoor(bodyId: string): MoverItemFlagParticipantRules.Transition
	return assert(MoverItemFlagParticipantRules.ResolveBlockedDoor(flagMoverRecordForBodyId(bodyId).participant))
end

function FlagService.PrepareMoverParticipantUpdate(
	finalBodiesValue: unknown
): (PreparedMoverParticipantUpdate?, string?)
	if activePreparedMoverParticipantUpdate ~= nil or type(finalBodiesValue) ~= "table" then
		return nil, "flag-mover-participant-owner-unavailable"
	end
	local finalBodiesById: { [string]: unknown } = {}
	for _, body in finalBodiesValue :: { any } do
		if type(body) == "table" and type(body.id) == "string" then
			finalBodiesById[body.id] = body
		end
	end
	local baseAuthority = flagMoverAuthority
	local nextRecordsByTeamId = table.clone(baseAuthority.recordsByTeamId)
	local nextOrder: { FlagMoverRecord } = {}
	local changedRecords: { FlagMoverRecord } = {}
	local returnedTeamIds: { [string]: boolean } = {}
	for _, record in baseAuthority.order do
		local finalBody = finalBodiesById[record.participant.body.id]
		if finalBody == nil then
			return nil, "retained-base-flag-mover-body-removed"
		end
		local participant = record.participant
		if participant.lifecycle == "HiddenLinked" and (finalBody :: any).contents == 0x40000000 then
			local transition, transitionError = MoverItemFlagParticipantRules.Respawn(participant)
			if not transition then
				return nil, transitionError or "blocked base flag reset failed"
			end
			participant = transition.participant
			returnedTeamIds[record.teamId] = true
		end
		local nextParticipant, participantError = MoverItemFlagParticipantRules.ApplyMoverBody(participant, finalBody)
		if not nextParticipant then
			return nil, participantError or "base flag mover body invalid"
		end
		local nextRecord = record
		if
			nextParticipant.lifecycle ~= record.participant.lifecycle
			or nextParticipant.body.position ~= record.participant.body.position
			or nextParticipant.body.groundMoverId ~= record.participant.body.groundMoverId
		then
			nextRecord = table.freeze({
				teamId = record.teamId,
				registration = record.registration,
				participant = nextParticipant,
			})
			nextRecordsByTeamId[record.teamId] = nextRecord
			table.insert(changedRecords, nextRecord)
		end
		table.insert(nextOrder, nextRecord)
	end
	table.freeze(nextRecordsByTeamId)
	table.freeze(nextOrder)
	table.freeze(changedRecords)
	table.freeze(returnedTeamIds)
	local nextAuthority: FlagMoverAuthority = baseAuthority
	if #changedRecords > 0 then
		nextAuthority = table.freeze({
			revision = baseAuthority.revision + 1,
			recordsByTeamId = nextRecordsByTeamId,
			order = nextOrder,
		})
	end
	local prepared: PreparedMoverParticipantUpdate = table.freeze({})
	local receipt: MoverParticipantUpdateReceipt = table.freeze({})
	local capability: PreparedCapability = {
		status = "Prepared",
		preflightPassCount = 0,
		baseAuthority = baseAuthority,
		nextAuthority = nextAuthority,
		changedRecords = changedRecords,
		returnedTeamIds = returnedTeamIds,
		prepared = prepared,
		receipt = receipt,
	}
	preparedMoverCapabilities[prepared] = capability
	moverReceiptCapabilities[receipt] = capability
	activePreparedMoverParticipantUpdate = prepared
	return prepared, nil
end

function FlagService.CanApplyPreparedMoverParticipantUpdate(preparedValue: unknown): (boolean, string?)
	local capability = if type(preparedValue) == "table"
		then preparedMoverCapabilities[preparedValue :: PreparedMoverParticipantUpdate]
		else nil
	if
		not capability
		or capability.status ~= "Prepared"
		or activePreparedMoverParticipantUpdate ~= preparedValue
		or flagMoverAuthority ~= capability.baseAuthority
	then
		return false, "stale-prepared-flag-mover-participant-update"
	end
	capability.preflightPassCount = math.min(capability.preflightPassCount + 1, 2)
	return true, nil
end

function FlagService.ApplyPreparedMoverParticipantUpdate(preparedValue: unknown): MoverParticipantUpdateReceipt
	local prepared = preparedValue :: PreparedMoverParticipantUpdate
	local capability = assert(preparedMoverCapabilities[prepared], "invalid prepared flag mover participant update")
	assert(
		capability.status == "Prepared"
			and capability.preflightPassCount >= 2
			and activePreparedMoverParticipantUpdate == prepared
			and flagMoverAuthority == capability.baseAuthority,
		"stale prepared flag mover participant apply"
	)
	flagMoverAuthority = capability.nextAuthority
	capability.status = "Applied"
	preparedMoverCapabilities[prepared] = nil
	return capability.receipt
end

function FlagService.FlushPreparedMoverParticipantUpdate(receiptValue: unknown): boolean
	local capability = if type(receiptValue) == "table"
		then moverReceiptCapabilities[receiptValue :: MoverParticipantUpdateReceipt]
		else nil
	if not capability or capability.status ~= "Applied" then
		return false
	end
	capability.status = "Flushed"
	moverReceiptCapabilities[capability.receipt] = nil
	activePreparedMoverParticipantUpdate = nil
	for _, moverRecord in capability.changedRecords do
		local record = assert(flags[moverRecord.teamId], "moved flag record is unavailable")
		record.marker.Position = moverRecord.participant.body.position
		record.basePosition = moverRecord.participant.body.position
		if record.state == FlagDefinitions.States.AtBase then
			record.lastPosition = record.basePosition
		end
	end
	for teamId in capability.returnedTeamIds do
		local record = assert(flags[teamId], "returned flag record is unavailable")
		returnFlag(record, "BlockedDoor", nil)
	end
	return true
end

function FlagService.AbortPreparedMoverParticipantUpdate(preparedValue: unknown): boolean
	local prepared = if type(preparedValue) == "table" then preparedValue :: PreparedMoverParticipantUpdate else nil
	local capability = if prepared then preparedMoverCapabilities[prepared] else nil
	if not capability or capability.status ~= "Prepared" or activePreparedMoverParticipantUpdate ~= prepared then
		return false
	end
	capability.status = "Aborted"
	preparedMoverCapabilities[prepared :: PreparedMoverParticipantUpdate] = nil
	moverReceiptCapabilities[capability.receipt] = nil
	activePreparedMoverParticipantUpdate = nil
	return true
end

local moverParticipantUpdateAdapter: MoverParticipantUpdateAdapter = table.freeze({
	Collect = FlagService.CollectMoverParticipants,
	ResolveSine = FlagService.ResolveMoverSine,
	ResolveBlockedDoor = FlagService.ResolveMoverBlockedDoor,
	Prepare = FlagService.PrepareMoverParticipantUpdate,
	CanApply = FlagService.CanApplyPreparedMoverParticipantUpdate,
	Apply = FlagService.ApplyPreparedMoverParticipantUpdate,
	Flush = FlagService.FlushPreparedMoverParticipantUpdate,
	Abort = FlagService.AbortPreparedMoverParticipantUpdate,
})

function FlagService.GetMoverParticipantUpdateAdapter(): MoverParticipantUpdateAdapter
	return moverParticipantUpdateAdapter
end

function FlagService.IsActive(): boolean
	return objectiveActive
end

function FlagService.Start(worldFolder: Folder, serviceDependencies: any, runtimeMapData: RuntimeMapData?)
	assert(not started, "FlagService.Start may only be called once")
	assert(worldFolder:IsA("Folder"), "FlagService.Start requires the arena world Folder")
	assert(type(serviceDependencies) == "table", "FlagService.Start requires service dependencies")
	assert(type(serviceDependencies.MatchService) == "table", "MatchService dependency is required")
	assert(type(serviceDependencies.CombatService) == "table", "CombatService dependency is required")

	local match = serviceDependencies.MatchService
	validateDependency(match, "GetModeId")
	validateDependency(match, "GetState")
	validateDependency(match, "GetPlayerTeam")
	validateDependency(match, "CanPlayerFight")
	validateDependency(match, "ReportTeamObjective")
	validateDependency(match, "AwardObjectiveBonus")
	validateDependency(match, "OnStateChanged")
	validateDependency(match, "OnModeChanged")
	validateDependency(match, "OnEliminationRecorded")
	validateDependency(serviceDependencies.CombatService, "GetItemState")
	validateDependency(serviceDependencies.CombatService, "HasWorldVisibility")
	validateDependency(serviceDependencies.CombatService, "OnPlayerDamaged")
	validateDependency(serviceDependencies, "GetPointContents")

	local markers = resolveMarkers(worldFolder, runtimeMapData)
	if markers then
		basesAvailable = true
		local moverRecordsByTeamId: { [string]: FlagMoverRecord } = {}
		local moverOrder: { FlagMoverRecord } = {}
		for _, teamId in FlagDefinitions.TeamOrder do
			local marker = markers[teamId]
			local mapEntityId = marker:GetAttribute("ArenaMapEntityId")
			assert(type(mapEntityId) == "string", "flag base lost ArenaMapEntityId")
			local mapRegistration =
				assert(EntitySlotService.GetMapRegistration(mapEntityId), "flag base map registration is unavailable")
			assert(
				mapRegistration.kind == "TeamFlag"
					and mapRegistration.registration.kind == "World"
					and EntitySlotService.InspectSlot(mapRegistration.registration.sourceOrder)
						== mapRegistration.registration,
				"flag base map registration is stale"
			)
			flags[teamId] = {
				teamId = teamId,
				marker = marker,
				basePosition = marker.Position,
				state = FlagDefinitions.States.AtBase,
				carrier = nil,
				lastPosition = marker.Position,
				droppedPosition = nil,
				returnAtMilliseconds = nil,
				revision = 0,
				mapRegistration = mapRegistration,
			}
			local registration = mapRegistration.registration
			local participant, participantError = MoverItemFlagParticipantRules.Create({
				binding = {
					kind = "TeamFlag",
					bodyId = registration.bodyId,
					teamId = teamId,
				},
				body = {
					id = registration.bodyId,
					sourceOrder = registration.sourceOrder,
					position = marker.Position,
					size = Vector3.new(3, 3, 3),
					centerOffset = Vector3.zero,
					velocity = Vector3.zero,
					groundMoverId = nil,
					contents = 0x40000000,
					clipMask = 0x1,
				},
				lifecycle = "ActiveLinked",
				dropped = false,
			})
			local moverRecord: FlagMoverRecord = table.freeze({
				teamId = teamId,
				registration = registration,
				participant = assert(participant, participantError),
			})
			moverRecordsByTeamId[teamId] = moverRecord
			table.insert(moverOrder, moverRecord)
		end
		table.sort(moverOrder, function(left, right)
			return left.registration.sourceOrder < right.registration.sourceOrder
		end)
		table.freeze(moverRecordsByTeamId)
		table.freeze(moverOrder)
		flagMoverAuthority = table.freeze({
			revision = 1,
			recordsByTeamId = moverRecordsByTeamId,
			order = moverOrder,
		})
	end

	dependencies = serviceDependencies
	DroppedFlagService.Start(worldFolder, {
		GetPointContents = serviceDependencies.GetPointContents,
		OnPosition = function(teamId: TeamId, position: Vector3)
			local record = flags[teamId]
			if record and record.state == FlagDefinitions.States.Dropped then
				record.lastPosition = position
				record.droppedPosition = position
				record.revision += 1
			end
		end,
		OnReturn = function(teamId: TeamId, reason: string)
			local record = flags[teamId]
			if record and record.state == FlagDefinitions.States.Dropped then
				returnFlag(record, reason, nil)
			end
		end,
		OnStagedAbort = function(teamId: TeamId, _dropId: string, reason: "Removed" | "Abort")
			for player, pending in pendingSynchronousMoverDrops do
				if pending.record.teamId == teamId then
					if reason == "Removed" then
						pending.removedByMover = true
					else
						pendingSynchronousMoverDrops[player] = nil
					end
				end
			end
		end,
	})
	local network = ensureFolder(sharedRoot, FlagDefinitions.NetworkFolderName)
	snapshotRemote = ensureRemote(network, FlagDefinitions.SnapshotRemoteName)
	eventRemote = ensureRemote(network, FlagDefinitions.EventRemoteName)
	started = true

	match.OnStateChanged(function(_snapshot: unknown)
		queueFlowReconcile("MatchStateChanged")
	end)
	match.OnModeChanged(function(_modeId: unknown, _rules: unknown)
		queueFlowReconcile("ModeChanged")
	end)
	match.OnEliminationRecorded(function(victim: Player, attacker: Player?, means: string, _result: unknown)
		onElimination(victim, attacker, means)
	end)
	serviceDependencies.CombatService.OnPlayerDamaged(onPlayerDamaged)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	Players.PlayerAdded:Connect(function(player: Player)
		pendingSnapshotTargets[player] = true
	end)
end

return table.freeze(FlagService)
