--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-only PM_DEAD trace and immediate post-Pmove capture orchestration.
Source mapping:
  code/game/g_active.c (PM_DEAD trace mask and post-Pmove entity conversion)
  code/game/bg_pmove.c (PmoveSingle / PM_DeadMove)
  code/game/bg_misc.c (BG_PlayerStateToEntityState)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local simulation = ReplicatedStorage:WaitForChild("Q3Engine"):WaitForChild("simulation")
local Constants = require(simulation:WaitForChild("Constants"))
local DeadPmoveTraceComposition = require(simulation:WaitForChild("DeadPmoveTraceComposition"))
local Movement = require(simulation:WaitForChild("Movement"))
local MoverConsequenceRules = require(simulation:WaitForChild("MoverConsequenceRules"))
local MoverPushRules = require(simulation:WaitForChild("MoverPushRules"))
local PersistentStaticSolidDomain = require(simulation:WaitForChild("PersistentStaticSolidDomain"))
local PlayerClipDomain = require(simulation:WaitForChild("PlayerClipDomain"))
local WorldBodyTrace = require(simulation:WaitForChild("WorldBodyTrace"))
local CorpseService = require(script.Parent.CorpseService)
local EntitySlotService = require(script.Parent.EntitySlotService)
local PostPmoveCorpseSourceService = require(script.Parent.PostPmoveCorpseSourceService)

local MovementDeadRuntime = {}

export type Runtime = {
	deadWorldDomain: WorldBodyTrace.Domain,
}

export type StepRequest = {
	deadState: Movement.DeadState,
	command: Movement.Command,
	deltaTime: number,
	pointContents: Movement.PointContentsFunction,
	movementRevision: number,
	commandSequence: number,
	lifeSequence: number,
	moverClockRevision: number,
	moverClockStep: number,
	moverTimeMilliseconds: number,
}

local BODY_QUEUE_TRACE_QUERY: Movement.DeadTraceQuery = table.freeze({
	collisionMode = "PlayerSolidWithoutBodies",
	excludesBodies = true,
	colliderSize = Constants.DeadColliderSize,
	colliderCenterOffset = Constants.DeadColliderCenterOffset,
})

function MovementDeadRuntime.new(
	staticSolidDomain: PersistentStaticSolidDomain.Domain,
	playerClipDomain: PlayerClipDomain.Domain
): Runtime
	local domain, exact = WorldBodyTrace.CreatePlayerMovement(staticSolidDomain, playerClipDomain)
	assert(domain and exact, "Exact dead-player static body trace is unavailable")
	return {
		deadWorldDomain = domain,
	}
end

