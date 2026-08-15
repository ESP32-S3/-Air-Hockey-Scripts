-- Discord: goofygoober211 | Roblox: zohohohobro

-- PuckService, server side puck for my air hockey game.
-- Engine physics didn't work here. Puck tips onto its edge, glide is nothing like a real table, and at speed it
-- passes clean through rails that are only ~0.3 studs thick. So it's anchored and I move it myself.
-- tick() -> drag -> substep the move -> push out of walls -> goal check
-- One per table. TableManager owns the Heartbeat loop, PaddleService calls applyPaddleHit when a mallet connects.

local TUNING = {
	MAX_SPEED = 26,            -- studs/s. table's ~13.75 studs end to end so this crosses it in a bit over half a sec
	DRAG_PER_SECOND = 0.88,    -- air cushion, applied as ^dt. was a flat per frame multiply and the puck slid further on a laggy server
	PADDLE_RESTITUTION = 0.8,
	TANGENT_KEEP = 0.85,       -- sideways slide kept through a paddle hit
	WALL_RESTITUTION = 0.92,
	MIN_HIT_SPEED = 3,         -- not a launch speed, just stops the puck parking inside the paddle face
	MAX_PADDLE_SPEED = 14,     -- paddle vel is derived from client cursor pos, one hitched frame reports something stupid
	WALL_HIT_MIN_SPEED = 4,
	WALL_HIT_COOLDOWN = 0.08,  -- otherwise a puck grinding down a rail machine guns the sound
	CONTACT_SKIN = 0.001,      -- gap left after a push out so the same contact doesn't fire again next frame
	MAX_SUBSTEPS = 8,
}

local STATE_PLAYING = "Playing"

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- half height of the world space bbox. a few of the rails are angled so Size.Y on its own tells me nothing
local function worldHalfHeight(part: BasePart): number
	local cf, size = part.CFrame, part.Size
	return math.abs(cf.RightVector.Y) * size.X * 0.5
		+ math.abs(cf.UpVector.Y) * size.Y * 0.5
		+ math.abs(cf.LookVector.Y) * size.Z * 0.5
end

local function pointInsidePart(point: Vector3, part: BasePart): boolean
	local p = part.CFrame:PointToObjectSpace(point)
	local h = part.Size * 0.5
	return math.abs(p.X) <= h.X and math.abs(p.Y) <= h.Y and math.abs(p.Z) <= h.Z
end

-- closest point test, circle vs the wall's footprint, run in the wall's object space so angled rails need no special case
-- gives back a world space push direction + how deep the overlap is, or nil when it's clear
local function circleVsWall(pos: Vector3, wall: BasePart, radius: number): (Vector3?, number)
	local localPos = wall.CFrame:PointToObjectSpace(pos)
	local half = wall.Size * 0.5

	local clampedX = math.clamp(localPos.X, -half.X, half.X)
	local clampedZ = math.clamp(localPos.Z, -half.Z, half.Z)
	local offsetX = localPos.X - clampedX
	local offsetZ = localPos.Z - clampedZ
	local distSq = offsetX * offsetX + offsetZ * offsetZ

	if distSq > radius * radius then
		return nil, 0
	end

	local localNormal: Vector3
	local depth: number

	if distSq > 1e-8 then
		-- outside the box, push out from the nearest point. gets the goal post corners right as well as flat faces
		local dist = math.sqrt(distSq)
		localNormal = Vector3.new(offsetX / dist, 0, offsetZ / dist)
		depth = radius - dist
	else
		-- centre's already inside, so it tunnelled or got spawned in there. nearest point is useless, leave by nearest face
		local penX = half.X - math.abs(localPos.X)
		local penZ = half.Z - math.abs(localPos.Z)
		if penX < penZ then
			localNormal = Vector3.new(localPos.X >= 0 and 1 or -1, 0, 0)
			depth = penX + radius
		else
			localNormal = Vector3.new(0, 0, localPos.Z >= 0 and 1 or -1)
			depth = penZ + radius
		end
	end

	local worldNormal = flat(wall.CFrame:VectorToWorldSpace(localNormal))
	if worldNormal.Magnitude <= 1e-6 then
		return nil, 0
	end
	return worldNormal.Unit, depth
end

local PuckService = {}
PuckService.__index = PuckService

