--[[
SPDX-License-Identifier: GPL-2.0-or-later

Roblox/Luau translation of movement behavior from:
	code/game/bg_pmove.c (PM_Friction, PM_Accelerate, PM_AirMove,
	PM_WalkMove, PM_WaterMove, PM_CheckWaterJump, PM_WaterJumpMove,
	PM_SetWaterLevel, PM_WaterEvents, PM_CheckJump, PM_CheckDuck,
	PM_GroundTrace, PM_CorrectAllSolid, PM_DeadMove, PM_DropTimers,
	PmoveSingle/trap_SnapVector)
	code/game/q_shared.h (BUTTON_ATTACK, BUTTON_USE_HOLDABLE, BUTTON_WALKING)
	code/client/cl_input.c (CL_KeyMove run/walk command scaling)
	code/game/bg_slidemove.c (PM_ClipVelocity, PM_SlideMove,
	PM_StepSlideMove)
	code/game/g_active.c (PM_DEAD MASK_PLAYERSOLID body exclusion)
	code/unix/unix_shared.c and code/win32/win_shared.c (Sys_SnapVector)

Upstream commit: dbe4ddb10315479fc00086f08e25d968b4b43c49
Modified for the Roblox Luau port on 2026-07-12.
]]

--!strict

local Constants = require(script.Parent.Constants)
local CommandQuantization = require(script.Parent.CommandQuantization)
local WorldPointContents = require(script.Parent.WorldPointContents)

export type TraceResult = {
	hit: boolean,
	fraction: number,
	position: Vector3,
	normal: Vector3,
	moverId: string?,
	startSolid: boolean?,
	allSolid: boolean?,
	surfaceSlick: boolean?,
	surfaceNoDamage: boolean?,
}

export type TraceFunction = (origin: Vector3, displacement: Vector3, crouched: boolean) -> TraceResult
export type DeadTraceQuery = {
	-- bg_public.h MASK_DEADSOLID / g_active.c removes CONTENTS_BODY while dead.
	collisionMode: "PlayerSolidWithoutBodies",
	excludesBodies: boolean,
	colliderSize: Vector3,
	colliderCenterOffset: Vector3,
}
export type DeadTraceFunction = (origin: Vector3, displacement: Vector3, query: DeadTraceQuery) -> TraceResult
export type CanOccupyFunction = (origin: Vector3, crouched: boolean) -> boolean
export type PointContentsFunction = WorldPointContents.PointContentsFunction

export type Command = {
	-- q_shared.h usercmd_t canonical network domain.
	forward: number,
	right: number,
	upMove: number,
	pitch: number,
	yaw: number,
	roll: number,
	buttons: number,
	-- q_shared.h usercmd_t repeats the desired weapon byte in every command.
	-- Combat remains server authoritative; movement only transports the intent.
	weaponId: number,
}

export type InputCommand = {
	forward: number,
	right: number,
	look: Vector3,
	upMove: number,
	attack: boolean,
	useHoldable: boolean,
	walking: boolean,
	weaponId: number,
}

export type ResolvedCommand = InputCommand

export type EffectiveButtonLevels = {
	read attack: boolean,
	read useHoldable: boolean,
	read walking: boolean,
}

export type LandingContact = {
	phase: "Initial" | "Final",
	previousOriginY: number,
	landedOriginY: number,
	previousVelocityY: number,
	crouched: boolean,
	waterLevel: number,
	noDamageSurface: boolean,
}

export type LandingContacts = { LandingContact }
export type WaterEvent = "Touch" | "Leave" | "Under" | "Clear"
export type WaterEvents = { WaterEvent }

export type State = {
	frame: number,
	position: Vector3,
	velocity: Vector3,
	look: Vector3,
	viewPitch: number,
	viewYaw: number,
	viewRoll: number,
	deltaPitch: number,
	deltaYaw: number,
	deltaRoll: number,
	grounded: boolean,
	groundPlane: boolean,
	groundNormal: Vector3,
	groundSlick: boolean,
	groundNoDamage: boolean,
	groundMoverId: string?,
	jumpHeld: boolean,
	crouched: boolean,
	waterLevel: number,
	waterType: number,
	movementTime: number,
	timeLand: boolean,
	timeKnockback: boolean,
	timeWaterJump: boolean,
	respawned: boolean,
}

export type DeadState = {
	-- Kept separate so normal State/wire call sites are unchanged until the live
	-- death composite can carry PM_DEAD and the Q3 viewheight explicitly.
	state: State,
	viewHeight: number,
}

export type DeadLandingEventPolicy = {
	emitFootstep: boolean,
	emitShort: boolean,
	emitMedium: boolean,
	emitFar: boolean,
	forwardFarToDamage: boolean,
}

export type DeadWeaponPolicy = {
	clearWeaponToNone: boolean,
	generateWeaponEvents: boolean,
	blockedByRespawnLatch: boolean,
}

export type DeadStepEffects = {
	-- Movement axes have already been zeroed exactly where PmoveSingle does it;
	-- Attack/Use remain intact for g_active.c's later respawn gate, while Walking
	-- reflects PmoveSingle's earlier horizontal anti-proxy clear.
	command: Command,
	attackPressed: boolean,
	useHoldablePressed: boolean,
	waterEvents: WaterEvents,
	landingContacts: LandingContacts,
	landingEventPolicy: DeadLandingEventPolicy,
	weaponPolicy: DeadWeaponPolicy,
	traceQuery: DeadTraceQuery,
}

local Movement = {}

local ZERO = Vector3.zero
local UP = Vector3.yAxis
local EPSILON = 1e-6
local RAW_JUMP_COMMAND_THRESHOLD = 10
local MAXIMUM_MOVER_ID_LENGTH = 64
local DEAD_TRACE_QUERY: DeadTraceQuery = table.freeze({
	collisionMode = "PlayerSolidWithoutBodies",
	excludesBodies = true,
	colliderSize = Constants.DeadColliderSize,
	colliderCenterOffset = Constants.DeadColliderCenterOffset,
})
local DEAD_LANDING_EVENT_POLICY: DeadLandingEventPolicy = table.freeze({
	-- PM_CrashLand still emits these events while dead. Only EV_FALL_MEDIUM is
	-- guarded by STAT_HEALTH > 0. ClientEvents handles EV_FALL_FAR afterward.
	emitFootstep = true,
	emitShort = true,
	emitMedium = false,
	emitFar = true,
	forwardFarToDamage = true,
})
local DEAD_WEAPON_POLICY: DeadWeaponPolicy = table.freeze({
	-- PM_Weapon sets ps.weapon = WP_NONE and returns before timers, changes,
	-- firing, ammo consumption, or weapon events.
	clearWeaponToNone = true,
	generateWeaponEvents = false,
	blockedByRespawnLatch = false,
})
local RESPAWN_LATCHED_DEAD_WEAPON_POLICY: DeadWeaponPolicy = table.freeze({
	-- PM_Weapon checks PMF_RESPAWNED before the health branch. A dead player who
	-- still owns that spawn latch returns before even the WP_NONE assignment.
	clearWeaponToNone = false,
	generateWeaponEvents = false,
	blockedByRespawnLatch = true,
})

local function validateMoverId(value: unknown): string?
	-- MoverPushRules owns definition lookup once a snapshot collision frame is
	-- present. Pmove only transports the stable identity, so it validates the
	-- shared authored-ID domain without rejecting a shape-valid ID merely because
	-- this consumer does not yet have a definition table.
	if
		type(value) == "string"
		and #value >= 1
		and #value <= MAXIMUM_MOVER_ID_LENGTH
		and string.match(value, "^[a-z][a-z0-9_]*$") ~= nil
	then
		return value
	end
	return nil