local function commitPostPmoveCorpsePose(player: Player, state: Movement.State)
	local token, beginError = CorpseService.Begin()
	assert(token, beginError or "dead Pmove corpse transaction unavailable")
	local function abortWith(message: string): never
		assert(CorpseService.Abort(token), "dead Pmove corpse transaction did not abort")
		error(message)
	end
	local collection, collectionError = CorpseService.Collect(token)
	if not collection then
		abortWith(collectionError or "dead Pmove corpse collection unavailable")
	end
	local corpseBody = nil
	local invisiblePoseStaged = false
	for _, body in collection.bodies do
		if collection.playersByBodyId[body.id] == player then
			corpseBody = body
			break
		end
	end
	if not corpseBody then
		if CorpseService.IsCurrentInvisibleClient(player) then
			-- The opaque service owns the exact body identity; use the current
			-- Movement player entity identity and canonical corpse hull for its pose.
			local registration = EntitySlotService.GetPlayerRegistration(player)
			assert(registration, "invisible dead-client registration unavailable")
			local staged, stageError = CorpseService.StagePostPmoveInvisiblePose(token, player, {
				id = registration.bodyId,
				sourceOrder = registration.sourceOrder,
				position = state.position,
				size = MoverConsequenceRules.ClientCorpseSize,
				centerOffset = MoverConsequenceRules.ClientCorpseCenterOffset,
				velocity = state.velocity,
				groundMoverId = state.groundMoverId,
				contents = MoverPushRules.Contents.Corpse,
				clipMask = MoverPushRules.Masks.PlayerSolid,
			})
			if not staged then
				abortWith(stageError or "invisible dead-client pose rejected")
			end
			invisiblePoseStaged = true
		else
			abortWith("dead Pmove committed corpse unavailable:" .. tostring(player.UserId))
		end
	end
	local binding = corpseBody and CorpseService.GetBinding(token, player, corpseBody.id) or nil
	if invisiblePoseStaged then
		local stagedCollection = assert(CorpseService.Collect(token))
		assert(CorpseService.ApplyMoverBodies(token, stagedCollection.bodies))
		assert(CorpseService.Seal(token))
		assert(CorpseService.Commit(token))
		return
	end
	if not binding then
		abortWith("dead Pmove corpse binding unavailable")
	end
	local stagedBody, stageError = CorpseService.StagePostPmoveCorpsePose(token, player, binding, {
		id = corpseBody.id,
		sourceOrder = corpseBody.sourceOrder,
		position = state.position,
		size = corpseBody.size,
		centerOffset = corpseBody.centerOffset,
		velocity = state.velocity,
		groundMoverId = state.groundMoverId,
		contents = corpseBody.contents,
		clipMask = corpseBody.clipMask,
	})
	if not stagedBody then
		abortWith(stageError or "dead Pmove corpse pose rejected")
	end
	local stagedCollection, stagedCollectionError = CorpseService.Collect(token)
	if not stagedCollection then
		abortWith(stagedCollectionError or "dead Pmove staged corpse collection unavailable")
	end
	local bodiesApplied, bodiesError = CorpseService.ApplyMoverBodies(token, stagedCollection.bodies)
	if not bodiesApplied then
		abortWith(bodiesError or "dead Pmove corpse bodies did not apply")
	end
	local sealed, sealError = CorpseService.Seal(token)
	if not sealed then
		abortWith(sealError or "dead Pmove corpse transaction did not seal")
	end
	local committed, commitError = CorpseService.Commit(token)
	if not committed then
		CorpseService.Abort(token)
		error(commitError or "dead Pmove corpse transaction did not commit")
	end
end

function MovementDeadRuntime.Step(
	runtime: Runtime,
	frame: unknown,
	player: Player,
	request: StepRequest
): (
	Movement.DeadState,
	Movement.DeadStepEffects,
	PostPmoveCorpseSourceService.PostPmoveCapture,
	PostPmoveCorpseSourceService.PostPmoveCaptureSummary
)
	local queries, queriesError =
		DeadPmoveTraceComposition.Create(frame, runtime.deadWorldDomain, request.pointContents)
	assert(queries, queriesError or "failed to bind dead Pmove trace")
	local nextDeadState, effects =
		Movement.stepDead(request.deadState, request.command, request.deltaTime, queries.trace, queries.pointContents)
	table.freeze(nextDeadState)
	local state = nextDeadState.state
	commitPostPmoveCorpsePose(player, state)
	local capture, captureSummary, captureError = PostPmoveCorpseSourceService.CapturePostPmove(player, {
		movementRevision = request.movementRevision,
		commandSequence = request.commandSequence,
		lifeSequence = request.lifeSequence,
		moverClockRevision = request.moverClockRevision,
		moverClockStep = request.moverClockStep,
		moverTimeMilliseconds = request.moverTimeMilliseconds,
		position = state.position,
		entityTrajectoryDelta = state.velocity,
		grounded = state.grounded,
		groundMoverId = state.groundMoverId,
	})
	assert(capture and captureSummary, captureError or "dead Pmove capture failed")
	return nextDeadState, effects, capture, captureSummary
end

function MovementDeadRuntime.TraceBodyQueue(
	runtime: Runtime,
	frame: unknown,
	origin: Vector3,
	displacement: Vector3
): Movement.TraceResult
	local queries, queriesError = DeadPmoveTraceComposition.Create(frame, runtime.deadWorldDomain, function()
		return 0
	end)
	assert(queries, queriesError or "failed to bind body-queue trace")
	return queries.trace(origin, displacement, BODY_QUEUE_TRACE_QUERY)
end

return table.freeze(MovementDeadRuntime)
