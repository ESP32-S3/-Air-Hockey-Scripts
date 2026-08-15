-- VFXEngine
-- The primitive layer every goal/win cosmetic is built from. Recipes in
-- VFXLibrary never touch Instance.new directly: they ask for primitives here,
-- which keeps cleanup, budgeting and the arena's scale in one place.
--
-- Design notes:
--   * Everything is client-side. Nothing here replicates.
--   * Geometry over textures. Untextured Beams and Trails render as clean
--     colour ramps, so the library needs no image assets and never falls back
--     to the stock sparkle sprite that made the old effects look identical.
--   * Every allocation goes through a Scope, which owns teardown. A recipe
--     cannot leak because the scope destroys its folder on a fixed timer
--     whether or not the recipe finished.
--   * Part allocation is budgeted globally. Past the cap, primitives degrade
--     (fewer shards, no decorative layer) instead of dropping frame rate.

local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Debris       = game:GetService("Debris")

local VFXEngine = {}

-- The playfield is small: 5.3 x 11.2 studs of ice. Effects are authored in
-- multiples of this so nothing outgrows the table it is standing on.
VFXEngine.ARENA_RADIUS = 3.2
VFXEngine.ARENA_HEIGHT = 12

-- Ceiling on simultaneously live effect parts across all scopes. Two players
-- scoring back to back on adjacent tables should never blow past this.
local MAX_LIVE_PARTS = 260
local livePartCount = 0

local rng = Random.new()

local container: Folder? = nil

local function getContainer(): Folder
	if container and container.Parent then
		return container
	end
	local existing = workspace:FindFirstChild("AirHockeyVFX")
	if existing and existing:IsA("Folder") then
		container = existing
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "AirHockeyVFX"
	folder.Parent = workspace
	container = folder
	return folder
end

local function tween(inst: Instance, duration: number, props: { [string]: any }, style, direction, delayTime)
	local info = TweenInfo.new(
		duration,
		style or Enum.EasingStyle.Quad,
		direction or Enum.EasingDirection.Out,
		0,
		false,
		delayTime or 0
	)
	local t = TweenService:Create(inst, info, props)
	t:Play()
	return t
end
VFXEngine.tween = tween

-- Camera shake ------------------------------------------------------------
-- One accumulator shared by every effect, so two overlapping shakes add up
-- smoothly instead of fighting over the camera CFrame.

local shakes: { { amplitude: number, duration: number, elapsed: number, frequency: number } } = {}
local shakeBound = false

local function ensureShakeLoop()
	if shakeBound or not RunService:IsClient() then
		return
	end
	shakeBound = true
	RunService:BindToRenderStep("AirHockeyVFXShake", Enum.RenderPriority.Camera.Value + 1, function(dt)
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end

		local offsetX, offsetY, roll = 0, 0, 0
		for index = #shakes, 1, -1 do
			local shake = shakes[index]
			shake.elapsed += dt
			if shake.elapsed >= shake.duration then
				table.remove(shakes, index)
			else
				-- Decays to nothing so the camera always settles back level.
				local falloff = 1 - (shake.elapsed / shake.duration)
				local strength = shake.amplitude * falloff * falloff
				local phase = shake.elapsed * shake.frequency
				offsetX += math.sin(phase * 6.283) * strength
				offsetY += math.sin(phase * 9.111 + 1.7) * strength
				roll    += math.sin(phase * 4.523 + 0.9) * strength * 0.35
			end
		end

		if offsetX ~= 0 or offsetY ~= 0 or roll ~= 0 then
			camera.CFrame = camera.CFrame * CFrame.new(offsetX, offsetY, 0) * CFrame.Angles(0, 0, roll)
		end
	end)
end

-- amplitude is in studs of camera offset; 0.12 is a tap, 0.5 is a legendary hit.
function VFXEngine.shake(amplitude: number, duration: number, frequency: number?)
	if not RunService:IsClient() then
		return
	end
	ensureShakeLoop()
	if #shakes >= 6 then
		return
	end
	table.insert(shakes, {
		amplitude = amplitude,
		duration = math.max(duration, 0.05),
		elapsed = 0,
		frequency = frequency or 18,
	})
end

-- Scope -------------------------------------------------------------------

local Scope = {}
Scope.__index = Scope

