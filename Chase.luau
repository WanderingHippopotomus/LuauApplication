local Pathfinding = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

-- tweak these to change behaviour
local CONFIG = {
	WalkSpeed = 14,
	SprintSpeed = 20,
	SlowSpeed = 8,
	BaseJumpPower = 50,
	MaxJumpPower = 110,

	SightRange = 180,
	AttackRange = 4,    -- studs before kill triggers
	SprintDist = 40,
	SlowDist = 10,

	StuckThreshold = 2.0,       -- seconds before declaring stuck
	MovementThreshold = 1.2,    -- studs moved per tick to not count as stuck
	MaxRecovery = 5,            -- attempts before teleporting

	TeleportDist = 12,
	TeleportCooldown = 6,

	PathUpdateRate = 0.35,  -- recompute path at most this often
	WanderDelay = 4,
	WanderRadius = 20,
}

local Character = script.Parent
local Humanoid = Character:WaitForChild("Humanoid")
local Root = Character:WaitForChild("HumanoidRootPart")

local normalPath = Pathfinding:CreatePath({
	AgentHeight = 6,
	AgentRadius = 3,
	AgentCanJump = true,
	AgentMaxSlope = 50,
	AgentCanClimb = true,
	Costs = { Water = 100 },
})

-- tighter params for when normal path keeps getting blocked
local precisePath = Pathfinding:CreatePath({
	AgentHeight = 5,
	AgentRadius = 2,
	AgentCanJump = false,
	AgentMaxSlope = 35,
	AgentCanClimb = true,
})

local state = {
	stuckTimer = 0,
	recoveryAttempt = 0,
	consecutiveStuck = 0,
	lastPosition = Root.Position,
	lastPathTime = 0,
	lastTeleportTime = 0,
	lastWanderTime = 0,
	isJumping = false,
	precisionMode = false,
	waypoints = {},
	waypointIndex = 2,
	reachedConn = nil,
	blockedConn = nil,
}

-- raycast that ignores our own character
local function rayEx(origin, dir)
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = { Character }
	return workspace:Raycast(origin, dir, p)
end

local function disconnectPath()
	if state.reachedConn then state.reachedConn:Disconnect(); state.reachedConn = nil end
	if state.blockedConn then state.blockedConn:Disconnect(); state.blockedConn = nil end
end

-- slight random variance so speed changes don't look robotic
local function setSpeed(s)
	Humanoid.WalkSpeed = s + math.random(-1, 1)
end

local function doJump(heightDiff)
	if state.isJumping then return end
	Humanoid.JumpPower = math.clamp(CONFIG.BaseJumpPower + heightDiff * 3.5, CONFIG.BaseJumpPower, CONFIG.MaxJumpPower)
	Humanoid.Jump = true
	state.isJumping = true
	task.delay(0.9, function()
		state.isJumping = false
		Humanoid.JumpPower = CONFIG.BaseJumpPower
	end)
end

-- wire up touch kill on every body part so the hitbox is the full character
local function setupKillTouch()
	for _, part in ipairs(Character:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Touched:Connect(function(hit)
				local char = hit.Parent
				if char == Character then return end
				local hum = char:FindFirstChildOfClass("Humanoid")
				if not hum or hum.Health <= 0 then return end
				for _, p in ipairs(Players:GetPlayers()) do
					if p.Character == char then
						hum.Health = 0
						break
					end
				end
			end)
		end
	end
end

-- returns nearest alive player and their distance
local function findTarget()
	local nearest, nearestDist = nil, CONFIG.SightRange
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then
				local d = (Root.Position - char.HumanoidRootPart.Position).Magnitude
				if d < nearestDist then
					nearest = char
					nearestDist = d
				end
			end
		end
	end
	return nearest, nearestDist
end

-- backup kill check each frame in case touch didn't fire
local function killIfClose(char)
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		if (Root.Position - char.HumanoidRootPart.Position).Magnitude <= CONFIG.AttackRange then
			hum.Health = 0
		end
	end
end

local function updateSpeed(dist)
	if dist > CONFIG.SprintDist then
		setSpeed(CONFIG.SprintSpeed)
	elseif dist < CONFIG.SlowDist then
		setSpeed(CONFIG.SlowSpeed)
	else
		setSpeed(CONFIG.WalkSpeed)
	end
end

-- checks for a wall or gap directly in front of the character
local function detectObstacle()
	local forward = Root.CFrame.LookVector
	local pos = Root.Position

	local wall = rayEx(pos + Vector3.new(0, 1, 0), forward * 3.5)
	if wall then
		local h = wall.Position.Y - pos.Y
		if h > 0.5 and h < 12 then return "wall", h end
	end

	local gap = rayEx(pos + forward * 4 + Vector3.new(0, 0.5, 0), Vector3.new(0, -6, 0))
	if not gap then return "gap", 4 end

	return "none", 0
end

local function followPath(dest)
	local p = state.precisionMode and precisePath or normalPath
	local ok = pcall(function() p:ComputeAsync(Root.Position, dest) end)

	if not ok or p.Status ~= Enum.PathStatus.Success then
		state.consecutiveStuck += 1
		Humanoid:MoveTo(dest)
		return
	end

	state.waypoints = p:GetWaypoints()
	if #state.waypoints < 2 then
		Humanoid:MoveTo(dest)
		return
	end

	disconnectPath()

	-- recompute in precision mode if something blocks the current path
	state.blockedConn = p.Blocked:Connect(function(idx)
		if idx >= state.waypointIndex then
			disconnectPath()
			state.precisionMode = true
			followPath(dest)
		end
	end)

	state.reachedConn = Humanoid.MoveToFinished:Connect(function(reached)
		if reached and state.waypointIndex < #state.waypoints then
			state.waypointIndex += 1
			local wp = state.waypoints[state.waypointIndex]
			if wp.Action == Enum.PathWaypointAction.Jump then
				doJump(wp.Position.Y - Root.Position.Y)
			end
			Humanoid:MoveTo(wp.Position)
		else
			disconnectPath()
			state.precisionMode = false
		end
	end)

	state.waypointIndex = 2
	Humanoid:MoveTo(state.waypoints[2].Position)
end

-- last resort: snap close to the target so we don't get permanently stuck
local function tryTeleport(targetPos)
	local now = tick()
	if now - state.lastTeleportTime < CONFIG.TeleportCooldown then return false end

	local dir = (Root.Position - targetPos).Unit
	local pos = targetPos + dir * CONFIG.TeleportDist
	local ground = rayEx(pos + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0))
	if ground then pos = ground.Position + Vector3.new(0, 4, 0) end

	Root.CFrame = CFrame.new(pos)
	state.lastTeleportTime = now
	state.consecutiveStuck = 0
	state.recoveryAttempt = 0
	state.stuckTimer = 0
	state.precisionMode = false
	state.lastPosition = Root.Position
	return true
