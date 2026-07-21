--!strict

local MovementTelemetryRuntime = {}

export type Snapshot = {
	heartbeatCount: number,
	fixedStepCount: number,
	maximumAccumulatorSeconds: number,
	clampedTimeSeconds: number,
	maximumStepsPerHeartbeat: number,
	fixedStepCpuSeconds: number,
	maximumFixedStepCpuSeconds: number,
	frameOpenCpuSeconds: number,
	playerCpuSeconds: number,
	preMoverCpuSeconds: number,
	moverCpuSeconds: number,
	postMoverCpuSeconds: number,
	closeCpuSeconds: number,
	maximumCommandBacklogByUserId: { [number]: number },
	queueCapacityRejectCount: number,
	rateRejectCount: number,
}

export type Runtime = {
	ObserveHeartbeat: (self: Runtime) -> (),
	ObserveFixedStep: (self: Runtime) -> (),
	ObserveAccumulator: (self: Runtime, seconds: number) -> (),
	AddClampedTime: (self: Runtime, seconds: number) -> (),
	ObserveStepsPerHeartbeat: (self: Runtime, steps: number) -> (),
	ObserveFixedStepCpu: (
		self: Runtime,
		totalSeconds: number,
		frameOpenSeconds: number,
		playerSeconds: number,
		preMoverSeconds: number,
		moverSeconds: number,
		postMoverSeconds: number,
		closeSeconds: number
	) -> (),
	ObserveCommandBacklog: (self: Runtime, userId: number, backlog: number) -> (),
	AddPlayer: (self: Runtime, userId: number) -> (),
	RemovePlayer: (self: Runtime, userId: number) -> (),
	ObserveRateReject: (self: Runtime) -> (),
	ObserveQueueCapacityReject: (self: Runtime) -> (),
	Snapshot: (self: Runtime, currentBacklogs: { [number]: number }) -> Snapshot,
}

type State = {
	heartbeatCount: number,
	fixedStepCount: number,
	maximumAccumulatorSeconds: number,
	clampedTimeSeconds: number,
	maximumStepsPerHeartbeat: number,
	fixedStepCpuSeconds: number,
	maximumFixedStepCpuSeconds: number,
	frameOpenCpuSeconds: number,
	playerCpuSeconds: number,
	preMoverCpuSeconds: number,
	moverCpuSeconds: number,
	postMoverCpuSeconds: number,
	closeCpuSeconds: number,
	maximumCommandBacklogByUserId: { [number]: number },
	queueCapacityRejectCount: number,
	rateRejectCount: number,
}

local MAXIMUM_COUNTER = 9_007_199_254_740_991

local function saturatedAdd(current: number, amount: number): number
	return math.min(current + amount, MAXIMUM_COUNTER)
end