export type Scope = typeof(setmetatable({} :: {
	root: Folder,
	parts: number,
	closed: boolean,
	connections: { RBXScriptConnection },
}, Scope))

-- lifetime is a hard ceiling: the scope tears itself down then no matter what
-- the recipe is doing, which is what makes leaks structurally impossible.
function VFXEngine.beginScope(name: string, lifetime: number): Scope
	local root = Instance.new("Folder")
	root.Name = name
	root.Parent = getContainer()

	local scope = setmetatable({
		root = root,
		parts = 0,
		closed = false,
		connections = {},
	}, Scope)

	task.delay(lifetime, function()
		scope:destroy()
	end)

	return scope
end

function Scope:destroy()
	if self.closed then
		return
	end
	self.closed = true
	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
	table.clear(self.connections)
	livePartCount -= self.parts
	self.parts = 0
	self.root:Destroy()
end

function Scope:bind(connection: RBXScriptConnection): RBXScriptConnection
	if self.closed then
		connection:Disconnect()
	else
		table.insert(self.connections, connection)
	end
	return connection
end

-- Schedules a beat. Silently drops if the scope has already torn down, so a
-- late tail can never resurrect a dead effect.
function Scope:after(delayTime: number, fn: (Scope) -> ())
	task.delay(delayTime, function()
		if not self.closed then
			fn(self)
		end
	end)
end

-- Returns nil once the global budget is spent. Callers must handle nil.
function Scope:part(): Part?
	if self.closed or livePartCount >= MAX_LIVE_PARTS then
		return nil
	end
	livePartCount += 1
	self.parts += 1

	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.Neon
	part.Parent = self.root
	return part
end

-- True when the budget still has room for `count` more parts, so recipes can
-- skip an optional layer wholesale rather than drawing half of it.
function Scope:canAfford(count: number): boolean
	return not self.closed and (livePartCount + count) <= MAX_LIVE_PARTS
end

function Scope:attachment(part: BasePart, offset: Vector3?): Attachment
	local attachment = Instance.new("Attachment")
	if offset then
		attachment.Position = offset
	end
	attachment.Parent = part
	return attachment
end

-- Primitives --------------------------------------------------------------
-- Every primitive takes (scope, ...) and returns whatever a recipe might want
-- to keep tweening. All of them tolerate a spent budget by doing less.

-- A Cylinder part's axis runs along X, so laying one flat or standing one up
-- both need this quarter turn. Kept in one place to stop sign errors.
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)

local function colorSequence(color: any): ColorSequence
	if typeof(color) == "ColorSequence" then
		return color
	end
	return ColorSequence.new(color)
end

local function numberRange(value: any, fallbackLow: number, fallbackHigh: number): NumberRange
	if typeof(value) == "NumberRange" then
		return value
	end
	if typeof(value) == "number" then
		return NumberRange.new(value)
	end
	return NumberRange.new(fallbackLow, fallbackHigh)
end

-- Beam.Transparency is a NumberSequence, which TweenService refuses to touch.
-- One driver value per call fades a whole group of beams together, which is
-- both correct and cheaper than a connection per beam.
local function fadeBeams(
	scope: Scope,
	beams: { Beam },
	duration: number,
	fromValue: number,
	toValue: number,
	delayTime: number?,
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?
)
	if #beams == 0 then
		return
	end

	local driver = Instance.new("NumberValue")
	driver.Value = fromValue
	driver.Parent = scope.root

	scope:bind(driver.Changed:Connect(function(value: number)
		local sequence = NumberSequence.new(value)
		for _, beam in ipairs(beams) do
			if beam.Parent then
				beam.Transparency = sequence
			end
		end
	end))

	tween(driver, duration, { Value = toValue },
		style or Enum.EasingStyle.Quad,
		direction or Enum.EasingDirection.In,
		delayTime)
end
VFXEngine.fadeBeams = fadeBeams