end

local function unitOrZero(vector: Vector3): Vector3
	local magnitude = vector.Magnitude
	if magnitude <= EPSILON then
		return ZERO
	end
	return vector / magnitude
end

local function clipVelocity(velocity: Vector3, normal: Vector3): Vector3
	local backoff = velocity:Dot(normal)

	if backoff < 0 then
		backoff *= Constants.Overclip
	else
		backoff /= Constants.Overclip
	end

	return velocity - normal * backoff
end

local function applyPmoveFriction(
	velocity: Vector3,
	deltaTime: number,
	walking: boolean,
	groundFrictionEnabled: boolean,
	waterLevel: number,
	flightActive: boolean?
): Vector3
	-- PM_Friction clears source vertical speed only while measuring walking
	-- speed. Water friction is added to ordinary ground friction at level one,
	-- and scales every component of the stored velocity.
	local measuredVelocity = if walking then Vector3.new(velocity.X, 0, velocity.Z) else velocity
	local speed = measuredVelocity.Magnitude
	if speed < 1 * Constants.UnitsToStuds then
		return Vector3.new(0, velocity.Y, 0)
	end

	local drop = 0
	if waterLevel <= 1 and walking and groundFrictionEnabled then
		local control = math.max(speed, Constants.StopSpeed)
		drop += control * Constants.GroundFriction * deltaTime
	end
	if waterLevel > 0 then
		drop += speed * Constants.WaterFriction * waterLevel * deltaTime
	end
	if flightActive then
		drop += speed * Constants.FlightFriction * deltaTime
	end

	local newSpeed = math.max(speed - drop, 0)
	return velocity * (newSpeed / speed)
end

local function applyWalkingFriction(velocity: Vector3, deltaTime: number, frictionEnabled: boolean): Vector3
	return applyPmoveFriction(velocity, deltaTime, true, frictionEnabled, 0)
end

local function applyGroundFriction(velocity: Vector3, deltaTime: number): Vector3
	return applyWalkingFriction(velocity, deltaTime, true)
end

local function applyDryAirFriction(velocity: Vector3): Vector3
	-- PM_AirMove still calls PM_Friction. With no water, flight, or spectator
	-- friction, its only effect is the source's sub-one-unit velocity cutoff.
	-- Airborne speed includes the vertical component, while only the two
	-- horizontal components are cleared.
	return applyPmoveFriction(velocity, 0, false, false, 0)
end

local function roundSourceUnitToEven(value: number): number
	-- trap_SnapVector delegates to rint/fistp in the pinned engine. Their default
	-- round-to-nearest mode resolves exact halves to the nearest even integer.
	-- Vector3 stores Roblox-unit components at float precision, so converting the
	-- 0.1-stud scale back to source units needs one float-relative tolerance to
	-- recover an exact source half.
	local lower = math.floor(value)
	local fraction = value - lower
	local halfTolerance = math.max(math.abs(value), 1) * 1e-7
	if fraction < 0.5 - halfTolerance then
		return lower
	elseif fraction > 0.5 + halfTolerance then
		return lower + 1
	elseif lower % 2 == 0 then
		return lower
	end
	return lower + 1
end

local function snapVelocity(velocity: Vector3): Vector3
	local scale = Constants.UnitsToStuds
	return Vector3.new(
		roundSourceUnitToEven(velocity.X / scale) * scale,
		roundSourceUnitToEven(velocity.Y / scale) * scale,
		roundSourceUnitToEven(velocity.Z / scale) * scale
	)
end

local function accelerate(
	velocity: Vector3,
	wishDirection: Vector3,
	wishSpeed: number,
	acceleration: number,
	deltaTime: number
): Vector3
	local currentSpeed = velocity:Dot(wishDirection)
	local addSpeed = wishSpeed - currentSpeed

	if addSpeed <= 0 then
		return velocity
	end

	local accelerationSpeed = acceleration * deltaTime * wishSpeed
	accelerationSpeed = math.min(accelerationSpeed, addSpeed)

	return velocity + wishDirection * accelerationSpeed
end

local function resolvePlanes(velocity: Vector3, endVelocity: Vector3, planes: { Vector3 }): (Vector3, Vector3, boolean)
	local originalVelocity = velocity
	local originalEndVelocity = endVelocity

	for firstIndex, firstPlane in planes do
		if velocity:Dot(firstPlane) >= 0.1 * Constants.UnitsToStuds then
			continue
		end

		local clipped = clipVelocity(velocity, firstPlane)
		local endClipped = clipVelocity(endVelocity, firstPlane)

		for secondIndex, secondPlane in planes do
			if secondIndex == firstIndex then
				continue
			end
			if clipped:Dot(secondPlane) >= 0.1 * Constants.UnitsToStuds then
				continue
			end

			clipped = clipVelocity(clipped, secondPlane)
			endClipped = clipVelocity(endClipped, secondPlane)

			-- bg_slidemove.c continues looking for another second plane when
			-- this clip no longer enters the first one. The triple-plane test
			-- applies only after projection onto a genuine two-plane crease.
			if clipped:Dot(firstPlane) >= 0 then
				continue
			end

			local crease = unitOrZero(firstPlane:Cross(secondPlane))
			clipped = crease * crease:Dot(originalVelocity)
			endClipped = crease * crease:Dot(originalEndVelocity)

			for thirdIndex, thirdPlane in planes do
				if thirdIndex == firstIndex or thirdIndex == secondIndex then
					continue
				end
				if clipped:Dot(thirdPlane) < 0.1 * Constants.UnitsToStuds then
					return ZERO, ZERO, true
				end
			end
		end

		return clipped, endClipped, false
	end

	return velocity, endVelocity, false
end

local function slideMove(
	position: Vector3,
	velocity: Vector3,
	deltaTime: number,
	applyGravity: boolean,
	groundNormal: Vector3?,
	crouched: boolean,
	trace: TraceFunction,
	timed: boolean
): (Vector3, Vector3, boolean)
	-- bg_slidemove.c PM_SlideMove snapshots primal_velocity before gravity. With
	-- pm_time active it restores that velocity after moving/clipping so knockback
	-- is not turned by walls. Gravity replaces only its vertical component.
	local primalVelocity = velocity
	local endVelocity = velocity

	if applyGravity then
		endVelocity -= UP * Constants.Gravity * deltaTime
		velocity = Vector3.new(velocity.X, (velocity.Y + endVelocity.Y) * 0.5, velocity.Z)
		primalVelocity = Vector3.new(primalVelocity.X, endVelocity.Y, primalVelocity.Z)

		if groundNormal then
			velocity = clipVelocity(velocity, groundNormal)
		end
	end

	local timeLeft = deltaTime
	local planes: { Vector3 } = {}
	local collided = false

	if groundNormal then
		table.insert(planes, groundNormal)
	end

	local initialDirection = unitOrZero(velocity)
	if initialDirection ~= ZERO then
		table.insert(planes, initialDirection)
	end

	for _ = 1, Constants.MaximumBumps do
		local displacement = velocity * timeLeft
		if displacement.Magnitude <= EPSILON then
			break
		end

		local result = trace(position, displacement, crouched)
		if result.allSolid then
			velocity = Vector3.new(velocity.X, 0, velocity.Z)
			return position, velocity, true
		end
		position = result.position

		if not result.hit or result.fraction >= 1 - EPSILON then
			break
		end

		collided = true
		timeLeft *= 1 - result.fraction

		if #planes >= Constants.MaximumClipPlanes then
			-- PM_SlideMove returns immediately at MAX_CLIP_PLANES. Like the
			-- allsolid/triple-plane exits, this intentionally bypasses the later
			-- pm_time primal-velocity restore.
			return position, ZERO, true
		end

		local duplicatePlane = false
		for _, plane in planes do
			if result.normal:Dot(plane) > 0.99 then
				velocity += result.normal * Constants.PlaneNudge
				duplicatePlane = true
				break
			end
		end

		if duplicatePlane then
			continue
		end

		table.insert(planes, result.normal)
		local resolvedVelocity, resolvedEndVelocity, stoppedAtTriplePlane = resolvePlanes(velocity, endVelocity, planes)
		if stoppedAtTriplePlane then
			-- The source returns immediately here, before the pm_time restore.
			return position, ZERO, true
		end
		velocity = resolvedVelocity
		endVelocity = resolvedEndVelocity
	end

	if applyGravity then
		velocity = endVelocity
	end
	if timed then
		velocity = primalVelocity
	end

	return position, velocity, collided
