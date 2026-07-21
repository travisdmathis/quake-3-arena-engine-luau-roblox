--[[
SPDX-License-Identifier: GPL-2.0-or-later

Pure authority-close and deferred-publication state machine translated from
Quake III Arena's frame boundary:
  code/game/g_main.c (G_RunFrame entity traversal, ClientEndFrame, and the
    post-client CheckTournament/CheckExitRules phase)
  code/qcommon/common.c (Com_Error ERR_DROP and abortframe longjmp)
  code/server/sv_main.c (GAME_RUN_FRAME before SV_SendClientMessages)

Q3 mutates authoritative game state synchronously during one G_RunFrame. A
fatal error stops that frame/server path; the game VM has no general rollback
of mutations that already ran. the Roblox Luau port must additionally prevent Remote,
Instance, and observer publication from escaping before the authority close.
This module therefore queues immutable publication descriptors while authority
is open, discards them on a terminal pre-close fault without claiming rollback,
and permits one ordered flush only after one successful close.

Publication execution is deliberately outside this pure module. A caller may
catch a post-commit publication error, record its bounded diagnostic, and keep
flushing later descriptors. Such a failure can never undo committed authority.
Opaque single-use capabilities reject forged, stale, duplicate, and regressed
transitions.

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local FramePublicationCloseRules = {}

export type Lineage = {}
export type OpenFrame = {}
export type FaultedFrame = {}
export type CommittedFrame = {}
export type FlushCursor = {}
export type PublicationAttempt = {}

export type PublicationValue = { [unknown]: unknown }
export type PublicationDescriptor = {
	read order: number,
	read value: PublicationValue,
}

export type OpenSummary = {
	read lineage: Lineage,
	read frameOrder: number,
	read revision: number,
	read authorityOperationCount: number,
	read queuedPublicationCount: number,
	read lastDeterministicOrder: number,
}

export type FaultSummary = {
	read lineage: Lineage,
	read frameOrder: number,
	read revision: number,
	read faultOrder: number,
	read diagnostic: string,
	read authorityOperationCount: number,
	read discardedPublicationCount: number,
	read closeCommitted: false,
	read authorityRolledBack: false,
}

export type CommitSummary = {
	read lineage: Lineage,
	read frameOrder: number,
	read revision: number,
	read closeOrder: number,
	read authorityOperationCount: number,
	read publicationCount: number,
	read publications: { PublicationDescriptor },
	read closeCommitted: true,
	read authorityRolledBack: false,
}

export type FlushSummary = {
	read lineage: Lineage,
	read frameOrder: number,
	read revision: number,
	read publicationCount: number,
	read attemptedCount: number,
	read succeededCount: number,
	read failedCount: number,
	read nextPublicationOrder: number?,
	read closeCommitted: true,
	read authorityRolledBack: false,
}

export type PublicationAttemptSummary = {
	read lineage: Lineage,
	read frameOrder: number,
	read ordinal: number,
	read descriptor: PublicationDescriptor,
}

export type PublicationFailure = {
	read ordinal: number,
	read order: number,
	read descriptor: PublicationDescriptor,
	read diagnostic: string,
}

export type PublicationReport = {
	read lineage: Lineage,
	read frameOrder: number,
	read commit: CommitSummary,
	read publicationCount: number,
	read attemptedCount: number,
	read succeededCount: number,
	read failedCount: number,
	read failures: { PublicationFailure },
	read closeCommitted: true,
	read authorityRolledBack: false,
}

type OpenCapability = {
	frame: OpenFrame,
	current: boolean,
	lineage: Lineage,
	frameOrder: number,
	revision: number,
	authorityOperationCount: number,
	lastDeterministicOrder: number,
	publications: { PublicationDescriptor },
	summary: OpenSummary,
}

type FaultCapability = {
	frame: FaultedFrame,
	lineage: Lineage,
	summary: FaultSummary,
}

type CommitStatus = "Committed" | "Flushing" | "Flushed"
type CommitCapability = {
	frame: CommittedFrame,
	status: CommitStatus,
	lineage: Lineage,
	summary: CommitSummary,
}

type FlushCapability = {
	cursor: FlushCursor,
	current: boolean,
	commit: CommitCapability,
	revision: number,
	nextIndex: number,
	attemptedCount: number,
	succeededCount: number,
	failedCount: number,
	failures: { PublicationFailure },
	summary: FlushSummary,
}

type AttemptCapability = {
	attempt: PublicationAttempt,
	current: boolean,
	flush: FlushCapability,
	ordinal: number,
	descriptor: PublicationDescriptor,
	summary: PublicationAttemptSummary,
}

local MAXIMUM_ORDER = 2_147_483_647
local MAXIMUM_DIAGNOSTIC_LENGTH = 512
local MAXIMUM_PUBLICATION_TABLE_COUNT = 256
local MAXIMUM_PUBLICATION_DEPTH = 16

local openCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[OpenFrame]: OpenCapability,
}
local openFramesBySummary = setmetatable({}, { __mode = "k" }) :: {
	[OpenSummary]: OpenFrame,
}
local faultCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[FaultedFrame]: FaultCapability,
}
local faultFramesBySummary = setmetatable({}, { __mode = "k" }) :: {
	[FaultSummary]: FaultedFrame,
}
local commitCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[CommittedFrame]: CommitCapability,
}
local committedFramesBySummary = setmetatable({}, { __mode = "k" }) :: {
	[CommitSummary]: CommittedFrame,
}
local flushCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[FlushCursor]: FlushCapability,
}
local flushCursorsBySummary = setmetatable({}, { __mode = "k" }) :: {
	[FlushSummary]: FlushCursor,
}
local attemptCapabilities = setmetatable({}, { __mode = "k" }) :: {
	[PublicationAttempt]: AttemptCapability,
}
local attemptsBySummary = setmetatable({}, { __mode = "k" }) :: {
	[PublicationAttemptSummary]: PublicationAttempt,
}
local publicationReports = setmetatable({}, { __mode = "k" }) :: {
	[PublicationReport]: boolean,
}

