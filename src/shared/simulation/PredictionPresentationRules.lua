--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure acknowledgement rules shared by deterministic prediction probes and the
live client presentation layer.
]]

--!strict

local CommandSequence = require(script.Parent.CommandSequence)

export type PredictedTeleport = {
	sourceRevision: number,
	commandSequence: number,
	triggerId: number,
	look: Vector3,
}

export type TeleportAction = "ConfirmPrediction" | "QueueAuthoritative" | "Clear"

local TeleportAction = table.freeze({
	ConfirmPrediction = "ConfirmPrediction" :: "ConfirmPrediction",
	QueueAuthoritative = "QueueAuthoritative" :: "QueueAuthoritative",
	Clear = "Clear" :: "Clear",
})

local PredictionPresentationRules = {
	TeleportAction = TeleportAction,
}

function PredictionPresentationRules.ResolveTeleportAction(
	predicted: PredictedTeleport?,
	currentRevision: number,
	snapshotRevision: number,
	ackSequence: number,
	teleportTriggerId: number?,
	teleportLook: Vector3?
): TeleportAction
	if teleportTriggerId == nil or teleportLook == nil then
		return TeleportAction.Clear
	end

	local lookMagnitude = teleportLook.Magnitude
	local confirmsPrediction = predicted ~= nil
		and currentRevision == predicted.sourceRevision
		and snapshotRevision == predicted.sourceRevision + 1
		and teleportTriggerId == predicted.triggerId
		and lookMagnitude > 1e-6
		and teleportLook.Unit:Dot(predicted.look.Unit) > 1 - 1e-6
		and CommandSequence.IsAtOrBefore(predicted.commandSequence, ackSequence)
	return if confirmsPrediction then TeleportAction.ConfirmPrediction else TeleportAction.QueueAuthoritative
end

function PredictionPresentationRules.ShouldStartLanding(
	existingOffsetStuds: number?,
	incomingOffsetStuds: number
): boolean
	return existingOffsetStuds == nil or math.abs((existingOffsetStuds :: number) - incomingOffsetStuds) > 1e-6
end

function PredictionPresentationRules.ShouldClearRejectedTeleport(
	predicted: PredictedTeleport?,
	currentRevision: number,
	snapshotRevision: number,
	ackSequence: number,
	teleportTriggerId: number?,
	teleportLook: Vector3?
): boolean
	return predicted ~= nil
		and currentRevision == predicted.sourceRevision
		and snapshotRevision == predicted.sourceRevision
		and teleportTriggerId == nil
		and teleportLook == nil
		and CommandSequence.IsAtOrBefore(predicted.commandSequence, ackSequence)
end

function PredictionPresentationRules.CanStartPredictedTeleport(
	predicted: PredictedTeleport?,
	currentRevision: number
): boolean
	return predicted == nil or predicted.sourceRevision ~= currentRevision
end

return table.freeze(PredictionPresentationRules)