end

local function stepSlideMove(
	position: Vector3,
	velocity: Vector3,
	deltaTime: number,
	applyGravity: boolean,
	groundNormal: Vector3?,
	crouched: boolean,
	trace: TraceFunction,
	timed: boolean
): (Vector3, Vector3)
	local startPosition = position
	local startVelocity = velocity
	local downPosition, downVelocity, collided =
		slideMove(position, velocity, deltaTime, applyGravity, groundNormal, crouched, trace, timed)

	if not collided then
		return downPosition, downVelocity
	end

	local groundBelow = trace(startPosition, -UP * Constants.StepSize, crouched)
	if downVelocity.Y > 0 and (not groundBelow.hit or groundBelow.normal.Y < Constants.MinimumWalkNormal) then
		return downPosition, downVelocity
	end

	local stepUp = trace(startPosition, UP * Constants.StepSize, crouched)
	if stepUp.allSolid then
		return downPosition, downVelocity
	end

	local stepHeight = math.max(stepUp.position.Y - startPosition.Y, 0)
	local stepPosition, stepVelocity =
		slideMove(stepUp.position, startVelocity, deltaTime, applyGravity, groundNormal, crouched, trace, timed)

	if stepHeight > EPSILON then
		local settle = trace(stepPosition, -UP * stepHeight, crouched)
		stepPosition = settle.position
		if settle.hit then
			stepVelocity = clipVelocity(stepVelocity, settle.normal)
		end
	end

	return stepPosition, stepVelocity
end

local function correctAllSolid(position: Vector3, crouched: boolean, trace: TraceFunction): TraceResult?
	-- bg_pmove.c PM_CorrectAllSolid checks the 3x3x3 neighborhood at one
	-- source-unit offsets. Finding any non-all-solid sample is only a precision
	-- recovery signal; Q3 then repeats the canonical 0.25-unit ground trace from
	-- the original origin rather than moving the player to the jitter sample.
	for sourceX = -1, 1 do
		for sourceHorizontalY = -1, 1 do
			for sourceZ = -1, 1 do
				local offset = Vector3.new(sourceX, sourceZ, sourceHorizontalY) * Constants.AllSolidJitterDistance
				local sample = trace(position + offset, ZERO, crouched)
				if sample.allSolid ~= true then
					return trace(position, -UP * Constants.GroundProbeDistance, crouched)
				end
			end
		end
	end

	return nil
end

local function queryGround(
	position: Vector3,
	velocity: Vector3,
	crouched: boolean,
	trace: TraceFunction
): (boolean, boolean, Vector3, boolean, boolean, string?)
	local result = trace(position, -UP * Constants.GroundProbeDistance, crouched)
	assert(
		result.moverId == nil or validateMoverId(result.moverId) ~= nil,
		"movement trace returned an invalid mover identity"
	)
	if result.allSolid then
		local corrected = correctAllSolid(position, crouched, trace)
		if not corrected then
			return false, false, UP, false, false, nil
		end
		result = corrected
		assert(
			result.moverId == nil or validateMoverId(result.moverId) ~= nil,
			"corrected movement trace returned an invalid mover identity"
		)
	end
	if not result.hit then
		return false, false, result.normal, false, false, nil
	end
	-- bg_pmove.c PM_GroundTrace requires both positive source-Z velocity and a
	-- plane-normal component above 10 source units. Horizontal motion into a
	-- slope must not cause a false kickoff while the player is descending.
	if velocity.Y > 0 and velocity:Dot(result.normal) > Constants.GroundKickoffSpeed then
		return false, false, result.normal, false, false, nil
	end
	local surfaceSlick = result.surfaceSlick == true
	local surfaceNoDamage = result.surfaceNoDamage == true
	if result.normal.Y < Constants.MinimumWalkNormal then
		return false, true, result.normal, surfaceSlick, surfaceNoDamage, nil
	end

	return true, true, result.normal, surfaceSlick, surfaceNoDamage, result.moverId
end

local function emptyPointContents(_point: Vector3): number
	return WorldPointContents.Empty
end

local function sampleWaterAtViewHeight(
	position: Vector3,
	viewHeight: number,
	pointContents: PointContentsFunction
): (number, number)
	-- PM_SetWaterLevel first samples one source unit above MINS_Z. The bottom
	-- sample's complete known contents mask becomes watertype; the midpoint and
	-- viewheight samples only increase waterlevel.
	local bottomContents = pointContents(position + UP * Constants.WaterBottomSampleOffset)
	if not WorldPointContents.IsWater(bottomContents) then
		return 0, WorldPointContents.Empty
	end

	local sample2 = viewHeight - Constants.PlayerMinimumY
	local sample1 = sample2 * 0.5
	local waterLevel = 1
	local middleContents = pointContents(position + UP * (Constants.PlayerMinimumY + sample1))
	if WorldPointContents.IsWater(middleContents) then
		waterLevel = 2
		local headContents = pointContents(position + UP * (Constants.PlayerMinimumY + sample2))
		if WorldPointContents.IsWater(headContents) then
			waterLevel = 3
		end
	end

	return waterLevel, bottomContents
end

local function sampleWater(position: Vector3, crouched: boolean, pointContents: PointContentsFunction): (number, number)
	return sampleWaterAtViewHeight(position, Constants.ViewHeightFor(crouched), pointContents)
end

local function waterEvents(previousWaterLevel: number, waterLevel: number): WaterEvents
	local events: WaterEvents = {}
	-- PM_WaterEvents emits these four independent transitions in this exact
	-- order. Direct 0<->3 transitions therefore produce two ordered events.
	if previousWaterLevel == 0 and waterLevel ~= 0 then
		table.insert(events, "Touch")
	end
	if previousWaterLevel ~= 0 and waterLevel == 0 then
		table.insert(events, "Leave")
	end
	if previousWaterLevel ~= 3 and waterLevel == 3 then
		table.insert(events, "Under")
	end
	if previousWaterLevel == 3 and waterLevel ~= 3 then
		table.insert(events, "Clear")
	end
	return events
end

local function commandScale(command: Command): (number, number, number, number)
	-- bg_pmove.c PM_CmdScale operates directly on signed-char usercmd axes.
	-- Preserve the complete -128..127 domain and the source 127 denominator.
	local forwardMove = command.forward
	local rightMove = command.right
	local upMove = command.upMove
	local maximumAxis = math.max(math.abs(forwardMove), math.abs(rightMove), math.abs(upMove))
	local total = math.sqrt(forwardMove ^ 2 + rightMove ^ 2 + upMove ^ 2)
	local scale = if total > EPSILON
		then Constants.MaxSpeed * maximumAxis / (CommandQuantization.NormalizedAxisScale * total)
		else 0
	return scale, forwardMove, rightMove, upMove