export type PuckService = typeof(setmetatable({} :: {
	tableModel: Model,
	borders: Instance,
	puckModel: Model,
	puckRoot: BasePart,
	blueGoal: BasePart,
	orangeGoal: BasePart,
	velocity: Vector3,
	radius: number,
	planeY: number,
	scored: boolean,
	walls: { BasePart },
	bounds: { minX: number, maxX: number, minZ: number, maxZ: number, centerX: number, centerZ: number },
	rayParams: RaycastParams,
	baseRotation: CFrame,
	lastWallHitAt: number,
	goalHandler: ((string) -> ())?,
	wallHitHandler: ((number) -> ())?,
}, PuckService))

function PuckService.new(tableModel: Model): PuckService
	local borders = tableModel:WaitForChild("Table"):WaitForChild("Borders")
	local puckModel = tableModel:WaitForChild("GamePeices"):WaitForChild("Puck")
	local puckRoot = puckModel:FindFirstChildWhichIsA("BasePart", true)
	assert(puckRoot, "Puck model needs a BasePart in " .. tableModel.Name)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { puckModel }

	return setmetatable({
		tableModel = tableModel,
		borders = borders,
		puckModel = puckModel,
		puckRoot = puckRoot,
		blueGoal = borders.BlueSide:WaitForChild("Goal"),
		orangeGoal = borders.OrangeSide:WaitForChild("Goal"),

		velocity = Vector3.zero,
		radius = 0,
		planeY = 0,
		scored = false,
		walls = {},
		bounds = {
			minX = math.huge, maxX = -math.huge,
			minZ = math.huge, maxZ = -math.huge,
			centerX = 0, centerZ = 0,
		},
		rayParams = rayParams,
		baseRotation = puckRoot.CFrame.Rotation,
		lastWallHitAt = 0,
	}, PuckService)
end

function PuckService:init()
	self:_weldParts()
	-- order matters, walls and bounds both need planeY
	self.planeY = self.puckRoot.Position.Y
	self.radius = self:_measureRadius()
	self:_collectWalls()
	self:_computeBounds()

	-- PaddleService and the client's mouse ray read this. tables sit at different heights around the map
	self.tableModel:SetAttribute("PlayPlaneY", self.planeY)

	self.puckRoot.AssemblyLinearVelocity = Vector3.zero
	self.puckRoot.AssemblyAngularVelocity = Vector3.zero
end

-- one anchored part carries everything else. way cheaper than making the solver hold a model rigid,
-- and it leaves CanQuery true on exactly one part for the paddle's raycasts to find
function PuckService:_weldParts()
	local root = self.puckRoot
	root.Anchored = true
	root.CanCollide = true
	root.CanQuery = true
	root.CanTouch = false

	for _, part in ipairs(self.puckModel:GetDescendants()) do
		if part:IsA("BasePart") and part ~= root then
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false

			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = root
		end
	end
end

-- measure the model, NOT puckRoot. root is a thin cylinder and its Size.X is the thickness, using that
-- gave me a radius about a fifth of the real one and the puck clipped straight through the rails
function PuckService:_measureRadius(): number
	local extents = self.puckModel:GetExtentsSize()
	return math.max(extents.X, extents.Z) * 0.5
end

-- only borders actually at the puck's height. there's trim sitting above and below the play plane and two bits
-- of it cross the goal mouths, counting those as solid walled both goals off
function PuckService:_collectWalls()
	table.clear(self.walls)
	for _, inst in ipairs(self.borders:GetDescendants()) do
		if inst:IsA("BasePart") and inst.Name ~= "Goal" then
			local half = worldHalfHeight(inst)
			local centreY = inst.Position.Y
			if self.planeY >= centreY - half and self.planeY <= centreY + half then
				table.insert(self.walls, inst)
			end
		end
	end
end

-- outer extents of the border frame, only a backstop for a puck that's escaped entirely, _resolveWalls does the real work
function PuckService:_computeBounds()
	local b = self.bounds
	for _, inst in ipairs(self.borders:GetDescendants()) do
		if inst:IsA("BasePart") and inst.Name ~= "Goal" then
			local half = inst.Size * 0.5
			local pos = inst.Position
			b.minX = math.min(b.minX, pos.X - half.X)
			b.maxX = math.max(b.maxX, pos.X + half.X)
			b.minZ = math.min(b.minZ, pos.Z - half.Z)
			b.maxZ = math.max(b.maxZ, pos.Z + half.Z)
		end
	end

	-- pad both. I only had X in here at first and the puck sank a full radius into the side rails
	b.minX += self.radius
	b.maxX -= self.radius
	b.minZ += self.radius
	b.maxZ -= self.radius
	b.centerX = (b.minX + b.maxX) * 0.5
	b.centerZ = (b.minZ + b.maxZ) * 0.5
end

