--!strict

local MovementNormalToDeadPreparedRegistry = {}

export type Registry = {
	RetirePreparedSummary: (self: Registry, prepared: unknown, summary: unknown) -> (),
	RetiredSummaryMatches: (self: Registry, prepared: unknown, summary: unknown) -> boolean,
	GetActiveForRecord: (self: Registry, record: unknown) -> unknown?,
	SetActiveForRecord: (self: Registry, record: unknown, prepared: unknown?) -> (),
	GetAppliedReceiptForRecord: (self: Registry, record: unknown) -> unknown?,
	SetAppliedReceiptForRecord: (self: Registry, record: unknown, receipt: unknown?) -> (),
	GetPreparedCapability: (self: Registry, prepared: unknown) -> unknown?,
	SetPreparedCapability: (self: Registry, prepared: unknown, capability: unknown?) -> (),
	GetPreparedForSummary: (self: Registry, summary: unknown) -> unknown?,
	SetPreparedForSummary: (self: Registry, summary: unknown, prepared: unknown?) -> (),
	GetReceiptCapability: (self: Registry, receipt: unknown) -> unknown?,
	SetReceiptCapability: (self: Registry, receipt: unknown, capability: unknown?) -> (),
	GetBatchCapability: (self: Registry, prepared: unknown) -> unknown?,
	SetBatchCapability: (self: Registry, prepared: unknown, capability: unknown?) -> (),
	GetBatchForSummary: (self: Registry, summary: unknown) -> unknown?,
	SetBatchForSummary: (self: Registry, summary: unknown, prepared: unknown?) -> (),
	GetBatchReceiptCapability: (self: Registry, receipt: unknown) -> unknown?,
	SetBatchReceiptCapability: (self: Registry, receipt: unknown, capability: unknown?) -> (),
	GetMoverStepForBatch: (self: Registry, prepared: unknown) -> unknown?,
	SetMoverStepForBatch: (self: Registry, prepared: unknown, moverStep: unknown?) -> (),
	GetActiveBatch: (self: Registry) -> unknown?,
	SetActiveBatch: (self: Registry, prepared: unknown?) -> (),
}