-- Flat disc that expands and fades: the workhorse shockwave.
function VFXEngine.disc(scope: Scope, cf: CFrame, opts: { [string]: any })
	local part = scope:part()
	if not part then
		return nil
	end

	local startRadius = opts.startRadius or 0.4
	local endRadius   = opts.endRadius or 6
	local thickness   = opts.thickness or 0.12

	part.Shape = Enum.PartType.Cylinder
	part.Material = opts.material or Enum.Material.Neon
	part.Color = opts.color or Color3.fromRGB(255, 255, 255)
	part.Transparency = opts.startTransparency or 0.2
	part.Size = Vector3.new(thickness, startRadius * 2, startRadius * 2)
	part.CFrame = cf * UPRIGHT

	tween(part, opts.duration or 0.45, {
		Size = Vector3.new(thickness * (opts.thin and 0.35 or 1), endRadius * 2, endRadius * 2),
		Transparency = 1,
	}, opts.style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

	return part
end

-- Expanding (or imploding, with endRadius < startRadius) ball.
function VFXEngine.sphere(scope: Scope, cf: CFrame, opts: { [string]: any })
	local part = scope:part()
	if not part then
		return nil
	end

	local startRadius = opts.startRadius or 0.3
	local endRadius   = opts.endRadius or 3

	part.Shape = Enum.PartType.Ball
	part.Material = opts.material or Enum.Material.Neon
	part.Color = opts.color or Color3.fromRGB(255, 255, 255)
	part.Transparency = opts.startTransparency or 0.1
	part.Size = Vector3.new(startRadius, startRadius, startRadius) * 2
	part.CFrame = cf

	tween(part, opts.duration or 0.35, {
		Size = Vector3.new(endRadius, endRadius, endRadius) * 2,
		Transparency = opts.endTransparency or 1,
	}, opts.style or Enum.EasingStyle.Quad, opts.direction or Enum.EasingDirection.Out)

	return part
end

-- Vertical column of light. `grow` makes it rise from the floor rather than
-- appearing at full height, which is what sells a spotlight or a rift.
function VFXEngine.pillar(scope: Scope, cf: CFrame, opts: { [string]: any })
	local part = scope:part()
	if not part then
		return nil
	end

	local height = opts.height or VFXEngine.ARENA_HEIGHT
	local radius = opts.radius or 1.2
	local startHeight = opts.grow and 0.2 or height

	part.Shape = Enum.PartType.Cylinder
	part.Material = opts.material or Enum.Material.Neon
	part.Color = opts.color or Color3.fromRGB(255, 255, 255)
	part.Transparency = opts.startTransparency or 0.55
	part.Size = Vector3.new(startHeight, radius * 2, radius * 2)
	part.CFrame = cf * CFrame.new(0, startHeight / 2, 0) * UPRIGHT

	tween(part, opts.duration or 0.6, {
		Size = Vector3.new(height, (opts.endRadius or radius) * 2, (opts.endRadius or radius) * 2),
		CFrame = cf * CFrame.new(0, height / 2, 0) * UPRIGHT,
		Transparency = opts.endTransparency or 1,
	}, opts.style or Enum.EasingStyle.Quad, opts.direction or Enum.EasingDirection.Out)

	return part
end

-- A true ring silhouette: N bodies pushed outward on a circle. Unlike a disc
-- this reads as discrete objects, which is what separates "ring of ice spikes"
-- from "ring of energy".
function VFXEngine.ring(scope: Scope, cf: CFrame, opts: { [string]: any })
	local count = opts.count or 12
	if not scope:canAfford(count) then
		count = math.max(4, math.floor(count / 2))
	end

	local startRadius = opts.startRadius or 0.5
	local endRadius   = opts.endRadius or 4.5
	local size        = opts.size or Vector3.new(0.22, 0.22, 0.9)
	local duration    = opts.duration or 0.5
	local rise        = opts.rise or 0
	local spin        = opts.spin or 0
	local made = {}

	for index = 0, count - 1 do
		local part = scope:part()
		if not part then
			break
		end
		local angle = (index / count) * math.pi * 2 + (opts.phase or 0)
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))

		part.Shape = Enum.PartType.Block
		part.Material = opts.material or Enum.Material.Neon
		part.Color = opts.color or Color3.fromRGB(255, 255, 255)
		part.Transparency = opts.startTransparency or 0
		part.Size = size
		part.CFrame = cf * CFrame.new(direction * startRadius) * CFrame.Angles(0, -angle, 0)

		tween(part, duration, {
			CFrame = cf
				* CFrame.new(direction * endRadius + Vector3.new(0, rise, 0))
				* CFrame.Angles(0, -angle, 0)
				* CFrame.Angles(spin, 0, 0),
			Size = size * (opts.endScale or 1),
			Transparency = 1,
		}, opts.style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

		table.insert(made, part)
	end

	return made
end

-- Ballistic debris. Two chained tweens (out-and-up, then down) give a real
-- arc without paying for a per-frame simulation.
function VFXEngine.shards(scope: Scope, cf: CFrame, opts: { [string]: any })
	local count = opts.count or 14
	if not scope:canAfford(count) then
		count = math.max(3, math.floor(count / 3))
	end

	local spread   = opts.spread or 4.5
	local lift     = opts.lift or 3
	local fall     = opts.fall or 4
	local riseTime = opts.riseTime or 0.4
	local fallTime = opts.fallTime or 0.9
	local colors   = opts.colors

	for index = 1, count do
		local part = scope:part()
		if not part then
			break
		end

		local angle = rng:NextNumber(0, math.pi * 2)
		local reach = spread * rng:NextNumber(0.45, 1)
		local direction = Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
		local apex = lift * rng:NextNumber(0.5, 1.3)

		part.Shape = Enum.PartType.Block
		part.Material = opts.material or Enum.Material.Neon
		part.Color = colors and colors[rng:NextInteger(1, #colors)] or (opts.color or Color3.fromRGB(255, 255, 255))
		part.Transparency = opts.startTransparency or 0
		part.Size = opts.size or Vector3.new(0.28, 0.28, 0.28)
		part.CFrame = cf * CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), rng:NextNumber(0, 6))

		local tumble = CFrame.Angles(rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), rng:NextNumber(-8, 8))
		local apexCF = cf * CFrame.new(direction * 0.65 + Vector3.new(0, apex, 0)) * tumble

		tween(part, riseTime, { CFrame = apexCF }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		tween(part, fallTime, {
			CFrame = apexCF * CFrame.new(direction * 0.35) * CFrame.new(0, -(apex + fall), 0) * tumble,
			Transparency = 1,
		}, Enum.EasingStyle.Quad, Enum.EasingDirection.In, riseTime)
	end
end

-- Trailed projectiles: bright heads dragging a colour ramp behind them.
function VFXEngine.streaks(scope: Scope, cf: CFrame, opts: { [string]: any })
	local count = opts.count or 8
	if not scope:canAfford(count) then
		count = math.max(2, math.floor(count / 3))
	end

	local reach    = opts.reach or 6
	local rise     = opts.rise or 4
	local duration = opts.duration or 0.7
	local color    = opts.color or Color3.fromRGB(255, 255, 255)

	for index = 1, count do
		local part = scope:part()
		if not part then
			break
		end

		local angle = (index / count) * math.pi * 2 + rng:NextNumber(-0.25, 0.25)
		local outward = Vector3.new(math.cos(angle), 0, math.sin(angle)) * reach * rng:NextNumber(0.7, 1.15)

		part.Shape = Enum.PartType.Ball
		part.Material = Enum.Material.Neon
		part.Color = color
		part.Size = Vector3.new(1, 1, 1) * (opts.headSize or 0.3)
		part.CFrame = cf

		local top = scope:attachment(part, Vector3.new(0, 0.14, 0))
		local bottom = scope:attachment(part, Vector3.new(0, -0.14, 0))

		local trail = Instance.new("Trail")
		trail.Attachment0 = top
		trail.Attachment1 = bottom
		trail.Color = colorSequence(opts.trailColor or color)
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, opts.trailTransparency or 0.15),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.Lifetime = opts.trailLifetime or 0.35
		trail.WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(1, 0),
		})
		trail.LightEmission = opts.lightEmission or 0.8
		trail.FaceCamera = true
		trail.Parent = part

		tween(part, duration, {
			CFrame = cf * CFrame.new(outward + Vector3.new(0, rise * rng:NextNumber(0.6, 1.25), 0)),
			Transparency = 1,
		}, opts.style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	end
end

-- Jagged multi-segment arc. Segment count drives how electric vs how clean it
-- reads: 1 is a laser, 8 is a lightning bolt.
function VFXEngine.bolt(scope: Scope, from: Vector3, to: Vector3, opts: { [string]: any })
	local anchor = scope:part()
	if not anchor then
		return nil
	end
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.CFrame = CFrame.new(from)

	local segments = opts.segments or 6
	local jitter   = opts.jitter or 0.5
	local color    = opts.color or Color3.fromRGB(255, 255, 255)
	local width    = opts.width or 0.35

	local points: { Attachment } = {}
	for index = 0, segments do
		local alpha = index / segments
		local base = from:Lerp(to, alpha)
		-- Endpoints stay pinned so the bolt actually connects what it should.
		if index > 0 and index < segments then
			base += Vector3.new(
				rng:NextNumber(-jitter, jitter),
				rng:NextNumber(-jitter, jitter),
				rng:NextNumber(-jitter, jitter)
			)
		end
		table.insert(points, scope:attachment(anchor, anchor.CFrame:PointToObjectSpace(base)))
	end

	local beams: { Beam } = {}
	for index = 1, #points - 1 do
		local beam = Instance.new("Beam")
		beam.Attachment0 = points[index]
		beam.Attachment1 = points[index + 1]
		beam.Color = colorSequence(color)
		beam.Width0 = width
		beam.Width1 = width
		beam.LightEmission = 1
		beam.FaceCamera = true
		beam.Transparency = NumberSequence.new(0)
		beam.Parent = anchor
		table.insert(beams, beam)
	end

	fadeBeams(scope, beams, opts.duration or 0.28, 0, 1, opts.hold)
	return anchor
end

-- Spokes of light radiating from a point, tapering outward.
function VFXEngine.rays(scope: Scope, cf: CFrame, opts: { [string]: any })
	local anchor = scope:part()
	if not anchor then
		return nil
	end
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.CFrame = cf

	local count    = opts.count or 8
	local reach    = opts.reach or 5
	local color    = opts.color or Color3.fromRGB(255, 255, 255)
	local duration = opts.duration or 0.5
	local tilt     = opts.tilt or 0

	local hub = scope:attachment(anchor, Vector3.zero)
	local startTransparency = opts.startTransparency or 0.1
	local beams: { Beam } = {}

	for index = 0, count - 1 do
		local angle = (index / count) * math.pi * 2 + (opts.phase or 0)
		local direction = Vector3.new(math.cos(angle), tilt, math.sin(angle)).Unit

		local tip = scope:attachment(anchor, direction * (opts.startReach or 0.3))

		local beam = Instance.new("Beam")
		beam.Attachment0 = hub
		beam.Attachment1 = tip
		beam.Color = colorSequence(color)
		beam.Width0 = opts.width or 0.5
		beam.Width1 = opts.tipWidth or 0.02
		beam.LightEmission = 1
		beam.FaceCamera = true
		beam.Transparency = NumberSequence.new(startTransparency)
		beam.Parent = anchor
		table.insert(beams, beam)

		tween(tip, duration, { Position = direction * reach }, opts.style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	end

	fadeBeams(scope, beams, duration, startTransparency, 1, opts.hold)
	return anchor
end

-- Bodies circling the centre. Uses one bound RenderStepped for the whole set,
-- and the scope disconnects it, so orbits can never outlive their effect.
function VFXEngine.orbit(scope: Scope, cf: CFrame, opts: { [string]: any })
	local count = opts.count or 5
	if not scope:canAfford(count) then
		return
	end

	local bodies: { { part: Part, phase: number } } = {}
	for index = 0, count - 1 do
		local part = scope:part()
		if not part then
			break
		end
		part.Shape = opts.shape or Enum.PartType.Ball
		part.Material = opts.material or Enum.Material.Neon
		part.Color = opts.color or Color3.fromRGB(255, 255, 255)
		part.Size = opts.size or Vector3.new(0.35, 0.35, 0.35)
		table.insert(bodies, { part = part, phase = (index / count) * math.pi * 2 })
	end

	if #bodies == 0 then
		return
	end

	local radius     = opts.radius or 2.6
	local speed      = opts.speed or 3
	local height     = opts.height or 0.6
	local climb      = opts.climb or 0
	local shrink     = opts.shrink or 0
	local duration   = opts.duration or 1.6
	local elapsed    = 0

	scope:bind(RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		local alpha = math.clamp(elapsed / duration, 0, 1)
		for _, body in ipairs(bodies) do
			local angle = body.phase + elapsed * speed
			local r = radius * (1 - shrink * alpha)
			body.part.CFrame = cf * CFrame.new(
				math.cos(angle) * r,
				height + climb * alpha,
				math.sin(angle) * r
			)
			body.part.Transparency = alpha < 0.75 and 0 or (alpha - 0.75) / 0.25
		end
	end))
end

-- Particle burst. Recipes pass a full spec so no two effects share an emitter
-- configuration; this is deliberately not a "default emitter with a colour".
function VFXEngine.motes(scope: Scope, cf: CFrame, spec: { [string]: any })
	local anchor = scope:part()
	if not anchor then
		return nil
	end
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.CFrame = cf

	local attachment = scope:attachment(anchor, Vector3.zero)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = spec.texture or "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = colorSequence(spec.color or Color3.fromRGB(255, 255, 255))
	emitter.Size = typeof(spec.size) == "NumberSequence" and spec.size or NumberSequence.new(spec.size or 0.5)
	emitter.Transparency = typeof(spec.transparency) == "NumberSequence"
		and spec.transparency
		or NumberSequence.new({
			NumberSequenceKeypoint.new(0, spec.transparency or 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
	emitter.Lifetime = numberRange(spec.lifetime, 0.4, 0.9)
	emitter.Speed = numberRange(spec.speed, 6, 12)
	emitter.SpreadAngle = spec.spreadAngle or Vector2.new(180, 180)
	emitter.Rotation = numberRange(spec.rotation, 0, 360)
	emitter.RotSpeed = numberRange(spec.rotSpeed, -90, 90)
	emitter.Acceleration = spec.acceleration or Vector3.new(0, -14, 0)
	emitter.Drag = spec.drag or 2
	emitter.LightEmission = spec.lightEmission or 0.7
	emitter.LightInfluence = spec.lightInfluence or 0
	emitter.Squash = typeof(spec.squash) == "NumberSequence" and spec.squash or NumberSequence.new(spec.squash or 0)
	emitter.Orientation = spec.orientation or Enum.ParticleOrientation.FacingCamera
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = attachment

	emitter:Emit(spec.count or 24)
	return emitter
end

-- Point light pop. Short, bright, and always cleaned up with its scope.
function VFXEngine.flash(scope: Scope, cf: CFrame, opts: { [string]: any })
	local anchor = scope:part()
	if not anchor then
		return nil
	end
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.05, 0.05, 0.05)
	anchor.CFrame = cf

	local light = Instance.new("PointLight")
	light.Color = opts.color or Color3.fromRGB(255, 255, 255)
	light.Brightness = opts.brightness or 6
	light.Range = opts.range or 18
	light.Shadows = false
	light.Parent = anchor

	tween(light, opts.duration or 0.35, { Brightness = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	return light
end

-- Sound layering. Spatial by default so impacts come off the table; pass
-- spatial = false for fanfares that should sit flat in the mix.
function VFXEngine.play(scope: Scope, cf: CFrame, spec: { [string]: any })
	local id = spec.id
	if not id then
		return nil
	end

	local soundId = typeof(id) == "number" and ("rbxassetid://" .. id) or tostring(id)
	local spatial = spec.spatial ~= false

	local function start()
		if scope.closed and spatial then
			return
		end

		local sound = Instance.new("Sound")
		sound.SoundId = soundId
		sound.Volume = spec.volume or 0.6
		sound.PlaybackSpeed = spec.speed or 1
		sound.TimePosition = spec.startAt or 0

		if spatial then
			local anchor = scope:part()
			if not anchor then
				return
			end
			anchor.Transparency = 1
			anchor.Size = Vector3.new(0.05, 0.05, 0.05)
			anchor.CFrame = cf
			sound.RollOffMaxDistance = spec.rollOff or 90
			sound.RollOffMode = Enum.RollOffMode.InverseTapered
			sound.Parent = anchor
		else
			-- Parented outside the scope on purpose: a victory fanfare should
			-- finish even after the visuals have been torn down.
			sound.Parent = SoundService
			Debris:AddItem(sound, (spec.stopAfter or 8) + 0.5)
		end

		sound:Play()

		if spec.stopAfter then
			tween(sound, spec.fadeOut or 0.4, { Volume = 0 }, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, spec.stopAfter)
		end
	end

	if spec.delay and spec.delay > 0 then
		task.delay(spec.delay, start)
	else
		start()
	end
end

VFXEngine.Scope = Scope

return VFXEngine