local EMPTY_PUBLICATIONS: { PublicationDescriptor } = table.freeze({})
local EMPTY_FAILURES: { PublicationFailure } = table.freeze({})

local function isIntegerInRange(value: unknown, minimum: number, maximum: number): boolean
	return type(value) == "number"
		and value == value
		and math.abs(value :: number) < math.huge
		and (value :: number) % 1 == 0
		and (value :: number) >= minimum
		and (value :: number) <= maximum
end

local function isOpaqueEmpty(value: unknown): boolean
	return type(value) == "table"
		and getmetatable(value :: table) == nil
		and table.isfrozen(value :: table)
		and next(value :: { [unknown]: unknown }) == nil
end

local function isPublicationValue(value: unknown): boolean
	if type(value) ~= "table" then
		return false
	end
	local visited: { [table]: boolean } = {}
	local tableCount = 0
	local function visit(candidate: unknown, depth: number): boolean
		if type(candidate) ~= "table" then
			return true
		end
		local candidateTable = candidate :: table
		if
			depth > MAXIMUM_PUBLICATION_DEPTH
			or getmetatable(candidateTable) ~= nil
			or not table.isfrozen(candidateTable)
		then
			return false
		end
		if visited[candidateTable] then
			return true
		end
		visited[candidateTable] = true
		tableCount += 1
		if tableCount > MAXIMUM_PUBLICATION_TABLE_COUNT then
			return false
		end
		for key, nested in next, candidateTable do
			if not visit(key, depth + 1) or not visit(nested, depth + 1) then
				return false
			end
		end
		return true
	end
	return visit(value, 1)
end

local function isDiagnostic(value: unknown): boolean
	return type(value) == "string" and #value >= 1 and #value <= MAXIMUM_DIAGNOSTIC_LENGTH
end

