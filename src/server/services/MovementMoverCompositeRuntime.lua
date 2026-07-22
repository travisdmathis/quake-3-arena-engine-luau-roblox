--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-only multi-owner mover commit orchestration translated from Quake III
Arena:
  code/game/g_mover.c (G_MoverPush, G_MoverTeam, blocked rollback)
  code/game/g_main.c (synchronous G_RunFrame publication barrier)

The host retains every authority root. This module only orders already narrow
prepared-owner APIs so all fallible work and two complete currentness passes
finish before the first assignment-only apply.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-13.
]]

--!strict

export type DamageAdapter = {
	Prepare: (token: unknown) -> (unknown?, unknown?, string?),
	InspectPreparedMovementDependency: (prepared: unknown) -> unknown?,
	CanApplyPrepared: (prepared: unknown) -> (boolean, string?),
	ApplyPrepared: (prepared: unknown) -> unknown,
	Abort: (token: unknown) -> boolean,
}

export type ParticipantAdapter = {
	CanApply: (prepared: unknown) -> (boolean, string?),
	Apply: (prepared: unknown) -> unknown,
	Abort: (prepared: unknown) -> boolean,
}

export type BodyQueueAdapter = ParticipantAdapter

export type Host = {
	prepareMovement: (stepServerTime: number) -> (unknown?, string?),
	getDamageToken: (prepared: unknown) -> unknown?,
	getParticipantPrepared: (prepared: unknown) -> unknown?,
	getBodyQueuePrepared: (prepared: unknown) -> unknown?,
	bindCombatDependency: (
		prepared: unknown,
		combatPrepared: unknown,
		summary: unknown
	) -> (boolean, string?),
	canApplyMovement: (prepared: unknown) -> (boolean, string?),
	applyMovement: (prepared: unknown) -> unknown,
	abortMovement: (prepared: unknown) -> boolean,
	clearActiveDamageToken: () -> (),
	damageAdapter: DamageAdapter?,
	participantAdapter: ParticipantAdapter?,
	bodyQueueAdapter: BodyQueueAdapter?,
}

local MovementMoverCompositeRuntime = {}

local function abortPreparedMoverComposite(
	host: Host,
	prepared: unknown,
	damageToken: unknown?
): boolean
	local participantPrepared = host.getParticipantPrepared(prepared)
	local bodyQueuePrepared = host.getBodyQueuePrepared(prepared)
	local movementAborted = host.abortMovement(prepared)
	local damageAborted = true
	if damageToken ~= nil then
		local adapter = assert(host.damageAdapter, "prepared mover damage adapter disappeared")
		damageAborted = adapter.Abort(damageToken)
		if damageAborted then
			host.clearActiveDamageToken()
		end
	end
	local participantAborted = true
	if participantPrepared ~= nil then
		participantAborted = (assert(
			host.participantAdapter,
			"prepared mover participant adapter disappeared"
		)).Abort(participantPrepared)
	end
	local bodyQueueAborted = true
	if bodyQueuePrepared ~= nil then
		bodyQueueAborted = (assert(
			host.bodyQueueAdapter,
			"prepared BodyQueue mover adapter disappeared"
		)).Abort(bodyQueuePrepared)
	end
	return movementAborted and damageAborted and participantAborted and bodyQueueAborted
end

function MovementMoverCompositeRuntime.Run(
	stepServerTime: number,
	host: Host
): (unknown, unknown?, unknown?, unknown?)
	local prepared, prepareError = host.prepareMovement(stepServerTime)
	assert(prepared, prepareError or "authoritative mover step could not prepare")
	local damageToken = host.getDamageToken(prepared)
	local adapter = host.damageAdapter
	local combatPrepared: unknown? = nil
	local participantPrepared = host.getParticipantPrepared(prepared)
	local participantAdapter = host.participantAdapter
	local bodyQueuePrepared = host.getBodyQueuePrepared(prepared)
	local bodyQueueAdapter = host.bodyQueueAdapter
	if damageToken ~= nil then
		local requiredAdapter = assert(adapter, "prepared mover damage adapter disappeared")
		local preparedCombat, _matchSummary, combatPrepareError =
			requiredAdapter.Prepare(damageToken)
		if not preparedCombat then
			abortPreparedMoverComposite(host, prepared, damageToken)
			error(combatPrepareError or "mover Combat participant could not prepare")
		end
		combatPrepared = preparedCombat
		local movementSummary = requiredAdapter.InspectPreparedMovementDependency(preparedCombat)
		if movementSummary == nil then
			abortPreparedMoverComposite(host, prepared, damageToken)
			error("mover Combat participant omitted its Movement dependency")
		end
		local bound, bindError =
			host.bindCombatDependency(prepared, preparedCombat, movementSummary)
		if not bound then
			abortPreparedMoverComposite(host, prepared, damageToken)
			error(bindError or "mover Combat-Movement dependency could not bind")
		end
	end

	-- The final Movement -> Combat pass is immediately adjacent to the first
	-- authority apply, so all participants remain armed/current without a yield.
	for _preflightPass = 1, 2 do
		local movementCanApply, movementCanApplyError = host.canApplyMovement(prepared)
		if not movementCanApply then
			abortPreparedMoverComposite(host, prepared, damageToken)
			error(movementCanApplyError or "mover Movement participant failed preflight")
		end
		if combatPrepared ~= nil then
			local requiredAdapter = assert(adapter, "prepared mover damage adapter disappeared")
			local combatCanApply, combatCanApplyError =
				requiredAdapter.CanApplyPrepared(combatPrepared)
			if not combatCanApply then
				abortPreparedMoverComposite(host, prepared, damageToken)
				error(combatCanApplyError or "mover Combat participant failed preflight")
			end
		end
		if participantPrepared ~= nil then
			local requiredParticipantAdapter =
				assert(participantAdapter, "prepared mover participant adapter disappeared")
			local participantCanApply, participantCanApplyError =
				requiredParticipantAdapter.CanApply(participantPrepared)
			if not participantCanApply then
				abortPreparedMoverComposite(host, prepared, damageToken)
				error(participantCanApplyError or "mover Item participant failed preflight")
			end
		end
		if bodyQueuePrepared ~= nil then
			local requiredBodyQueueAdapter =
				assert(bodyQueueAdapter, "prepared BodyQueue mover adapter disappeared")
			local bodyQueueCanApply, bodyQueueCanApplyError =
				requiredBodyQueueAdapter.CanApply(bodyQueuePrepared)
			if not bodyQueueCanApply then
				abortPreparedMoverComposite(host, prepared, damageToken)
				error(bodyQueueCanApplyError or "mover BodyQueue participant failed preflight")
			end
		end
	end

	local movementReceipt = host.applyMovement(prepared)
	local combatReceipt: unknown? = nil
	if combatPrepared ~= nil then
		combatReceipt = (assert(adapter, "prepared mover damage adapter disappeared")).ApplyPrepared(
			combatPrepared
		)
		host.clearActiveDamageToken()
	end
	local participantReceipt: unknown? = nil
	if participantPrepared ~= nil then
		participantReceipt = (assert(
			participantAdapter,
			"prepared mover participant adapter disappeared"
		)).Apply(participantPrepared)
	end
	local bodyQueueReceipt: unknown? = nil
	if bodyQueuePrepared ~= nil then
		bodyQueueReceipt = (
			assert(bodyQueueAdapter, "prepared BodyQueue mover adapter disappeared")
		).Apply(bodyQueuePrepared)
	end
	return movementReceipt, combatReceipt, participantReceipt, bodyQueueReceipt
end

return table.freeze(MovementMoverCompositeRuntime)