end

local function getWish(
	command: Command,
	look: Vector3,
	effectiveUpMove: number,
	groundNormal: Vector3?,
	grounded: boolean,
	crouched: boolean,
	waterLevel: number
): (Vector3, number)
	local horizontalLook = Vector3.new(look.X, 0, look.Z)
	local forward = unitOrZero(horizontalLook)
	if forward == ZERO then
		forward = Vector3.new(0, 0, -1)
	end

	local right = Vector3.new(-forward.Z, 0, forward.X)

	if groundNormal then
		forward = unitOrZero(clipVelocity(forward, groundNormal))
		right = unitOrZero(clipVelocity(right, groundNormal))
	end

	local effectiveCommand = table.clone(command)
	effectiveCommand.upMove = effectiveUpMove
	local commandMovementScale, forwardMove, rightMove, _upMove = commandScale(effectiveCommand)
	local wishVelocity = forward * forwardMove + right * rightMove
	local wishDirection = unitOrZero(wishVelocity)
	local wishSpeed = wishVelocity.Magnitude * commandMovementScale
	if grounded and crouched then
		wishSpeed = math.min(wishSpeed, Constants.MaxSpeed * Constants.CrouchSpeedScale)
	end
	if grounded and waterLevel > 0 then
		local waterScale = waterLevel / 3
		waterScale = 1 - (1 - Constants.SwimSpeedScale) * waterScale
		wishSpeed = math.min(wishSpeed, Constants.MaxSpeed * waterScale)
	end

	return wishDirection, wishSpeed
end

local function commandLookWithoutDelta(command: Command): Vector3
	return CommandQuantization.DecodeViewLook({
		pitch = command.pitch,
		yaw = command.yaw,
	}) or Vector3.new(0, 0, -1)
end

local function getSwimWish(command: Command, effectiveLook: Vector3?): (Vector3, number)
	local movementScale, forwardMove, rightMove, upMove = commandScale(command)
	if movementScale == 0 then
		return -UP, Constants.WaterSinkSpeed
	end

	local forward = unitOrZero(effectiveLook or commandLookWithoutDelta(command))
	if forward == ZERO then
		forward = Vector3.new(0, 0, -1)
	end
	local flatForward = unitOrZero(Vector3.new(forward.X, 0, forward.Z))
	if flatForward == ZERO then
		flatForward = Vector3.new(0, 0, -1)
	end
	local right = Vector3.new(-flatForward.Z, 0, flatForward.X)
	local wishVelocity = (forward * forwardMove + right * rightMove + UP * upMove) * movementScale
	local wishSpeed = wishVelocity.Magnitude
	local wishDirection = unitOrZero(wishVelocity)
	return wishDirection, math.min(wishSpeed, Constants.MaxSpeed * Constants.SwimSpeedScale)
end

local function checkCrouch(state: State, command: Command, canOccupy: CanOccupyFunction): boolean
	if command.upMove < 0 then
		return true
	end
	if state.crouched and not canOccupy(state.position, false) then
		return true
	end
	return false
end

function Movement.newState(position: Vector3): State
	return {
		frame = 0,
		position = position,
		velocity = ZERO,
		look = Vector3.new(0, 0, -1),
		viewPitch = 0,
		viewYaw = 0,
		viewRoll = 0,
		deltaPitch = 0,
		deltaYaw = 0,
		deltaRoll = 0,
		grounded = false,
		groundPlane = false,
		groundNormal = UP,
		groundSlick = false,
		groundNoDamage = false,
		groundMoverId = nil,
		jumpHeld = false,
		crouched = false,
		waterLevel = 0,
		waterType = WorldPointContents.Empty,
		movementTime = 0,
		timeLand = false,
		timeKnockback = false,
		timeWaterJump = false,
		respawned = false,
	}
end

function Movement.ResolveEffectiveButtonLevels(command: Command): EffectiveButtonLevels?
	-- PmoveSingle clears a forged BUTTON_WALKING before any pm_type branch when
	-- either raw horizontal signed-char axis exceeds 64. Upmove is deliberately
	-- excluded from this anti-proxy rule.
	if
		CommandQuantization.DecodeAxes({
			forward = command.forward,
			right = command.right,
			upMove = command.upMove,
		}) == nil
	then
		return nil
	end
	local levels = CommandQuantization.DecodeButtonBits(command.buttons)
	if levels == nil then
		return nil
	end
	local effectiveWalking = levels.walking
		and math.abs(command.forward) <= CommandQuantization.WalkingAxisScale
		and math.abs(command.right) <= CommandQuantization.WalkingAxisScale
	if effectiveWalking == levels.walking then
		return levels
	end
	return table.freeze({
		attack = levels.attack,
		useHoldable = levels.useHoldable,
		walking = false,
	})
end

function Movement.EncodeCommand(input: InputCommand, state: State?): Command?
	local axes = CommandQuantization.EncodeAxesAtScale({
		forward = input.forward,
		right = input.right,
		upMove = input.upMove,
	}, if input.walking then CommandQuantization.WalkingAxisScale else CommandQuantization.RunAxisScale)
	local angles = CommandQuantization.EncodeViewLookWithDelta(input.look, {
		pitch = if state then state.deltaPitch else 0,
		yaw = if state then state.deltaYaw else 0,
		roll = if state then state.deltaRoll else 0,
	})
	local buttons = CommandQuantization.ButtonBitsFromLevels(input.attack, input.useHoldable, input.walking)
	local weaponId = CommandQuantization.ValidateWeaponByte(input.weaponId)
	if not axes or not angles or buttons == nil or weaponId == nil then
		return nil
	end
	return {
		forward = axes.forward,
		right = axes.right,
		upMove = axes.upMove,
		pitch = angles.pitch,
		yaw = angles.yaw,
		roll = angles.roll,
		buttons = buttons,
		weaponId = weaponId,
	}
end

function Movement.ResolveCommand(state: State, command: Command): ResolvedCommand?
	local axes = CommandQuantization.DecodeAxes({
		forward = command.forward,
		right = command.right,
		upMove = command.upMove,
	})
	local buttonLevels = Movement.ResolveEffectiveButtonLevels(command)
	local weaponId = CommandQuantization.ValidateWeaponByte(command.weaponId)
	if not axes or buttonLevels == nil or weaponId == nil then
		return nil
	end
	return {
		forward = axes.forward,
		right = axes.right,
		look = state.look,
		upMove = axes.upMove,
		attack = buttonLevels.attack,
		useHoldable = buttonLevels.useHoldable,
		walking = buttonLevels.walking,
		weaponId = weaponId,
	}
end

function Movement.SetViewAngle(state: State, command: Command, look: Vector3): State?
	local _delta, resolved = CommandQuantization.DeltaAnglesForViewLook({
		pitch = command.pitch,
		yaw = command.yaw,
		roll = command.roll,
	}, look)
	if not resolved then
		return nil
	end
	local nextState = table.clone(state)
	nextState.look = resolved.look
	nextState.viewPitch = resolved.pitch
	nextState.viewYaw = resolved.yaw
	nextState.viewRoll = resolved.roll
	nextState.deltaPitch = resolved.deltaPitch
	nextState.deltaYaw = resolved.deltaYaw
	nextState.deltaRoll = resolved.deltaRoll
	return nextState
end

