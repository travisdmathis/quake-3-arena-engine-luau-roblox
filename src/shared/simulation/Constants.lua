--[[
SPDX-License-Identifier: GPL-2.0-or-later

Derived from Quake III Arena source code:
  code/game/bg_public.h
  code/game/bg_local.h
  code/game/bg_pmove.c

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-11.
]]

--!strict

local UNITS_TO_STUDS = 0.1
local STANDING_COLLIDER_SIZE = Vector3.new(30, 56, 30) * UNITS_TO_STUDS
local STANDING_COLLIDER_CENTER_OFFSET = Vector3.new(0, 4, 0) * UNITS_TO_STUDS
local CROUCHED_COLLIDER_SIZE = Vector3.new(30, 40, 30) * UNITS_TO_STUDS
local CROUCHED_COLLIDER_CENTER_OFFSET = Vector3.new(0, -4, 0) * UNITS_TO_STUDS
-- bg_pmove.c::PM_CheckDuck uses mins {-15, -15, MINS_Z} and
-- maxs {15, 15, -8} for PM_DEAD. Roblox Y represents source Z.
local DEAD_COLLIDER_SIZE = Vector3.new(30, 16, 30) * UNITS_TO_STUDS
local DEAD_COLLIDER_CENTER_OFFSET = Vector3.new(0, -16, 0) * UNITS_TO_STUDS

local function colliderSize(crouched: boolean): Vector3
	return if crouched then CROUCHED_COLLIDER_SIZE else STANDING_COLLIDER_SIZE
end

local function colliderCenterOffset(crouched: boolean): Vector3
	return if crouched then CROUCHED_COLLIDER_CENTER_OFFSET else STANDING_COLLIDER_CENTER_OFFSET
end

local function viewHeight(crouched: boolean): number
	return if crouched then 12 * UNITS_TO_STUDS else 26 * UNITS_TO_STUDS
end

local Constants = table.freeze({
	SourceCommit = "dbe4ddb10315479fc00086f08e25d968b4b43c49",
	UnitsToStuds = UNITS_TO_STUDS,
	FixedStep = 1 / 60,
	SnapshotStepFrames = 3,
	MaximumAccumulatedTime = 0.25,
	-- sv_main.c::SV_Frame drains sv.timeResidual in a dedicated server loop. Roblox
	-- Studio and local play share simulation and presentation CPU, so an unbounded
	-- drain can starve the next Heartbeat and create a permanent catch-up spiral.
	MaximumCatchUpStepsPerHeartbeat = 4,
	MaximumServerCommandBacklog = 120,
	-- Keep enough reliable commands in flight for 200 ms RTT at 60 Hz while
	-- preventing a throttled authority from being buried by client prediction.
	MaximumInFlightCommands = 32,
	MaximumPredictedCommands = 600,

	PredictionCorrectionDeadzone = 0.03,
	PredictionSnapDistance = 5,
	PredictionCorrectionSpeed = 14,

	-- Q3's default 90-degree horizontal FOV converted to vertical FOV at 4:3.
	CameraVerticalFieldOfView = 73.739795,

	Gravity = 800 * UNITS_TO_STUDS,
	MaxSpeed = 320 * UNITS_TO_STUDS,
	StopSpeed = 100 * UNITS_TO_STUDS,
	GroundAcceleration = 10,
	AirAcceleration = 1,
	WaterAcceleration = 4,
	FlightAcceleration = 8,
	GroundFriction = 6,
	WaterFriction = 1,
	FlightFriction = 3,
	SwimSpeedScale = 0.5,
	WaterSinkSpeed = 60 * UNITS_TO_STUDS,
	CrouchSpeedScale = 0.25,
	CrouchCameraSeconds = 0.1,
	JumpCommandThreshold = 10 / 127,
	JumpVelocity = 270 * UNITS_TO_STUDS,
	WaterJumpForwardProbeDistance = 30 * UNITS_TO_STUDS,
	WaterJumpLowerProbeHeight = 4 * UNITS_TO_STUDS,
	WaterJumpUpperProbeHeight = 16 * UNITS_TO_STUDS,
	WaterJumpForwardVelocity = 200 * UNITS_TO_STUDS,
	WaterJumpVerticalVelocity = 350 * UNITS_TO_STUDS,
	WaterJumpTimerSeconds = 2,
	LandingTimerVelocity = -200 * UNITS_TO_STUDS,
	LandingTimerSeconds = 0.25,
	MinimumDamageKnockbackSeconds = 0.05,
	MaximumDamageKnockbackSeconds = 0.2,
	StepSize = 18 * UNITS_TO_STUDS,
	MinimumWalkNormal = 0.7,
	Overclip = 1.001,

	StandingColliderSize = STANDING_COLLIDER_SIZE,
	StandingColliderCenterOffset = STANDING_COLLIDER_CENTER_OFFSET,
	CrouchedColliderSize = CROUCHED_COLLIDER_SIZE,
	CrouchedColliderCenterOffset = CROUCHED_COLLIDER_CENTER_OFFSET,
	DeadColliderSize = DEAD_COLLIDER_SIZE,
	DeadColliderCenterOffset = DEAD_COLLIDER_CENTER_OFFSET,
	StandingViewHeight = 26 * UNITS_TO_STUDS,
	CrouchedViewHeight = 12 * UNITS_TO_STUDS,
	DeadViewHeight = -16 * UNITS_TO_STUDS,
	-- PM_DeadMove removes this fixed amount from total velocity once per
	-- PmoveSingle while the dead player is walking; it is not time-scaled.
	DeadMoveSpeedDrop = 20 * UNITS_TO_STUDS,
	PlayerMinimumY = -24 * UNITS_TO_STUDS,
	WaterBottomSampleOffset = (-24 + 1) * UNITS_TO_STUDS,
	VisualRootOffset = Vector3.new(0, 6, 0) * UNITS_TO_STUDS,
	-- PM_GroundTrace probes 0.25 source units beneath the player.
	GroundProbeDistance = 0.25 * UNITS_TO_STUDS,
	-- PM_CorrectAllSolid jitters each source axis by {-1, 0, 1} units.
	AllSolidJitterDistance = 1 * UNITS_TO_STUDS,
	GroundKickoffSpeed = 10 * UNITS_TO_STUDS,
	-- cm_trace.c::CM_TraceThroughBrush reports an entering contact this far on
	-- the near side of the collision plane.
	SurfaceClipEpsilon = 0.125 * UNITS_TO_STUDS,
	-- Q3 expands world brush planes by the exact player mins/maxs. Static-world
	-- Blockcasts must therefore sweep the complete hull. Insetting the sweep by
	-- CollisionSkin creates a blind strip: CollisionSkin + the source plane
	-- epsilon is larger than PM_GroundTrace's complete 0.25-unit probe.
	StaticWorldSweepInset = 0,
	-- Roblox exact-overlap queries retain this small platform guard so a hull
	-- resting on a boundary is not misclassified as startsolid/allsolid.
	CollisionSkin = 0.02,
	PlaneNudge = 1 * UNITS_TO_STUDS,
	MaximumBumps = 4,
	MaximumClipPlanes = 5,

	ColliderSizeFor = colliderSize,
	ColliderCenterOffsetFor = colliderCenterOffset,
	ViewHeightFor = viewHeight,
})

return Constants
