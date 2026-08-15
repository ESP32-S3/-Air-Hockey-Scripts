-- Discord: goofygoober211 | Roblox: zohohohobro

--[[
	PuckService
	Server authoritative puck for my air hockey game.

	Roblox's rigid body solver isn't much use to me here. A real puck rides on an
	air cushion, never leaves one flat plane, and has to bounce cleanly off rails
	that are a fraction of a stud thick. Handing that to the engine got me pucks
	tipping up onto their edge, pucks crawling to a stop nothing like a real
	table, and once they got quick, pucks passing straight through the boards
	between two frames.

	So the puck is anchored and I move it myself every tick:

		integrate velocity -> substep the motion -> push out of any wall -> goal check

	One of these per table. TableManager constructs them and drives tick() off
	Heartbeat, PaddleService calls applyPaddleHit() when a mallet catches the puck.
	Nothing here touches a global, so twenty five tables run side by side without
	knowing about each other.
]]

local TUNING = {
	-- studs/sec. the table is ~13.75 studs goal to goal, so this ceiling crosses
	-- it in a bit over half a second. any quicker and you genuinely can't react.
	MAX_SPEED = 26,

	-- the air cushion. fraction of speed kept per second, raised to dt so the
	-- glide is the same whether the server is at 60 or at 20. it was a flat
	-- per-frame multiply originally and the puck slid noticeably further on a
	-- busy server, which took me embarrassingly long to spot.
	DRAG_PER_SECOND = 0.88,

	PADDLE_RESTITUTION = 0.8,  -- plastic on plastic
	TANGENT_KEEP = 0.85,       -- sideways slide that survives a paddle hit
	WALL_RESTITUTION = 0.92,   -- boards take a little more out of it

	-- not a launch speed. this only exists so a puck can't end up parked inside
	-- the paddle face with nowhere to go.
	MIN_HIT_SPEED = 3,

	-- paddle velocity is derived from cursor positions the client sends, so one
	-- hitched frame can report something ridiculous. cap what a single hit is
	-- allowed to transfer or that frame becomes an unreturnable shot.
	MAX_PADDLE_SPEED = 14,

	-- quieter bounces are silent, and one wall sound per cooldown at most.
	-- without both of these a puck grinding along a rail machine guns the audio.
	WALL_HIT_MIN_SPEED = 4,
	WALL_HIT_COOLDOWN = 0.08,

	-- gap left between puck and wall after a push out, so the same contact
	-- doesn't immediately resolve again next frame
	CONTACT_SKIN = 0.001,

	MAX_SUBSTEPS = 8,
}

local STATE_PLAYING = "Playing"

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Half height of a part's world space bounding box, correct at any rotation.
-- Needed because a few rails on the table are angled and their Size.Y alone
-- says nothing useful about how tall they are in world space.
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

