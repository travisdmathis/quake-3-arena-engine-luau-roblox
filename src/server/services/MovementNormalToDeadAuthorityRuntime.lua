--[[
SPDX-License-Identifier: GPL-2.0-or-later

Assignment-only Normal-to-Dead authority translated from:
  code/game/g_combat.c (G_Damage and player_die record mutation)
  code/game/bg_misc.c (BG_PlayerStateToEntityState projection ownership)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-13.
]]

--!strict

local MovementNormalToDeadAuthorityRuntime = {}

export type Runtime = {
	RetireAppliedReceipt: (record: any) -> (),
	RetirePrepared: (capability: any) -> (),
	RetirePreparedBatch: (capability: any) -> (),
	ApplyPrepared: (capability: any) -> (),
	ApplyPreparedBatch: (capability: any) -> (),
	Invalidate: (record: any) -> (),
}

function MovementNormalToDeadAuthorityRuntime.new(registry: any): Runtime
	local runtime = {} :: any

	function runtime.RetireAppliedReceipt(record: any)
		local receipt = registry:GetAppliedReceiptForRecord(record)
		if not receipt then
			return
		end
		local receiptCapability = registry:GetReceiptCapability(receipt)
		if receiptCapability and receiptCapability.receipt == receipt then
			receiptCapability.status = "Retired"
		end
		registry:SetAppliedReceiptForRecord(record, nil)
	end

	function runtime.RetirePrepared(capability: any)
		capability.status = "Aborted"
		capability.applyValidated = false
		capability.batchOwner = nil
		capability.receiptCapability.status = "Retired"
		registry:RetirePreparedSummary(capability.prepared, capability.summary)
		if registry:GetActiveForRecord(capability.record) == capability.prepared then
			registry:SetActiveForRecord(capability.record, nil)
		end
		if registry:GetPreparedForSummary(capability.summary) == capability.prepared then
			registry:SetPreparedForSummary(capability.summary, nil)
		end
		if registry:GetPreparedCapability(capability.prepared) == capability then
			registry:SetPreparedCapability(capability.prepared, nil)
		end
	end

	function runtime.RetirePreparedBatch(capability: any)
		capability.status = "Aborted"
		capability.applyValidated = false
		capability.receiptCapability.status = "Retired"
		for index = 1, #capability.entries do
			runtime.RetirePrepared(capability.entries[index].preparedCapability)
		end
		if capability.outerMoverOwner then
			registry:SetMoverStepForBatch(capability.prepared, nil)
			capability.outerMoverOwner = nil
		end
		if registry:GetActiveBatch() == capability.prepared then
			registry:SetActiveBatch(nil)
		end
		if registry:GetBatchForSummary(capability.summary) == capability.prepared then
			registry:SetBatchForSummary(capability.summary, nil)
		end
		if registry:GetBatchCapability(capability.prepared) == capability then
			registry:SetBatchCapability(capability.prepared, nil)
		end
	end

	-- Prepare allocated and froze every next value. No fallible work is admitted
	-- after this function's first record assignment.
	function runtime.ApplyPrepared(capability: any)
		capability.record.state = capability.nextState
		capability.record.entityTrajectoryBase = capability.nextEntityTrajectoryBase
		capability.record.entityTrajectoryDelta = capability.nextEntityTrajectoryDelta
		capability.record.entityAngularTrajectoryBase = capability.nextEntityAngularTrajectoryBase
		capability.record.entityGenericAngles = capability.deathTransition.deathGenericAngles
		capability.record.playerStateViewAngles = capability.deathTransition.playerStateViewAngles
		capability.record.deadState = capability.deadState
		capability.record.deathTransition = capability.deathTransition
		capability.record.firstDeadStepPhase = capability.firstDeadStepPhase
		capability.record.spawnReserved = false
		capability.status = "Applied"
		capability.applyValidated = false
		capability.batchOwner = nil
		capability.receiptCapability.status = "Applied"
		registry:SetActiveForRecord(capability.record, nil)
		registry:SetPreparedForSummary(capability.summary, nil)
		registry:SetPreparedCapability(capability.prepared, nil)
		registry:SetAppliedReceiptForRecord(capability.record, capability.receipt)
	end

	function runtime.ApplyPreparedBatch(capability: any)
		for index = 1, #capability.entries do
			runtime.ApplyPrepared(capability.entries[index].preparedCapability)
		end
		capability.status = "Applied"
		capability.applyValidated = false
		capability.outerMoverOwner = nil
		capability.receiptCapability.status = "Applied"
		registry:SetActiveBatch(nil)
		registry:SetBatchForSummary(capability.summary, nil)
		registry:SetBatchCapability(capability.prepared, nil)
	end

	function runtime.Invalidate(record: any)
		local prepared = registry:GetActiveForRecord(record)
		if prepared then
			local capability = registry:GetPreparedCapability(prepared)
			if capability and capability.prepared == prepared and capability.status == "Prepared" then
				local batch = capability.batchOwner
				local batchCapability = if batch then registry:GetBatchCapability(batch) else nil
				if batchCapability and batchCapability.prepared == batch and batchCapability.status == "Prepared" then
					runtime.RetirePreparedBatch(batchCapability)
				else
					runtime.RetirePrepared(capability)
				end
			end
			registry:SetActiveForRecord(record, nil)
		end
		runtime.RetireAppliedReceipt(record)
	end

	return table.freeze(runtime) :: Runtime
end

return table.freeze(MovementNormalToDeadAuthorityRuntime)
