local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared    = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared:WaitForChild("Constants"))
local Remotes   = require(Shared:WaitForChild("Remotes"))
local Extras    = require(Shared:WaitForChild("Extras"))
local Monetization = require(Shared:WaitForChild("Monetization"))

local Services       = script.Parent
local PassService    = require(Services:WaitForChild("PassService"))
local LoadoutService = require(Services:WaitForChild("LoadoutService"))

local PaddleTemplate = ReplicatedStorage:WaitForChild("Paddles"):WaitForChild("DefaultPaddle")
local OriginalPivot    = PaddleTemplate:GetPivot()
local OriginalRotation = OriginalPivot - OriginalPivot.Position

local PADDLE_INSET          = 0.6
local PADDLE_POSITION_OFFSET = Vector3.new(0, 0.2, 0)

local function collectParts(model: Model): { BasePart }
	local parts = {}
	for _, v in ipairs(model:GetDescendants()) do
		if v:IsA("BasePart") then table.insert(parts, v) end
	end
	return parts
end

local function getPaddleCFrame(pos: Vector3): CFrame
	return CFrame.new(pos + PADDLE_POSITION_OFFSET) * OriginalRotation
end

-- Play-plane radius of the paddle face. The paddle always renders at
-- OriginalRotation, so this never changes at runtime.
local PADDLE_RADIUS = (function()
	local extents = PaddleTemplate:GetExtentsSize()
	return math.max(extents.X, extents.Z) * 0.5
end)()

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- ── Cosmetics ─────────────────────────────────────────────────────────────
-- A skin only ever restyles the clone: colour, material, reflectance, and an
-- optional light. Geometry is deliberately untouched, because PADDLE_RADIUS is
-- measured off the template and feeds the swept collision test — a skin that
-- changed the silhouette would quietly change how the game plays.

local function applySkin(paddle: Model, skinId: string?)
	local skin = Extras.getPaddleSkin(skinId)

	for _, part in ipairs(paddle:GetDescendants()) do
		if part:IsA("BasePart") then
			-- A UnionOperation ignores Color unless it is told to stop using the
			-- colours baked in at union time, and the default paddle is a union.
			if part:IsA("UnionOperation") then
				part.UsePartColor = true
			end
			part.Color = skin.color
			part.Material = skin.material
			part.Reflectance = skin.reflectance or 0
		end
	end

	if skin.glow then
		local root = paddle.PrimaryPart or paddle:FindFirstChildWhichIsA("BasePart", true)
		if root then
			local light = Instance.new("PointLight")
			light.Name = "SkinGlow"
			light.Color = skin.glow
			light.Brightness = 2.5
			light.Range = 12
			light.Shadows = false
			light.Parent = root
		end
	end
end

local function attachNameTag(paddle: Model, player: Player)
	if not PassService.owns(player, "NameTag") then return end

	local root = paddle.PrimaryPart or paddle:FindFirstChildWhichIsA("BasePart", true)
	if not root then return end

	local title = Extras.getTitle(player:GetAttribute(Monetization.LOADOUT_ATTR_TITLE))

	local gui = Instance.new("BillboardGui")
	gui.Name = "AirHockeyNameTag"
	gui.Size = UDim2.fromOffset(220, 56)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 250
	gui.LightInfluence = 0

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.BackgroundTransparency = 1
	titleLabel.Size = UDim2.new(1, 0, 0.45, 0)
	titleLabel.Font = Enum.Font.GothamBlack
	titleLabel.TextScaled = true
	titleLabel.Text = title.text
	titleLabel.TextColor3 = title.color
	titleLabel.Visible = title.text ~= ""
	titleLabel.Parent = gui

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "PlayerName"
	nameLabel.BackgroundTransparency = 1
	nameLabel.Position = UDim2.new(0, 0, 0.45, 0)
	nameLabel.Size = UDim2.new(1, 0, 0.55, 0)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.Text = player.DisplayName
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(15, 20, 35)
	stroke.Parent = titleLabel
	stroke:Clone().Parent = nameLabel

	gui.Parent = root
end

-- Earliest fraction of the sweep p0 -> p1 at which a disc of the combined radius
-- first touches a disc fixed at q, or nil if it never does. Solving this rather
-- than testing for overlap at the end of the frame is what stops a fast flick
-- passing clean through the puck between two ticks, and it yields the point of
-- first contact instead of the overshoot point.
local function sweptContact(p0: Vector3, p1: Vector3, q: Vector3, reach: number): number?
	local offset = p0 - q
	local gap = offset:Dot(offset) - reach * reach
	if gap <= 0 then
		return 0  -- already touching when the frame began
	end

	local delta = p1 - p0
	local a = delta:Dot(delta)
	if a <= 1e-10 then
		return nil  -- stationary and not touching
	end

	local b = 2 * offset:Dot(delta)
	if b >= 0 then
		return nil  -- travelling away from the puck, not toward it
	end

	local discriminant = b * b - 4 * a * gap
	if discriminant < 0 then
		return nil  -- passes to one side without touching
	end

	local t = (-b - math.sqrt(discriminant)) / (2 * a)
	if t < 0 or t > 1 then
		return nil
	end
	return t
