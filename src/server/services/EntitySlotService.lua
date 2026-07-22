--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-only owner for the Quake III entity-number domain translated by
ReplicatedStorage/Q3Engine/simulation/EntitySourceOrderRules.lua.

The service owns admission-time client registrations, the eight never-free
body-queue registrations and its transaction-local corpse-ring cursor, and one
abortable world-allocation transaction. Committed world registrations remain
strongly indexed by source order and generation-bound body identity. A
canonical map spawn plan plus every G_Spawn-equivalent (temporary events,
missiles, drops, and flags) must still be composed through this owner before
the full entity domain can be called 1:1. The transaction-local body cursor is
gated by one opaque capability claimed and retained only by BodyQueueService.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

assert(RunService:IsServer(), "EntitySlotService is server-only")

local sharedRoot = ReplicatedStorage:WaitForChild("Q3Engine")
local EntitySourceOrderRules =
	require(sharedRoot:WaitForChild("simulation"):WaitForChild("EntitySourceOrderRules"))
local EntitySpawnPlanRules =
	require(sharedRoot:WaitForChild("maps"):WaitForChild("EntitySpawnPlanRules"))

local EntitySlotService = {}

export type RegistrationKind = "Player" | "BodyQueue" | "World"

export type Registration = {
	read kind: RegistrationKind,
	read domain: EntitySourceOrderRules.Domain,
	read bodyId: string,
	read sourceOrder: number,
	read generation: number,
	read bodyQueueIndex: number?,
}

export type TransactionToken = {}
export type PreparedCommit = {}
export type BodyQueueCursorOwner = {}

export type CommitReceipt = {
	read revision: number,
	read nextBodyQueueIndex: number,
	read pendingPlayerReleaseCount: number,
}

export type PreparedRegistrationOutcome = {
	read registration: Registration,
	read lease: EntitySourceOrderRules.Lease,
	read kind: "World" | "Player",
	read status: "Retained" | "Released",
}

export type PreparedCommitSummary = {
	read revision: number,
	read stepTimeMilliseconds: number,
	read nextBodyQueueIndex: number,
	read worldOutcomes: { PreparedRegistrationOutcome },
	read playerOutcomes: { PreparedRegistrationOutcome },
}

export type MapRegistration = {
	read eventId: string,
	read kind: EntitySpawnPlanRules.EntityKind,
	read registration: Registration,
}

export type DebugSnapshot = {
	read started: boolean,
	read playerReleaseLifecycleSealed: boolean,
	read revision: number,
	read mapRegistrationRevision: number,
	read levelTimeMilliseconds: number,
	read highestWorldSourceOrder: number,
	read activeClientCount: number,
	read activeWorldCount: number,
	read registeredPlayerCount: number,
	read registeredWorldCount: number,
	read mapSpawnPlanInstalled: boolean,
	read mapRegistrationCount: number,
	read bodyQueueCount: number,
	read nextBodyQueueIndex: number,
	read bodyQueueCursorOwnerClaimed: boolean,
	read pendingPlayerReleaseCount: number,
	read transactionOpen: boolean,
	read transactionStatus: string?,
	read transactionGeneration: number?,
	read transactionApplyValidated: boolean,
	read transactionPreparedRevision: number?,
}

type RegistrationStatus = "Active" | "Pending" | "Released" | "Aborted"

type RegistrationCapability = {
	kind: RegistrationKind,
	lease: EntitySourceOrderRules.Lease,
	bodyId: string,
	bodyQueueIndex: number?,
	player: Player?,
	status: RegistrationStatus,
	transactionIdentity: unknown?,
	releaseStaged: boolean,
}

type StagedRegistration = {
	registration: Registration,
	capability: RegistrationCapability,
}

type TransactionStatus = "Open" | "Prepared" | "Applied" | "Aborted"

type ActiveTransaction = {
	identity: unknown,
	token: TransactionToken,
	stepTimeMilliseconds: number,
	rulesTransaction: EntitySourceOrderRules.Transaction,
	nextBodyQueueIndex: number,
	provisional: { StagedRegistration },
	releases: { StagedRegistration },
	playerReleases: { StagedRegistration },
	status: TransactionStatus,
	prepared: PreparedCommit?,
}

type PreparedStatus = "Prepared" | "Applied" | "Aborted"
type CommitReceiptStatus = "Pending" | "Applied" | "Aborted"
type CommitReceiptCapability = {
	receipt: CommitReceipt,
	summary: PreparedCommitSummary,
	status: CommitReceiptStatus,
	appliedState: EntitySourceOrderRules.State?,
}
type CapabilityMutation = {
	registration: Registration,
	capability: RegistrationCapability,
	expectedStatus: RegistrationStatus,
	expectedTransactionIdentity: unknown?,
	expectedReleaseStaged: boolean,
	nextStatus: RegistrationStatus,
}
type PreparedCapability = {
	transaction: ActiveTransaction,
	status: PreparedStatus,
	rulesPrepared: EntitySourceOrderRules.PreparedCommit,
	baseAuthoritativeState: EntitySourceOrderRules.State,
	baseNextBodyQueueIndex: number,
	baseRegistrationsByPlayer: { [Player]: Registration },
	baseWorldRegistrationsBySourceOrder: { [number]: Registration },
	baseWorldRegistrationsByBodyId: { [string]: Registration },
	baseMapRegistrationsByEventId: { [string]: MapRegistration },
	baseMapEventIdsByRegistration: { [table]: string },
	baseMapRegistrationRevision: number,
	basePendingPlayerReleases: { [Player]: boolean },
	pendingPlayerReleaseSnapshot: { [Player]: boolean },
	nextRegistrationsByPlayer: { [Player]: Registration },
	nextWorldRegistrationsBySourceOrder: { [number]: Registration },
	nextWorldRegistrationsByBodyId: { [string]: Registration },
	nextMapRegistrationsByEventId: { [string]: MapRegistration },
	nextMapEventIdsByRegistration: { [table]: string },
	nextMapRegistrationRevision: number,
	mutations: { CapabilityMutation },
	receipt: CommitReceipt,
	receiptCapability: CommitReceiptCapability,
	summary: PreparedCommitSummary,
	applyValidated: boolean,
}

local MAXIMUM_TIME_MILLISECONDS = 2_147_483_647
local MAXIMUM_MAP_REGISTRATION_REVISION = 2_147_483_647
local MAXIMUM_BODY_PREFIX_LENGTH = 32
local MAP_BODY_PREFIX_BY_KIND: { [EntitySpawnPlanRules.EntityKind]: string } = table.freeze({
	[EntitySpawnPlanRules.EntityKinds.Spawn] = "map_spawn",
	[EntitySpawnPlanRules.EntityKinds.Item] = "map_item",
	[EntitySpawnPlanRules.EntityKinds.TeamFlag] = "map_flag",
	[EntitySpawnPlanRules.EntityKinds.Target] = "map_target",
	[EntitySpawnPlanRules.EntityKinds.Trigger] = "map_trigger",
	[EntitySpawnPlanRules.EntityKinds.Mover] = "map_mover",
})

local started = false
local authoritativeState: EntitySourceOrderRules.State? = nil
local activeTransaction: ActiveTransaction? = nil
local registrationsByPlayer: { [Player]: Registration } = {}
local bodyQueueRegistrations: { Registration } = {}
local worldRegistrationsBySourceOrder: { [number]: Registration } = {}
local worldRegistrationsByBodyId: { [string]: Registration } = {}
local mapRegistrationsByEventId: { [string]: MapRegistration } = {}
local mapEventIdsByRegistration = setmetatable({}, { __mode = "k" }) :: { [table]: string }
local mapSpawnPlanInstalled = false
local mapRegistrationRevision = 0
local pendingPlayerReleases: { [Player]: boolean } = {}
local nextBodyQueueIndex = 1
local playerReleaseLifecycleSealed = false
local bodyQueueCursorOwner: BodyQueueCursorOwner? = nil
local playerAddedConnection: RBXScriptConnection? = nil
local playerRemovingConnection: RBXScriptConnection? = nil
local registrationCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[table]: RegistrationCapability,
}
local preparedCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedCommit]: PreparedCapability,
}
local preparedSummaryCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PreparedCommitSummary]: PreparedCommit,
}
local commitReceiptCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[CommitReceipt]: CommitReceiptCapability,
}
local currentAppliedCommitReceipt: CommitReceipt? = nil

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isBodyPrefix(value: unknown): boolean
	return type(value) == "string"
		and #value >= 1
		and #value <= MAXIMUM_BODY_PREFIX_LENGTH
		and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
