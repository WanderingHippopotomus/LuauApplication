--!strict

--[[
Path Finding AI
The AI Will:
- Wander when no player is visible.
- Sprint toward the nearest player once they enter SightRange.
- Kill any player it touches OR reaches within AttackRange.
- Attempt several stuck-recovery strategies before teleporting.

* Script resides inside AI Model in Workspace
]]--

local PathfindingService = game:GetService("PathfindingService")
local Players           = game:GetService("Players")
local Debris            = game:GetService("Debris")

-------------------------------------------------------
-- Tunable constants
-------------------------------------------------------
local CONFIG = {
	-- Movement speeds
	WalkSpeed   = 16,
	SprintSpeed = 20,
	SlowSpeed   = 10,

	-- Jump forces
	BaseJumpImpulse = 50,
	MaxJumpImpulse  = 110,

	-- Detection / engagement
	SightRange  = 180, -- studs; maximum distance to detect a player
	AttackRange = 4,   -- studs; instant-kill radius
	SprintDist  = 40,  -- switch to sprint when target is farther than this
	SlowDist    = 10,  -- switch to slow walk when target is closer than this

	-- Stuck detection
	StuckThreshold    = 2.0, -- seconds of low movement before "stuck" triggers
	MovementThreshold = 1.2, -- studs; minimum movement per tick to not be "stuck"
	MaxRecoverySteps  = 5,   -- how many recovery attempts before we teleport

	-- Teleport (last-resort recovery)
	TeleportOffset   = 12, -- studs behind the target to land
	TeleportCooldown = 6,  -- seconds between allowed teleports

	-- Pathfinding
	PathUpdateRate = 0.35, -- seconds between path recomputes while chasing
	WanderDelay    = 4,    -- seconds between wander moves when idle
	WanderRadius   = 20,   -- studs; maximum wander displacement
}

-------------------------------------------------------
-- Character references
-------------------------------------------------------
local NpcModel  = script.Parent
local Humanoid  = NpcModel:WaitForChild("Humanoid") :: Humanoid
local RootPart  = NpcModel:WaitForChild("HumanoidRootPart") :: BasePart

-------------------------------------------------------
-- Path objects
-------------------------------------------------------
-- normalPath   – used for general navigation; allows jumping and climbing.
-- precisePath  – used when normalPath is blocked; tighter radius, no jumping.

local normalPath = PathfindingService:CreatePath({
	AgentHeight    = 6,
	AgentRadius    = 3,
	AgentCanJump   = true,
	AgentMaxSlope  = 50,
	AgentCanClimb  = true,
	Costs          = { Water = 100 },
})

local precisePath = PathfindingService:CreatePath({
	AgentHeight   = 5,
	AgentRadius   = 2,
	AgentCanJump  = false,
	AgentMaxSlope = 35,
	AgentCanClimb = true,
})

-------------------------------------------------------
--Mutable runtime state
-------------------------------------------------------
local navState = {
	-- Stuck detection
	stuckTimer       = 0,
	lastPosition     = RootPart.Position,

	-- Recovery bookkeeping
	recoveryStep     = 0,   -- which recovery strategy are we on?
	consecutiveStuck = 0,   -- total stuck events since last successful move

	-- Timing
	lastPathTime     = 0,
	lastTeleportTime = 0,
	lastWanderTime   = 0,

	-- Jump state (prevents double-jump)
	isJumping        = false,

	-- When true, use precisePath instead of normalPath
	precisionMode    = false,

	-- Active path waypoints
	waypoints      = {} :: { PathWaypoint },
	waypointIndex  = 2,

	-- Active path event connections (cleaned up before each new path)
	reachedConn = nil :: RBXScriptConnection?,
	blockedConn = nil :: RBXScriptConnection?,
}

-------------------------------------------------------
-- UTILITY HELPERS
-------------------------------------------------------

-- Cast a ray while excluding the NPC's own parts.
local function castRay(origin: Vector3, direction: Vector3): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType                  = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances  = { NpcModel }
	return workspace:Raycast(origin, direction, params)
end

-- Disconnect both path event listeners and nil their references.
local function disconnectPathEvents()
	if navState.reachedConn then
		navState.reachedConn:Disconnect()
		navState.reachedConn = nil
	end
	if navState.blockedConn then
		navState.blockedConn:Disconnect()
		navState.blockedConn = nil
	end
end

--- Apply a walk speed with a ±1 stud/s jitter so movement feels organic.
local function applySpeed(speed: number)
	Humanoid.WalkSpeed = speed + math.random(-1, 1)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- JUMP (replaces deprecated JumpPower / BodyVelocity)
-- ─────────────────────────────────────────────────────────────────────────────