function MovementTelemetryRuntime.new(): Runtime
	local state: State = {
		heartbeatCount = 0,
		fixedStepCount = 0,
		maximumAccumulatorSeconds = 0,
		clampedTimeSeconds = 0,
		maximumStepsPerHeartbeat = 0,
		fixedStepCpuSeconds = 0,
		maximumFixedStepCpuSeconds = 0,
		frameOpenCpuSeconds = 0,
		playerCpuSeconds = 0,
		preMoverCpuSeconds = 0,
		moverCpuSeconds = 0,
		postMoverCpuSeconds = 0,
		closeCpuSeconds = 0,
		maximumCommandBacklogByUserId = {},
		queueCapacityRejectCount = 0,
		rateRejectCount = 0,
	}
	local runtime = {} :: Runtime

	function runtime:ObserveHeartbeat()
		state.heartbeatCount = saturatedAdd(state.heartbeatCount, 1)
	end

	function runtime:ObserveFixedStep()
		state.fixedStepCount = saturatedAdd(state.fixedStepCount, 1)
	end

	function runtime:ObserveAccumulator(seconds: number)
		state.maximumAccumulatorSeconds = math.max(state.maximumAccumulatorSeconds, seconds)
	end

	function runtime:AddClampedTime(seconds: number)
		state.clampedTimeSeconds = saturatedAdd(state.clampedTimeSeconds, seconds)
	end

	function runtime:ObserveStepsPerHeartbeat(steps: number)
		state.maximumStepsPerHeartbeat = math.max(state.maximumStepsPerHeartbeat, steps)
	end

	function runtime:ObserveFixedStepCpu(
		totalSeconds: number,
		frameOpenSeconds: number,
		playerSeconds: number,
		preMoverSeconds: number,
		moverSeconds: number,
		postMoverSeconds: number,
		closeSeconds: number
	)
		state.fixedStepCpuSeconds = saturatedAdd(state.fixedStepCpuSeconds, totalSeconds)
		state.maximumFixedStepCpuSeconds = math.max(state.maximumFixedStepCpuSeconds, totalSeconds)
		state.frameOpenCpuSeconds = saturatedAdd(state.frameOpenCpuSeconds, frameOpenSeconds)
		state.playerCpuSeconds = saturatedAdd(state.playerCpuSeconds, playerSeconds)
		state.preMoverCpuSeconds = saturatedAdd(state.preMoverCpuSeconds, preMoverSeconds)
		state.moverCpuSeconds = saturatedAdd(state.moverCpuSeconds, moverSeconds)
		state.postMoverCpuSeconds = saturatedAdd(state.postMoverCpuSeconds, postMoverSeconds)
		state.closeCpuSeconds = saturatedAdd(state.closeCpuSeconds, closeSeconds)
	end

	function runtime:ObserveCommandBacklog(userId: number, backlog: number)
		state.maximumCommandBacklogByUserId[userId] =
			math.max(state.maximumCommandBacklogByUserId[userId] or 0, backlog)
	end

	function runtime:AddPlayer(userId: number)
		state.maximumCommandBacklogByUserId[userId] = 0
	end

	function runtime:RemovePlayer(userId: number)
		state.maximumCommandBacklogByUserId[userId] = nil
	end

	function runtime:ObserveRateReject()
		state.rateRejectCount = saturatedAdd(state.rateRejectCount, 1)
	end

	function runtime:ObserveQueueCapacityReject()
		state.queueCapacityRejectCount = saturatedAdd(state.queueCapacityRejectCount, 1)
	end

	function runtime:Snapshot(currentBacklogs: { [number]: number }): Snapshot
		local maximumBacklogs: { [number]: number } = {}
		for userId, current in currentBacklogs do
			maximumBacklogs[userId] = math.max(state.maximumCommandBacklogByUserId[userId] or 0, current)
		end
		return table.freeze({
			heartbeatCount = state.heartbeatCount,
			fixedStepCount = state.fixedStepCount,
			maximumAccumulatorSeconds = state.maximumAccumulatorSeconds,
			clampedTimeSeconds = state.clampedTimeSeconds,
			maximumStepsPerHeartbeat = state.maximumStepsPerHeartbeat,
			fixedStepCpuSeconds = state.fixedStepCpuSeconds,
			maximumFixedStepCpuSeconds = state.maximumFixedStepCpuSeconds,
			frameOpenCpuSeconds = state.frameOpenCpuSeconds,
			playerCpuSeconds = state.playerCpuSeconds,
			preMoverCpuSeconds = state.preMoverCpuSeconds,
			moverCpuSeconds = state.moverCpuSeconds,
			postMoverCpuSeconds = state.postMoverCpuSeconds,
			closeCpuSeconds = state.closeCpuSeconds,
			maximumCommandBacklogByUserId = table.freeze(maximumBacklogs),
			queueCapacityRejectCount = state.queueCapacityRejectCount,
			rateRejectCount = state.rateRejectCount,
		})
	end

	return runtime
end

return table.freeze(MovementTelemetryRuntime)
