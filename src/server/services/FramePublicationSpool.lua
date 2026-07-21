--[[
SPDX-License-Identifier: GPL-2.0-or-later

Server-private executor owner for FramePublicationCloseRules. Authority callers
queue recursively frozen descriptors while callbacks remain private here.

Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Rules = require(
	ReplicatedStorage:WaitForChild("Q3Engine"):WaitForChild("simulation"):WaitForChild("FramePublicationCloseRules")
)

export type Spool = {
	_frame: Rules.OpenFrame?,
	_frameOrder: number,
	_nextOrder: number,
	_executors: { () -> () },
	_terminal: boolean,
}

local FramePublicationSpool = {}
FramePublicationSpool.__index = FramePublicationSpool

local function nextOrder(self: Spool): number
	self._nextOrder += 1
	return self._nextOrder
end

function FramePublicationSpool.new(frameOrder: number): Spool
	local frame, _, openError = Rules.Open(frameOrder)
	return setmetatable({
		_frame = assert(frame, openError),
		_frameOrder = frameOrder,
		_nextOrder = 0,
		_executors = {},
		_terminal = false,
	}, FramePublicationSpool) :: any
end

function FramePublicationSpool.RecordAuthority(self: Spool)
	assert(not self._terminal and self._frame, "publication spool is not open")
	local frame, _, recordError = Rules.RecordAuthorityOperation(self._frame, nextOrder(self))
	self._frame = assert(frame, recordError)
end

function FramePublicationSpool.Queue(
	self: Spool,
	value: Rules.PublicationValue,
	executor: () -> ()
): Rules.PublicationDescriptor
	assert(not self._terminal and self._frame, "publication spool is not open")
	assert(type(executor) == "function", "publication executor must be private callback")
	local frame, _, descriptor, queueError = Rules.QueuePublication(self._frame, nextOrder(self), value)
	self._frame = assert(frame, queueError)
	table.insert(self._executors, executor)
	return assert(descriptor, queueError)
end

function FramePublicationSpool.Fault(self: Spool): Rules.FaultSummary
	assert(not self._terminal and self._frame, "publication spool is not open")
	local _, summary, faultError = Rules.FaultBeforeClose(self._frame, nextOrder(self), "authority-frame-faulted")
	self._frame = nil
	self._executors = {}
	self._terminal = true
	return assert(summary, faultError)
end

function FramePublicationSpool.CloseAndFlush(self: Spool): Rules.PublicationReport
	assert(not self._terminal and self._frame, "publication spool is not open")
	local committed, summary, closeError = Rules.Close(self._frame, nextOrder(self))
	self._frame = nil
	committed = assert(committed, closeError)
	summary = assert(summary, closeError)
	local cursor, _, flushError = Rules.BeginPublicationFlush(committed, summary)
	cursor = assert(cursor, flushError)
	for index, executor in self._executors do
		local attempt, descriptor, attemptError = Rules.BeginNextPublication(cursor)
		attempt = assert(attempt, attemptError)
		assert(descriptor == summary.publications[index], "publication descriptor order drifted")
		local succeeded = pcall(executor)
		local nextCursor, _, resolveError =
			Rules.ResolvePublication(attempt, succeeded, if succeeded then nil else "publication-callback-failed")
		cursor = assert(nextCursor, resolveError)
	end
	local report, reportError = Rules.FinishPublicationFlush(cursor)
	self._executors = {}
	self._terminal = true
	return assert(report, reportError)
end

return table.freeze(FramePublicationSpool)