--[[
	Closest point test between the puck's circle and one wall's footprint, done
	in the wall's own object space so angled rails need no special casing. The
	whole thing collapses to "clamp the puck centre into the box, look at what's
	left over".

	Returns a world space direction to push along and how deep the overlap is,
	or nil when the puck is clear of this wall.
]]
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
		-- centre is outside the box. push straight out from the nearest point,
		-- which gets the goal post corners right as well as the flat faces.
		local dist = math.sqrt(distSq)
		localNormal = Vector3.new(offsetX / dist, 0, offsetZ / dist)
		depth = radius - dist
	else
		-- centre is already inside the box. that means it tunnelled or got spawned
		-- there, and the nearest point is useless, so leave by the nearest face.
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
	assert(puckRoot, "Puck model needs at least one BasePart in " .. tableModel.Name)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { puckModel }

	local self = setmetatable({
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

	return self
end

-- Everything downstream depends on knowing the plane the puck sits on, so
-- planeY has to be resolved before the walls or the bounds are worked out.
function PuckService:init()
	self:_weldParts()
	self.planeY = self.puckRoot.Position.Y
	self.radius = self:_measureRadius()
	self:_collectWalls()
	self:_computeBounds()

	-- published so PaddleService and the client's mouse ray aim at the same
	-- height. tables are scattered around the map at different elevations.
	self.tableModel:SetAttribute("PlayPlaneY", self.planeY)

	self.puckRoot.AssemblyLinearVelocity = Vector3.zero
	self.puckRoot.AssemblyAngularVelocity = Vector3.zero
end

-- One anchored part carries the puck and every other part is welded to it and
-- made non-collidable. Moving a single anchored root is far cheaper than asking
-- the solver to keep a model rigid, and it means CanQuery stays true on exactly
-- one part for the paddle's raycasts to find.
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

-- Measured off the whole model rather than off puckRoot. puckRoot is a thin
-- cylinder whose Size.X is its *thickness*, so reading it directly gave me a
-- radius about a fifth of the real one and the puck happily clipped the rails.
-- The model extents give the visible disc exactly.
function PuckService:_measureRadius(): number
	local extents = self.puckModel:GetExtentsSize()
	return math.max(extents.X, extents.Z) * 0.5
end

-- Only the border parts that actually sit at the puck's height count as walls.
-- The rink has trim and support pieces above and below the play plane, two of
-- them across the goal mouths, and treating those as solid walled off both goals.
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

-- These are the outer extents of the border frame, so this is only a far field
-- backstop for a puck that has somehow escaped the rink entirely. _resolveWalls
-- does the real containment. Both axes get padded by the radius; Z was left
-- unpadded at first and the puck sank a full radius into the side rails.
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

	b.minX += self.radius
	b.maxX -= self.radius
	b.minZ += self.radius
	b.maxZ -= self.radius
	b.centerX = (b.minX + b.maxX) * 0.5
	b.centerZ = (b.minZ + b.maxZ) * 0.5
end

-- Keeps the puck's original pitch and roll but lets the yaw it has picked up
-- carry through, and pins Y to the play plane. Building the CFrame from
-- orientation rather than assigning Position stops any drift off the plane.
function PuckService:_setPosition(pos: Vector3)
	local _, yaw, _ = self.puckRoot.CFrame:ToOrientation()
	local pitch, _, roll = self.baseRotation:ToOrientation()
	self.puckRoot.CFrame = CFrame.new(pos.X, self.planeY, pos.Z)
		* CFrame.Angles(pitch, yaw, roll)
end

--[[
	Pushes the puck out of anything it overlaps and reflects its velocity off
	whatever it hit. Deepest overlap first, then run again, up to four passes:
	a puck jammed into a corner needs resolving against both walls, and doing
	them in one pass just shoves it into the other one.

	Returns the corrected position and the speed of the hardest impact, which
	tick() grades the bounce sound on.
]]
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

		pos = Vector3.new(pos.X, self.planeY, pos.Z)
			+ bestNormal * (bestDepth + TUNING.CONTACT_SKIN)

		-- only reflect if it's actually moving into the wall. a puck sliding
		-- along a rail is in contact every frame and shouldn't be braked for it.
		local closing = self.velocity:Dot(bestNormal)
		if closing < 0 then
			impactSpeed = math.max(impactSpeed, self.velocity.Magnitude)
			local reflected = self.velocity
				- (1 + TUNING.WALL_RESTITUTION) * closing * bestNormal
			self.velocity = flat(reflected)
		end
	end

	return pos, impactSpeed
end

-- Did the puck cross this goal at any point during the frame? A raycast alone
-- misses the case where the puck starts the frame already inside the goal box,
-- so the swept segment gets sampled as well.
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

-- Hard clamp to the rink, except inside a goal mouth where the puck is supposed
-- to be past the Z limit.
function PuckService:_clamp(pos: Vector3): Vector3
	local b = self.bounds
	local z = pos.Z
	if not pointInsidePart(pos, self.blueGoal) and not pointInsidePart(pos, self.orangeGoal) then
		z = math.clamp(z, b.minZ, b.maxZ)
	end
	return Vector3.new(math.clamp(pos.X, b.minX, b.maxX), self.planeY, z)
end

function PuckService:setGoalHandler(fn: (string) -> ())
	self.goalHandler = fn
end

-- Called with the impact speed every time the puck bounces off a border.
function PuckService:setWallHitHandler(fn: (number) -> ())
	self.wallHitHandler = fn
end

--[[
	One physics step. Driven from TableManager's Heartbeat loop.

	The substepping is the important part. The rails are around 0.3 studs thick
	and the puck can be doing 26 studs/sec, which is over 0.4 studs of travel in
	a single 60hz frame, so a naive "move then test" lets it teleport clean
	through a board. Splitting the frame so no step advances more than half a
	radius makes that impossible, and re-reading velocity each step means the
	rest of the frame follows the rebound instead of ploughing onward.
]]
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

	-- goals are checked against the swept segment, not the end point, for the
	-- same reason the motion is substepped
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

-- Guarded by self.scored so a puck that clips both goal posts on the way in
-- can't fire the handler twice and award two points.
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

--[[
	Resolves a paddle contact as a bounce off an infinitely heavy moving wall,
	which is near enough how a mallet behaves against a puck: the puck rebounds
	along the contact normal having lost a bit of energy, then picks up the
	paddle's own motion on top. The nice property is that a stationary paddle
	behaves as a wall rather than a launcher, which is what you want.

	`normal` points from the paddle centre to the puck centre and comes from
	PaddleService's swept contact test, so it's the normal at first touch rather
	than at wherever the paddle ended up.

	Returns the puck's new speed; the caller picks a hit sound off it.
]]
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

	-- shift into the paddle's frame, bounce, shift back
	local rel = self.velocity - pv
	local vn = rel:Dot(n)
	local vt = rel - n * vn

	if vn < 0 then
		-- closing, so flip the normal component and bleed the slide
		rel = vt * TUNING.TANGENT_KEEP - n * (vn * TUNING.PADDLE_RESTITUTION)
	else
		-- already separating. leave the normal component alone, otherwise a
		-- glancing touch on a puck that's leaving kills its momentum.
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

--[[
	Pushes the puck clear of a point it's overlapping, in practice wherever the
	paddle ended up this frame.

	The paddle follows the cursor exactly and is allowed to travel straight past
	the puck, so without this the puck is left visually buried inside the mallet
	and gets re-contacted next frame. It leaves along the heading it just picked
	up where there is one, so a hard flick carries it forward rather than
	squeezing it out sideways, and the result goes back through the wall solver
	so popping it out can never bury it in a rail instead.
]]
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
		return  -- dead centre and not moving, nothing sensible to pick
	end

	local target = Vector3.new(point.X, self.planeY, point.Z)
		+ direction * (minDistance + TUNING.CONTACT_SKIN)
	self:_setPosition(self:_clamp((self:_resolveWalls(target))))
end

function PuckService:getVelocity(): Vector3
	return self.velocity
end

-- The collision radius, so PaddleService sweeps against the same disc the wall
-- solver uses instead of against puckRoot's raw box.
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