end

-- ── Factory ───────────────────────────────────────────────────────────────────
local function createPaddleService(tableModel: Model, puckService)
	local Ice = tableModel
		:WaitForChild("Table")
		:WaitForChild("UnderTable")
		:WaitForChild("Ice")

	local Pads      = tableModel:WaitForChild("Pads")
	local BluePad   = Pads:WaitForChild("BluePad")
	local OrangePad = Pads:WaitForChild("OrangePad")

	-- The playfield in its own frame rather than in world X/Z. `long` is the
	-- goal-to-goal axis, `wide` the sideline axis, and `blueSign` says which way
	-- along `long` Blue's half lies. All three are measured off the table, so a
	-- table may sit at any yaw and either way round and still play correctly.
	local field = {
		centre   = Vector3.zero,
		long     = Vector3.xAxis,
		wide     = Vector3.zAxis,
		halfLong = 0,
		halfWide = 0,
		blueSign = 1,
	}

	-- Height the paddles ride at. Resolved from the puck in init() so a table can
	-- be placed anywhere in the world; PADDLE_OFFSET_Y is only the fallback.
	local planeY = Constants.PADDLE_OFFSET_Y

	-- Drops a world direction onto the play plane. The ice may be tilted a hair
	-- without that leaking a Y component into the clamp maths.
	local function flatten(v: Vector3): Vector3
		local flat = Vector3.new(v.X, 0, v.Z)
		return flat.Magnitude > 1e-4 and flat.Unit or Vector3.xAxis
	end

	local function computePlayfield()
		local cf, size = Ice.CFrame, Ice.Size
		field.centre = cf.Position

		-- Goal to goal is whichever horizontal edge of the ice is the longer one.
		if size.X >= size.Z then
			field.long, field.halfLong = flatten(cf.RightVector), size.X * 0.5
			field.wide, field.halfWide = flatten(cf.LookVector),  size.Z * 0.5
		else
			field.long, field.halfLong = flatten(cf.LookVector),  size.Z * 0.5
			field.wide, field.halfWide = flatten(cf.RightVector), size.X * 0.5
		end

		-- Which end belongs to Blue is asked of the pads, never assumed. The old
		-- code pinned Blue to the low-world-X half, so re-laying the tables put
		-- every paddle on the half opposite its own pad. Comparing the two pads
		-- rather than testing one against zero also survives a table whose pads
		-- are both nudged off the centre line the same way.
		local blueAlong   = (BluePad:GetPivot().Position   - field.centre):Dot(field.long)
		local orangeAlong = (OrangePad:GetPivot().Position - field.centre):Dot(field.long)
		if blueAlong == orangeAlong then
			warn(("[PaddleService] %s: pads share a half (blue=%.2f orange=%.2f); assuming Blue is +long")
				:format(tableModel.Name, blueAlong, orangeAlong))
			field.blueSign = 1
		else
			field.blueSign = blueAlong > orangeAlong and 1 or -1
		end
	end

	-- Each role owns the half of the ice its own pad stands behind: free between
	-- the sidelines, and from the centre line out to its own end.
	local function clampTarget(role: string, pos: Vector3): Vector3
		local sign     = role == "Blue" and field.blueSign or -field.blueSign
		local offset   = pos - field.centre
		local longLimit = math.max(field.halfLong - PADDLE_INSET, 0)
		local wideLimit = math.max(field.halfWide - PADDLE_INSET, 0)
		local along  = math.clamp(offset:Dot(field.long) * sign, 0, longLimit)
		local across = math.clamp(offset:Dot(field.wide), -wideLimit, wideLimit)
		local world  = field.centre + field.long * (along * sign) + field.wide * across
		return Vector3.new(world.X, planeY, world.Z)
	end

	local paddleByRole   = {}
	local targetByRole   = {}
	local velocityByRole = {}
	local prevPosByRole  = {}
	local lastHit        = { Blue = 0, Orange = 0 }

	-- Track which player owns which role for this table
	local playerForRole: { [string]: Player } = {}

	local service = {}

	function service.init()
		computePlayfield()
		if puckService.getPlaneY then
			planeY = puckService.getPlaneY()
		end
		-- Listen only for players assigned to this table
		Remotes.PaddleTarget.OnServerEvent:Connect(function(player: Player, pos)
			local role = player:GetAttribute("AirHockeyRole")
			if not role then return end
			if playerForRole[role] ~= player then return end  -- wrong table
			if typeof(pos) ~= "Vector3" then return end
			targetByRole[role] = Vector3.new(pos.X, planeY, pos.Z)
		end)
	end

	-- onHit(role, impactSpeed) — impactSpeed is the puck speed the hit produced,
	-- which the caller uses to pick the hit sound.
	function service.tick(dt: number, state: string, onHit: (string, number) -> ())
		for role, paddle in pairs(paddleByRole) do
			local target  = targetByRole[role]
			local current = paddle:GetPivot().Position
			-- Both ends of this frame's motion are kept, because the contact test
			-- needs the segment the paddle travelled, not just where it landed.
			local from = prevPosByRole[role] or current
			local to   = current
			if target then
				to = clampTarget(role, target)
				paddle:PivotTo(getPaddleCFrame(to))
			end
			velocityByRole[role] = (to - from) / math.max(dt, Constants.MIN_DT)
			prevPosByRole[role]  = to
			service._tryHit(role, from, to, state, onHit)
		end
	end

	function service._tryHit(role: string, fromPos: Vector3, toPos: Vector3, state: string, onHit)
		if state ~= Constants.STATE_PLAYING then return end

		local PuckRoot = puckService.getPuckRoot()
		local reach    = PADDLE_RADIUS + puckService.getRadius()
		local puckPos  = flat(PuckRoot.Position)
		local from, to = flat(fromPos), flat(toPos)

		local t = sweptContact(from, to, puckPos, reach)
		if not t then return end

		-- Normal at the moment of first touch, never at the overshoot point. Taking
		-- it from where the paddle *ended* was the whole bug: any flick that carried
		-- the paddle centre past the puck centre produced a normal pointing
		-- backwards, the puck then read as already separating, and it was nudged
		-- away at PUCK_MIN_HIT_SPEED in the wrong direction.
		local contact = from:Lerp(to, t)
		local normal  = puckPos - contact
		if normal.Magnitude < 1e-4 then
			normal = to - from  -- dead centre: send it along the swing
			if normal.Magnitude < 1e-4 then return end
		end
		normal = normal.Unit

		-- Only transfer while the paddle is actually closing on the puck. This is
		-- what keeps a resting puck from being re-hit every frame, and unlike a
		-- timer it can never swallow a genuine second flick.
		local paddleVel = velocityByRole[role] or Vector3.zero
		if (paddleVel - puckService.getVelocity()):Dot(normal) <= 0 then return end

		local impactSpeed = puckService.applyPaddleHit(normal, paddleVel)
		puckService.separateFrom(to, reach)

		-- The cooldown now rate-limits the hit *sound* only. The physics stays
		-- frame-responsive while a dribble still cannot machine-gun the audio.
		local now = os.clock()
		if onHit and now - (lastHit[role] or 0) >= Constants.HIT_COOLDOWN then
			lastHit[role] = now
			onHit(role, impactSpeed)
		end
	end

	function service.spawnPaddle(role: string, player: Player?)
		local old = paddleByRole[role]
		if old then old:Destroy() end
		if player then playerForRole[role] = player end
		-- Routed through clampTarget so the spawn can never land outside the
		-- role's own half, whatever the inset is set to.
		local sign     = role == "Blue" and field.blueSign or -field.blueSign
		local spawnPos = clampTarget(role,
			field.centre + field.long * (sign * Constants.PADDLE_SPAWN_INSET))
		local paddle   = PaddleTemplate:Clone()
		paddle.Name    = role .. "Paddle_" .. tableModel.Name
		for _, p in ipairs(collectParts(paddle)) do
			p.Anchored = true; p.CanCollide = false; p.CanTouch = false; p.CanQuery = true
		end

		-- Styled before parenting so the paddle never pops in wearing the house
		-- colours for a frame.
		local owner = playerForRole[role]
		if owner then
			local loadout = LoadoutService.get(owner)
			applySkin(paddle, loadout.paddleSkin)
			attachNameTag(paddle, owner)
		end

		paddle.Parent  = workspace
		paddle:PivotTo(getPaddleCFrame(spawnPos))
		paddleByRole[role]   = paddle
		targetByRole[role]   = spawnPos
		prevPosByRole[role]  = spawnPos
		velocityByRole[role] = Vector3.zero
		lastHit[role]        = 0
	end

	function service.removePaddle(role: string)
		targetByRole[role]   = nil
		velocityByRole[role] = nil
		prevPosByRole[role]  = nil
		lastHit[role]        = nil
		playerForRole[role]  = nil
		local paddle = paddleByRole[role]
		if paddle then paddle:Destroy(); paddleByRole[role] = nil end
	end

	function service.getBounds() return field end

	return service
end

return { create = createPaddleService }