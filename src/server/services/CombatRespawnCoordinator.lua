--[[
SPDX-License-Identifier: GPL-2.0-or-later

Prepared CopyToBodyQue transaction translated from:
  code/game/g_active.c (strict respawn gate)
  code/game/g_client.c (respawn -> CopyToBodyQue before ClientSpawn)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local BodyQueueService = require(script.Parent.BodyQueueService)
local CorpseService = require(script.Parent.CorpseService)
local PostPmoveCorpseSourceService = require(script.Parent.PostPmoveCorpseSourceService)

local CombatRespawnCoordinator = {}

export type Request = {
	deathHandle: unknown,
	corpseTombstone: CorpseService.RespawnCopyTombstone,
	lineage: {
		matchId: string,
		matchLineage: unknown,
		playerBodyId: string,
		playerSourceOrder: number,
		playerLeaseGeneration: number,
		playerUserId: number,
		lifeSequence: number,
	},
	postPmoveCapture: unknown,
	postPmoveCaptureSummary: unknown,
	playerStateVelocity: Vector3,
	pointContents: (Vector3) -> number,
	nowMilliseconds: number,
	attackPressed: boolean,
	useHoldablePressed: boolean,
	forceRespawnSeconds: number,
}

export type Result = {
	respawnKind: string,
	bodyCopyKind: string,
	entityLifecycleDrained: boolean,
	sink: BodyQueueService.SinkDiagnostic?,
}

local function abortGate(gate: unknown?)
	if gate ~= nil then
		BodyQueueService.AbortAcceptedRespawnGate(gate)
	end
end

function CombatRespawnCoordinator.Execute(request: Request): (Result?, string?)
	local captureValid, captureError = PostPmoveCorpseSourceService.ValidatePostPmoveCaptureDependency(
		request.postPmoveCapture,
		request.postPmoveCaptureSummary
	)
	if not captureValid then
		return nil, captureError or "respawn-post-pmove-capture-invalid"
	end
	local gate, decision, gateError = BodyQueueService.EvaluateRespawn(request.deathHandle, {
		nowMilliseconds = request.nowMilliseconds,
		attackPressed = request.attackPressed,
		useHoldablePressed = request.useHoldablePressed,
		forceRespawnSeconds = request.forceRespawnSeconds,
	})
	if not gate or not decision then
		return nil, gateError or "respawn-gate-not-accepted"
	end
	local corpsePrepared, corpsePrepareError =
		CorpseService.PrepareRespawnCopyTombstoneConsume(request.corpseTombstone, request.lineage)
	if not corpsePrepared then
		abortGate(gate)
		return nil, corpsePrepareError or "respawn-corpse-consume-prepare-failed"
	end
	local corpseSource = CorpseService.InspectPreparedRespawnCopyTombstoneConsumeSource(corpsePrepared)
	if not corpseSource then
		CorpseService.AbortPreparedRespawnCopyTombstoneConsume(corpsePrepared)
		abortGate(gate)
		return nil, "respawn-corpse-source-unavailable"
	end
	local sourcePrepared, source, sourcePrepareError = PostPmoveCorpseSourceService.PrepareRespawnGate(
		request.postPmoveCapture,
		corpsePrepared,
		corpseSource,
		request.playerStateVelocity,
		request.pointContents
	)
	if not sourcePrepared or not source then
		CorpseService.AbortPreparedRespawnCopyTombstoneConsume(corpsePrepared)
		abortGate(gate)
		return nil, sourcePrepareError or "respawn-post-pmove-source-prepare-failed"
	end
	local bodyToken, stageDiagnostic, bodyStageError = BodyQueueService.StageRespawn(
		gate,
		if source.noDrop then { noDrop = true } else { noDrop = false, copySource = source.copySource }
	)
	if not bodyToken or not stageDiagnostic then
		abortGate(gate)
		PostPmoveCorpseSourceService.AbortPrepared(sourcePrepared)
		CorpseService.AbortPreparedRespawnCopyTombstoneConsume(corpsePrepared)
		return nil, bodyStageError or "respawn-body-queue-stage-failed"
	end
	gate = nil
	local bodyPrepared, bodyPrepareError = BodyQueueService.Prepare(bodyToken)
	if not bodyPrepared then
		PostPmoveCorpseSourceService.AbortPrepared(sourcePrepared)
		CorpseService.AbortPreparedRespawnCopyTombstoneConsume(corpsePrepared)
		return nil, bodyPrepareError or "respawn-body-queue-prepare-failed"
	end
	for _pass = 1, 2 do
		local bodyReady, bodyError = BodyQueueService.CanApplyPrepared(bodyPrepared)
		local sourceReady, sourceError = PostPmoveCorpseSourceService.CanApplyPrepared(sourcePrepared)
		local corpseReady, corpseError = CorpseService.CanApplyPreparedRespawnCopyTombstoneConsume(corpsePrepared)
		if not bodyReady or not sourceReady or not corpseReady then
			BodyQueueService.Abort(bodyToken)
			PostPmoveCorpseSourceService.AbortPrepared(sourcePrepared)
			CorpseService.AbortPreparedRespawnCopyTombstoneConsume(corpsePrepared)
			return nil, bodyError or sourceError or corpseError or "respawn-composite-preflight-failed"
		end
	end
	local entityReceipt, applyDiagnostic = BodyQueueService.ApplyPrepared(bodyPrepared)
	PostPmoveCorpseSourceService.ApplyPrepared(sourcePrepared)
	CorpseService.ApplyPreparedRespawnCopyTombstoneConsume(corpsePrepared)
	local lifecycleDrained = false
	if entityReceipt ~= nil then
		local drained, drainError = BodyQueueService.DrainEntitySlotLifecycleAfterCommit()
		assert(drained, drainError or "respawn body-queue lifecycle drain failed")
		lifecycleDrained = true
	end
	local result: Result = {
		respawnKind = decision.kind,
		bodyCopyKind = applyDiagnostic.kind,
		entityLifecycleDrained = lifecycleDrained,
		sink = applyDiagnostic.sink,
	}
	table.freeze(result)
	return result, nil
end

return table.freeze(CombatRespawnCoordinator)