end

local function currentState(): (EntitySourceOrderRules.State?, string?)
	if not started then
		return nil, "entity-slot-service-not-started"
	end
	local state = authoritativeState
	if not state then
		return nil, "entity-slot-state-unavailable"
	end
	local inspected, inspectError = EntitySourceOrderRules.Inspect(state)
	if not inspected then
		return nil, inspectError or "entity-slot-state-not-current"
	end
	return inspected, nil
end

local function countRegisteredPlayers(): number
	local count = 0
	for _ in registrationsByPlayer do
		count += 1
	end
	return count
end

local function countRegisteredWorldEntities(): number
	local count = 0
	for _ in worldRegistrationsBySourceOrder do
		count += 1
	end
	return count
end

local function countMapRegistrations(): number
	local count = 0
	for _ in mapRegistrationsByEventId do
		count += 1
	end
	return count
end

local function countPendingPlayerReleases(): number
	local count = 0
	for _ in pendingPlayerReleases do
		count += 1
	end
	return count
end

local function makeRegistration(
	kind: RegistrationKind,
	lease: EntitySourceOrderRules.Lease,
	bodyId: string,
	bodyQueueIndex: number?,
	player: Player?,
	status: RegistrationStatus,
	transactionIdentity: unknown?
): (Registration, RegistrationCapability)
	local registration: Registration = table.freeze({
		kind = kind,
		domain = lease.domain,
		bodyId = bodyId,
		sourceOrder = lease.sourceOrder,
		generation = lease.generation,
		bodyQueueIndex = bodyQueueIndex,
	})
	local capability: RegistrationCapability = {
		kind = kind,
		lease = lease,
		bodyId = bodyId,
		bodyQueueIndex = bodyQueueIndex,
		player = player,
		status = status,
		transactionIdentity = transactionIdentity,
		releaseStaged = false,
	}
	registrationCapabilities[registration :: table] = capability
	return registration, capability
end

local function inspectRegistration(
	value: unknown,
	expectedKind: RegistrationKind?
): (Registration?, RegistrationCapability?, string?)
	if type(value) ~= "table" then
		return nil, nil, "registration-not-capability"
	end
	local capability = registrationCapabilities[value :: table]
	if not capability then
		return nil, nil, "registration-not-capability"
	end
	local registration = value :: Registration
	local lease = capability.lease
	if
		registration.kind ~= capability.kind
		or registration.domain ~= lease.domain
		or registration.bodyId ~= capability.bodyId
		or registration.sourceOrder ~= lease.sourceOrder
		or registration.generation ~= lease.generation
		or registration.bodyQueueIndex ~= capability.bodyQueueIndex
	then
		return nil, nil, "registration-capability-mismatch"
	end
	if expectedKind and capability.kind ~= expectedKind then
		return nil, nil, "registration-kind-mismatch"
	end
	return registration, capability, nil
end

local function releaseRetainedWorldRegistration(
	registration: Registration,
	capability: RegistrationCapability
)
	if worldRegistrationsBySourceOrder[capability.lease.sourceOrder] == registration then
		worldRegistrationsBySourceOrder[capability.lease.sourceOrder] = nil
	end
	if worldRegistrationsByBodyId[capability.bodyId] == registration then
		worldRegistrationsByBodyId[capability.bodyId] = nil
	end
end

local function cloneMapEventIdsByRegistration(source: { [table]: string }): { [table]: string }
	local clone = setmetatable({}, { __mode = "k" }) :: { [table]: string }
	for registration, eventId in source do
		clone[registration] = eventId
	end
	return clone
end

local function samePlayerSet(left: { [Player]: boolean }, right: { [Player]: boolean }): boolean
	for player, present in left do
		if present ~= true or right[player] ~= true then
			return false
		end
	end
	for player, present in right do
		if present ~= true or left[player] ~= true then
			return false
		end
	end
	return true
end

local function getTransaction(
	tokenValue: unknown,
	allowPrepared: boolean?
): (ActiveTransaction?, string?)
	local transaction = activeTransaction
	if not transaction or type(tokenValue) ~= "table" or tokenValue ~= transaction.token then
		return nil, "entity-slot-transaction-not-current"
	end
	if transaction.status == "Open" then
		local inspected, inspectError =
			EntitySourceOrderRules.InspectTransaction(transaction.rulesTransaction)
		if not inspected then
			return nil, inspectError or "entity-slot-transaction-invalid"
		end
	elseif
		transaction.status ~= "Prepared"
		or allowPrepared ~= true
		or transaction.prepared == nil
	then
		return nil, "entity-slot-transaction-not-current"
	end
	return transaction, nil
end

local function getPreparedCapability(preparedValue: unknown): (PreparedCapability?, string?)
	if type(preparedValue) ~= "table" then
		return nil, "invalid-entity-slot-prepared-commit"
	end
	local capability = preparedCapabilities[preparedValue :: PreparedCommit]
	if not capability then
		return nil, "invalid-entity-slot-prepared-commit"
	end
	return capability, nil
end

local function denyPlayerAdmission(player: Player, reason: string)
	warn(
		string.format(
			"Authoritative entity-slot admission denied for user %d: %s",
			player.UserId,
			reason
		)
	)
	if player.Parent == Players then
		player:Kick("This arena server could not reserve an authoritative player slot.")
	end
end

local function releasePlayerRegistrationNow(
	player: Player,
	allowMissing: boolean
): (boolean, string?)
	local state, stateError = currentState()
	if not state then
		return false, stateError
	end
	if activeTransaction then
		return false, "entity-slot-transaction-active"
	end
	local registration = registrationsByPlayer[player]
	if not registration then
		if allowMissing then
			return true, nil
		end
		return false, "player-not-registered"
	end
	local _, capability, registrationError = inspectRegistration(registration, "Player")
	if not capability then
		return false, registrationError
	end
	if capability.player ~= player or capability.status ~= "Active" then
		return false, "player-registration-not-active"
	end
	local nextState, releaseError = EntitySourceOrderRules.ReleaseClient(state, capability.lease)
	if not nextState then
		return false, releaseError or "client-slot-release-failed"
	end
	authoritativeState = nextState
	capability.status = "Released"
	registrationsByPlayer[player] = nil
	return true, nil
end

local function drainPendingPlayerReleases(): (boolean, string?)
	assert(activeTransaction == nil, "player releases may drain only outside a world transaction")
	local queued = pendingPlayerReleases
	pendingPlayerReleases = {}
	for player in queued do
		local released, releaseError = releasePlayerRegistrationNow(player, true)
		if not released then
			return false, releaseError or "queued-player-slot-release-failed"
		end
	end
	return true, nil
end

local function releaseOrQueueDepartingPlayer(player: Player): (boolean, string?)
	if activeTransaction then
		pendingPlayerReleases[player] = true
		return true, nil
	end
	return releasePlayerRegistrationNow(player, true)
end