function Movement.newSpawnState(position: Vector3): State
	-- g_client.c ClientSpawn sets 100 ms TIME_KNOCKBACK, then immediately runs a
	-- synthetic 100 ms ClientThink split that expires it before publication. Our
	-- authored spawn is already floor-resolved, so publish that post-think timer
	-- state while retaining PMF_RESPAWNED until Attack and Use are released.
	local state = Movement.newState(position)
	state.respawned = true
	return state
end

local function landingContact(
	phase: "Initial" | "Final",
	previousPosition: Vector3,
	landedPosition: Vector3,
	previousVelocity: Vector3,
	crouched: boolean,
	waterLevel: number,
	noDamageSurface: boolean
): LandingContact
	return {
		phase = phase,
		previousOriginY = previousPosition.Y,
		landedOriginY = landedPosition.Y,
		previousVelocityY = previousVelocity.Y,
		crouched = crouched,
		waterLevel = waterLevel,
		noDamageSurface = noDamageSurface,
	}
end

local function dropMovementTimer(
	movementTime: number,
	timeLand: boolean,
	timeKnockback: boolean,
	deltaTime: number
): (number, boolean, boolean)
	-- bg_pmove.c PM_DropTimers clears PMF_ALL_TIMES together only when the
	-- shared pm_time expires. TIME_LAND and TIME_KNOCKBACK may coexist.
	if movementTime > 0 then
		if deltaTime + EPSILON >= movementTime then
			return 0, false, false
		end
		movementTime -= deltaTime
	end
	return movementTime, timeLand, timeKnockback
end

local function dropAllMovementTimers(
	movementTime: number,
	timeLand: boolean,
	timeKnockback: boolean,
	timeWaterJump: boolean,
	deltaTime: number
): (number, boolean, boolean, boolean)
	local wasTimed = movementTime > 0
	movementTime, timeLand, timeKnockback = dropMovementTimer(movementTime, timeLand, timeKnockback, deltaTime)
	if wasTimed and movementTime == 0 then
		timeWaterJump = false
	end
	return movementTime, timeLand, timeKnockback, timeWaterJump
end

local function checkWaterJump(
	position: Vector3,
	command: Command,
	waterLevel: number,
	movementTime: number,
	pointContents: PointContentsFunction,
	effectiveLook: Vector3?
): Vector3?
	if movementTime ~= 0 or waterLevel ~= 2 then
		return nil
	end

	local forward = unitOrZero(effectiveLook or commandLookWithoutDelta(command))
	if forward == ZERO then
		forward = Vector3.new(0, 0, -1)
	end
	local flatForward = unitOrZero(Vector3.new(forward.X, 0, forward.Z))
	local lowerPoint = position
		+ flatForward * Constants.WaterJumpForwardProbeDistance
		+ UP * Constants.WaterJumpLowerProbeHeight
	local lowerContents = pointContents(lowerPoint)
	if bit32.band(lowerContents, WorldPointContents.Contents.Solid) == 0 then
		return nil
	end

	local upperContents = pointContents(lowerPoint + UP * Constants.WaterJumpUpperProbeHeight)
	if upperContents ~= WorldPointContents.Empty then
		return nil
	end

	return Vector3.new(
		forward.X * Constants.WaterJumpForwardVelocity,
		Constants.WaterJumpVerticalVelocity,
		forward.Z * Constants.WaterJumpForwardVelocity
	)
end