local function copyPublications(publications: { PublicationDescriptor }): { PublicationDescriptor }
	local copied: { PublicationDescriptor } = table.create(#publications)
	for _, descriptor in publications do
		table.insert(copied, descriptor)
	end
	return copied
end

local function copyFailures(failures: { PublicationFailure }): { PublicationFailure }
	local copied: { PublicationFailure } = table.create(#failures)
	for _, failure in failures do
		table.insert(copied, failure)
	end
	return copied
end

local function makeOpenSummary(
	lineage: Lineage,
	frameOrder: number,
	revision: number,
	authorityOperationCount: number,
	publications: { PublicationDescriptor },
	lastDeterministicOrder: number
): OpenSummary
	return table.freeze({
		lineage = lineage,
		frameOrder = frameOrder,
		revision = revision,
		authorityOperationCount = authorityOperationCount,
		queuedPublicationCount = #publications,
		lastDeterministicOrder = lastDeterministicOrder,
	})
end

local function registerOpen(
	lineage: Lineage,
	frameOrder: number,
	revision: number,
	authorityOperationCount: number,
	publications: { PublicationDescriptor },
	lastDeterministicOrder: number
): (OpenFrame, OpenSummary)
	local frame: OpenFrame = table.freeze({})
	local summary =
		makeOpenSummary(lineage, frameOrder, revision, authorityOperationCount, publications, lastDeterministicOrder)
	openCapabilities[frame] = {
		frame = frame,
		current = true,
		lineage = lineage,
		frameOrder = frameOrder,
		revision = revision,
		authorityOperationCount = authorityOperationCount,
		lastDeterministicOrder = lastDeterministicOrder,
		publications = publications,
		summary = summary,
	}
	openFramesBySummary[summary] = frame
	return frame, summary
end

local function currentOpen(frameValue: unknown, summaryValue: unknown?): (OpenCapability?, string?)
	if not isOpaqueEmpty(frameValue) then
		return nil, "open-frame-not-capability"
	end
	local frame = frameValue :: OpenFrame
	local capability = openCapabilities[frame]
	if
		not capability
		or not capability.current
		or capability.frame ~= frame
		or openFramesBySummary[capability.summary] ~= frame
		or capability.summary.lineage ~= capability.lineage
		or capability.summary.frameOrder ~= capability.frameOrder
		or capability.summary.revision ~= capability.revision
		or capability.summary.authorityOperationCount ~= capability.authorityOperationCount
		or capability.summary.queuedPublicationCount ~= #capability.publications
		or capability.summary.lastDeterministicOrder ~= capability.lastDeterministicOrder
	then
		return nil, "stale-open-frame"
	end
	if summaryValue ~= nil and summaryValue ~= capability.summary then
		return nil, "forged-open-frame-summary"
	end
	return capability, nil
end

local function retireOpen(capability: OpenCapability)
	capability.current = false
	openFramesBySummary[capability.summary] = nil
end

local function nextOrder(capability: OpenCapability, orderValue: unknown): (number?, string?)
	if not isIntegerInRange(orderValue, 1, MAXIMUM_ORDER) then
		return nil, "invalid-deterministic-order"
	end
	local order = orderValue :: number
	if order <= capability.lastDeterministicOrder then
		return nil, "duplicate-or-regressed-deterministic-order"
	end
	return order, nil
end

local function currentFaulted(frameValue: unknown): FaultCapability?
	if not isOpaqueEmpty(frameValue) then
		return nil
	end
	local frame = frameValue :: FaultedFrame
	local capability = faultCapabilities[frame]
	if
		not capability
		or capability.frame ~= frame
		or faultFramesBySummary[capability.summary] ~= frame
		or capability.summary.lineage ~= capability.lineage
	then
		return nil
	end
	return capability
end

local function currentCommitted(
	frameValue: unknown,
	summaryValue: unknown?,
	requiredStatus: CommitStatus?
): (CommitCapability?, string?)
	if not isOpaqueEmpty(frameValue) then
		return nil, "committed-frame-not-capability"
	end
	local frame = frameValue :: CommittedFrame
	local capability = commitCapabilities[frame]
	if
		not capability
		or capability.frame ~= frame
		or committedFramesBySummary[capability.summary] ~= frame
		or capability.summary.lineage ~= capability.lineage
		or (requiredStatus ~= nil and capability.status ~= requiredStatus)
	then
		return nil, "stale-committed-frame"
	end
	if summaryValue ~= nil and summaryValue ~= capability.summary then
		return nil, "forged-commit-summary"
	end
	return capability, nil
end

local function makeFlushSummary(
	commit: CommitCapability,
	revision: number,
	nextIndex: number,
	attemptedCount: number,
	succeededCount: number,
	failedCount: number
): FlushSummary
	local nextDescriptor = commit.summary.publications[nextIndex]
	return table.freeze({
		lineage = commit.lineage,
		frameOrder = commit.summary.frameOrder,
		revision = revision,
		publicationCount = commit.summary.publicationCount,
		attemptedCount = attemptedCount,
		succeededCount = succeededCount,
		failedCount = failedCount,
		nextPublicationOrder = if nextDescriptor then nextDescriptor.order else nil,
		closeCommitted = true,
		authorityRolledBack = false,
	})
end

local function registerFlush(
	commit: CommitCapability,
	revision: number,
	nextIndex: number,
	attemptedCount: number,
	succeededCount: number,
	failedCount: number,
	failures: { PublicationFailure }
): (FlushCursor, FlushSummary)
	local cursor: FlushCursor = table.freeze({})
	local summary = makeFlushSummary(commit, revision, nextIndex, attemptedCount, succeededCount, failedCount)
	flushCapabilities[cursor] = {
		cursor = cursor,
		current = true,
		commit = commit,
		revision = revision,
		nextIndex = nextIndex,
		attemptedCount = attemptedCount,
		succeededCount = succeededCount,
		failedCount = failedCount,
		failures = failures,
		summary = summary,
	}
	flushCursorsBySummary[summary] = cursor
	return cursor, summary
end

local function currentFlush(cursorValue: unknown): (FlushCapability?, string?)
	if not isOpaqueEmpty(cursorValue) then
		return nil, "flush-cursor-not-capability"
	end
	local cursor = cursorValue :: FlushCursor
	local capability = flushCapabilities[cursor]
	if
		not capability
		or not capability.current
		or capability.cursor ~= cursor
		or capability.commit.status ~= "Flushing"
		or flushCursorsBySummary[capability.summary] ~= cursor
		or capability.attemptedCount ~= capability.succeededCount + capability.failedCount
		or capability.nextIndex ~= capability.attemptedCount + 1
		or capability.summary.revision ~= capability.revision
		or capability.summary.attemptedCount ~= capability.attemptedCount
		or capability.summary.succeededCount ~= capability.succeededCount
		or capability.summary.failedCount ~= capability.failedCount
	then
		return nil, "stale-flush-cursor"
	end
	return capability, nil
end

local function retireFlush(capability: FlushCapability)
	capability.current = false
	flushCursorsBySummary[capability.summary] = nil
end

local function currentAttempt(attemptValue: unknown): (AttemptCapability?, string?)
	if not isOpaqueEmpty(attemptValue) then
		return nil, "publication-attempt-not-capability"
	end
	local attempt = attemptValue :: PublicationAttempt
	local capability = attemptCapabilities[attempt]
	if
		not capability
		or not capability.current
		or capability.attempt ~= attempt
		or capability.flush.current
		or attemptsBySummary[capability.summary] ~= attempt
		or capability.summary.descriptor ~= capability.descriptor
		or capability.summary.ordinal ~= capability.ordinal
	then
		return nil, "stale-publication-attempt"
	end
	return capability, nil
end

function FramePublicationCloseRules.Open(frameOrderValue: unknown): (OpenFrame?, OpenSummary?, string?)
	if not isIntegerInRange(frameOrderValue, 1, MAXIMUM_ORDER) then
		return nil, nil, "invalid-frame-order"
	end
	local lineage: Lineage = table.freeze({})
	local frame, summary = registerOpen(lineage, frameOrderValue :: number, 1, 0, EMPTY_PUBLICATIONS, 0)
	return frame, summary, nil
end

function FramePublicationCloseRules.InspectOpen(frameValue: unknown): OpenSummary?
	local capability = select(1, currentOpen(frameValue, nil))
	return if capability then capability.summary else nil
end

function FramePublicationCloseRules.ValidateOpenDependency(
	frameValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	local capability, capabilityError = currentOpen(frameValue, summaryValue)
	return capability ~= nil, capabilityError
end

function FramePublicationCloseRules.RecordAuthorityOperation(
	frameValue: unknown,
	orderValue: unknown
): (OpenFrame?, OpenSummary?, string?)
	local capability, capabilityError = currentOpen(frameValue, nil)
	if not capability then
		return nil, nil, capabilityError
	end
	local order, orderError = nextOrder(capability, orderValue)
	if not order then
		return nil, nil, orderError
	end
	local nextFrame, nextSummary = registerOpen(
		capability.lineage,
		capability.frameOrder,
		capability.revision + 1,
		capability.authorityOperationCount + 1,
		capability.publications,
		order
	)
	retireOpen(capability)
	return nextFrame, nextSummary, nil
end

function FramePublicationCloseRules.QueuePublication(
	frameValue: unknown,
	orderValue: unknown,
	publicationValue: unknown
): (OpenFrame?, OpenSummary?, PublicationDescriptor?, string?)
	local capability, capabilityError = currentOpen(frameValue, nil)
	if not capability then
		return nil, nil, nil, capabilityError
	end
	local order, orderError = nextOrder(capability, orderValue)
	if not order then
		return nil, nil, nil, orderError
	end
	if not isPublicationValue(publicationValue) then
		return nil, nil, nil, "invalid-publication-value"
	end
	for _, descriptor in capability.publications do
		if descriptor.value == publicationValue then
			return nil, nil, nil, "duplicate-publication-descriptor"
		end
	end
	local descriptor: PublicationDescriptor = table.freeze({
		order = order,
		value = publicationValue :: PublicationValue,
	})
	local publications = copyPublications(capability.publications)
	table.insert(publications, descriptor)
	table.freeze(publications)
	local nextFrame, nextSummary = registerOpen(
		capability.lineage,
		capability.frameOrder,
		capability.revision + 1,
		capability.authorityOperationCount,
		publications,
		order
	)
	retireOpen(capability)
	return nextFrame, nextSummary, descriptor, nil
end

function FramePublicationCloseRules.FaultBeforeClose(
	frameValue: unknown,
	orderValue: unknown,
	diagnosticValue: unknown
): (FaultedFrame?, FaultSummary?, string?)
	local capability, capabilityError = currentOpen(frameValue, nil)
	if not capability then
		return nil, nil, capabilityError
	end
	local order, orderError = nextOrder(capability, orderValue)
	if not order then
		return nil, nil, orderError
	end
	if not isDiagnostic(diagnosticValue) then
		return nil, nil, "invalid-pre-close-fault-diagnostic"
	end
	local faulted: FaultedFrame = table.freeze({})
	local summary: FaultSummary = table.freeze({
		lineage = capability.lineage,
		frameOrder = capability.frameOrder,
		revision = capability.revision + 1,
		faultOrder = order,
		diagnostic = diagnosticValue :: string,
		authorityOperationCount = capability.authorityOperationCount,
		discardedPublicationCount = #capability.publications,
		closeCommitted = false,
		authorityRolledBack = false,
	})
	faultCapabilities[faulted] = {
		frame = faulted,
		lineage = capability.lineage,
		summary = summary,
	}
	faultFramesBySummary[summary] = faulted
	retireOpen(capability)
	return faulted, summary, nil
end

function FramePublicationCloseRules.InspectFaulted(frameValue: unknown): FaultSummary?
	local capability = currentFaulted(frameValue)
	return if capability then capability.summary else nil
end

function FramePublicationCloseRules.Close(
	frameValue: unknown,
	orderValue: unknown
): (CommittedFrame?, CommitSummary?, string?)
	local capability, capabilityError = currentOpen(frameValue, nil)
	if not capability then
		return nil, nil, capabilityError
	end
	local order, orderError = nextOrder(capability, orderValue)
	if not order then
		return nil, nil, orderError
	end
	local committed: CommittedFrame = table.freeze({})
	local summary: CommitSummary = table.freeze({
		lineage = capability.lineage,
		frameOrder = capability.frameOrder,
		revision = capability.revision + 1,
		closeOrder = order,
		authorityOperationCount = capability.authorityOperationCount,
		publicationCount = #capability.publications,
		publications = capability.publications,
		closeCommitted = true,
		authorityRolledBack = false,
	})
	commitCapabilities[committed] = {
		frame = committed,
		status = "Committed",
		lineage = capability.lineage,
		summary = summary,
	}
	committedFramesBySummary[summary] = committed
	retireOpen(capability)
	return committed, summary, nil
end

function FramePublicationCloseRules.InspectCommitted(frameValue: unknown): CommitSummary?
	local capability = select(1, currentCommitted(frameValue, nil, "Committed"))
	return if capability then capability.summary else nil
end

function FramePublicationCloseRules.ValidateCommitDependency(
	frameValue: unknown,
	summaryValue: unknown
): (boolean, string?)
	local capability, capabilityError = currentCommitted(frameValue, summaryValue, "Committed")
	return capability ~= nil, capabilityError
end

function FramePublicationCloseRules.BeginPublicationFlush(
	frameValue: unknown,
	summaryValue: unknown
): (FlushCursor?, FlushSummary?, string?)
	local capability, capabilityError = currentCommitted(frameValue, summaryValue, "Committed")
	if not capability then
		return nil, nil, capabilityError
	end
	local cursor, summary = registerFlush(capability, 1, 1, 0, 0, 0, EMPTY_FAILURES)
	capability.status = "Flushing"
	return cursor, summary, nil
end

function FramePublicationCloseRules.InspectFlush(cursorValue: unknown): FlushSummary?
	local capability = select(1, currentFlush(cursorValue))
	return if capability then capability.summary else nil
end

function FramePublicationCloseRules.BeginNextPublication(
	cursorValue: unknown
): (PublicationAttempt?, PublicationDescriptor?, string?)
	local capability, capabilityError = currentFlush(cursorValue)
	if not capability then
		return nil, nil, capabilityError
	end
	local descriptor = capability.commit.summary.publications[capability.nextIndex]
	if not descriptor then
		return nil, nil, "publication-flush-complete"
	end
	local attempt: PublicationAttempt = table.freeze({})
	local summary: PublicationAttemptSummary = table.freeze({
		lineage = capability.commit.lineage,
		frameOrder = capability.commit.summary.frameOrder,
		ordinal = capability.nextIndex,
		descriptor = descriptor,
	})
	attemptCapabilities[attempt] = {
		attempt = attempt,
		current = true,
		flush = capability,
		ordinal = capability.nextIndex,
		descriptor = descriptor,
		summary = summary,
	}
	attemptsBySummary[summary] = attempt
	retireFlush(capability)
	return attempt, descriptor, nil
end

function FramePublicationCloseRules.InspectPublicationAttempt(attemptValue: unknown): PublicationAttemptSummary?
	local capability = select(1, currentAttempt(attemptValue))
	return if capability then capability.summary else nil
end

function FramePublicationCloseRules.ResolvePublication(
	attemptValue: unknown,
	succeededValue: unknown,
	diagnosticValue: unknown?
): (FlushCursor?, FlushSummary?, string?)
	local capability, capabilityError = currentAttempt(attemptValue)
	if not capability then
		return nil, nil, capabilityError
	end
	if type(succeededValue) ~= "boolean" then
		return nil, nil, "invalid-publication-outcome"
	end
	if succeededValue then
		if diagnosticValue ~= nil then
			return nil, nil, "successful-publication-has-diagnostic"
		end
	elseif not isDiagnostic(diagnosticValue) then
		return nil, nil, "failed-publication-requires-diagnostic"
	end

	local base = capability.flush
	local failures = base.failures
	local succeededCount = base.succeededCount
	local failedCount = base.failedCount
	if succeededValue then
		succeededCount += 1
	else
		local copiedFailures = copyFailures(base.failures)
		local failure: PublicationFailure = table.freeze({
			ordinal = capability.ordinal,
			order = capability.descriptor.order,
			descriptor = capability.descriptor,
			diagnostic = diagnosticValue :: string,
		})
		table.insert(copiedFailures, failure)
		table.freeze(copiedFailures)
		failures = copiedFailures
		failedCount += 1
	end
	local nextCursor, nextSummary = registerFlush(
		base.commit,
		base.revision + 1,
		base.nextIndex + 1,
		base.attemptedCount + 1,
		succeededCount,
		failedCount,
		failures
	)
	capability.current = false
	attemptsBySummary[capability.summary] = nil
	return nextCursor, nextSummary, nil
end

function FramePublicationCloseRules.FinishPublicationFlush(cursorValue: unknown): (PublicationReport?, string?)
	local capability, capabilityError = currentFlush(cursorValue)
	if not capability then
		return nil, capabilityError
	end
	local commitSummary = capability.commit.summary
	if
		capability.nextIndex <= commitSummary.publicationCount
		or capability.attemptedCount ~= commitSummary.publicationCount
	then
		return nil, "publication-flush-incomplete"
	end
	local report: PublicationReport = table.freeze({
		lineage = capability.commit.lineage,
		frameOrder = commitSummary.frameOrder,
		commit = commitSummary,
		publicationCount = commitSummary.publicationCount,
		attemptedCount = capability.attemptedCount,
		succeededCount = capability.succeededCount,
		failedCount = capability.failedCount,
		failures = capability.failures,
		closeCommitted = true,
		authorityRolledBack = false,
	})
	publicationReports[report] = true
	retireFlush(capability)
	capability.commit.status = "Flushed"
	return report, nil
end

function FramePublicationCloseRules.InspectPublicationReport(reportValue: unknown): PublicationReport?
	if
		type(reportValue) ~= "table"
		or not table.isfrozen(reportValue :: table)
		or publicationReports[reportValue :: PublicationReport] ~= true
	then
		return nil
	end
	return reportValue :: PublicationReport
end

FramePublicationCloseRules.MaximumOrder = MAXIMUM_ORDER
FramePublicationCloseRules.MaximumDiagnosticLength = MAXIMUM_DIAGNOSTIC_LENGTH
FramePublicationCloseRules.MaximumPublicationTableCount = MAXIMUM_PUBLICATION_TABLE_COUNT
FramePublicationCloseRules.MaximumPublicationDepth = MAXIMUM_PUBLICATION_DEPTH

return table.freeze(FramePublicationCloseRules)