--- Trigger a jump scaled by the height difference to the next waypoint.
--- Uses Humanoid:ChangeState to avoid writing to the deprecated JumpPower.
--- An Attachment + LinearVelocity impulse is used for the extra vertical boost.
local function performJump(heightDifference: number)
	if navState.isJumping then return end

	-- Scale impulse: taller obstacle → stronger jump, clamped to MaxJumpImpulse.
	local impulse = math.clamp(
		CONFIG.BaseJumpImpulse + heightDifference * 3.5,
		CONFIG.BaseJumpImpulse,
		CONFIG.MaxJumpImpulse
	)

	-- Create a one-shot LinearVelocity to provide the vertical boost.
	-- LinearVelocity replaced the deprecated BodyVelocity in Roblox 2022.
	local attachment = Instance.new("Attachment")
	attachment.Parent = RootPart

	local lv = Instance.new("LinearVelocity")
	lv.Attachment0       = attachment
	lv.MaxForce          = math.huge
	lv.VectorVelocity    = Vector3.new(0, impulse, 0)
	lv.RelativeTo        = Enum.ActuatorRelativeTo.World
	lv.Parent            = attachment

	-- The impulse only needs to act for one physics frame; clean up quickly.
	Debris:AddItem(lv, 0.08)
	Debris:AddItem(attachment, 0.1)

	-- Signal the Humanoid so animations and state machine stay in sync.
	Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)

	navState.isJumping = true
	task.delay(0.9, function()
		navState.isJumping = false
	end)
end

-------------------------------------------------------
-- KILL-ON-TOUCH
-------------------------------------------------------

-- Wire up Touched events on every NPC part so contact kills the player.
local function setupKillOnTouch()
	for _, part in NpcModel:GetDescendants() do
		if not part:IsA("BasePart") then continue end

		part.Touched:Connect(function(hit: BasePart)
			local hitModel = hit.Parent
			if not hitModel then return end          -- parent may be nil (strict mode)
			if hitModel == NpcModel then return end  -- ignore self-collision

			local hitHumanoid = hitModel:FindFirstChildOfClass("Humanoid") :: Humanoid?
			if not hitHumanoid or hitHumanoid.Health <= 0 then return end

			-- Only kill actual player characters, not other NPCs.
			for _, player in Players:GetPlayers() do
				if player.Character == hitModel then
					hitHumanoid.Health = 0
					break
				end
			end
		end)
	end
end

-------------------------------------------------------
-- TARGET DETECTION
-------------------------------------------------------

-- Return the nearest living player character within SightRange, plus distance.
local function findNearestTarget(): (Model?, number)
	local bestTarget: Model? = nil
	local bestDist = CONFIG.SightRange

	for _, player in Players:GetPlayers() do
		local char = player.Character
		if not char then continue end

		local targetRoot = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not targetRoot then continue end

		local targetHum = char:FindFirstChildOfClass("Humanoid")
		if not targetHum or targetHum.Health <= 0 then continue end

		local dist = (RootPart.Position - targetRoot.Position).Magnitude
		if dist < bestDist then
			bestTarget = char
			bestDist   = dist
		end
	end

	return bestTarget, bestDist
end

-- Instantly kill the target if it is within AttackRange.
local function killIfInRange(targetChar: Model)
	local targetRoot = targetChar:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not targetRoot then return end

	local targetHum = targetChar:FindFirstChildOfClass("Humanoid")
	if not targetHum or targetHum.Health <= 0 then return end

	if (RootPart.Position - targetRoot.Position).Magnitude <= CONFIG.AttackRange then
		targetHum.Health = 0
	end
end

-------------------------------------------------------
-- SPEED MANAGEMENT
-------------------------------------------------------

-- Adjust walk speed based on distance to target.
local function updateChaseSpeed(dist: number)
	if dist > CONFIG.SprintDist then
		applySpeed(CONFIG.SprintSpeed)
	elseif dist < CONFIG.SlowDist then
		applySpeed(CONFIG.SlowSpeed)
	else
		applySpeed(CONFIG.WalkSpeed)
	end
end

-------------------------------------------------------
-- OBSTACLE DETECTION
-------------------------------------------------------

type ObstacleKind = "wall" | "gap" | "none"

-- Look ahead with two rays to detect walls and ledge gaps.
-- Returns the obstacle type and a numeric payload (wall height or gap depth).
local function detectObstacleAhead(): (ObstacleKind, number)
	local forward = RootPart.CFrame.LookVector
	local pos     = RootPart.Position

	-- Forward ray slightly above ground: checks for climbable walls.
	local wallHit = castRay(pos + Vector3.new(0, 1, 0), forward * 3.5)
	if wallHit then
		local wallHeight = wallHit.Position.Y - pos.Y
		if wallHeight > 0.5 and wallHeight < 12 then
			return "wall", wallHeight
		end
	end

	-- Downward ray ahead of the NPC: missing ground means a gap.
	local groundAhead = castRay(pos + forward * 4 + Vector3.new(0, 0.5, 0), Vector3.new(0, -6, 0))
	if not groundAhead then
		return "gap", 4
	end

	return "none", 0