function EntitySlotService.EnsurePlayerRegistration(player: Player): (Registration?, string?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return nil, "invalid-player-registration"
	end
	local state, stateError = currentState()
	if not state then
		local failure = stateError or "entity-slot-state-unavailable"
		denyPlayerAdmission(player, failure)
		return nil, failure
	end
	local existing = registrationsByPlayer[player]
	if existing then
		local _, capability, registrationError = inspectRegistration(existing, "Player")
		local leaseOwner = if activeTransaction then activeTransaction.rulesTransaction else state
		if
			capability
			and capability.player == player
			and capability.status == "Active"
			and not capability.releaseStaged
			and EntitySourceOrderRules.InspectLease(leaseOwner, capability.lease, "Client")
				~= nil
		then
			return existing, nil
		end
		local failure = registrationError or "player-registration-not-active"
		denyPlayerAdmission(player, failure)
		return nil, failure
	end
	if activeTransaction then
		denyPlayerAdmission(player, "entity-slot-transaction-active")
		return nil, "entity-slot-transaction-active"
	end

	local nextState, lease, allocationError = EntitySourceOrderRules.AllocateClient(state)
	if not nextState or not lease then
		local failure = allocationError or "client-slot-allocation-failed"
		denyPlayerAdmission(player, failure)
		return nil, failure
	end
	local bodyId, bodyIdError = EntitySourceOrderRules.MakeBodyId("player", nextState, lease)
	if not bodyId then
		local recoveredState = EntitySourceOrderRules.ReleaseClient(nextState, lease)
		authoritativeState = recoveredState or nextState
		local failure = bodyIdError or "client-body-identity-failed"
		denyPlayerAdmission(player, failure)
		return nil, failure
	end
	local registration = makeRegistration("Player", lease, bodyId, nil, player, "Active", nil)
	authoritativeState = nextState
	registrationsByPlayer[player] = registration
	return registration, nil
end

function EntitySlotService.Start(maximumClientsValue: number?): (boolean, string?)
	if started then
		return false, "entity-slot-service-already-started"
	end
	local maximumClients = maximumClientsValue or EntitySourceOrderRules.MaximumClients
	if not isIntegerInRange(maximumClients, 1, EntitySourceOrderRules.MaximumClients) then
		return false, "invalid-maximum-clients"
	end
	if Players.MaxPlayers > maximumClients then
		return false, "configured-server-exceeds-q3-client-domain"
	end
	local state, createError = EntitySourceOrderRules.Create(maximumClients, {}, 0)
	if not state then
		return false, createError or "entity-slot-state-create-failed"
	end

	local queue: { Registration } = {}
	for index = 1, EntitySourceOrderRules.BodyQueueSize do
		local nextState, lease, allocationError = EntitySourceOrderRules.AllocateWorld(state, 0)
		if not nextState or not lease then
			return false, allocationError or "body-queue-allocation-failed"
		end
		state = nextState
		local bodyId, bodyIdError = EntitySourceOrderRules.MakeBodyId("bodyque", state, lease)
		if not bodyId then
			return false, bodyIdError or "body-queue-identity-failed"
		end
		local registration = makeRegistration("BodyQueue", lease, bodyId, index, nil, "Active", nil)
		table.insert(queue, registration)
	end

	table.freeze(queue)
	authoritativeState = state
	bodyQueueRegistrations = queue
	registrationsByPlayer = {}
	worldRegistrationsBySourceOrder = {}
	worldRegistrationsByBodyId = {}
	mapRegistrationsByEventId = {}
	mapEventIdsByRegistration = setmetatable({}, { __mode = "k" }) :: { [table]: string }
	mapSpawnPlanInstalled = false
	mapRegistrationRevision = 0
	pendingPlayerReleases = {}
	nextBodyQueueIndex = 1
	bodyQueueCursorOwner = nil
	activeTransaction = nil
	currentAppliedCommitReceipt = nil
	playerReleaseLifecycleSealed = false
	started = true

	-- Connect before the initial sweep so a join racing startup is either handled
	-- by this callback or found by GetPlayers; Ensure makes both paths converge.
	playerAddedConnection = Players.PlayerAdded:Connect(function(player: Player)
		EntitySlotService.EnsurePlayerRegistration(player)
	end)
	for _, player in Players:GetPlayers() do
		EntitySlotService.EnsurePlayerRegistration(player)
	end
	return true, nil
end

-- Installs the complete retained original-map gentity plan into this service's
-- actual lineage. EntitySpawnPlanRules first replays the plan independently as
-- a source-derived oracle; the service then stages the same registrations and
-- requires every source order, generation, and body identity to agree before
-- one commit. Current MapSchema plans are retained-only. Filter/free parse
-- events remain represented by the pure replay but are not yet live consumers.
function EntitySlotService.InstallMapSpawnPlan(eventsValue: unknown): (boolean, string?)
	if not started then
		return false, "entity-slot-service-not-started"
	end
	if playerReleaseLifecycleSealed then
		return false, "map-plan-install-after-player-lifecycle-seal"
	end
	if mapSpawnPlanInstalled then
		return false, "map-spawn-plan-already-installed"
	end
	if mapRegistrationRevision ~= 0 then
		return false, "map-spawn-plan-revision-not-pristine"
	end
	if activeTransaction then
		return false, "entity-slot-transaction-active"
	end
	local state, stateError = currentState()
	if not state then
		return false, stateError
	end
	if
		state.activeWorldCount ~= EntitySourceOrderRules.BodyQueueSize
		or countRegisteredWorldEntities() ~= 0
	then
		return false, "map-plan-install-world-domain-not-pristine"
	end

	local reference, replayError =
		EntitySpawnPlanRules.Replay(EntitySourceOrderRules, eventsValue, 0)
	if not reference then
		return false, "map-spawn-plan-invalid:" .. (replayError or "unknown")
	end
	local eventCount = 0
	for _ in eventsValue :: { [unknown]: unknown } do
		eventCount += 1
	end
	if #reference.active ~= eventCount then
		return false, "live-map-spawn-plan-must-retain-every-event"
	end
	for index, expectedBodyQueue in reference.bodyQueue do
		local actual = bodyQueueRegistrations[index]
		if
			not actual
			or actual.sourceOrder ~= expectedBodyQueue.sourceOrder
			or actual.generation ~= expectedBodyQueue.lease.generation
			or actual.bodyId ~= expectedBodyQueue.bodyId
		then
			return false, "map-spawn-plan-body-queue-drift"
		end
	end

	local token, beginError = EntitySlotService.Begin(0)
	if not token then
		return false, beginError or "map-spawn-plan-transaction-begin-failed"
	end
	local staged: { { expected: EntitySpawnPlanRules.ActiveRegistration, registration: Registration } } =
		{}
	local function abortInstall(message: string): (boolean, string?)
		local aborted, abortError = EntitySlotService.Abort(token)
		if not aborted then
			return false, message .. ":abort-failed:" .. (abortError or "unknown")
		end
		return false, message
	end

	for _, expected in reference.active do
		local prefix = MAP_BODY_PREFIX_BY_KIND[expected.kind]
		if not prefix then
			return abortInstall("map-spawn-plan-kind-prefix-missing")
		end
		local registration, allocationError = EntitySlotService.AllocateWorld(token, prefix)
		if not registration then
			return abortInstall(
				"map-spawn-plan-allocation-failed:" .. (allocationError or "unknown")
			)
		end
		if
			registration.sourceOrder ~= expected.sourceOrder
			or registration.generation ~= expected.lease.generation
			or registration.bodyId ~= expected.bodyId
		then
			return abortInstall("map-spawn-plan-registration-drift")
		end
		table.insert(staged, {
			expected = expected,
			registration = registration,
		})
	end

	local committed, commitError = EntitySlotService.Commit(token)
	if not committed then
		return false, commitError or "map-spawn-plan-commit-failed"
	end
	for _, entry in staged do
		local registration = entry.registration
		if
			worldRegistrationsBySourceOrder[registration.sourceOrder] ~= registration
			or worldRegistrationsByBodyId[registration.bodyId] ~= registration
		then
			return false, "committed-map-registration-not-indexed"
		end
		local eventId = entry.expected.eventId
		if mapRegistrationsByEventId[eventId] then
			return false, "committed-map-registration-id-collision"
		end
		local mapRegistration: MapRegistration = table.freeze({
			eventId = eventId,
			kind = entry.expected.kind,
			registration = registration,
		})
		mapRegistrationsByEventId[eventId] = mapRegistration
		mapEventIdsByRegistration[registration :: table] = eventId
	end
	mapSpawnPlanInstalled = true
	mapRegistrationRevision = 1
	return true, nil
end

function EntitySlotService.SealPlayerReleaseLifecycle(): (boolean, string?)
	if not started then
		return false, "entity-slot-service-not-started"
	end
	if playerReleaseLifecycleSealed then
		return false, "player-release-lifecycle-already-sealed"
	end
	assert(playerAddedConnection ~= nil, "player admission observer is unavailable")
	assert(playerRemovingConnection == nil, "player release observer was installed before seal")
	playerRemovingConnection = Players.PlayerRemoving:Connect(function(player: Player)
		local released, releaseError = releaseOrQueueDepartingPlayer(player)
		if not released then
			warn(releaseError or "departing player entity slot could not be released")
		end
	end)
	playerReleaseLifecycleSealed = true

	-- A player can leave while the rest of the server services are starting,
	-- before this deliberately-last PlayerRemoving observer is installed.
	local departedBeforeSeal: { Player } = {}
	for player in registrationsByPlayer do
		if player.Parent ~= Players then
			table.insert(departedBeforeSeal, player)
		end
	end
	for _, player in departedBeforeSeal do
		local released, releaseError = releaseOrQueueDepartingPlayer(player)
		if not released then
			return false, releaseError or "pre-seal-player-slot-release-failed"
		end
	end
	return true, nil
end

function EntitySlotService.GetPlayerRegistration(player: Player): Registration?
	local registration = registrationsByPlayer[player]
	if not registration then
		return nil
	end
	local state = select(1, currentState())
	local _, capability = inspectRegistration(registration, "Player")
	if
		not state
		or not capability
		or capability.status ~= "Active"
		or capability.player ~= player
		or capability.releaseStaged
		or EntitySourceOrderRules.InspectLease(state, capability.lease, "Client") == nil
	then
		return nil
	end
	return registration
end

function EntitySlotService.GetPlayerSourceOrder(player: Player): number?
	local registration = EntitySlotService.GetPlayerRegistration(player)
	return if registration then registration.sourceOrder else nil
end

function EntitySlotService.GetPlayerBodyId(player: Player): string?
	local registration = EntitySlotService.GetPlayerRegistration(player)
	return if registration then registration.bodyId else nil
end

function EntitySlotService.GetPlayerLease(player: Player): EntitySourceOrderRules.Lease?
	local registration = EntitySlotService.GetPlayerRegistration(player)
	if not registration then
		return nil
	end
	local capability = registrationCapabilities[registration :: table]
	return if capability then capability.lease else nil
end

function EntitySlotService.GetBodyQueueRegistration(indexValue: unknown): Registration?
	if not isIntegerInRange(indexValue, 1, EntitySourceOrderRules.BodyQueueSize) then
		return nil
	end
	local registration = bodyQueueRegistrations[indexValue :: number]
	local state = select(1, currentState())
	local _, capability = inspectRegistration(registration, "BodyQueue")
	if
		not state
		or not capability
		or capability.status ~= "Active"
		or EntitySourceOrderRules.InspectLease(state, capability.lease, "World") == nil
	then
		return nil
	end
	return registration
end

function EntitySlotService.GetBodyQueueLease(indexValue: unknown): EntitySourceOrderRules.Lease?
	local registration = EntitySlotService.GetBodyQueueRegistration(indexValue)
	if not registration then
		return nil
	end
	local capability = registrationCapabilities[registration :: table]
	return if capability then capability.lease else nil
end

-- The body-ring cursor is one field of the Q3 level owner, not a generic world
-- allocation primitive. BodyQueueService claims this opaque capability once at
-- level startup and never exposes it. A transaction token alone cannot advance
-- the cursor, so unrelated server consumers cannot split the paired owners.
function EntitySlotService.ClaimBodyQueueCursorOwner(): (BodyQueueCursorOwner?, string?)
	if not started then
		return nil, "entity-slot-service-not-started"
	end
	if activeTransaction then
		return nil, "entity-slot-transaction-active"
	end
	if bodyQueueCursorOwner then
		return nil, "body-queue-cursor-owner-already-claimed"
	end
	local owner: BodyQueueCursorOwner = table.freeze({})
	bodyQueueCursorOwner = owner
	return owner, nil
end

function EntitySlotService.Begin(stepTimeMillisecondsValue: unknown): (TransactionToken?, string?)
	local state, stateError = currentState()
	if not state then
		return nil, stateError
	end
	if activeTransaction then
		return nil, "entity-slot-transaction-active"
	end
	if
		not isIntegerInRange(
			stepTimeMillisecondsValue,
			state.levelTimeMilliseconds,
			MAXIMUM_TIME_MILLISECONDS
		)
	then
		return nil, "invalid-entity-slot-step-time"
	end
	local rulesTransaction, beginError = EntitySourceOrderRules.Begin(state)
	if not rulesTransaction then
		return nil, beginError or "entity-slot-transaction-begin-failed"
	end
	local token: TransactionToken = table.freeze({})
	-- A prepared dependent owner must apply immediately after the exact commit
	-- it bound. Opening any later transaction permanently retires that adjacency
	-- proof, even if the later transaction aborts back to the same state root.
	currentAppliedCommitReceipt = nil
	activeTransaction = {
		identity = table.freeze({}),
		token = token,
		stepTimeMilliseconds = stepTimeMillisecondsValue :: number,
		rulesTransaction = rulesTransaction,
		nextBodyQueueIndex = nextBodyQueueIndex,
		provisional = {},
		releases = {},
		playerReleases = {},
		status = "Open",
		prepared = nil,
	}
	return token, nil
end

function EntitySlotService.NextBodyQueue(
	tokenValue: unknown,
	ownerValue: unknown
): (Registration?, string?)
	if type(ownerValue) ~= "table" or ownerValue ~= bodyQueueCursorOwner then
		return nil, "body-queue-cursor-owner-required"
	end
	local transaction, transactionError = getTransaction(tokenValue)
	if not transaction then
		return nil, transactionError
	end
	local index = transaction.nextBodyQueueIndex
	local registration = bodyQueueRegistrations[index]
	local _, capability, registrationError = inspectRegistration(registration, "BodyQueue")
	if
		not capability
		or capability.status ~= "Active"
		or capability.bodyQueueIndex ~= index
		or EntitySourceOrderRules.InspectLease(
				transaction.rulesTransaction,
				capability.lease,
				"World"
			)
			== nil
	then
		return nil, registrationError or "body-queue-registration-not-active"
	end
	transaction.nextBodyQueueIndex = (index % EntitySourceOrderRules.BodyQueueSize) + 1
	return registration, nil
end

function EntitySlotService.AllocateWorld(
	tokenValue: unknown,
	prefixValue: unknown
): (Registration?, string?)
	local transaction, transactionError = getTransaction(tokenValue)
	if not transaction then
		return nil, transactionError
	end
	if not isBodyPrefix(prefixValue) then
		return nil, "body-prefix-invalid"
	end
	local nextRulesTransaction, lease, stageError =
		EntitySourceOrderRules.Stage(transaction.rulesTransaction, {
			kind = "AllocateWorld",
			nowMilliseconds = transaction.stepTimeMilliseconds,
		})
	if not nextRulesTransaction or not lease then
		return nil, stageError or "world-slot-allocation-failed"
	end
	transaction.rulesTransaction = nextRulesTransaction
	local bodyId, bodyIdError =
		EntitySourceOrderRules.MakeBodyId(prefixValue, nextRulesTransaction, lease)
	if not bodyId then
		return nil, bodyIdError or "world-body-identity-failed"
	end
	local registration, capability =
		makeRegistration("World", lease, bodyId, nil, nil, "Pending", transaction.identity)
	table.insert(transaction.provisional, {
		registration = registration,
		capability = capability,
	})
	return registration, nil
end

function EntitySlotService.ReleaseWorld(
	tokenValue: unknown,
	registrationValue: unknown
): (boolean, string?)
	local transaction, transactionError = getTransaction(tokenValue)
	if not transaction then
		return false, transactionError
	end
	local registration, capability, registrationError =
		inspectRegistration(registrationValue, "World")
	if not registration or not capability then
		return false, registrationError
	end
	if capability.status ~= "Active" and capability.status ~= "Pending" then
		return false, "world-registration-not-active"
	end
	if
		capability.status == "Pending"
		and capability.transactionIdentity ~= transaction.identity
	then
		return false, "world-registration-transaction-mismatch"
	end
	if
		capability.status == "Active"
		and (
			worldRegistrationsBySourceOrder[capability.lease.sourceOrder] ~= registration
			or worldRegistrationsByBodyId[capability.bodyId] ~= registration
		)
	then
		return false, "world-registration-not-committed"
	end
	if capability.releaseStaged then
		return false, "world-registration-release-already-staged"
	end
	if
		EntitySourceOrderRules.InspectLease(transaction.rulesTransaction, capability.lease, "World")
		== nil
	then
		return false, "world-registration-lease-not-current"
	end

	local nextRulesTransaction, _, stageError =
		EntitySourceOrderRules.Stage(transaction.rulesTransaction, {
			kind = "ReleaseWorld",
			lease = capability.lease,
			nowMilliseconds = transaction.stepTimeMilliseconds,
		})
	if not nextRulesTransaction then
		return false, stageError or "world-slot-release-failed"
	end
	transaction.rulesTransaction = nextRulesTransaction
	capability.releaseStaged = true
	table.insert(transaction.releases, {
		registration = registration,
		capability = capability,
	})
	return true, nil
end

-- This is intentionally not wired to PlayerRemoving yet. Disconnect callbacks
-- are queued while a transaction is open and released after its outcome. The
-- staged form exists for the later single mover-consequence composition, where
-- removal of a player body and its client entity must share one commit.
function EntitySlotService.StagePlayerRelease(
	tokenValue: unknown,
	player: Player
): (boolean, string?)
	local transaction, transactionError = getTransaction(tokenValue)
	if not transaction then
		return false, transactionError
	end
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, "invalid-player-registration"
	end
	local registration = registrationsByPlayer[player]
	if not registration then
		return false, "player-not-registered"
	end
	local _, capability, registrationError = inspectRegistration(registration, "Player")
	if not capability then
		return false, registrationError
	end
	if capability.player ~= player or capability.status ~= "Active" then
		return false, "player-registration-not-active"
	end
	if capability.releaseStaged then
		return false, "player-registration-release-already-staged"
	end
	if
		EntitySourceOrderRules.InspectLease(
			transaction.rulesTransaction,
			capability.lease,
			"Client"
		) == nil
	then
		return false, "player-registration-lease-not-current"
	end

	local nextRulesTransaction, _, stageError =
		EntitySourceOrderRules.Stage(transaction.rulesTransaction, {
			kind = "ReleaseClient",
			lease = capability.lease,
		})
	if not nextRulesTransaction then
		return false, stageError or "client-slot-release-failed"
	end
	transaction.rulesTransaction = nextRulesTransaction
	capability.releaseStaged = true
	table.insert(transaction.playerReleases, {
		registration = registration,
		capability = capability,
	})
	return true, nil
end

function EntitySlotService.GetWorldLease(
	registrationValue: unknown,
	tokenValue: unknown?
): EntitySourceOrderRules.Lease?
	local registration, capability = inspectRegistration(registrationValue, "World")
	if not capability or capability.releaseStaged then
		return nil
	end
	if capability.status == "Pending" then
		local transaction = select(1, getTransaction(tokenValue))
		if
			not transaction
			or capability.transactionIdentity ~= transaction.identity
			or EntitySourceOrderRules.InspectLease(
					transaction.rulesTransaction,
					capability.lease,
					"World"
				)
				== nil
		then
			return nil
		end
		return capability.lease
	elseif capability.status == "Active" then
		local state = select(1, currentState())
		if
			not state
			or worldRegistrationsBySourceOrder[capability.lease.sourceOrder] ~= registration
			or worldRegistrationsByBodyId[capability.bodyId] ~= registration
			or EntitySourceOrderRules.InspectLease(state, capability.lease, "World") == nil
		then
			return nil
		end
		return capability.lease
	end
	return nil
end

local function trustedWorldRegistration(registration: Registration?): Registration?
	if not registration then
		return nil
	end
	local state = select(1, currentState())
	local inspected, capability = inspectRegistration(registration, "World")
	if
		not state
		or not inspected
		or not capability
		or capability.status ~= "Active"
		or capability.releaseStaged
		or worldRegistrationsBySourceOrder[capability.lease.sourceOrder] ~= registration
		or worldRegistrationsByBodyId[capability.bodyId] ~= registration
		or EntitySourceOrderRules.InspectLease(state, capability.lease, "World") == nil
	then
		return nil
	end
	return registration
end

function EntitySlotService.GetWorldRegistrationBySourceOrder(
	sourceOrderValue: unknown
): Registration?
	if
		not isIntegerInRange(
			sourceOrderValue,
			EntitySourceOrderRules.FirstWorldSourceOrder,
			EntitySourceOrderRules.MaximumNormalSourceOrder
		)
	then
		return nil
	end
	return trustedWorldRegistration(worldRegistrationsBySourceOrder[sourceOrderValue :: number])
end

function EntitySlotService.GetWorldRegistrationByBodyId(bodyIdValue: unknown): Registration?
	if type(bodyIdValue) ~= "string" then
		return nil
	end
	return trustedWorldRegistration(worldRegistrationsByBodyId[bodyIdValue :: string])
end

function EntitySlotService.GetMapRegistration(eventIdValue: unknown): MapRegistration?
	if
		type(eventIdValue) ~= "string"
		or #eventIdValue < 1
		or #eventIdValue > EntitySpawnPlanRules.MaximumIdentifierLength
	then
		return nil
	end
	local mapRegistration = mapRegistrationsByEventId[eventIdValue :: string]
	if
		not mapRegistration
		or mapRegistration.eventId ~= eventIdValue
		or trustedWorldRegistration(mapRegistration.registration)
			~= mapRegistration.registration
	then
		return nil
	end
	return mapRegistration
end

-- A dynamic-tail coordinator must distinguish an intentionally empty installed
-- map plan from startup before InstallMapSpawnPlan. Keep that authority check
-- out of DebugSnapshot, and fail closed while a transaction could expose a
-- provisional world-domain boundary.
function EntitySlotService.IsMapSpawnPlanInstalled(): boolean
	return started and mapSpawnPlanInstalled and activeTransaction == nil
end

-- Read-only committed views for the source-ordered G_RunFrame dispatcher.
-- Transaction-local registrations and allocator bounds are deliberately not
-- exposed here: a G_Spawn-equivalent becomes traversable only after its whole
-- composite has applied EntitySlot and closed the transaction.
function EntitySlotService.GetTraversalUpperBound(): number?
	if activeTransaction then
		return nil
	end
	local state = select(1, currentState())
	return if state then state.highestWorldSourceOrder else nil
end

function EntitySlotService.GetPlayerForRegistration(registrationValue: unknown): Player?
	if activeTransaction then
		return nil
	end
	local state = select(1, currentState())
	local registration, capability = inspectRegistration(registrationValue, "Player")
	local player = if capability then capability.player else nil
	if
		not state
		or not registration
		or not capability
		or not player
		or capability.status ~= "Active"
		or capability.releaseStaged
		or registrationsByPlayer[player] ~= registration
		or EntitySourceOrderRules.InspectLease(state, capability.lease, "Client") == nil
	then
		return nil
	end
	return player
end

function EntitySlotService.InspectSlot(sourceOrderValue: unknown): Registration?
	if activeTransaction then
		return nil
	end
	local state = select(1, currentState())
	if
		not state
		or not isIntegerInRange(
			sourceOrderValue,
			1,
			EntitySourceOrderRules.MaximumNormalSourceOrder
		)
		or (sourceOrderValue :: number) > state.highestWorldSourceOrder
	then
		return nil
	end
	local sourceOrder = sourceOrderValue :: number
	if sourceOrder < EntitySourceOrderRules.FirstWorldSourceOrder then
		local found: Registration? = nil
		for _, registration in registrationsByPlayer do
			if registration.sourceOrder == sourceOrder then
				if EntitySlotService.GetPlayerForRegistration(registration) == nil or found then
					return nil
				end
				found = registration
			end
		end
		return found
	end

	local bodyQueueIndex = sourceOrder - EntitySourceOrderRules.FirstWorldSourceOrder + 1
	if bodyQueueIndex <= EntitySourceOrderRules.BodyQueueSize then
		return EntitySlotService.GetBodyQueueRegistration(bodyQueueIndex)
	end
	return EntitySlotService.GetWorldRegistrationBySourceOrder(sourceOrder)
end

function EntitySlotService.GetMapRegistrationsInSourceOrder(): { MapRegistration }?
	if activeTransaction then
		return nil
	end
	local state = select(1, currentState())
	if not state then
		return nil
	end
	local ordered: { MapRegistration } = {}
	local observedSourceOrders: { [number]: boolean } = {}
	for eventId, mapRegistration in mapRegistrationsByEventId do
		local registration = mapRegistration.registration
		local sourceOrder = registration.sourceOrder
		if
			not table.isfrozen(mapRegistration :: any)
			or mapRegistration.eventId ~= eventId
			or MAP_BODY_PREFIX_BY_KIND[mapRegistration.kind] == nil
			or mapEventIdsByRegistration[registration :: table] ~= eventId
			or EntitySlotService.GetMapRegistration(eventId) ~= mapRegistration
			or EntitySlotService.InspectSlot(sourceOrder) ~= registration
			or observedSourceOrders[sourceOrder]
		then
			return nil
		end
		observedSourceOrders[sourceOrder] = true
		table.insert(ordered, mapRegistration)
	end
	table.sort(ordered, function(left: MapRegistration, right: MapRegistration): boolean
		return left.registration.sourceOrder < right.registration.sourceOrder
	end)
	table.freeze(ordered)
	return ordered
end

-- Constant-time committed witness for the retained authored-map membership.
-- Dynamic G_Spawn/G_FreeEntity transactions do not change this revision. It
-- advances only when the installed map index itself changes, allowing frame
-- dispatchers to reuse a previously completed exact-prefix audit without
-- weakening the transaction-open fail-closed boundary.
function EntitySlotService.GetMapRegistrationRevision(): number?
	if not started or not mapSpawnPlanInstalled or activeTransaction then
		return nil
	end
	return mapRegistrationRevision
end

local function preparedCommitCurrentError(
	preparedValue: unknown,
	capability: PreparedCapability
): string?
	local transaction = capability.transaction
	local receiptCapability = capability.receiptCapability
	if
		capability.status ~= "Prepared"
		or activeTransaction ~= transaction
		or transaction.status ~= "Prepared"
		or transaction.prepared ~= preparedValue
		or authoritativeState ~= capability.baseAuthoritativeState
		or nextBodyQueueIndex ~= capability.baseNextBodyQueueIndex
		or registrationsByPlayer ~= capability.baseRegistrationsByPlayer
		or worldRegistrationsBySourceOrder ~= capability.baseWorldRegistrationsBySourceOrder
		or worldRegistrationsByBodyId ~= capability.baseWorldRegistrationsByBodyId
		or mapRegistrationsByEventId ~= capability.baseMapRegistrationsByEventId
		or mapEventIdsByRegistration ~= capability.baseMapEventIdsByRegistration
		or mapRegistrationRevision ~= capability.baseMapRegistrationRevision
		or pendingPlayerReleases ~= capability.basePendingPlayerReleases
		or not samePlayerSet(pendingPlayerReleases, capability.pendingPlayerReleaseSnapshot)
		or not table.isfrozen(preparedValue :: any)
		or not table.isfrozen(capability.pendingPlayerReleaseSnapshot)
		or not table.isfrozen(capability.mutations)
		or not table.isfrozen(capability.receipt)
		or commitReceiptCapabilities[capability.receipt] ~= receiptCapability
		or receiptCapability.receipt ~= capability.receipt
		or receiptCapability.summary ~= capability.summary
		or receiptCapability.status ~= "Pending"
		or receiptCapability.appliedState ~= nil
		or not table.isfrozen(capability.summary)
		or not table.isfrozen(capability.summary.worldOutcomes)
		or not table.isfrozen(capability.summary.playerOutcomes)
		or preparedSummaryCapabilities[capability.summary] ~= preparedValue
		or capability.receipt.revision ~= capability.baseAuthoritativeState.revision + 1
		or capability.summary.revision ~= capability.receipt.revision
		or capability.summary.stepTimeMilliseconds ~= transaction.stepTimeMilliseconds
		or capability.summary.nextBodyQueueIndex ~= capability.receipt.nextBodyQueueIndex
		or capability.receipt.nextBodyQueueIndex ~= transaction.nextBodyQueueIndex
		or capability.nextMapRegistrationRevision < capability.baseMapRegistrationRevision
		or capability.nextMapRegistrationRevision > capability.baseMapRegistrationRevision + 1
	then
		return "stale-entity-slot-prepared-commit"
	end
	for _, mutation in capability.mutations do
		local registrationCapability = mutation.capability
		if
			not table.isfrozen(mutation)
			or registrationCapabilities[mutation.registration :: table] ~= registrationCapability
			or registrationCapability.status ~= mutation.expectedStatus
			or registrationCapability.transactionIdentity ~= mutation.expectedTransactionIdentity
			or registrationCapability.releaseStaged ~= mutation.expectedReleaseStaged
		then
			return "stale-entity-slot-prepared-commit"
		end
	end
	for _, outcome in capability.summary.worldOutcomes do
		if
			not table.isfrozen(outcome)
			or outcome.kind ~= "World"
			or registrationCapabilities[outcome.registration :: table] == nil
		then
			return "stale-entity-slot-prepared-world-outcome"
		end
	end
	for _, outcome in capability.summary.playerOutcomes do
		if
			not table.isfrozen(outcome)
			or outcome.kind ~= "Player"
			or registrationCapabilities[outcome.registration :: table] == nil
		then
			return "stale-entity-slot-prepared-player-outcome"
		end
	end
	return nil
end

function EntitySlotService.Prepare(tokenValue: unknown): (PreparedCommit?, string?)
	local transaction, transactionError = getTransaction(tokenValue)
	if not transaction then
		return nil, transactionError
	end
	if transaction.prepared ~= nil or transaction.status ~= "Open" then
		return nil, "invalid-entity-slot-transaction-state"
	end
	local state, stateError = currentState()
	if not state then
		return nil, stateError
	end
	if transaction.rulesTransaction.baseRevision ~= state.revision then
		return nil, "stale-entity-slot-transaction-base"
	end

	local nextRegistrationsByPlayer = table.clone(registrationsByPlayer)
	local nextWorldRegistrationsBySourceOrder = table.clone(worldRegistrationsBySourceOrder)
	local nextWorldRegistrationsByBodyId = table.clone(worldRegistrationsByBodyId)
	local nextMapRegistrationsByEventId = table.clone(mapRegistrationsByEventId)
	local nextMapEventIdsByRegistration = cloneMapEventIdsByRegistration(mapEventIdsByRegistration)
	local mapRegistrationMembershipChanged = false
	local pendingPlayerReleaseSnapshot = table.clone(pendingPlayerReleases)
	table.freeze(pendingPlayerReleaseSnapshot)

	local mutations: { CapabilityMutation } = {}
	local mutationsByCapability: { [table]: CapabilityMutation } = {}
	local function planMutation(
		registration: Registration,
		registrationCapability: RegistrationCapability,
		nextStatus: RegistrationStatus
	)
		local existing = mutationsByCapability[registrationCapability]
		if existing then
			assert(
				existing.registration == registration,
				"registration capability identity drifted"
			)
			existing.nextStatus = nextStatus
			return
		end
		local mutation: CapabilityMutation = {
			registration = registration,
			capability = registrationCapability,
			expectedStatus = registrationCapability.status,
			expectedTransactionIdentity = registrationCapability.transactionIdentity,
			expectedReleaseStaged = registrationCapability.releaseStaged,
			nextStatus = nextStatus,
		}
		mutationsByCapability[registrationCapability] = mutation
		table.insert(mutations, mutation)
	end
	local function removeMapIndex(registration: Registration)
		local eventId = nextMapEventIdsByRegistration[registration :: table]
		if not eventId then
			return
		end
		local mapRegistration = nextMapRegistrationsByEventId[eventId]
		if mapRegistration and mapRegistration.registration == registration then
			nextMapRegistrationsByEventId[eventId] = nil
			mapRegistrationMembershipChanged = true
		end
		nextMapEventIdsByRegistration[registration :: table] = nil
	end

	-- Remove old generations before retaining a replacement that reused the
	-- same source order in this transaction. Every index root is built before
	-- the nested allocator is prepared, so ApplyPrepared only swaps roots.
	for _, entry in transaction.releases do
		local registrationCapability = entry.capability
		if
			EntitySourceOrderRules.InspectLease(
				transaction.rulesTransaction,
				registrationCapability.lease,
				"World"
			) == nil
		then
			removeMapIndex(entry.registration)
			if
				nextWorldRegistrationsBySourceOrder[registrationCapability.lease.sourceOrder]
				== entry.registration
			then
				nextWorldRegistrationsBySourceOrder[registrationCapability.lease.sourceOrder] = nil
			end
			if
				nextWorldRegistrationsByBodyId[registrationCapability.bodyId]
				== entry.registration
			then
				nextWorldRegistrationsByBodyId[registrationCapability.bodyId] = nil
			end
			planMutation(entry.registration, registrationCapability, "Released")
		else
			planMutation(entry.registration, registrationCapability, registrationCapability.status)
		end
	end
	for _, entry in transaction.playerReleases do
		local registrationCapability = entry.capability
		if
			EntitySourceOrderRules.InspectLease(
				transaction.rulesTransaction,
				registrationCapability.lease,
				"Client"
			) == nil
		then
			local player = registrationCapability.player
			if player and nextRegistrationsByPlayer[player] == entry.registration then
				nextRegistrationsByPlayer[player] = nil
			end
			planMutation(entry.registration, registrationCapability, "Released")
		else
			planMutation(entry.registration, registrationCapability, registrationCapability.status)
		end
	end
	for _, entry in transaction.provisional do
		local registrationCapability = entry.capability
		if
			EntitySourceOrderRules.InspectLease(
				transaction.rulesTransaction,
				registrationCapability.lease,
				"World"
			)
		then
			local sourceOrder = registrationCapability.lease.sourceOrder
			local existingBySourceOrder = nextWorldRegistrationsBySourceOrder[sourceOrder]
			local existingByBodyId = nextWorldRegistrationsByBodyId[registrationCapability.bodyId]
			if existingBySourceOrder and existingBySourceOrder ~= entry.registration then
				return nil, "prepared-world-source-order-collision"
			end
			if existingByBodyId and existingByBodyId ~= entry.registration then
				return nil, "prepared-world-body-id-collision"
			end
			nextWorldRegistrationsBySourceOrder[sourceOrder] = entry.registration
			nextWorldRegistrationsByBodyId[registrationCapability.bodyId] = entry.registration
			planMutation(entry.registration, registrationCapability, "Active")
		else
			planMutation(entry.registration, registrationCapability, "Released")
		end
	end
	for _, mutation in mutations do
		table.freeze(mutation)
	end
	table.freeze(mutations)

	local rulesPrepared, rulesPrepareError =
		EntitySourceOrderRules.Prepare(transaction.rulesTransaction)
	if not rulesPrepared then
		return nil, rulesPrepareError or "entity-slot-rules-prepare-failed"
	end
	if
		mapRegistrationMembershipChanged
		and mapRegistrationRevision >= MAXIMUM_MAP_REGISTRATION_REVISION
	then
		return nil, "map-registration-revision-exhausted"
	end
	local nextMapRegistrationRevision = mapRegistrationRevision
		+ (if mapRegistrationMembershipChanged then 1 else 0)
	local pendingReleaseCount = 0
	for _ in pendingPlayerReleaseSnapshot do
		pendingReleaseCount += 1
	end
	local receipt: CommitReceipt = {
		revision = state.revision + 1,
		nextBodyQueueIndex = transaction.nextBodyQueueIndex,
		pendingPlayerReleaseCount = pendingReleaseCount,
	}
	table.freeze(receipt)
	local worldOutcomes: { PreparedRegistrationOutcome } = {}
	local playerOutcomes: { PreparedRegistrationOutcome } = {}
	for _, mutation in mutations do
		local kind = mutation.capability.kind
		if kind == "World" or kind == "Player" then
			local outcome: PreparedRegistrationOutcome = {
				registration = mutation.registration,
				lease = mutation.capability.lease,
				kind = kind,
				status = if mutation.nextStatus == "Active" then "Retained" else "Released",
			}
			table.freeze(outcome)
			table.insert(if kind == "World" then worldOutcomes else playerOutcomes, outcome)
		end
	end
	table.freeze(worldOutcomes)
	table.freeze(playerOutcomes)
	local summary: PreparedCommitSummary = {
		revision = receipt.revision,
		stepTimeMilliseconds = transaction.stepTimeMilliseconds,
		nextBodyQueueIndex = receipt.nextBodyQueueIndex,
		worldOutcomes = worldOutcomes,
		playerOutcomes = playerOutcomes,
	}
	table.freeze(summary)
	local receiptCapability: CommitReceiptCapability = {
		receipt = receipt,
		summary = summary,
		status = "Pending",
		appliedState = nil,
	}
	local prepared: PreparedCommit = table.freeze({})
	preparedCapabilities[prepared] = {
		transaction = transaction,
		status = "Prepared",
		rulesPrepared = rulesPrepared,
		baseAuthoritativeState = state,
		baseNextBodyQueueIndex = nextBodyQueueIndex,
		baseRegistrationsByPlayer = registrationsByPlayer,
		baseWorldRegistrationsBySourceOrder = worldRegistrationsBySourceOrder,
		baseWorldRegistrationsByBodyId = worldRegistrationsByBodyId,
		baseMapRegistrationsByEventId = mapRegistrationsByEventId,
		baseMapEventIdsByRegistration = mapEventIdsByRegistration,
		baseMapRegistrationRevision = mapRegistrationRevision,
		basePendingPlayerReleases = pendingPlayerReleases,
		pendingPlayerReleaseSnapshot = pendingPlayerReleaseSnapshot,
		nextRegistrationsByPlayer = nextRegistrationsByPlayer,
		nextWorldRegistrationsBySourceOrder = nextWorldRegistrationsBySourceOrder,
		nextWorldRegistrationsByBodyId = nextWorldRegistrationsByBodyId,
		nextMapRegistrationsByEventId = nextMapRegistrationsByEventId,
		nextMapEventIdsByRegistration = nextMapEventIdsByRegistration,
		nextMapRegistrationRevision = nextMapRegistrationRevision,
		mutations = mutations,
		receipt = receipt,
		receiptCapability = receiptCapability,
		summary = summary,
		applyValidated = false,
	}
	commitReceiptCapabilities[receipt] = receiptCapability
	preparedSummaryCapabilities[summary] = prepared
	transaction.prepared = prepared
	transaction.status = "Prepared"
	return prepared, nil
end

function EntitySlotService.InspectPreparedCommitSummary(
	preparedValue: unknown
): PreparedCommitSummary?
	local capability = select(1, getPreparedCapability(preparedValue))
	if not capability or preparedCommitCurrentError(preparedValue, capability) then
		return nil
	end
	return capability.summary
end

function EntitySlotService.InspectPreparedCommitReceipt(preparedValue: unknown): CommitReceipt?
	local capability = select(1, getPreparedCapability(preparedValue))
	if not capability or preparedCommitCurrentError(preparedValue, capability) then
		return nil
	end
	return capability.receipt
end

-- This is the assignment-adjacency proof consumed by prepared participants
-- after EntitySlot applies. The receipt is allocated during Prepare but its
-- private status and exact applied state root are not armed until ApplyPrepared.
-- Beginning any later EntitySlot transaction retires the proof permanently.
function EntitySlotService.ValidateAppliedCommitDependency(
	receiptValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(receiptValue) ~= "table" or type(summaryValue) ~= "table" then
		return false, "invalid-applied-entity-slot-commit-dependency"
	end
	local receipt = receiptValue :: CommitReceipt
	local capability = commitReceiptCapabilities[receipt]
	if not capability or capability.receipt ~= receipt then
		return false, "invalid-applied-entity-slot-commit-receipt"
	end
	if capability.summary ~= summaryValue then
		return false, "forged-applied-entity-slot-commit-summary"
	end
	if capability.status ~= "Applied" or capability.appliedState == nil then
		return false, "entity-slot-commit-dependency-not-applied"
	end
	if
		currentAppliedCommitReceipt ~= receipt
		or activeTransaction ~= nil
		or authoritativeState ~= capability.appliedState
		or capability.appliedState.revision ~= receipt.revision
		or nextBodyQueueIndex ~= receipt.nextBodyQueueIndex
		or not table.isfrozen(receipt)
		or not table.isfrozen(capability.summary)
	then
		return false, "stale-applied-entity-slot-commit-dependency"
	end
	return true, nil
end

function EntitySlotService.ValidatePreparedCommitDependency(
	preparedValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	if type(summaryValue) ~= "table" then
		return false, "invalid-entity-slot-prepared-summary"
	end
	local capability, capabilityError = getPreparedCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	if
		capability.summary ~= summaryValue
		or preparedSummaryCapabilities[summaryValue :: PreparedCommitSummary] ~= preparedValue
	then
		return false, "forged-entity-slot-prepared-summary"
	end
	local currentError = preparedCommitCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	return true, nil
end

function EntitySlotService.ValidatePreparedWorldRegistrationOutcome(
	preparedValue: unknown,
	summaryValue: unknown,
	registrationValue: unknown,
	leaseValue: unknown,
	expectedStatusValue: unknown
): (boolean, string?)
	if expectedStatusValue ~= "Retained" and expectedStatusValue ~= "Released" then
		return false, "invalid-entity-slot-world-outcome-status"
	end
	local validDependency, dependencyError =
		EntitySlotService.ValidatePreparedCommitDependency(preparedValue, summaryValue)
	if not validDependency then
		return false, dependencyError
	end
	local capability = preparedCapabilities[preparedValue :: PreparedCommit]
	assert(capability, "validated EntitySlot prepared capability disappeared")
	for _, outcome in capability.summary.worldOutcomes do
		if outcome.registration == registrationValue and outcome.lease == leaseValue then
			if outcome.status ~= expectedStatusValue then
				return false, "entity-slot-world-outcome-status-mismatch"
			end
			return true, nil
		end
	end
	return false, "entity-slot-world-outcome-missing"
end

function EntitySlotService.CanApplyPrepared(preparedValue: unknown): (boolean, string?)
	local capability, capabilityError = getPreparedCapability(preparedValue)
	if not capability then
		return false, capabilityError
	end
	capability.applyValidated = false
	local currentError = preparedCommitCurrentError(preparedValue, capability)
	if currentError then
		return false, currentError
	end
	local rulesCanApply, rulesCanApplyError =
		EntitySourceOrderRules.CanApplyPrepared(capability.rulesPrepared)
	if not rulesCanApply then
		return false, rulesCanApplyError or "entity-slot-rules-preflight-failed"
	end
	capability.applyValidated = true
	return true, nil
end

-- All allocator state, cursor values, registration indexes, removals, and
-- registration-capability outcomes were constructed by Prepare. After the
-- fallible composite preflight, this phase only applies fixed assignments and
-- returns its already-frozen receipt. Pending departures are deliberately not
-- drained inside this authority boundary.
function EntitySlotService.ApplyPrepared(preparedValue: unknown): CommitReceipt
	local capability, capabilityError = getPreparedCapability(preparedValue)
	assert(capability, capabilityError or "invalid-entity-slot-prepared-commit")
	assert(capability.applyValidated, "entity-slot-prepared-commit-not-validated")
	local currentError = preparedCommitCurrentError(preparedValue, capability)
	assert(currentError == nil, currentError or "stale-entity-slot-prepared-commit")

	local transaction = capability.transaction
	local nextState = EntitySourceOrderRules.ApplyPrepared(capability.rulesPrepared)
	authoritativeState = nextState
	nextBodyQueueIndex = capability.receipt.nextBodyQueueIndex
	registrationsByPlayer = capability.nextRegistrationsByPlayer
	worldRegistrationsBySourceOrder = capability.nextWorldRegistrationsBySourceOrder
	worldRegistrationsByBodyId = capability.nextWorldRegistrationsByBodyId
	mapRegistrationsByEventId = capability.nextMapRegistrationsByEventId
	mapEventIdsByRegistration = capability.nextMapEventIdsByRegistration
	mapRegistrationRevision = capability.nextMapRegistrationRevision
	for _, mutation in capability.mutations do
		mutation.capability.status = mutation.nextStatus
		mutation.capability.transactionIdentity = nil
		mutation.capability.releaseStaged = false
	end
	transaction.status = "Applied"
	transaction.prepared = nil
	activeTransaction = nil
	capability.status = "Applied"
	capability.applyValidated = false
	capability.receiptCapability.status = "Applied"
	capability.receiptCapability.appliedState = nextState
	currentAppliedCommitReceipt = capability.receipt
	preparedSummaryCapabilities[capability.summary] = nil
	preparedCapabilities[preparedValue :: PreparedCommit] = nil
	return capability.receipt
end

function EntitySlotService.DrainPendingPlayerReleases(): (boolean, string?)
	if activeTransaction then
		return false, "entity-slot-transaction-active"
	end
	return drainPendingPlayerReleases()
end

function EntitySlotService.Commit(tokenValue: unknown): (boolean, string?)
	local prepared, prepareError = EntitySlotService.Prepare(tokenValue)
	if not prepared then
		EntitySlotService.Abort(tokenValue)
		return false, prepareError
	end
	local canApply, canApplyError = EntitySlotService.CanApplyPrepared(prepared)
	if not canApply then
		EntitySlotService.Abort(tokenValue)
		return false, canApplyError
	end
	EntitySlotService.ApplyPrepared(prepared)
	local drained, drainError = EntitySlotService.DrainPendingPlayerReleases()
	if not drained then
		warn(drainError or "post-commit-player-slot-release-failed")
	end
	return true, nil
end

function EntitySlotService.Abort(tokenValue: unknown): (boolean, string?)
	local transaction, transactionError = getTransaction(tokenValue, true)
	if not transaction then
		return false, transactionError
	end
	local prepared = transaction.prepared
	local preparedCapability = if prepared then preparedCapabilities[prepared] else nil
	local baseState, abortError = EntitySourceOrderRules.Abort(transaction.rulesTransaction)
	if not baseState then
		return false, abortError or "entity-slot-transaction-abort-failed"
	end
	authoritativeState = baseState
	for _, entry in transaction.provisional do
		local capability = entry.capability
		capability.status = "Aborted"
		capability.transactionIdentity = nil
		capability.releaseStaged = false
		releaseRetainedWorldRegistration(entry.registration, capability)
	end
	for _, entry in transaction.releases do
		entry.capability.releaseStaged = false
	end
	for _, entry in transaction.playerReleases do
		entry.capability.releaseStaged = false
	end
	if prepared then
		if preparedCapability then
			preparedCapability.status = "Aborted"
			preparedCapability.applyValidated = false
			preparedCapability.receiptCapability.status = "Aborted"
			preparedCapability.receiptCapability.appliedState = nil
			preparedSummaryCapabilities[preparedCapability.summary] = nil
		end
		preparedCapabilities[prepared] = nil
		transaction.prepared = nil
	end
	transaction.status = "Aborted"
	activeTransaction = nil
	local drained, drainError = drainPendingPlayerReleases()
	if not drained then
		warn(drainError or "post-abort-player-slot-release-failed")
	end
	return true, nil
end

function EntitySlotService.GetDebugSnapshot(): DebugSnapshot
	local state = select(1, currentState())
	local transaction = activeTransaction
	local preparedCapability = if transaction and transaction.prepared
		then preparedCapabilities[transaction.prepared]
		else nil
	local snapshot: DebugSnapshot = {
		started = state ~= nil,
		playerReleaseLifecycleSealed = playerReleaseLifecycleSealed,
		revision = if state then state.revision else 0,
		mapRegistrationRevision = mapRegistrationRevision,
		levelTimeMilliseconds = if state then state.levelTimeMilliseconds else 0,
		highestWorldSourceOrder = if state then state.highestWorldSourceOrder else 0,
		activeClientCount = if state then state.activeClientCount else 0,
		activeWorldCount = if state then state.activeWorldCount else 0,
		registeredPlayerCount = countRegisteredPlayers(),
		registeredWorldCount = countRegisteredWorldEntities(),
		mapSpawnPlanInstalled = mapSpawnPlanInstalled,
		mapRegistrationCount = countMapRegistrations(),
		bodyQueueCount = #bodyQueueRegistrations,
		nextBodyQueueIndex = if transaction
			then transaction.nextBodyQueueIndex
			else nextBodyQueueIndex,
		bodyQueueCursorOwnerClaimed = bodyQueueCursorOwner ~= nil,
		pendingPlayerReleaseCount = countPendingPlayerReleases(),
		transactionOpen = transaction ~= nil,
		transactionStatus = if transaction then transaction.status else nil,
		transactionGeneration = if transaction
			then transaction.rulesTransaction.generation
			else nil,
		transactionApplyValidated = if preparedCapability
			then preparedCapability.applyValidated
			else false,
		transactionPreparedRevision = if preparedCapability
			then preparedCapability.receipt.revision
			else nil,
	}
	return table.freeze(snapshot)
end

function EntitySlotService.IsStarted(): boolean
	return started
end

return table.freeze(EntitySlotService)
