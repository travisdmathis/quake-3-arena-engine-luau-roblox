--[[
SPDX-License-Identifier: GPL-2.0-or-later

Private identity registry for prepared Match elimination transactions.
It owns no scoring or lifecycle decisions; MatchService remains authoritative.

Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

export type Registry = {
	_active: any?,
	_prepared: { [table]: any },
	_summaries: { [table]: table },
	_applied: { [table]: any },
	_commitSerial: number,
}

local MatchEliminationPreparedRegistry = {}
MatchEliminationPreparedRegistry.__index = MatchEliminationPreparedRegistry

function MatchEliminationPreparedRegistry.new(): Registry
	return setmetatable({
		_active = nil,
		_prepared = setmetatable({}, { __mode = "k" }),
		_summaries = setmetatable({}, { __mode = "k" }),
		_applied = setmetatable({}, { __mode = "k" }),
		_commitSerial = 0,
	}, MatchEliminationPreparedRegistry) :: any
end

function MatchEliminationPreparedRegistry.GetActive(self: Registry): any?
	return self._active
end

function MatchEliminationPreparedRegistry.SetActive(self: Registry, transaction: any?)
	assert(transaction == nil or type(transaction) == "table", "active Match batch must be opaque")
	self._active = transaction
end

function MatchEliminationPreparedRegistry.GetPrepared(self: Registry, prepared: unknown): any?
	return if type(prepared) == "table" then self._prepared[prepared :: table] else nil
end

function MatchEliminationPreparedRegistry.SetPrepared(
	self: Registry,
	prepared: table,
	capability: any?
)
	assert(type(prepared) == "table", "prepared Match handle must be opaque")
	assert(
		capability == nil or type(capability) == "table",
		"prepared Match capability must be table"
	)
	self._prepared[prepared] = capability
end

function MatchEliminationPreparedRegistry.GetPreparedForSummary(
	self: Registry,
	summary: unknown
): table?
	return if type(summary) == "table" then self._summaries[summary :: table] else nil
end

function MatchEliminationPreparedRegistry.SetPreparedForSummary(
	self: Registry,
	summary: table,
	prepared: table?
)
	assert(type(summary) == "table", "prepared Match summary must be table")
	assert(prepared == nil or type(prepared) == "table", "prepared Match handle must be opaque")
	self._summaries[summary] = prepared
end

function MatchEliminationPreparedRegistry.GetApplied(self: Registry, receipt: unknown): any?
	return if type(receipt) == "table" then self._applied[receipt :: table] else nil
end

function MatchEliminationPreparedRegistry.SetApplied(
	self: Registry,
	receipt: table,
	capability: any?
)
	assert(type(receipt) == "table", "applied Match receipt must be opaque")
	assert(
		capability == nil or type(capability) == "table",
		"applied Match capability must be table"
	)
	self._applied[receipt] = capability
end

function MatchEliminationPreparedRegistry.GetCommitSerial(self: Registry): number
	return self._commitSerial
end

function MatchEliminationPreparedRegistry.SetCommitSerial(self: Registry, serial: number)
	assert(
		serial == self._commitSerial + 1 and serial <= 9_007_199_254_740_991,
		"Match elimination commit serial must be monotonic"
	)
	self._commitSerial = serial
end

return table.freeze(MatchEliminationPreparedRegistry)