function Movement.step(
	state: State,
	command: Command,
	deltaTime: number,
	trace: TraceFunction,
	canOccupy: CanOccupyFunction,
	pointContents: PointContentsFunction?,
	flightActive: boolean?
): (State, LandingContacts, WaterEvents)
	assert(
		state.groundMoverId == nil or validateMoverId(state.groundMoverId) ~= nil,
		"Movement.step received an invalid ground mover identity"
	)
	assert(
		state.groundMoverId == nil or state.grounded,
		"Movement.step received a ground mover identity while airborne"
	)
	local pointContentsAt = pointContents or emptyPointContents
	-- PmoveSingle calls PM_UpdateViewAngles before every movement branch. Preserve
	-- the raw usercmd angle bits and authoritative delta-angle bits through the
	-- same circular signed-short addition and exact +/-16000 pitch correction.
	local resolvedView = assert(
		CommandQuantization.ResolveViewAngles({
			pitch = command.pitch,
			yaw = command.yaw,
			roll = command.roll,
		}, {
			pitch = state.deltaPitch,
			yaw = state.deltaYaw,
			roll = state.deltaRoll,
		}),
		"Movement.step received invalid packed view angles"
	)
	local effectiveLook = resolvedView.look
	local buttonLevels = Movement.ResolveEffectiveButtonLevels(command)
	assert(buttonLevels ~= nil, "Movement.step received invalid button bits")
	local position = state.position
	local velocity = state.velocity
	-- PmoveSingle samples water before PM_CheckDuck, so this first query uses the
	-- prior command's viewheight/stance. The final sample below uses the newly
	-- resolved crouch state.
	local initialWaterLevel, _initialWaterType = sampleWater(position, state.crouched, pointContentsAt)
	local crouched = checkCrouch(state, command, canOccupy)
	local grounded, groundPlane, groundNormal, groundSlick, groundNoDamage, _groundMoverId =
		queryGround(position, velocity, crouched, trace)
	local movementTime = state.movementTime
	local timeLand = state.timeLand
	local timeKnockback = state.timeKnockback
	local timeWaterJump = state.timeWaterJump
	local landingContacts: LandingContacts = {}
	-- PM_GroundTrace clears WATERJUMP and LAND (and the shared pm_time) before
	-- PM_CrashLand. A sufficiently hard new landing may immediately create LAND.
	if grounded and timeWaterJump then
		timeWaterJump = false
		timeLand = false
		movementTime = 0
	end
	if grounded and not state.grounded then
		table.insert(
			landingContacts,
			landingContact(
				"Initial",
				state.position,
				position,
				state.velocity,
				crouched,
				initialWaterLevel,
				groundNoDamage
			)
		)
		if state.velocity.Y < Constants.LandingTimerVelocity then
			timeLand = true
			movementTime = Constants.LandingTimerSeconds
		end
	end
	-- PmoveSingle runs PM_DropTimers after its initial PM_GroundTrace. A timer
	-- created by that trace is dropped in this command; one created by the final
	-- trace is not. Slide primal restore uses any surviving nonzero pm_time.
	movementTime, timeLand, timeKnockback, timeWaterJump =
		dropAllMovementTimers(movementTime, timeLand, timeKnockback, timeWaterJump, deltaTime)
	local timedMovement = movementTime > 0

	-- PmoveSingle clears PMF_RESPAWNED before PM_CheckJump on the first alive
	-- command with both BUTTON_ATTACK and BUTTON_USE_HOLDABLE released. Because
	-- this precedes PM_CheckJump, that same release command may jump.
	local respawned = state.respawned
	if respawned and not buttonLevels.attack and not buttonLevels.useHoldable then
		respawned = false
	end

	local wantsJump = command.upMove >= RAW_JUMP_COMMAND_THRESHOLD
	-- PMF_JUMP_HELD records a successful jump, not raw airborne button input.
	-- PmoveSingle clears it on release. PM_CheckJump sets it only when a grounded
	-- jump succeeds and clears upmove only when a grounded held jump is rejected.
	-- Airborne held upmove must remain in PM_CmdScale.
	local jumpHeld = if wantsJump then state.jumpHeld else false
	local jumping = initialWaterLevel <= 1
		and not flightActive
		and not timeWaterJump
		and wantsJump
		and not jumpHeld
		and grounded
		and not respawned
	if jumping then
		jumpHeld = true
	end
	local effectiveUpMove = if flightActive
		then command.upMove
		else if not respawned and grounded and wantsJump and state.jumpHeld then 0 else command.upMove
	local wishDirection: Vector3
	local wishSpeed: number
	local skipStepSlide = false
	local movementHandled = false

	if flightActive then
		-- Base Q3 checks PW_FLIGHT before WATERJUMP, swimming, and ordinary
		-- walk/air movement. PM_FlyMove applies flight friction and full 3D
		-- command acceleration, then step-slides without gravity.
		velocity = applyPmoveFriction(
			velocity,
			deltaTime,
			grounded,
			not (groundSlick or timeKnockback),
			initialWaterLevel,
			true
		)
		wishDirection, wishSpeed =
			getWish(command, effectiveLook, effectiveUpMove, nil, false, crouched, initialWaterLevel)
		velocity = accelerate(velocity, wishDirection, wishSpeed, Constants.FlightAcceleration, deltaTime)
		movementHandled = false
		grounded = false
		groundPlane = false
		groundNormal = UP
		groundSlick = false
		groundNoDamage = false
	elseif timeWaterJump then
		-- PM_WaterJumpMove has no command control. PM_StepSlideMove(qtrue)
		-- applies gravity once, then the function subtracts gravity a second time.
		position, velocity = stepSlideMove(
			position,
			velocity,
			deltaTime,
			true,
			if groundPlane then groundNormal else nil,
			crouched,
			trace,
			timedMovement
		)
		velocity -= UP * Constants.Gravity * deltaTime
		if velocity.Y < 0 then
			movementTime = 0
			timeLand = false
			timeKnockback = false
			timeWaterJump = false
		end
		movementHandled = true
	elseif initialWaterLevel > 1 then
		local launchVelocity =
			checkWaterJump(position, command, initialWaterLevel, movementTime, pointContentsAt, effectiveLook)
		if launchVelocity then
			velocity = launchVelocity
			movementTime = Constants.WaterJumpTimerSeconds
			timeWaterJump = true
			-- The timer is created after PM_DropTimers and is visible to the same
			-- command's timed slide restore.
			position, velocity = stepSlideMove(
				position,
				velocity,
				deltaTime,
				true,
				if groundPlane then groundNormal else nil,
				crouched,
				trace,
				true
			)
			velocity -= UP * Constants.Gravity * deltaTime
			if velocity.Y < 0 then
				movementTime = 0
				timeLand = false
				timeKnockback = false
				timeWaterJump = false
			end
		else
			velocity =
				applyPmoveFriction(velocity, deltaTime, grounded, not (groundSlick or timeKnockback), initialWaterLevel)
			wishDirection, wishSpeed = getSwimWish(command, effectiveLook)
			velocity = accelerate(velocity, wishDirection, wishSpeed, Constants.WaterAcceleration, deltaTime)
			if groundPlane and velocity:Dot(groundNormal) < 0 then
				local speed = velocity.Magnitude
				velocity = clipVelocity(velocity, groundNormal)
				if speed > EPSILON and velocity.Magnitude > EPSILON then
					velocity = velocity.Unit * speed
				end
			end
			position, velocity = slideMove(
				position,
				velocity,
				deltaTime,
				false,
				if groundPlane then groundNormal else nil,
				crouched,
				trace,
				timedMovement
			)
		end
		movementHandled = true
	elseif jumping then
		grounded = false
		groundPlane = false
		groundNormal = UP
		groundSlick = false
		groundNoDamage = false
		velocity = Vector3.new(velocity.X, Constants.JumpVelocity, velocity.Z)
		velocity = applyPmoveFriction(velocity, deltaTime, false, false, initialWaterLevel)
		wishDirection, wishSpeed =
			getWish(command, effectiveLook, effectiveUpMove, nil, false, crouched, initialWaterLevel)
		velocity = accelerate(velocity, wishDirection, wishSpeed, Constants.AirAcceleration, deltaTime)
	else
		if grounded then
			-- PM_Friction always performs its walking speed cutoff. SURF_SLICK and
			-- PMF_TIME_KNOCKBACK suppress only the ordinary friction drop.
			local reducedControl = groundSlick or timeKnockback
			velocity = applyPmoveFriction(velocity, deltaTime, true, not reducedControl, initialWaterLevel)
			wishDirection, wishSpeed =
				getWish(command, effectiveLook, effectiveUpMove, groundNormal, true, crouched, initialWaterLevel)
			velocity = accelerate(
				velocity,
				wishDirection,
				wishSpeed,
				if reducedControl then Constants.AirAcceleration else Constants.GroundAcceleration,
				deltaTime
			)
			if reducedControl then
				-- PM_WalkMove applies gravity for SURF_SLICK or PMF_TIME_KNOCKBACK
				-- before clipping to the ground plane, then step-slides without gravity.
				velocity -= UP * Constants.Gravity * deltaTime
			end

			local speed = velocity.Magnitude
			velocity = clipVelocity(velocity, groundNormal)
			if speed > EPSILON and velocity.Magnitude > EPSILON then
				velocity = velocity.Unit * speed
			end
			-- PM_WalkMove returns before PM_StepSlideMove when both source
			-- horizontal components are exactly zero. The final ground trace still
			-- runs below, as it does in PmoveSingle.
			skipStepSlide = velocity.X == 0 and velocity.Z == 0
		else
			velocity = applyPmoveFriction(velocity, deltaTime, false, false, initialWaterLevel)
			wishDirection, wishSpeed =
				getWish(command, effectiveLook, effectiveUpMove, nil, false, crouched, initialWaterLevel)
			velocity = accelerate(velocity, wishDirection, wishSpeed, Constants.AirAcceleration, deltaTime)
			if groundPlane then
				-- PM_AirMove clips against a steep ground plane before
				-- PM_StepSlideMove snapshots the gravity end velocity.
				velocity = clipVelocity(velocity, groundNormal)
			end
		end
	end

	if not movementHandled and not skipStepSlide then
		position, velocity = stepSlideMove(
			position,
			velocity,
			deltaTime,
			not grounded,
			if groundPlane then groundNormal else nil,
			crouched,
			trace,
			timedMovement
		)
	end

	local groundedBeforeFinalTrace = grounded
	local finalGrounded, finalGroundPlane, finalNormal, finalGroundSlick, finalGroundNoDamage, finalGroundMoverId =
		queryGround(position, velocity, crouched, trace)
	if finalGrounded and timeWaterJump then
		timeWaterJump = false
		timeLand = false
		movementTime = 0
	end
	if finalGrounded and not groundedBeforeFinalTrace then
		table.insert(
			landingContacts,
			landingContact(
				"Final",
				state.position,
				position,
				state.velocity,
				crouched,
				initialWaterLevel,
				finalGroundNoDamage
			)
		)
		if state.velocity.Y < Constants.LandingTimerVelocity then
			timeLand = true
			movementTime = Constants.LandingTimerSeconds
		end
	end
	if finalGrounded then
		grounded = true
		groundPlane = true
		groundNormal = finalNormal
	else
		grounded = false
		groundPlane = finalGroundPlane
		groundNormal = if finalGroundPlane then finalNormal else UP
	end
	groundSlick = if finalGroundPlane then finalGroundSlick else false
	groundNoDamage = if finalGroundPlane then finalGroundNoDamage else false
	local groundMoverId = if finalGrounded then finalGroundMoverId else nil
	local finalWaterLevel, finalWaterType = sampleWater(position, crouched, pointContentsAt)
	local orderedWaterEvents = waterEvents(initialWaterLevel, finalWaterLevel)

	-- PmoveSingle snaps velocity only after final ground, final water sampling,
	-- and PM_WaterEvents. Positions remain unsnapped.
	velocity = snapVelocity(velocity)

	return {
		frame = state.frame + 1,
		position = position,
		velocity = velocity,
		look = effectiveLook,
		viewPitch = resolvedView.pitch,
		viewYaw = resolvedView.yaw,
		viewRoll = resolvedView.roll,
		deltaPitch = resolvedView.deltaPitch,
		deltaYaw = resolvedView.deltaYaw,
		deltaRoll = resolvedView.deltaRoll,
		grounded = grounded,
		groundPlane = groundPlane,
		groundNormal = groundNormal,
		groundSlick = groundSlick,
		groundNoDamage = groundNoDamage,
		groundMoverId = groundMoverId,
		jumpHeld = jumpHeld,
		crouched = crouched,
		waterLevel = finalWaterLevel,
		waterType = finalWaterType,
		movementTime = movementTime,
		timeLand = timeLand,
		timeKnockback = timeKnockback,
		timeWaterJump = timeWaterJump,
		respawned = respawned,
	},
		landingContacts,
		orderedWaterEvents