-- keeps the puck's original pitch/roll, lets yaw carry, pins Y. built from orientation so it can't drift off the plane
function PuckService:_setPosition(pos: Vector3)
	local _, yaw, _ = self.puckRoot.CFrame:ToOrientation()
	local pitch, _, roll = self.baseRotation:ToOrientation()
	self.puckRoot.CFrame = CFrame.new(pos.X, self.planeY, pos.Z) * CFrame.Angles(pitch, yaw, roll)
end

-- push out of whatever it's overlapping and reflect off it. deepest first, then go again up to 4 times,
-- because a puck jammed in a corner needs both walls and doing one just shoves it into the other
-- returns the fixed up position + the hardest impact speed, tick() picks the bounce sound off that
function PuckService:_resolveWalls(pos: Vector3): (Vector3, number)
	local impactSpeed = 0

	for _ = 1, 4 do
		local bestNormal: Vector3? = nil
		local bestDepth = 0

		for _, wall in ipairs(self.walls) do
			local normal, depth = circleVsWall(pos, wall, self.radius)
			if normal and depth > bestDepth then
				bestNormal, bestDepth = normal, depth
			end
		end

		if not bestNormal then
			break
		end

		pos = Vector3.new(pos.X, self.planeY, pos.Z) + bestNormal * (bestDepth + TUNING.CONTACT_SKIN)

		-- only bounce if it's moving INTO the wall. a puck sliding along a rail touches every frame and shouldn't get braked for it
		local closing = self.velocity:Dot(bestNormal)
		if closing < 0 then
			impactSpeed = math.max(impactSpeed, self.velocity.Magnitude)
			self.velocity = flat(self.velocity - (1 + TUNING.WALL_RESTITUTION) * closing * bestNormal)
		end
	end

	return pos, impactSpeed
end

-- raycast misses the case where the puck starts the frame already sat in the goal box, so sample the segment too
function PuckService:_crossedGoal(startPos: Vector3, endPos: Vector3, goal: BasePart): boolean
	local dir = endPos - startPos
	if dir.Magnitude <= 0 then
		return false
	end

	local hit = workspace:Raycast(startPos, dir, self.rayParams)
	if hit and hit.Instance == goal then
		return true
	end

	for i = 0, 12 do
		if pointInsidePart(startPos:Lerp(endPos, i / 12), goal) then
			return true
		end
	end

	return false
end

function PuckService:_clamp(pos: Vector3): Vector3
	local b = self.bounds
	local z = pos.Z
	-- don't clamp Z inside a goal mouth, it's meant to be past the limit there
	if not pointInsidePart(pos, self.blueGoal) and not pointInsidePart(pos, self.orangeGoal) then
		z = math.clamp(z, b.minZ, b.maxZ)
	end
	return Vector3.new(math.clamp(pos.X, b.minX, b.maxX), self.planeY, z)
end

function PuckService:setGoalHandler(fn: (string) -> ())
	self.goalHandler = fn
end

-- gets the impact speed each time it bounces off a border
function PuckService:setWallHitHandler(fn: (number) -> ())
	self.wallHitHandler = fn
end

-- one physics step, driven off TableManager's Heartbeat
function PuckService:tick(state: string, dt: number?)
	if self.scored then
		return
	end

	if state ~= STATE_PLAYING then
		self.velocity = Vector3.zero
		self:_setPosition(self.puckRoot.Position)
		return
	end

	dt = dt or 1 / 60
	self.velocity *= TUNING.DRAG_PER_SECOND ^ dt

	local speed = self.velocity.Magnitude
	if speed < 0.01 then
		self.velocity = Vector3.zero
	elseif speed > TUNING.MAX_SPEED then
		self.velocity = self.velocity.Unit * TUNING.MAX_SPEED
	end

	local startPos = self.puckRoot.Position
	local travel = self.velocity.Magnitude * dt

	-- this is the bit that stops tunnelling. no step moves more than half a radius. rails are ~0.3 studs and 26 studs/s
	-- is 0.43 per 60hz frame, so move-then-test lets it jump the board. velocity is re-read each step so the rest of
	-- the frame follows the bounce instead of carrying on into the wall
	local steps = 1
	if self.radius > 0 then
		steps = math.clamp(math.ceil(travel / (self.radius * 0.5)), 1, TUNING.MAX_SUBSTEPS)
	end
	local stepDt = dt / steps

	local newPos = startPos
	local impactSpeed = 0
	for _ = 1, steps do
		newPos += self.velocity * stepDt
		local stepImpact
		newPos, stepImpact = self:_resolveWalls(newPos)
		impactSpeed = math.max(impactSpeed, stepImpact)
	end

	if impactSpeed >= TUNING.WALL_HIT_MIN_SPEED and self.wallHitHandler then
		local now = os.clock()
		if now - self.lastWallHitAt >= TUNING.WALL_HIT_COOLDOWN then
			self.lastWallHitAt = now
			self.wallHitHandler(impactSpeed)
		end
	end

	newPos = self:_clamp(newPos)

	-- swept, same reason as the substepping above
	if self:_crossedGoal(startPos, newPos, self.blueGoal) then
		return self:score("Orange")
	elseif self:_crossedGoal(startPos, newPos, self.orangeGoal) then
		return self:score("Blue")
	end

	self:_setPosition(newPos)