end

-------------------------------------------------------
-- PATHFINDING
-------------------------------------------------------

-- Compute a path to `destination` and begin following it waypoint by waypoint.
-- Falls back to a direct MoveTo if pathfinding fails.
local function followPath(destination: Vector3)
	local activePath = navState.precisionMode and precisePath or normalPath

	local computeOk = pcall(function()
		activePath:ComputeAsync(RootPart.Position, destination)
	end)

	if not computeOk or activePath.Status ~= Enum.PathStatus.Success then
		-- Path computation failed; move directly and note we may be stuck.
		navState.consecutiveStuck += 1
		Humanoid:MoveTo(destination)
		return
	end

	local waypoints = activePath:GetWaypoints()
	if #waypoints < 2 then
		Humanoid:MoveTo(destination)
		return
	end

	disconnectPathEvents()
	navState.waypoints     = waypoints
	navState.waypointIndex = 2

	-- If the path becomes blocked mid-traversal, switch to precision mode and retry.
	navState.blockedConn = activePath.Blocked:Connect(function(blockedIdx: number)
		if blockedIdx < navState.waypointIndex then return end -- already past the block
		disconnectPathEvents()
		navState.precisionMode = true
		followPath(destination)
	end)

	-- Advance to the next waypoint once the current one is reached.
	navState.reachedConn = Humanoid.MoveToFinished:Connect(function(didReach: boolean)
		if not didReach or navState.waypointIndex >= #navState.waypoints then
			disconnectPathEvents()
			navState.precisionMode = false
			return
		end

		navState.waypointIndex += 1
		local nextWaypoint = navState.waypoints[navState.waypointIndex]

		if nextWaypoint.Action == Enum.PathWaypointAction.Jump then
			performJump(nextWaypoint.Position.Y - RootPart.Position.Y)
		end

		Humanoid:MoveTo(nextWaypoint.Position)
	end)

	Humanoid:MoveTo(waypoints[2].Position)
end

-------------------------------------------------------
-- TELEPORT (last-resort recovery)
-------------------------------------------------------

-- Teleport the NPC to a point behind the target, clearing all stuck state.
-- Returns true if the teleport actually happened (cooldown may prevent it).
local function teleportBehindTarget(targetPos: Vector3): boolean
	if tick() - navState.lastTeleportTime < CONFIG.TeleportCooldown then
		return false
	end

	-- Land a fixed offset behind the target (relative to NPC→target direction).
	local behindDir   = (RootPart.Position - targetPos).Unit
	local landingPos  = targetPos + behindDir * CONFIG.TeleportOffset

	-- Snap to ground if a surface exists below the landing point.
	local groundHit = castRay(landingPos + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0))
	if groundHit then
		landingPos = groundHit.Position + Vector3.new(0, 4, 0)
	end

	RootPart.CFrame = CFrame.new(landingPos)

	navState.lastTeleportTime = tick()
	navState.consecutiveStuck = 0
	navState.recoveryStep     = 0
	navState.stuckTimer       = 0
	navState.precisionMode    = false
	navState.lastPosition     = RootPart.Position
	return true
end

-------------------------------------------------------
-- STUCK DETECTION
-------------------------------------------------------

-- Returns true once the NPC has barely moved for StuckThreshold seconds.
local function checkIfStuck(): boolean
	local moved = (RootPart.Position - navState.lastPosition).Magnitude

	if moved >= CONFIG.MovementThreshold or navState.isJumping then
		-- Made meaningful progress – reset the stuck timer.
		navState.stuckTimer   = 0
		navState.lastPosition = RootPart.Position
		return false
	end

	navState.stuckTimer += 0.1 -- matches the task.wait(0.1) in main()
	return navState.stuckTimer >= CONFIG.StuckThreshold
end

-------------------------------------------------------
-- STUCK RECOVERY  (ordered escalation, no deep nesting)
-------------------------------------------------------

-- Each recovery action is a self-contained function.
-- They are indexed so handleStuck() can select by recoveryStep.