end

local function applyDeadMove(velocity: Vector3, walking: boolean): Vector3
	-- bg_pmove.c::PM_DeadMove removes exactly 20 source units from the complete
	-- three-dimensional velocity once per PmoveSingle, but only while walking.
	-- This fixed decrement deliberately does not scale with pml.frametime.
	if not walking then
		return velocity
	end

	local speed = velocity.Magnitude
	local remainingSpeed = speed - Constants.DeadMoveSpeedDrop
	if remainingSpeed <= 0 then
		return ZERO
	end
	return velocity * (remainingSpeed / speed)
end

local function sanitizeDeadCommand(command: Command): (Command, boolean, boolean)
	assert(CommandQuantization.DecodeAxes({
		forward = command.forward,
		right = command.right,
		upMove = command.upMove,
	}) ~= nil, "Movement.stepDead received invalid command axes")
	assert(
		CommandQuantization.ValidateAngleBits(command.pitch) ~= nil
			and CommandQuantization.ValidateAngleBits(command.yaw) ~= nil
			and CommandQuantization.ValidateAngleBits(command.roll) ~= nil,
		"Movement.stepDead received invalid packed view angles"
	)
	local buttonLevels = Movement.ResolveEffectiveButtonLevels(command)
	assert(buttonLevels ~= nil, "Movement.stepDead received invalid button bits")
	local effectiveButtons = assert(
		CommandQuantization.ButtonBitsFromLevels(buttonLevels.attack, buttonLevels.useHoldable, buttonLevels.walking),
		"Movement.stepDead failed to encode effective button levels"
	)
	local weaponId = CommandQuantization.ValidateWeaponByte(command.weaponId)
	assert(weaponId ~= nil, "Movement.stepDead received invalid weapon byte")

	return table.freeze({
		forward = 0,
		right = 0,
		upMove = 0,
		pitch = command.pitch,
		yaw = command.yaw,
		roll = command.roll,
		buttons = effectiveButtons,
		weaponId = weaponId,
	}),
		buttonLevels.attack,
		buttonLevels.useHoldable
end

local function deadTraceAdapter(trace: DeadTraceFunction): TraceFunction
	return function(origin: Vector3, displacement: Vector3, _crouched: boolean): TraceResult
		return trace(origin, displacement, DEAD_TRACE_QUERY)
	end
end

function Movement.newDeadState(state: State): DeadState
	assert(
		state.groundMoverId == nil or validateMoverId(state.groundMoverId) ~= nil,
		"Movement.newDeadState received an invalid ground mover identity"
	)
	assert(
		state.groundMoverId == nil or state.grounded,
		"Movement.newDeadState received a ground mover identity while airborne"
	)
	-- The first dead Pmove samples water before PM_CheckDuck replaces the prior
	-- alive viewheight with DEAD_VIEWHEIGHT. Carry that one prior value explicitly.
	return {
		state = state,
		viewHeight = Constants.ViewHeightFor(state.crouched),
	}
end