function MovementNormalToDeadPreparedRegistry.new(): Registry
	local retiredSummaries = setmetatable({}, { __mode = "k" }) :: { [table]: unknown }
	local activePreparedByRecord = setmetatable({}, { __mode = "k" }) :: { [table]: unknown }
	local appliedReceiptByRecord = setmetatable({}, { __mode = "k" }) :: { [table]: unknown }
	local preparedCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: unknown }
	local preparedBySummary = setmetatable({}, { __mode = "k" }) :: { [table]: unknown }
	local receiptCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: unknown }
	local batchCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: unknown }
	local batchBySummary = setmetatable({}, { __mode = "k" }) :: { [table]: unknown }
	local batchReceiptCapabilities = setmetatable({}, { __mode = "k" }) :: { [table]: unknown }
	local moverStepByBatch = setmetatable({}, { __mode = "k" }) :: { [table]: unknown }
	local activeBatch: unknown? = nil
	local registry = {} :: Registry

	function registry:RetirePreparedSummary(prepared: unknown, summary: unknown)
		assert(type(prepared) == "table", "retired prepared handle must be opaque table")
		assert(type(summary) == "table", "retired prepared summary must be table")
		retiredSummaries[prepared :: table] = summary
	end

	function registry:RetiredSummaryMatches(prepared: unknown, summary: unknown): boolean
		return type(prepared) == "table" and retiredSummaries[prepared :: table] == summary
	end

	function registry:GetActiveForRecord(record: unknown): unknown?
		return if type(record) == "table" then activePreparedByRecord[record :: table] else nil
	end

	function registry:SetActiveForRecord(record: unknown, prepared: unknown?)
		assert(type(record) == "table", "prepared record key must be table")
		assert(prepared == nil or type(prepared) == "table", "prepared record value must be opaque")
		activePreparedByRecord[record :: table] = prepared
	end

	function registry:GetAppliedReceiptForRecord(record: unknown): unknown?
		return if type(record) == "table" then appliedReceiptByRecord[record :: table] else nil
	end

	function registry:SetAppliedReceiptForRecord(record: unknown, receipt: unknown?)
		assert(type(record) == "table", "applied receipt record key must be table")
		assert(receipt == nil or type(receipt) == "table", "applied receipt must be opaque")
		appliedReceiptByRecord[record :: table] = receipt
	end

	function registry:GetPreparedCapability(prepared: unknown): unknown?
		return if type(prepared) == "table" then preparedCapabilities[prepared :: table] else nil
	end

	function registry:SetPreparedCapability(prepared: unknown, capability: unknown?)
		assert(type(prepared) == "table", "prepared capability key must be opaque")
		assert(
			capability == nil or type(capability) == "table",
			"prepared capability must be table"
		)
		preparedCapabilities[prepared :: table] = capability
	end

	function registry:GetPreparedForSummary(summary: unknown): unknown?
		return if type(summary) == "table" then preparedBySummary[summary :: table] else nil
	end

	function registry:SetPreparedForSummary(summary: unknown, prepared: unknown?)
		assert(type(summary) == "table", "prepared summary key must be table")
		assert(
			prepared == nil or type(prepared) == "table",
			"prepared summary value must be opaque"
		)
		preparedBySummary[summary :: table] = prepared
	end

	function registry:GetReceiptCapability(receipt: unknown): unknown?
		return if type(receipt) == "table" then receiptCapabilities[receipt :: table] else nil
	end

	function registry:SetReceiptCapability(receipt: unknown, capability: unknown?)
		assert(type(receipt) == "table", "receipt capability key must be opaque")
		assert(capability == nil or type(capability) == "table", "receipt capability must be table")
		receiptCapabilities[receipt :: table] = capability
	end

	function registry:GetBatchCapability(prepared: unknown): unknown?
		return if type(prepared) == "table" then batchCapabilities[prepared :: table] else nil
	end

	function registry:SetBatchCapability(prepared: unknown, capability: unknown?)
		assert(type(prepared) == "table", "batch capability key must be opaque")
		assert(capability == nil or type(capability) == "table", "batch capability must be table")
		batchCapabilities[prepared :: table] = capability
	end

	function registry:GetBatchForSummary(summary: unknown): unknown?
		return if type(summary) == "table" then batchBySummary[summary :: table] else nil
	end

	function registry:SetBatchForSummary(summary: unknown, prepared: unknown?)
		assert(type(summary) == "table", "batch summary key must be table")
		assert(prepared == nil or type(prepared) == "table", "batch summary value must be opaque")
		batchBySummary[summary :: table] = prepared
	end

	function registry:GetBatchReceiptCapability(receipt: unknown): unknown?
		return if type(receipt) == "table" then batchReceiptCapabilities[receipt :: table] else nil
	end

	function registry:SetBatchReceiptCapability(receipt: unknown, capability: unknown?)
		assert(type(receipt) == "table", "batch receipt key must be opaque")
		assert(
			capability == nil or type(capability) == "table",
			"batch receipt capability must be table"
		)
		batchReceiptCapabilities[receipt :: table] = capability
	end

	function registry:GetMoverStepForBatch(prepared: unknown): unknown?
		return if type(prepared) == "table" then moverStepByBatch[prepared :: table] else nil
	end

	function registry:SetMoverStepForBatch(prepared: unknown, moverStep: unknown?)
		assert(type(prepared) == "table", "mover batch key must be opaque")
		assert(moverStep == nil or type(moverStep) == "table", "mover step must be opaque")
		moverStepByBatch[prepared :: table] = moverStep
	end

	function registry:GetActiveBatch(): unknown?
		return activeBatch
	end

	function registry:SetActiveBatch(prepared: unknown?)
		assert(prepared == nil or type(prepared) == "table", "active batch must be opaque")
		activeBatch = prepared
	end

	return registry
end

return table.freeze(MovementNormalToDeadPreparedRegistry)