local recoveryActions: { (targetPos: Vector3) -> () } = {
	-- Step 1 – try a simple jump toward the target.
	function(targetPos)
		performJump(15)
		Humanoid:MoveTo(targetPos)
	end,

	-- Step 2 – sidestep left then resume.
	function(targetPos)
		local leftPos = RootPart.Position - RootPart.CFrame.RightVector * 6
		Humanoid:MoveTo(leftPos)
		task.delay(0.8, function() Humanoid:MoveTo(targetPos) end)
	end,

	-- Step 3 – impulse launch (replaces deprecated BodyVelocity).
	function(targetPos)
		local attachment = Instance.new("Attachment")
		attachment.Parent = RootPart

		local lv = Instance.new("LinearVelocity")
		lv.Attachment0    = attachment
		lv.MaxForce       = math.huge
		lv.VectorVelocity = (targetPos - RootPart.Position).Unit * 35 + Vector3.new(0, 70, 0)
		lv.RelativeTo     = Enum.ActuatorRelativeTo.World
		lv.Parent         = attachment

		Debris:AddItem(lv, 0.5)
		Debris:AddItem(attachment, 0.6)

		Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end,

	-- Step 4 – sidestep right then resume.
	function(targetPos)
		local rightPos = RootPart.Position + RootPart.CFrame.RightVector * 6
		Humanoid:MoveTo(rightPos)
		task.delay(0.8, function() Humanoid:MoveTo(targetPos) end)
	end,

	-- Step 5 – teleport (cooldown permitting).
	function(targetPos)
		teleportBehindTarget(targetPos)
	end,
}

-- Escalate to the next recovery strategy and execute it.
local function handleStuck(targetPos: Vector3)
	navState.recoveryStep     = math.min(navState.recoveryStep + 1, #recoveryActions)
	navState.consecutiveStuck += 1
	navState.stuckTimer       = 0
	navState.lastPosition     = RootPart.Position

	recoveryActions[navState.recoveryStep](targetPos)

	-- Safety reset: clear any lingering jump state after 2 seconds.
	task.delay(2, function()
		navState.isJumping = false
	end)
end

-------------------------------------------------------
-- WANDER (idle behaviour)
-------------------------------------------------------

-- Pick a random nearby point on the ground and stroll toward it.
local function doWander()
	if tick() - navState.lastWanderTime < CONFIG.WanderDelay then return end
	navState.lastWanderTime = tick()

	local angle  = math.random(0, 360) * math.pi / 180
	local radius = math.random(5, CONFIG.WanderRadius)
	local target = RootPart.Position
		+ Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)

	-- Snap to whatever ground is below the target point.
	local groundHit = castRay(target + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0))
	if groundHit then
		target = groundHit.Position + Vector3.new(0, 3, 0)
	end

	applySpeed(CONFIG.WalkSpeed * 0.7)
	Humanoid:MoveTo(target)
end

-------------------------------------------------------
-- CHASE LOGIC  (called every tick when a target exists)
-------------------------------------------------------

-- Hard teleport if we have been stuck too many times in a row.
local function handleExtremeStuck(targetPos: Vector3)
	teleportBehindTarget(targetPos)
end

-- Normal frame: update speed, handle obstacles, recompute path if due.
local function chaseTarget(targetPos: Vector3, dist: number)
	-- Clear recovery state now that we are moving freely.
	navState.recoveryStep     = 0
	navState.consecutiveStuck = 0
	navState.precisionMode    = false

	updateChaseSpeed(dist)

	local obstacleKind, obstacleData = detectObstacleAhead()

	-- If there is an obstacle close ahead, jump over it rather than re-pathing.
	if obstacleKind ~= "none" and dist < 20 then
		performJump(obstacleData)
		Humanoid:MoveTo(targetPos)
		return
	end

	-- Throttle path recomputes to PathUpdateRate.
	if tick() - navState.lastPathTime < CONFIG.PathUpdateRate then return end
	navState.lastPathTime = tick()
	followPath(targetPos)
end

-------------------------------------------------------
-- MAIN LOOP
-------------------------------------------------------

local function main()
	while true do
		local target, dist = findNearestTarget()

		local targetRoot = target and target:FindFirstChild("HumanoidRootPart") :: BasePart?

		if target and targetRoot then
			local targetPos = targetRoot.Position

			-- Always check for an instant kill first.
			killIfInRange(target)

			if navState.consecutiveStuck >= CONFIG.MaxRecoverySteps then
				handleExtremeStuck(targetPos)
			elseif checkIfStuck() then
				handleStuck(targetPos)
			else
				chaseTarget(targetPos, dist)
			end
		else
			-- No player in range – reset chase state and wander.
			navState.recoveryStep     = 0
			navState.consecutiveStuck = 0
			doWander()
		end

		task.wait(0.1)
	end
end

-------------------------------------------------------
-- INITIALISATION
-------------------------------------------------------

setupKillOnTouch()
Humanoid.WalkSpeed     = CONFIG.WalkSpeed
navState.lastPosition  = RootPart.Position

-- Wrap in pcall so a runtime error surfaces in the output window rather than
-- silently killing the NPC's AI loop.
local ok, err = pcall(main)
if not ok then
	warn("[NpcAI] Fatal error in main loop:", err)
end
