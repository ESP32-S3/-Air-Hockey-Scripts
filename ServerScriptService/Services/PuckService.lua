local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))

-- ── Factory: createPuckService(tableModel) → isolated instance ────────────────
-- Each table gets its own PuckService with its own state, puck model, bounds,
-- and goal references. No global singletons.

local function createPuckService(tableModel: Model)
	local Borders = tableModel:WaitForChild("Table"):WaitForChild("Borders")
	local BlueGoal = Borders.BlueSide:WaitForChild("Goal")
	local OrangeGoal = Borders.OrangeSide:WaitForChild("Goal")

	local PuckModel = tableModel:WaitForChild("GamePeices"):WaitForChild("Puck")
	local PuckRoot = PuckModel:FindFirstChildWhichIsA("BasePart", true)

	assert(PuckRoot, "Puck model requires a BasePart in " .. tableModel.Name)

	local puckVel = Vector3.zero
	local puckRadius = 0
	-- Border parts that actually occupy the play plane. Deliberately not every
	-- part under Borders: the rink has trim and support pieces sitting just
	-- above and below the puck, including two in the goal mouth, and treating
	-- those as walls would wall off the goals.
	local wallParts: { BasePart } = {}
	local scored = false
	local _onGoal: ((string) -> ())?
	local _onWallHit: ((number) -> ())?
	local lastWallHitAt = 0
	local spawnY = 0
	local initialRotation: CFrame

	local bounds = {
		minX = math.huge,
		maxX = -math.huge,
		minZ = math.huge,
		maxZ = -math.huge,
		centerX = 0,
		centerZ = 0,
	}

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { PuckModel }

	local function setPuckCFrame(pos: Vector3)
		local _, y, _ = PuckRoot.CFrame:ToOrientation()
		local rx, _, rz = initialRotation:ToOrientation()
		PuckRoot.CFrame = CFrame.new(pos.X, spawnY, pos.Z) * CFrame.Angles(rx, y, rz)
	end

	local function weldPuckParts()
		PuckRoot.Anchored = true
		PuckRoot.CanCollide = true
		PuckRoot.CanQuery = true
		PuckRoot.CanTouch = false

		for _, part in ipairs(PuckModel:GetDescendants()) do
			if part:IsA("BasePart") and part ~= PuckRoot then
				part.Anchored = false
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false

				local weld = Instance.new("WeldConstraint")
				weld.Part0 = PuckRoot
				weld.Part1 = part
				weld.Parent = PuckRoot
			end
		end
	end

	-- The collision footprint of the whole puck model, not of PuckRoot. PuckRoot
	-- is a thin cylinder whose Size.X is its *thickness*, so measuring it
	-- directly under-reports the radius badly; the visible disc is a separate
	-- welded union. The model's world extents give the disc exactly.
	local function computePuckRadius(): number
		local extents = PuckModel:GetExtentsSize()
		return math.max(extents.X, extents.Z) * 0.5
	end

	-- Half-height of a part's world-space bounding box, valid for any rotation.
	local function worldHalfHeight(part: BasePart): number
		local cf, size = part.CFrame, part.Size
		return math.abs(cf.RightVector.Y) * size.X * 0.5
			+ math.abs(cf.UpVector.Y) * size.Y * 0.5
			+ math.abs(cf.LookVector.Y) * size.Z * 0.5
	end

	local function collectWalls()
		table.clear(wallParts)
		for _, inst in ipairs(Borders:GetDescendants()) do
			if inst:IsA("BasePart") and inst.Name ~= "Goal" then
				local half = worldHalfHeight(inst)
				local centreY = inst.Position.Y
				if spawnY >= centreY - half and spawnY <= centreY + half then
					table.insert(wallParts, inst)
				end
			end
		end
	end

	local function computeBounds()
		for _, inst in ipairs(Borders:GetDescendants()) do
			if inst:IsA("BasePart") and inst.Name ~= "Goal" then
				local half = inst.Size * 0.5
				local pos = inst.Position
				bounds.minX = math.min(bounds.minX, pos.X - half.X)
				bounds.maxX = math.max(bounds.maxX, pos.X + half.X)
				bounds.minZ = math.min(bounds.minZ, pos.Z - half.Z)
				bounds.maxZ = math.max(bounds.maxZ, pos.Z + half.Z)
			end
		end

		-- These are the *outer* extents of the border frame, so this is only a
		-- far-field backstop against a puck that somehow escapes the rink;
		-- resolveWalls does the real work. Padded on both axes — Z used to be
		-- left unpadded, which let the puck sink a full radius into the rails.
		bounds.minX += puckRadius
		bounds.maxX -= puckRadius
		bounds.minZ += puckRadius
		bounds.maxZ -= puckRadius
		bounds.centerX = (bounds.minX + bounds.maxX) * 0.5
		bounds.centerZ = (bounds.minZ + bounds.maxZ) * 0.5
	end

	-- Closest-point test between the puck's circle and one wall's footprint at
	-- the play plane. Works in the wall's own frame so angled rails are handled,
	-- and returns the world-space push-out direction plus how deep the overlap is.
	-- Returns nil when the puck is clear of this wall.
	local function circleVsWall(pos: Vector3, wall: BasePart): (Vector3?, number)
		local localPos = wall.CFrame:PointToObjectSpace(pos)
		local half = wall.Size * 0.5

		local clampedX = math.clamp(localPos.X, -half.X, half.X)
		local clampedZ = math.clamp(localPos.Z, -half.Z, half.Z)
		local offsetX = localPos.X - clampedX
		local offsetZ = localPos.Z - clampedZ
		local distanceSq = offsetX * offsetX + offsetZ * offsetZ

		if distanceSq > puckRadius * puckRadius then
			return nil, 0
		end

		local localNormal: Vector3
		local depth: number

		if distanceSq > 1e-8 then
			-- Centre is outside the box: push straight out from the nearest point,
			-- which handles the goal posts' corners as well as flat faces.
			local distance = math.sqrt(distanceSq)
			localNormal = Vector3.new(offsetX / distance, 0, offsetZ / distance)
			depth = puckRadius - distance
		else
			-- Centre is already inside the box (a tunnelled or spawned-in puck):
			-- leave by the nearest face rather than the nearest point.
			local penetrationX = half.X - math.abs(localPos.X)
			local penetrationZ = half.Z - math.abs(localPos.Z)
			if penetrationX < penetrationZ then
				localNormal = Vector3.new(localPos.X >= 0 and 1 or -1, 0, 0)
				depth = penetrationX + puckRadius
			else
				localNormal = Vector3.new(0, 0, localPos.Z >= 0 and 1 or -1)
				depth = penetrationZ + puckRadius
			end
		end

		local worldNormal = wall.CFrame:VectorToWorldSpace(localNormal)
		worldNormal = Vector3.new(worldNormal.X, 0, worldNormal.Z)
		if worldNormal.Magnitude <= 1e-6 then
			return nil, 0
		end
		return worldNormal.Unit, depth
	end

	-- Separation skin so the puck rests just clear of the wall and cannot
	-- re-trigger the same contact on the following frame.
	local CONTACT_SKIN = 0.001

	-- Pushes the puck out of anything it overlaps and reflects its velocity.
	-- Iterated a few times so a puck wedged into a corner is resolved against
	-- both walls instead of being shoved straight back into the other one.
	local function resolveWalls(pos: Vector3): (Vector3, number)
		local impactSpeed = 0

		for _ = 1, 4 do
			local bestNormal: Vector3? = nil
			local bestDepth = 0

			for _, wall in ipairs(wallParts) do
				local normal, depth = circleVsWall(pos, wall)
				if normal and depth > bestDepth then
					bestNormal, bestDepth = normal, depth
				end
			end

			if not bestNormal then
				break
			end

			pos = Vector3.new(pos.X, spawnY, pos.Z) + bestNormal * (bestDepth + CONTACT_SKIN)

			-- Only reflect when actually moving into the wall; a puck sliding
			-- along a rail keeps its speed instead of being braked every frame.
			local closingSpeed = puckVel:Dot(bestNormal)
			if closingSpeed < 0 then
				impactSpeed = math.max(impactSpeed, puckVel.Magnitude)
				local reflected = puckVel - (1 + Constants.PUCK_WALL_RESTITUTION) * closingSpeed * bestNormal
				puckVel = Vector3.new(reflected.X, 0, reflected.Z)
			end
		end

		return pos, impactSpeed
	end

	local function pointInsidePart(point: Vector3, part: BasePart)
		local p = part.CFrame:PointToObjectSpace(point)
		local h = part.Size * 0.5
		return math.abs(p.X) <= h.X and math.abs(p.Y) <= h.Y and math.abs(p.Z) <= h.Z
	end

	local function segmentIntersectsPart(startPos: Vector3, endPos: Vector3, part: BasePart)
		local dir = endPos - startPos
		if dir.Magnitude <= 0 then
			return false
		end

		local hit = workspace:Raycast(startPos, dir, rayParams)
		if hit and hit.Instance == part then
			return true
		end

		for i = 0, 12 do
			if pointInsidePart(startPos:Lerp(endPos, i / 12), part) then
				return true
			end
		end

		return false
	end

	local function clampPosition(pos: Vector3)
		local z = pos.Z
		if not pointInsidePart(pos, BlueGoal) and not pointInsidePart(pos, OrangeGoal) then
			z = math.clamp(z, bounds.minZ, bounds.maxZ)
		end
		return Vector3.new(math.clamp(pos.X, bounds.minX, bounds.maxX), spawnY, z)
	end

	-- ── Instance API ──────────────────────────────────────────────────────────

	local service = {}

	function service.init()
		initialRotation = PuckRoot.CFrame.Rotation
		weldPuckParts()
		-- spawnY first: both the wall set and the bounds depend on knowing which
		-- plane the puck actually travels on.
		spawnY = PuckRoot.Position.Y
		puckRadius = computePuckRadius()
		collectWalls()
		computeBounds()
		-- Published so the paddle service and the client's mouse ray both aim at
		-- the same height. Tables can sit at any elevation.
		tableModel:SetAttribute("PlayPlaneY", spawnY)
		PuckRoot.AssemblyLinearVelocity = Vector3.zero
		PuckRoot.AssemblyAngularVelocity = Vector3.zero
	end

	function service.setGoalHandler(handler: (string) -> ())
		_onGoal = handler
	end

	-- Called with the impact speed each time the puck bounces off a border.
	function service.setWallHitHandler(handler: (number) -> ())
		_onWallHit = handler
	end

	function service.tick(state: string, dt: number?)
		if scored then
			return
		end

		if state ~= Constants.STATE_PLAYING then
			puckVel = Vector3.zero
			setPuckCFrame(PuckRoot.Position)
			return
		end

		dt = dt or 1 / 60
		-- Time-based so glide is identical regardless of server frame rate.
		puckVel *= Constants.PUCK_DRAG_PER_SECOND ^ dt

		if puckVel.Magnitude < 0.01 then
			puckVel = Vector3.zero
		elseif puckVel.Magnitude > Constants.PUCK_MAX_SPEED then
			puckVel = puckVel.Unit * Constants.PUCK_MAX_SPEED
		end

		local currentPos = PuckRoot.Position
		local frameDistance = puckVel.Magnitude * dt

		-- Sub-stepped so a fast puck cannot pass through a 0.3 stud rail between
		-- frames: no single step advances more than half the puck's radius.
		local steps = 1
		if puckRadius > 0 then
			steps = math.clamp(math.ceil(frameDistance / (puckRadius * 0.5)), 1, 8)
		end
		local stepDt = dt / steps

		local newPos = currentPos
		local impactSpeed = 0
		for _ = 1, steps do
			-- Reads puckVel fresh each step, so the remainder of the frame follows
			-- the rebound heading rather than ploughing on into the wall.
			newPos += puckVel * stepDt
			local stepImpact
			newPos, stepImpact = resolveWalls(newPos)
			impactSpeed = math.max(impactSpeed, stepImpact)
		end

		-- A puck skimming a border can register contact every frame, so rate-limit
		-- it and stay silent for slow grazes.
		if impactSpeed > 0 then
			local now = os.clock()
			if _onWallHit
				and impactSpeed >= Constants.WALL_HIT_MIN_SPEED
				and now - lastWallHitAt >= Constants.WALL_HIT_COOLDOWN
			then
				lastWallHitAt = now
				_onWallHit(impactSpeed)
			end
		end

		newPos = clampPosition(newPos)

		if segmentIntersectsPart(currentPos, newPos, BlueGoal) then
			service.score("Orange")
			return
		end

		if segmentIntersectsPart(currentPos, newPos, OrangeGoal) then
			service.score("Blue")
			return
		end

		setPuckCFrame(newPos)
	end

	function service.reset()
		scored = false
		puckVel = Vector3.zero

		for _, part in ipairs(PuckModel:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Transparency = 0
				part.CanCollide = true
			end
		end

		PuckRoot.CFrame = CFrame.new(bounds.centerX, spawnY, bounds.centerZ) * initialRotation
	end

	function service.score(team: string)
		if scored then
			return
		end

		scored = true
		puckVel = Vector3.zero

		for _, part in ipairs(PuckModel:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Transparency = 1
				part.CanCollide = false
			end
		end

		if _onGoal then
			_onGoal(team)
		end
	end

	-- Resolves a paddle contact as a bounce off an infinitely heavy moving wall,
	-- which is how a mallet behaves against a puck: the puck rebounds along the
	-- contact normal having lost some energy, and picks up the paddle's motion on
	-- top of that. A stationary paddle is therefore a wall, not a launcher.
	-- `normal` points from the paddle centre to the puck centre.
	-- Returns the resulting puck speed, which the caller grades hit sounds on.
	function service.applyPaddleHit(normal: Vector3, paddleVel: Vector3): number
		if scored then
			return 0
		end

		local n = Vector3.new(normal.X, 0, normal.Z)
		if n.Magnitude <= 0 then
			return puckVel.Magnitude
		end
		n = n.Unit

		local pv = Vector3.new(paddleVel.X, 0, paddleVel.Z)
		if pv.Magnitude > Constants.PADDLE_MAX_EFFECTIVE_SPEED then
			pv = pv.Unit * Constants.PADDLE_MAX_EFFECTIVE_SPEED
		end

		-- Work in the paddle's frame, then return to world space.
		local rel = puckVel - pv
		local vn = rel:Dot(n)
		local vt = rel - n * vn
		if vn < 0 then
			-- Approaching: reflect the normal component and bleed the slide.
			rel = vt * Constants.PUCK_TANGENT_KEEP - n * (vn * Constants.PUCK_RESTITUTION)
		else
			-- Already separating; leave it be so a graze can't kill its momentum.
			rel = vt * Constants.PUCK_TANGENT_KEEP + n * vn
		end

		local newVel = rel + pv
		local speed = newVel.Magnitude
		if speed < Constants.PUCK_MIN_HIT_SPEED then
			-- Too slow to escape the face; nudge it clear along the normal.
			newVel = n * Constants.PUCK_MIN_HIT_SPEED
		elseif speed > Constants.PUCK_MAX_SPEED then
			newVel = newVel.Unit * Constants.PUCK_MAX_SPEED
		end

		puckVel = newVel
		return puckVel.Magnitude
	end

	function service.getVelocity()
		return puckVel
	end

	-- The puck's collision radius, so the paddle can sweep against the same disc
	-- the wall solver uses rather than against PuckRoot's raw box.
	function service.getRadius(): number
		return puckRadius
	end

	-- Pushes the puck clear of a point it is overlapping (in practice, where the
	-- paddle ended up this frame). The paddle is allowed to follow the cursor
	-- straight past the puck, so without this the puck is left visually buried
	-- inside it and is re-contacted on the following frame.
	function service.separateFrom(point: Vector3, minDistance: number)
		if scored then
			return
		end

		local pos = PuckRoot.Position
		local away = Vector3.new(pos.X - point.X, 0, pos.Z - point.Z)
		if away.Magnitude >= minDistance then
			return
		end

		-- Leave along the heading the puck just picked up where there is one, so a
		-- hard flick carries it forward instead of squeezing it out sideways.
		local direction
		if puckVel.Magnitude > 1e-4 then
			direction = puckVel.Unit
		elseif away.Magnitude > 1e-4 then
			direction = away.Unit
		else
			return
		end

		local target = Vector3.new(point.X, spawnY, point.Z)
			+ direction * (minDistance + CONTACT_SKIN)
		-- Routed through the wall solver so popping the puck out can never push it
		-- into a rail.
		setPuckCFrame(clampPosition((resolveWalls(target))))
	end

	function service.getPuckRoot()
		return PuckRoot
	end

	function service.getPuckModel()
		return PuckModel
	end

	function service.getBounds()
		return bounds
	end

	function service.getPlaneY()
		return spawnY
	end

	return service
end

return { create = createPuckService }