function Movement.stepDead(
	deadState: DeadState,
	command: Command,
	deltaTime: number,
	deadTrace: DeadTraceFunction,
	pointContents: PointContentsFunction?
): (DeadState, DeadStepEffects)
	local state = deadState.state
	assert(
		state.groundMoverId == nil or validateMoverId(state.groundMoverId) ~= nil,
		"Movement.stepDead received an invalid ground mover identity"
	)
	assert(
		state.groundMoverId == nil or state.grounded,
		"Movement.stepDead received a ground mover identity while airborne"
	)
	assert(
		deadState.viewHeight == Constants.StandingViewHeight
			or deadState.viewHeight == Constants.CrouchedViewHeight
			or deadState.viewHeight == Constants.DeadViewHeight,
		"Movement.stepDead received an invalid prior viewheight"
	)

	local pointContentsAt = pointContents or emptyPointContents
	local deadCommand, attackPressed, useHoldablePressed = sanitizeDeadCommand(command)
	local trace = deadTraceAdapter(deadTrace)
	local position = state.position
	local velocity = state.velocity
	local initialWaterLevel, _initialWaterType =
		sampleWaterAtViewHeight(position, deadState.viewHeight, pointContentsAt)

	-- PM_CheckDuck retains PMF_DUCKED while selecting the independent dead hull.
	-- Every trace below ignores that retained flag and receives DEAD_TRACE_QUERY.
	local crouched = state.crouched
	local grounded, groundPlane, groundNormal, groundSlick, groundNoDamage, _groundMoverId =
		queryGround(position, velocity, crouched, trace)
	local movementTime = state.movementTime
	local timeLand = state.timeLand
	local timeKnockback = state.timeKnockback
	local timeWaterJump = state.timeWaterJump
	local landingContacts: LandingContacts = {}

	if grounded and timeWaterJump then
		timeWaterJump = false
		timeLand = false
		movementTime = 0
	end
	if grounded and not state.grounded then
		table.insert(
			landingContacts,
			landingContact(
				"Initial",
				state.position,
				position,
				state.velocity,
				crouched,
				initialWaterLevel,
				groundNoDamage
			)
		)
		if state.velocity.Y < Constants.LandingTimerVelocity then
			timeLand = true
			movementTime = Constants.LandingTimerSeconds
		end
	end

	-- Source order is initial water -> dead hull -> initial ground -> PM_DeadMove
	-- -> PM_DropTimers -> the ordinary water/walk/air branch.
	velocity = applyDeadMove(velocity, grounded)
	movementTime, timeLand, timeKnockback, timeWaterJump =
		dropAllMovementTimers(movementTime, timeLand, timeKnockback, timeWaterJump, deltaTime)
	local timedMovement = movementTime > 0

	-- PMF_JUMP_HELD is released from the original command before PmoveSingle
	-- zeros the dead movement axes. A held positive axis cannot cause a jump.
	local jumpHeld = if command.upMove < RAW_JUMP_COMMAND_THRESHOLD then false else state.jumpHeld
	local effectiveLook = state.look -- PM_UpdateViewAngles is a no-op while dead.
	local wishDirection: Vector3
	local wishSpeed: number
	local skipStepSlide = false
	local movementHandled = false

	if timeWaterJump then
		position, velocity = stepSlideMove(
			position,
			velocity,
			deltaTime,
			true,
			if groundPlane then groundNormal else nil,
			crouched,
			trace,
			timedMovement
		)
		velocity -= UP * Constants.Gravity * deltaTime
		if velocity.Y < 0 then
			movementTime = 0
			timeLand = false
			timeKnockback = false
			timeWaterJump = false
		end
		movementHandled = true
	elseif initialWaterLevel > 1 then
		local launchVelocity =
			checkWaterJump(position, deadCommand, initialWaterLevel, movementTime, pointContentsAt, effectiveLook)
		if launchVelocity then
			velocity = launchVelocity
			movementTime = Constants.WaterJumpTimerSeconds
			timeWaterJump = true
			position, velocity = stepSlideMove(
				position,
				velocity,
				deltaTime,
				true,
				if groundPlane then groundNormal else nil,
				crouched,
				trace,
				true
			)
			velocity -= UP * Constants.Gravity * deltaTime
			if velocity.Y < 0 then
				movementTime = 0
				timeLand = false
				timeKnockback = false
				timeWaterJump = false
			end
		else
			velocity =
				applyPmoveFriction(velocity, deltaTime, grounded, not (groundSlick or timeKnockback), initialWaterLevel)
			wishDirection, wishSpeed = getSwimWish(deadCommand, effectiveLook)
			velocity = accelerate(velocity, wishDirection, wishSpeed, Constants.WaterAcceleration, deltaTime)
			if groundPlane and velocity:Dot(groundNormal) < 0 then
				local speed = velocity.Magnitude
				velocity = clipVelocity(velocity, groundNormal)
				if speed > EPSILON and velocity.Magnitude > EPSILON then
					velocity = velocity.Unit * speed
				end
			end
			position, velocity = slideMove(
				position,
				velocity,
				deltaTime,
				false,
				if groundPlane then groundNormal else nil,
				crouched,
				trace,
				timedMovement
			)
		end
		movementHandled = true
	elseif grounded then
		local reducedControl = groundSlick or timeKnockback
		velocity = applyPmoveFriction(velocity, deltaTime, true, not reducedControl, initialWaterLevel)
		wishDirection, wishSpeed =
			getWish(deadCommand, effectiveLook, 0, groundNormal, true, crouched, initialWaterLevel)
		velocity = accelerate(
			velocity,
			wishDirection,
			wishSpeed,
			if reducedControl then Constants.AirAcceleration else Constants.GroundAcceleration,
			deltaTime
		)
		if reducedControl then
			velocity -= UP * Constants.Gravity * deltaTime
		end

		local speed = velocity.Magnitude
		velocity = clipVelocity(velocity, groundNormal)
		if speed > EPSILON and velocity.Magnitude > EPSILON then
			velocity = velocity.Unit * speed
		end
		skipStepSlide = velocity.X == 0 and velocity.Z == 0
	else
		velocity = applyPmoveFriction(velocity, deltaTime, false, false, initialWaterLevel)
		wishDirection, wishSpeed = getWish(deadCommand, effectiveLook, 0, nil, false, crouched, initialWaterLevel)
		velocity = accelerate(velocity, wishDirection, wishSpeed, Constants.AirAcceleration, deltaTime)
		if groundPlane then
			velocity = clipVelocity(velocity, groundNormal)
		end
	end

	if not movementHandled and not skipStepSlide then
		position, velocity = stepSlideMove(
			position,
			velocity,
			deltaTime,
			not grounded,
			if groundPlane then groundNormal else nil,
			crouched,
			trace,
			timedMovement
		)
	end

	local groundedBeforeFinalTrace = grounded
	local finalGrounded, finalGroundPlane, finalNormal, finalGroundSlick, finalGroundNoDamage, finalGroundMoverId =
		queryGround(position, velocity, crouched, trace)
	if finalGrounded and timeWaterJump then
		timeWaterJump = false
		timeLand = false
		movementTime = 0
	end
	if finalGrounded and not groundedBeforeFinalTrace then
		table.insert(
			landingContacts,
			landingContact(
				"Final",
				state.position,
				position,
				state.velocity,
				crouched,
				initialWaterLevel,
				finalGroundNoDamage
			)
		)
		if state.velocity.Y < Constants.LandingTimerVelocity then
			timeLand = true
			movementTime = Constants.LandingTimerSeconds
		end
	end
	if finalGrounded then
		grounded = true
		groundPlane = true
		groundNormal = finalNormal
	else
		grounded = false
		groundPlane = finalGroundPlane
		groundNormal = if finalGroundPlane then finalNormal else UP
	end
	groundSlick = if finalGroundPlane then finalGroundSlick else false
	groundNoDamage = if finalGroundPlane then finalGroundNoDamage else false
	local groundMoverId = if finalGrounded then finalGroundMoverId else nil
	local finalWaterLevel, finalWaterType = sampleWaterAtViewHeight(position, Constants.DeadViewHeight, pointContentsAt)
	local orderedWaterEvents = waterEvents(initialWaterLevel, finalWaterLevel)
	velocity = snapVelocity(velocity)
	local weaponPolicy = if state.respawned then RESPAWN_LATCHED_DEAD_WEAPON_POLICY else DEAD_WEAPON_POLICY

	local nextState: State = {
		frame = state.frame + 1,
		position = position,
		velocity = velocity,
		look = state.look,
		viewPitch = state.viewPitch,
		viewYaw = state.viewYaw,
		viewRoll = state.viewRoll,
		deltaPitch = state.deltaPitch,
		deltaYaw = state.deltaYaw,
		deltaRoll = state.deltaRoll,
		grounded = grounded,
		groundPlane = groundPlane,
		groundNormal = groundNormal,
		groundSlick = groundSlick,
		groundNoDamage = groundNoDamage,
		groundMoverId = groundMoverId,
		jumpHeld = jumpHeld,
		crouched = crouched,
		waterLevel = finalWaterLevel,
		waterType = finalWaterType,
		movementTime = movementTime,
		timeLand = timeLand,
		timeKnockback = timeKnockback,
		timeWaterJump = timeWaterJump,
		-- PmoveSingle only clears PMF_RESPAWNED when health is positive.
		respawned = state.respawned,
	}
	return {
		state = nextState,
		viewHeight = Constants.DeadViewHeight,
	}, {
		command = deadCommand,
		attackPressed = attackPressed,
		useHoldablePressed = useHoldablePressed,
		waterEvents = orderedWaterEvents,
		landingContacts = landingContacts,
		landingEventPolicy = DEAD_LANDING_EVENT_POLICY,
		weaponPolicy = weaponPolicy,
		traceQuery = DEAD_TRACE_QUERY,
	}
end

Movement.clipVelocity = clipVelocity
Movement.accelerate = accelerate
Movement.applyWalkingFriction = applyWalkingFriction
Movement.applyGroundFriction = applyGroundFriction
Movement.applyDryAirFriction = applyDryAirFriction
Movement.applyPmoveFriction = applyPmoveFriction
Movement.snapVelocity = snapVelocity
Movement.queryGround = queryGround
Movement.sampleWater = sampleWater
Movement.waterEvents = waterEvents
Movement.checkWaterJump = checkWaterJump
Movement.getSwimWish = getSwimWish
Movement.resolvePlanes = resolvePlanes
Movement.slideMove = slideMove
Movement.stepSlideMove = stepSlideMove
Movement.dropMovementTimer = dropMovementTimer
Movement.applyDeadMove = applyDeadMove
Movement.ValidateMoverId = validateMoverId
Movement.MaximumMoverIdLength = MAXIMUM_MOVER_ID_LENGTH

return table.freeze(Movement)