end

function PuckService:reset()
	self.scored = false
	self.velocity = Vector3.zero
	self:_setVisible(true)

	local b = self.bounds
	self.puckRoot.CFrame = CFrame.new(b.centerX, self.planeY, b.centerZ) * self.baseRotation
end

function PuckService:_setVisible(visible: boolean)
	for _, part in ipairs(self.puckModel:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Transparency = visible and 0 or 1
			part.CanCollide = visible
		end
	end
end

-- self.scored guard, a puck clipping both posts on the way in used to fire this twice and score 2
function PuckService:score(team: string)
	if self.scored then
		return
	end

	self.scored = true
	self.velocity = Vector3.zero
	self:_setVisible(false)

	if self.goalHandler then
		self.goalHandler(team)
	end
end

-- treated as a bounce off an infinitely heavy moving wall, which is basically what a mallet is to a puck.
-- reflect along the normal, lose a bit, add the paddle's own velocity on top. a still paddle acts like a wall, not a launcher.
-- normal runs paddle centre -> puck centre and PaddleService hands it over at first contact, not wherever the sweep ended
function PuckService:applyPaddleHit(normal: Vector3, paddleVel: Vector3): number
	if self.scored then
		return 0
	end

	local n = flat(normal)
	if n.Magnitude <= 0 then
		return self.velocity.Magnitude
	end
	n = n.Unit

	local pv = flat(paddleVel)
	if pv.Magnitude > TUNING.MAX_PADDLE_SPEED then
		pv = pv.Unit * TUNING.MAX_PADDLE_SPEED
	end

	-- into the paddle's frame, bounce, back out
	local rel = self.velocity - pv
	local vn = rel:Dot(n)
	local vt = rel - n * vn

	if vn < 0 then
		rel = vt * TUNING.TANGENT_KEEP - n * (vn * TUNING.PADDLE_RESTITUTION)
	else
		-- already separating, leave the normal bit alone or a graze on a puck that's leaving kills it
		rel = vt * TUNING.TANGENT_KEEP + n * vn
	end

	local newVel = rel + pv
	local speed = newVel.Magnitude
	if speed < TUNING.MIN_HIT_SPEED then
		newVel = n * TUNING.MIN_HIT_SPEED
	elseif speed > TUNING.MAX_SPEED then
		newVel = newVel.Unit * TUNING.MAX_SPEED
	end

	self.velocity = newVel
	return newVel.Magnitude
end

-- shove the puck clear of wherever the paddle ended up. the paddle tracks the cursor exactly and is allowed to run
-- straight past the puck, so without this it ends up buried in the mallet and gets contacted again next frame.
-- leaves along the heading it just picked up so a hard flick carries it forward instead of squeezing out sideways
function PuckService:separateFrom(point: Vector3, minDistance: number)
	if self.scored then
		return
	end

	local pos = self.puckRoot.Position
	local away = flat(pos - point)
	if away.Magnitude >= minDistance then
		return
	end

	local direction
	if self.velocity.Magnitude > 1e-4 then
		direction = self.velocity.Unit
	elseif away.Magnitude > 1e-4 then
		direction = away.Unit
	else
		return -- dead centre and stopped, nothing sensible to pick
	end

	local target = Vector3.new(point.X, self.planeY, point.Z) + direction * (minDistance + TUNING.CONTACT_SKIN)
	-- back through the wall solver, otherwise popping it off the paddle can bury it in a rail
	self:_setPosition(self:_clamp((self:_resolveWalls(target))))
end

function PuckService:getVelocity(): Vector3
	return self.velocity
end

-- so PaddleService sweeps against the same disc the wall solver uses, not puckRoot's box
function PuckService:getRadius(): number
	return self.radius
end

function PuckService:getPuckRoot(): BasePart
	return self.puckRoot
end

function PuckService:getPlaneY(): number
	return self.planeY
end

function PuckService:getBounds()
	return self.bounds
end

return PuckService