end

local function isStuck()
	local moved = (Root.Position - state.lastPosition).Magnitude
	if moved < CONFIG.MovementThreshold and not state.isJumping then
		state.stuckTimer += 0.1
		return state.stuckTimer >= CONFIG.StuckThreshold
	end
	state.stuckTimer = 0
	state.lastPosition = Root.Position
	return false
end

-- escalating recovery: jump -> strafe left -> body impulse -> strafe right -> teleport
local function handleStuck(targetPos)
	state.recoveryAttempt += 1
	state.consecutiveStuck += 1

	if state.recoveryAttempt == 1 then
		doJump(15)
		Humanoid:MoveTo(targetPos)
	elseif state.recoveryAttempt == 2 then
		local side = Root.Position - Root.CFrame.RightVector * 6
		Humanoid:MoveTo(side)
		task.delay(0.8, function() Humanoid:MoveTo(targetPos) end)
	elseif state.recoveryAttempt == 3 then
		local bv = Instance.new("BodyVelocity")
		bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
		bv.Velocity = (targetPos - Root.Position).Unit * 35 + Vector3.new(0, 70, 0)
		bv.Parent = Root
		Debris:AddItem(bv, 0.5)
		Humanoid.Jump = true
	elseif state.recoveryAttempt == 4 then
		local side = Root.Position + Root.CFrame.RightVector * 6
		Humanoid:MoveTo(side)
		task.delay(0.8, function() Humanoid:MoveTo(targetPos) end)
	else
		tryTeleport(targetPos)
	end

	state.stuckTimer = 0
	state.lastPosition = Root.Position
	task.delay(2, function()
		state.isJumping = false
		Humanoid.JumpPower = CONFIG.BaseJumpPower
	end)
end

-- roam randomly when no player is in range
local function doWander()
	local now = tick()
	if now - state.lastWanderTime < CONFIG.WanderDelay then return end
	state.lastWanderTime = now

	local angle = math.random(0, 360) * math.pi / 180
	local dist = math.random(5, CONFIG.WanderRadius)
	local pos = Root.Position + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
	local ground = rayEx(pos + Vector3.new(0, 10, 0), Vector3.new(0, -20, 0))
	if ground then pos = ground.Position + Vector3.new(0, 3, 0) end

	setSpeed(CONFIG.WalkSpeed * 0.7)
	Humanoid:MoveTo(pos)
end

local function main()
	while true do
		local target, dist = findTarget()

		if target and target:FindFirstChild("HumanoidRootPart") then
			local targetPos = target.HumanoidRootPart.Position

			killIfClose(target)

			if state.consecutiveStuck >= CONFIG.MaxRecovery then
				tryTeleport(targetPos)
			elseif isStuck() then
				handleStuck(targetPos)
			else
				if state.recoveryAttempt > 0 then
					state.recoveryAttempt = 0
					state.consecutiveStuck = 0
					state.precisionMode = false
				end

				updateSpeed(dist)

				local obsType, obsData = detectObstacle()
				if obsType ~= "none" and dist < 20 then
					doJump(obsData)
					Humanoid:MoveTo(targetPos)
				else
					local now = tick()
					if now - state.lastPathTime >= CONFIG.PathUpdateRate then
						state.lastPathTime = now
						followPath(targetPos)
					end
				end
			end
		else
			state.recoveryAttempt = 0
			state.consecutiveStuck = 0
			doWander()
		end

		task.wait(0.1)
	end
end

setupKillTouch()
Humanoid.WalkSpeed = CONFIG.WalkSpeed
Humanoid.JumpPower = CONFIG.BaseJumpPower
state.lastPosition = Root.Position

local ok, err = pcall(main)
if not ok then warn(err) end
