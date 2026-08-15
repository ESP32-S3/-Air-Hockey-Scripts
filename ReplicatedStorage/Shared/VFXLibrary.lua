-- VFXLibrary
-- Every goal explosion and victory show, authored as a timed sequence of
-- VFXEngine primitives. This module owns *behaviour*; the folders under
-- ReplicatedStorage.AirHockeyFXPackage own *shop metadata* and are generated
-- from VFXLibrary.META so the two can never disagree about what exists.
--
-- Each recipe follows the same beat structure:
--   0.00s  impact    - the hit you feel: sound transient, flash, camera
--   0.05s  bloom     - the main body of the effect, the silhouette
--   0.20s  secondary - debris, rings, trails; the part that reads as detail
--   1.00s+ aftermath - what lingers and lets the moment breathe
--
-- A recipe must never assume it gets everything it asks for: VFXEngine hands
-- back nil once the part budget is spent, and primitives quietly do less.

local RunService = game:GetService("RunService")

local V = require(script.Parent:WaitForChild("VFXEngine"))

local VFXLibrary = {}

-- Sound palette -----------------------------------------------------------
-- All licensed Roblox library audio (Pro Sound Effects for SFX, APM Music for
-- stings). Durations are noted because most are long-tailed source recordings:
-- recipes pitch them and cut them with stopAfter rather than letting a 5
-- second whip crack ring out over a 1 second explosion.

local S = {
	BOOM_DEEP     = 9125484367,      -- 4.4s  deep reverberant boom, rumbling tail
	BOOM_HUGE     = 9125484743,      -- 5.3s  bigger, longer tail
	BASS_DROP     = 9125402735,      -- 2.9s  sub drop
	ZAP_TIGHT     = 9116279560,      -- 0.8s  tight electrical burst
	ZAP_MID       = 9116274227,      -- 0.8s  electrical burst
	ZAP_LONG      = 9116277954,      -- 2.0s  searing crackle
	STATIC_SHORT  = 9114246932,      -- 0.7s  static pop
	STATIC_LONG   = 9114248154,      -- 1.0s  static buzz
	GLASS         = 9114593452,      -- 1.4s  glass break, debris shards
	GLASS_STRESS  = 9114617899,      -- 2.0s  glass under pressure, cracking
	WOOD_CRACK    = 9120801590,      -- 1.5s  sharp snap
	SWISH         = 9119690473,      -- 2.8s  air swish
	RISER         = 9120734018,      -- 3.4s  rising airy whoosh
	SYNTH_A       = 9119853961,      -- 4.6s  synth whip crack + whoosh
	SYNTH_B       = 9119854246,      -- 3.9s
	SYNTH_C       = 9119854262,      -- 3.6s
	WHIP          = 9120666832,      -- 4.3s  whip crack
	SWORD_SWISH   = 9119749262,      -- 2.9s  metal shing
	SWORD_SCRAPE  = 9119748381,      -- 2.3s  blade scrape
	CROWD_APPLAUSE= 9120974378,      -- 4.3s  applause, crowd surge
	CROWD_CLAP    = 9120974507,      -- 4.0s  applause
	CROWD_OVATION = 9120974515,      -- 5.3s  standing ovation
	CROWD_BOO     = 9120974911,      -- 4.6s  boos and whistles
	CROWD_PYRO    = 9120975204,      -- 9.5s  cheers with pyro
	CROWD_SURGE   = 9120975307,      -- 3.5s  surging cheer
	STING_FUNK    = 9040142241,      -- 4.1s  bright funk brass
	STING_JAZZ    = 9039636412,      -- 4.6s  latin jazz fusion
	STING_JAZZ2   = 9039637427,      -- 6.5s
	STING_CORP    = 9042415011,      -- 5.7s  clean orchestral sting
	STING_ROOF    = 1840076509,      -- 2.3s  short organ sting
	STING_FUNK2   = 1839982934,      -- 4.5s
	STING_SPARKLE = 1841180330,      -- 8.5s  sparkling neutral bed
	STING_DIVINE  = 1846674838,      -- 8.2s  soaring
	STING_HEADLINE= 74373926089175,  -- 6.9s  headline stinger
	STING_MECH    = 117732278644683, -- 6.1s  heavy mechanical stinger
	STING_EMERGE  = 124233970118060, -- 7.1s  emerging swell
}
VFXLibrary.SOUNDS = S

-- Shared colour language --------------------------------------------------

local WHITE  = Color3.fromRGB(255, 255, 255)
local function rgb(r, g, b) return Color3.fromRGB(r, g, b) end

-- Flattens the incoming pivot to a world-axis frame. The puck model's pivot
-- carries whatever rotation it happened to stop at, which would otherwise
-- tilt every ring and disc slightly differently each goal.
local function level(cf: CFrame): CFrame
	return CFrame.new(cf.Position)
end

local GOAL = {}
local WIN = {}

-- ==========================================================================
-- GOAL EXPLOSIONS
-- ==========================================================================

-- COMMON -------------------------------------------------------------------

-- The free default. Deliberately restrained: one clean pop in the scoring
-- team's colour. It has to look finished, not cheap, without ever competing
-- with something a player paid for.
GOAL.flash = { lifetime = 2.5, build = function(scope, cf, ctx)
	local tint = ctx.teamColor or WHITE
	V.play(scope, cf, { id = S.BASS_DROP, volume = 0.5, speed = 1.4, stopAfter = 0.8, fadeOut = 0.3 })
	V.flash(scope, cf, { color = tint, brightness = 9, range = 24, duration = 0.3 })
	V.disc(scope, cf, { color = tint, endRadius = 4.6, duration = 0.4, thin = true })
	V.shake(0.11, 0.22)

	scope:after(0.07, function()
		V.ring(scope, cf, { color = tint, count = 10, endRadius = 3.4, duration = 0.45,
			size = Vector3.new(0.16, 0.16, 0.75) })
		V.motes(scope, cf, { color = tint, count = 20, size = 0.45,
			speed = NumberRange.new(8, 15), lifetime = NumberRange.new(0.3, 0.7) })
	end)
end }

-- Party popper: flat papers that tumble and flutter. The silhouette is the
-- rain of rectangles, so the shards are wide and thin rather than cubes.
GOAL.confetti = { lifetime = 3.5, build = function(scope, cf)
	local colors = { rgb(255, 107, 107), rgb(255, 201, 60), rgb(94, 222, 158), rgb(62, 168, 245), rgb(198, 134, 245) }
	V.play(scope, cf, { id = S.STATIC_SHORT, volume = 0.5, speed = 1.6, stopAfter = 0.4, fadeOut = 0.2 })
	V.play(scope, cf, { id = S.CROWD_SURGE, volume = 0.35, speed = 1.05, stopAfter = 2.2, fadeOut = 0.8, delay = 0.1 })
	V.flash(scope, cf, { color = rgb(255, 240, 200), brightness = 4, range = 14, duration = 0.2 })

	scope:after(0.05, function()
		V.shards(scope, cf, {
			count = 34, colors = colors, material = Enum.Material.SmoothPlastic,
			size = Vector3.new(0.34, 0.05, 0.22),
			spread = 5.5, lift = 4.2, fall = 5, riseTime = 0.5, fallTime = 1.7,
		})
	end)
	scope:after(0.35, function()
		V.shards(scope, cf, {
			count = 18, colors = colors, material = Enum.Material.SmoothPlastic,
			size = Vector3.new(0.28, 0.05, 0.18),
			spread = 3.4, lift = 3, fall = 4.5, riseTime = 0.55, fallTime = 1.8,
		})
	end)
end }

-- Hot metal sparks: low, fast, and gone. Everything hugs the ice.
GOAL.sparks = { lifetime = 2.5, build = function(scope, cf)
	local ember = rgb(255, 176, 46)
	V.play(scope, cf, { id = S.WOOD_CRACK, volume = 0.55, speed = 1.5, stopAfter = 0.5, fadeOut = 0.2 })
	V.play(scope, cf, { id = S.STATIC_LONG, volume = 0.35, speed = 1.3, stopAfter = 0.9, fadeOut = 0.4, delay = 0.04 })
	V.flash(scope, cf, { color = ember, brightness = 7, range = 16, duration = 0.22 })
	V.shake(0.1, 0.18)

	scope:after(0.05, function()
		V.ring(scope, cf, { color = rgb(255, 214, 120), count = 14, endRadius = 3.2, duration = 0.35,
			size = Vector3.new(0.1, 0.1, 0.55) })
		V.shards(scope, cf, {
			count = 26, color = ember, size = Vector3.new(0.12, 0.12, 0.4),
			spread = 6, lift = 1.4, fall = 1.8, riseTime = 0.22, fallTime = 0.7,
		})
	end)
	scope:after(0.2, function()
		V.motes(scope, cf, { color = rgb(255, 148, 60), count = 18, size = 0.22,
			speed = NumberRange.new(3, 8), lifetime = NumberRange.new(0.6, 1.2),
			acceleration = Vector3.new(0, -6, 0) })
	end)
end }

-- Wet, heavy, slow. Big soft blobs instead of sparks; the low flat splat disc
-- does the work and the spheres squash as they land.
GOAL.paint = { lifetime = 3, build = function(scope, cf)
	local colors = { rgb(255, 92, 138), rgb(64, 214, 214), rgb(255, 209, 74), rgb(150, 118, 240) }
	V.play(scope, cf, { id = S.BOOM_DEEP, volume = 0.5, speed = 1.8, stopAfter = 0.6, fadeOut = 0.3 })
	V.disc(scope, cf, { color = colors[1], endRadius = 4.2, duration = 0.5, thickness = 0.08,
		material = Enum.Material.SmoothPlastic, startTransparency = 0.05 })

	scope:after(0.06, function()
		for index = 1, 5 do
			local angle = (index / 5) * math.pi * 2
			local offset = CFrame.new(math.cos(angle) * 2.2, 0.5, math.sin(angle) * 2.2)
			V.sphere(scope, cf * offset, {
				color = colors[(index % #colors) + 1], material = Enum.Material.SmoothPlastic,
				startRadius = 0.15, endRadius = 1.1, duration = 0.55,
				style = Enum.EasingStyle.Back, endTransparency = 1,
			})
		end
	end)
	scope:after(0.3, function()
		V.shards(scope, cf, {
			count = 16, colors = colors, material = Enum.Material.SmoothPlastic,
			size = Vector3.new(0.3, 0.12, 0.3),
			spread = 4, lift = 1.6, fall = 2, riseTime = 0.3, fallTime = 0.9,
		})
	end)
end }

-- The gentle one. Glass spheres drift up and pop at staggered heights, so the
-- effect has a rhythm rather than a single hit.
GOAL.bubbles = { lifetime = 3.5, build = function(scope, cf)
	local tint = rgb(150, 226, 255)
	V.play(scope, cf, { id = S.STATIC_SHORT, volume = 0.35, speed = 2.1, stopAfter = 0.3, fadeOut = 0.15 })
	V.disc(scope, cf, { color = tint, endRadius = 3, duration = 0.5, thin = true, startTransparency = 0.5 })

	for index = 1, 10 do
		local delayTime = 0.05 + index * 0.055
		scope:after(delayTime, function()
			local angle = index * 2.399
			local radius = 0.6 + (index % 4) * 0.5
			local spot = cf * CFrame.new(math.cos(angle) * radius, 0.3, math.sin(angle) * radius)
			local bubble = V.sphere(scope, spot, {
				color = tint, material = Enum.Material.Glass,
				startRadius = 0.1, endRadius = 0.42, duration = 0.75,
				startTransparency = 0.45, endTransparency = 0.35,
			})
			if bubble then
				V.tween(bubble, 0.75, { CFrame = spot * CFrame.new(0, 2.6, 0) },
					Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			end
			-- Pops at apex rather than fading, which is what sells it as a bubble.
			scope:after(0.75, function()
				V.play(scope, spot, { id = S.STATIC_SHORT, volume = 0.16,
					speed = 2.4 + (index % 3) * 0.25, stopAfter = 0.16, fadeOut = 0.08 })
				V.motes(scope, spot * CFrame.new(0, 2.6, 0), {
					color = tint, count = 5, size = 0.16,
					speed = NumberRange.new(2, 4), lifetime = NumberRange.new(0.25, 0.5),
					acceleration = Vector3.new(0, -3, 0),
				})
			end)
		end)
	end
end }

-- Retro on purpose: axis-aligned cubes that step outward in a lattice, no
-- tumbling, no smooth arcs. The stiffness is the identity.
GOAL.pixel = { lifetime = 2.5, build = function(scope, cf)
	local colors = { rgb(255, 92, 92), rgb(94, 222, 158), rgb(62, 168, 245), rgb(255, 201, 60) }
	V.play(scope, cf, { id = S.STATIC_SHORT, volume = 0.5, speed = 1.9, stopAfter = 0.35, fadeOut = 0.1 })
	V.play(scope, cf, { id = S.STATIC_LONG, volume = 0.3, speed = 0.7, stopAfter = 0.6, fadeOut = 0.2, delay = 0.06 })
	V.flash(scope, cf, { color = WHITE, brightness = 6, range = 14, duration = 0.12 })

	-- Three square rings stepping outward reads as a pixel grid expanding.
	for step = 1, 3 do
		scope:after(0.05 + step * 0.07, function()
			local radius = step * 1.15
			local perSide = 3 + step
			for index = 0, perSide * 4 - 1 do
				local part = scope:part()
				if not part then break end
				local side = math.floor(index / perSide)
				local t = (index % perSide) / (perSide - 1) * 2 - 1
				local x = (side == 0 and t or side == 1 and 1 or side == 2 and -t or -1) * radius
				local z = (side == 0 and -1 or side == 1 and t or side == 2 and 1 or -t) * radius
				part.Shape = Enum.PartType.Block
				part.Color = colors[(index % #colors) + 1]
				part.Size = Vector3.new(0.34, 0.34, 0.34)
				part.CFrame = cf * CFrame.new(x, 0.2, z)
				V.tween(part, 0.45, { Transparency = 1, Size = Vector3.new(0.05, 0.05, 0.05) },
					Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0.12)
			end
		end)
	end
end }

-- RARE ---------------------------------------------------------------------

-- Anticipation is the whole point: the strike comes down before anything
-- happens on the ice, so the impact lands on a beat you can see coming.
GOAL.bolt = { lifetime = 3, build = function(scope, cf)
	local electric = rgb(150, 220, 255)
	local top = cf.Position + Vector3.new(0, 16, 0)

	V.play(scope, cf, { id = S.ZAP_TIGHT, volume = 0.55, speed = 1.1, stopAfter = 0.7, fadeOut = 0.25 })
	V.bolt(scope, top, cf.Position, { segments = 9, jitter = 0.75, color = electric, width = 0.4, duration = 0.22 })

	scope:after(0.09, function()
		V.play(scope, cf, { id = S.BOOM_DEEP, volume = 0.6, speed = 1.5, stopAfter = 1, fadeOut = 0.4 })
		V.flash(scope, cf, { color = WHITE, brightness = 14, range = 30, duration = 0.25 })
		V.disc(scope, cf, { color = electric, endRadius = 6, duration = 0.4, thin = true })
		V.shake(0.32, 0.4)
		-- Forks crawling outward across the ice.
		for index = 1, 4 do
			local angle = (index / 4) * math.pi * 2 + 0.4
			local target = cf.Position + Vector3.new(math.cos(angle) * 4.5, 0.15, math.sin(angle) * 4.5)
			V.bolt(scope, cf.Position, target, { segments = 5, jitter = 0.5, color = electric, width = 0.2, duration = 0.3 })
		end
	end)
	scope:after(0.4, function()
		V.motes(scope, cf, { color = electric, count = 16, size = 0.3,
			speed = NumberRange.new(4, 10), lifetime = NumberRange.new(0.4, 1),
			lightEmission = 1 })
	end)
end }

-- Forms, stresses, then breaks. The crystal has to exist for a moment before
-- it shatters or the shatter reads as noise.
GOAL.frost = { lifetime = 3.5, build = function(scope, cf)
	local ice = rgb(178, 235, 255)
	local deep = rgb(96, 168, 230)

	V.play(scope, cf, { id = S.GLASS_STRESS, volume = 0.45, speed = 1.2, stopAfter = 0.5, fadeOut = 0.15 })
	local crystal = V.sphere(scope, cf * CFrame.new(0, 1, 0), {
		color = ice, material = Enum.Material.Glass,
		startRadius = 2.2, endRadius = 0.7, duration = 0.3,
		startTransparency = 0.7, endTransparency = 0.25,
		style = Enum.EasingStyle.Quad, direction = Enum.EasingDirection.In,
	})

	scope:after(0.32, function()
		if crystal then crystal:Destroy() end
		V.play(scope, cf, { id = S.GLASS, volume = 0.65, speed = 1, stopAfter = 1.1, fadeOut = 0.35 })
		V.flash(scope, cf, { color = ice, brightness = 10, range = 22, duration = 0.25 })
		V.shake(0.18, 0.3)
		-- Spikes stab outward and up: an ice ring, not a smoke ring.
		V.ring(scope, cf, { color = ice, count = 14, endRadius = 4, duration = 0.5, rise = 0.8,
			material = Enum.Material.Glass, size = Vector3.new(0.24, 0.24, 1.5),
			spin = 0.5, startTransparency = 0.15 })
		V.shards(scope, cf * CFrame.new(0, 1, 0), {
			count = 22, color = deep, material = Enum.Material.Glass,
			size = Vector3.new(0.18, 0.5, 0.18),
			spread = 5, lift = 2.6, fall = 3.4, riseTime = 0.35, fallTime = 1.2,
			startTransparency = 0.2,
		})
	end)
	scope:after(0.9, function()
		V.motes(scope, cf * CFrame.new(0, 1.5, 0), {
			color = ice, count = 24, size = 0.14,
			speed = NumberRange.new(0.5, 2), lifetime = NumberRange.new(1, 1.8),
			acceleration = Vector3.new(0, -1.5, 0), drag = 4,
		})
	end)
end }

-- Vertical, not radial. Fire wants to climb, so the column carries the shape
-- and the ground ring is just the footprint.
GOAL.fire = { lifetime = 3.5, build = function(scope, cf)
	local flame = rgb(255, 138, 40)
	local hot = rgb(255, 226, 138)

	V.play(scope, cf, { id = S.RISER, volume = 0.4, speed = 1.5, stopAfter = 0.7, fadeOut = 0.25 })
	V.flash(scope, cf, { color = flame, brightness = 8, range = 20, duration = 0.3 })

	scope:after(0.1, function()
		V.play(scope, cf, { id = S.BOOM_DEEP, volume = 0.6, speed = 1.15, stopAfter = 1.4, fadeOut = 0.6 })
		V.pillar(scope, cf, { color = flame, height = 9, radius = 1.5, endRadius = 2.6,
			grow = true, duration = 0.7, startTransparency = 0.25 })
		V.disc(scope, cf, { color = hot, endRadius = 4.4, duration = 0.45, thin = true })
		V.shake(0.2, 0.35)
	end)
	scope:after(0.25, function()
		V.streaks(scope, cf, { count = 9, color = hot, trailColor = flame,
			reach = 3, rise = 7, duration = 0.9, headSize = 0.35, trailLifetime = 0.45 })
	end)
	scope:after(0.5, function()
		V.motes(scope, cf * CFrame.new(0, 3, 0), {
			color = ColorSequence.new(flame, rgb(90, 60, 60)),
			count = 20, size = NumberSequence.new(0.5, 1.6),
			speed = NumberRange.new(1, 3.5), lifetime = NumberRange.new(1, 2),
			acceleration = Vector3.new(0, 2.5, 0), drag = 3, lightEmission = 0.3,
			texture = "rbxasset://textures/particles/smoke_main.dds",
		})
	end)
end }

-- Clean sci-fi geometry: core, spokes, then one very wide very thin wave.
-- No debris at all, which is what keeps it feeling like energy not matter.
GOAL.plasma = { lifetime = 3, build = function(scope, cf)
	local core = rgb(126, 236, 255)
	local edge = rgb(150, 108, 255)

	V.play(scope, cf, { id = S.ZAP_LONG, volume = 0.45, speed = 1.4, stopAfter = 0.8, fadeOut = 0.3 })
	V.sphere(scope, cf * CFrame.new(0, 0.8, 0), { color = core, startRadius = 0.2, endRadius = 1.6,
		duration = 0.18, endTransparency = 0.2, style = Enum.EasingStyle.Back })

	scope:after(0.12, function()
		V.play(scope, cf, { id = S.BASS_DROP, volume = 0.55, speed = 1.1, stopAfter = 1.2, fadeOut = 0.5 })
		V.flash(scope, cf, { color = core, brightness = 12, range = 26, duration = 0.3 })
		V.rays(scope, cf * CFrame.new(0, 0.8, 0), { count = 10, reach = 6, color = edge,
			width = 0.65, duration = 0.5 })
		V.shake(0.22, 0.3)
	end)
	scope:after(0.22, function()
		V.disc(scope, cf * CFrame.new(0, 0.6, 0), { color = core, endRadius = 8,
			duration = 0.55, thickness = 0.3, thin = true, startTransparency = 0.35 })
	end)
	scope:after(0.5, function()
		V.orbit(scope, cf * CFrame.new(0, 0.9, 0), { count = 4, radius = 2, speed = 5,
			color = edge, size = Vector3.new(0.28, 0.28, 0.28), duration = 1.2, shrink = 1 })
	end)
end }

-- Runs backwards: opens, holds, collapses inward. The hold is what makes the
-- implosion land.
GOAL.portal = { lifetime = 3.5, build = function(scope, cf)
	local violet = rgb(176, 116, 255)
	local rim = rgb(255, 172, 236)
	local centre = cf * CFrame.new(0, 1.4, 0)

	V.play(scope, cf, { id = S.RISER, volume = 0.45, speed = 0.85, stopAfter = 1.1, fadeOut = 0.4 })
	local gate = V.disc(scope, centre, { color = violet, startRadius = 0.2, endRadius = 3,
		duration = 0.4, thickness = 0.25, startTransparency = 0.25, style = Enum.EasingStyle.Back })
	V.ring(scope, centre, { color = rim, count = 16, startRadius = 0.3, endRadius = 3,
		duration = 0.4, size = Vector3.new(0.14, 0.14, 0.6), style = Enum.EasingStyle.Back })

	scope:after(0.55, function()
		-- Collapse: streaks fall inward, then the gate snaps shut.
		V.play(scope, cf, { id = S.SYNTH_C, volume = 0.5, speed = 1.3, stopAfter = 1, fadeOut = 0.4 })
		for index = 1, 10 do
			local angle = (index / 10) * math.pi * 2
			local from = centre * CFrame.new(math.cos(angle) * 5, 0, math.sin(angle) * 5)
			local mote = scope:part()
			if mote then
				mote.Shape = Enum.PartType.Ball
				mote.Color = rim
				mote.Size = Vector3.new(0.3, 0.3, 0.3)
				mote.CFrame = from
				V.tween(mote, 0.35, { CFrame = centre, Size = Vector3.new(0.05, 0.05, 0.05) },
					Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			end
		end
		if gate then
			V.tween(gate, 0.35, { Size = Vector3.new(0.25, 0.2, 0.2), Transparency = 0 },
				Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		end
	end)
	scope:after(0.95, function()
		V.play(scope, cf, { id = S.BOOM_DEEP, volume = 0.55, speed = 1.6, stopAfter = 0.8, fadeOut = 0.35 })
		V.flash(scope, centre, { color = rim, brightness = 14, range = 26, duration = 0.25 })
		V.disc(scope, centre, { color = violet, endRadius = 7, duration = 0.45, thin = true })
		V.shake(0.26, 0.32)
	end)
end }

-- Sustained rather than instant: a column of orbiting debris that climbs and
-- tightens for a second and a half.
GOAL.tornado = { lifetime = 3.5, build = function(scope, cf)
	local dust = rgb(206, 220, 235)
	local core = rgb(140, 176, 210)

	V.play(scope, cf, { id = S.SWISH, volume = 0.5, speed = 0.9, stopAfter = 1.8, fadeOut = 0.7 })
	V.disc(scope, cf, { color = dust, endRadius = 3.6, duration = 0.4, thin = true, startTransparency = 0.45 })

	scope:after(0.08, function()
		V.shake(0.14, 1.2, 11)
		-- Three stacked orbits at different radii and speeds make a funnel.
		for tier = 1, 3 do
			V.orbit(scope, cf * CFrame.new(0, tier * 1.6, 0), {
				count = 5, radius = 2.6 - tier * 0.5, speed = 6 + tier * 2,
				color = tier == 2 and core or dust,
				size = Vector3.new(0.3, 0.3, 0.3), shape = Enum.PartType.Block,
				material = Enum.Material.SmoothPlastic,
				height = 0, climb = 2.4, shrink = 0.55, duration = 1.6,
			})
		end
	end)
	scope:after(0.3, function()
		V.motes(scope, cf, { color = dust, count = 26, size = NumberSequence.new(0.3, 1.1),
			speed = NumberRange.new(2, 5), lifetime = NumberRange.new(0.8, 1.6),
			acceleration = Vector3.new(0, 4, 0), drag = 2, lightEmission = 0.2,
			texture = "rbxasset://textures/particles/smoke_main.dds" })
	end)
end }

-- Pure rhythm: three shockwaves, each faster, thinner and wider than the last.
-- No particles anywhere, which makes it the cleanest silhouette in the set.
GOAL.wave = { lifetime = 2.5, build = function(scope, cf)
	local tones = { rgb(94, 222, 158), rgb(62, 168, 245), rgb(198, 134, 245) }
	for index = 1, 3 do
		scope:after((index - 1) * 0.13, function()
			V.play(scope, cf, { id = S.BASS_DROP, volume = 0.4,
				speed = 1.1 + index * 0.28, stopAfter = 0.5, fadeOut = 0.2 })
			V.disc(scope, cf * CFrame.new(0, index * 0.25, 0), {
				color = tones[index], endRadius = 4 + index * 2,
				duration = 0.4 + index * 0.1, thickness = 0.18 - index * 0.04,
				thin = true, startTransparency = 0.15,
			})
			V.ring(scope, cf * CFrame.new(0, index * 0.25, 0), {
				color = tones[index], count = 8 + index * 4,
				endRadius = 4 + index * 2, duration = 0.4 + index * 0.1,
				size = Vector3.new(0.1, 0.1, 0.5),
			})
			V.shake(0.09, 0.16)
		end)
	end
	V.flash(scope, cf, { color = tones[1], brightness = 6, range = 18, duration = 0.25 })
end }

-- Splits white into colour: one bright core, then beams fanning out in a
-- spectrum. The only effect where the colours are ordered rather than random.
GOAL.prism = { lifetime = 3, build = function(scope, cf)
	local spectrum = {
		rgb(255, 92, 92), rgb(255, 168, 60), rgb(255, 226, 92), rgb(94, 222, 158),
		rgb(62, 168, 245), rgb(126, 116, 245), rgb(198, 116, 235),
	}
	local centre = cf * CFrame.new(0, 1.2, 0)

	V.play(scope, cf, { id = S.SWORD_SCRAPE, volume = 0.4, speed = 1.5, stopAfter = 0.6, fadeOut = 0.25 })
	V.sphere(scope, centre, { color = WHITE, material = Enum.Material.Glass,
		startRadius = 1.4, endRadius = 0.5, duration = 0.22,
		startTransparency = 0.5, endTransparency = 0.1,
		style = Enum.EasingStyle.Quad, direction = Enum.EasingDirection.In })

	scope:after(0.24, function()
		V.play(scope, cf, { id = S.GLASS, volume = 0.5, speed = 1.3, stopAfter = 0.8, fadeOut = 0.3 })
		V.flash(scope, centre, { color = WHITE, brightness = 12, range = 22, duration = 0.2 })
		V.shake(0.15, 0.24)
		for index, color in ipairs(spectrum) do
			local angle = (index / #spectrum) * math.pi * 2
			local target = centre.Position + Vector3.new(math.cos(angle) * 6, 1.2, math.sin(angle) * 6)
			V.bolt(scope, centre.Position, target, {
				segments = 1, jitter = 0, color = color, width = 0.3, duration = 0.55,
			})
		end
	end)
	scope:after(0.45, function()
		V.shards(scope, centre, {
			count = 14, colors = spectrum, material = Enum.Material.Glass,
			size = Vector3.new(0.16, 0.4, 0.16), startTransparency = 0.2,
			spread = 4, lift = 2, fall = 3, riseTime = 0.35, fallTime = 1.1,
		})
	end)
end }

-- LEGENDARY ----------------------------------------------------------------

-- Slow, wide, and unhurried. A legendary should be willing to take two and a
-- half seconds; the orbiting stars are the payoff, not the initial hit.
GOAL.galaxy = { lifetime = 4.5, build = function(scope, cf)
	local deep = rgb(78, 60, 168)
	local star = rgb(214, 196, 255)
	local hot = rgb(255, 176, 236)
	local centre = cf * CFrame.new(0, 1.6, 0)

	V.play(scope, cf, { id = S.SYNTH_A, volume = 0.5, speed = 0.9, stopAfter = 2, fadeOut = 0.8 })
	V.flash(scope, centre, { color = hot, brightness = 10, range = 26, duration = 0.4 })
	V.sphere(scope, centre, { color = deep, startRadius = 0.3, endRadius = 2.4,
		duration = 0.5, endTransparency = 0.55 })

	scope:after(0.1, function()
		V.play(scope, cf, { id = S.BOOM_HUGE, volume = 0.5, speed = 1.05, stopAfter = 2.2, fadeOut = 0.9 })
		V.shake(0.24, 0.5)
		V.disc(scope, centre, { color = star, endRadius = 8, duration = 0.8, thin = true,
			startTransparency = 0.4 })
	end)
	scope:after(0.25, function()
		-- Two counter-rotating arms give the spiral read.
		V.orbit(scope, centre, { count = 7, radius = 3.4, speed = 2.2, color = star,
			size = Vector3.new(0.34, 0.34, 0.34), height = 0, duration = 2.6, shrink = 0.3 })
		V.orbit(scope, centre, { count = 5, radius = 2.2, speed = -3.4, color = hot,
			size = Vector3.new(0.26, 0.26, 0.26), height = 0.5, duration = 2.6, shrink = 0.2 })
	end)
	scope:after(0.5, function()
		V.motes(scope, centre, { color = ColorSequence.new(star, deep), count = 40, size = 0.2,
			speed = NumberRange.new(1, 5), lifetime = NumberRange.new(1.5, 3),
			acceleration = Vector3.new(0, 0, 0), drag = 1.2, lightEmission = 1 })
	end)
end }

-- The inversion: it takes before it gives. A full second of the arena being
-- pulled inward, then one frame of white, then the release.
GOAL.blackhole = { lifetime = 4.5, build = function(scope, cf)
	local void = rgb(24, 14, 40)
	local halo = rgb(255, 148, 78)
	local centre = cf * CFrame.new(0, 1.6, 0)

	V.play(scope, cf, { id = S.RISER, volume = 0.5, speed = 0.7, stopAfter = 1.2, fadeOut = 0.3 })
	local core = V.sphere(scope, centre, { color = void, material = Enum.Material.SmoothPlastic,
		startRadius = 0.1, endRadius = 1.5, duration = 0.5, endTransparency = 0 })

	-- Everything falls in.
	for index = 1, 16 do
		scope:after(0.1 + (index % 5) * 0.06, function()
			local angle = index * 0.9
			local radius = 5 + (index % 4)
			local from = centre * CFrame.new(math.cos(angle) * radius, (index % 3) - 1, math.sin(angle) * radius)
			local mote = scope:part()
			if mote then
				mote.Shape = Enum.PartType.Ball
				mote.Color = halo
				mote.Size = Vector3.new(0.26, 0.26, 0.26)
				mote.CFrame = from
				V.tween(mote, 0.7, { CFrame = centre, Size = Vector3.new(0.02, 0.02, 0.02) },
					Enum.EasingStyle.Quart, Enum.EasingDirection.In)
			end
		end)
	end

	scope:after(1.05, function()
		if core then core:Destroy() end
		V.play(scope, cf, { id = S.BOOM_HUGE, volume = 0.75, speed = 1, stopAfter = 2.4, fadeOut = 1 })
		V.flash(scope, centre, { color = WHITE, brightness = 22, range = 40, duration = 0.35 })
		V.shake(0.5, 0.6, 22)
		V.sphere(scope, centre, { color = WHITE, startRadius = 0.2, endRadius = 4.5, duration = 0.3 })
		V.disc(scope, centre, { color = halo, endRadius = 11, duration = 0.7, thin = true })
		V.rays(scope, centre, { count = 14, reach = 9, color = halo, width = 0.7, duration = 0.6 })
	end)
	scope:after(1.5, function()
		V.motes(scope, centre, { color = ColorSequence.new(halo, void), count = 30, size = 0.28,
			speed = NumberRange.new(4, 12), lifetime = NumberRange.new(1.2, 2.4), drag = 2 })
	end)
end }

-- Telegraphed from off-screen: the shell falls for most of a second with a
-- trail before anything hits, so the impact has somewhere to come from.
GOAL.meteor = { lifetime = 4, build = function(scope, cf)
	local rock = rgb(72, 58, 54)
	local molten = rgb(255, 128, 40)
	local start = cf * CFrame.new(-6, 22, -4)

	V.play(scope, cf, { id = S.RISER, volume = 0.45, speed = 1.2, stopAfter = 0.75, fadeOut = 0.2 })

	local head = scope:part()
	if head then
		head.Shape = Enum.PartType.Ball
		head.Color = molten
		head.Size = Vector3.new(1.1, 1.1, 1.1)
		head.CFrame = start
		local a0 = scope:attachment(head, Vector3.new(0, 0.4, 0))
		local a1 = scope:attachment(head, Vector3.new(0, -0.4, 0))
		local trail = Instance.new("Trail")
		trail.Attachment0, trail.Attachment1 = a0, a1
		trail.Color = ColorSequence.new(molten, rock)
		trail.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
		trail.Lifetime = 0.6
		trail.WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 2.2),
			NumberSequenceKeypoint.new(1, 0),
		})
		trail.LightEmission = 0.8
		trail.FaceCamera = true
		trail.Parent = head
		V.tween(head, 0.7, { CFrame = cf }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end

	scope:after(0.7, function()
		if head then head:Destroy() end
		V.play(scope, cf, { id = S.BOOM_HUGE, volume = 0.8, speed = 0.9, stopAfter = 2.5, fadeOut = 1 })
		V.flash(scope, cf, { color = molten, brightness = 18, range = 34, duration = 0.4 })
		V.shake(0.45, 0.55, 16)
		V.disc(scope, cf, { color = molten, endRadius = 9, duration = 0.55, thin = true })
		V.ring(scope, cf, { color = rock, count = 16, endRadius = 5, duration = 0.6, rise = 1.2,
			material = Enum.Material.Slate, size = Vector3.new(0.4, 0.4, 0.7), spin = 1.2 })
		V.shards(scope, cf, {
			count = 26, color = rock, material = Enum.Material.Slate,
			size = Vector3.new(0.36, 0.3, 0.36),
			spread = 7, lift = 5, fall = 6, riseTime = 0.45, fallTime = 1.4,
		})
	end)
	scope:after(1.05, function()
		-- Second, smaller shake as the debris lands.
		V.shake(0.16, 0.4, 9)
		V.motes(scope, cf, { color = ColorSequence.new(rgb(120, 100, 92), rgb(60, 52, 50)),
			count = 24, size = NumberSequence.new(0.8, 2.4),
			speed = NumberRange.new(1, 4), lifetime = NumberRange.new(1.4, 2.6),
			acceleration = Vector3.new(0, 1, 0), drag = 3, lightEmission = 0.1,
			texture = "rbxasset://textures/particles/smoke_main.dds" })
	end)
end }

-- The only effect built on stillness. A pale wave crawls out, everything hangs,
-- then colour snaps back. Nothing else in the set moves this slowly.
GOAL.timefreeze = { lifetime = 4.5, build = function(scope, cf)
	local pale = rgb(206, 226, 240)
	local accent = rgb(120, 200, 220)
	local centre = cf * CFrame.new(0, 1.2, 0)

	V.play(scope, cf, { id = S.GLASS_STRESS, volume = 0.5, speed = 0.75, stopAfter = 1.6, fadeOut = 0.5 })
	V.flash(scope, centre, { color = pale, brightness = 8, range = 24, duration = 0.5 })
	V.disc(scope, cf, { color = pale, endRadius = 9, duration = 1.5, thin = true,
		startTransparency = 0.3, style = Enum.EasingStyle.Sine })

	-- Frozen shards that hang in the air instead of falling.
	scope:after(0.15, function()
		for index = 1, 18 do
			local part = scope:part()
			if not part then break end
			local angle = index * 0.9
			local radius = 1 + (index % 5) * 0.7
			part.Shape = Enum.PartType.Block
			part.Material = Enum.Material.Glass
			part.Color = index % 3 == 0 and accent or pale
			part.Size = Vector3.new(0.12, 0.12, 0.12)
			part.Transparency = 0.3
			part.CFrame = centre * CFrame.new(math.cos(angle) * radius, (index % 4) * 0.5 - 0.5, math.sin(angle) * radius)
				* CFrame.Angles(index * 0.4, index * 0.7, 0)
			V.tween(part, 0.5, { Size = Vector3.new(0.2, 0.55, 0.2) }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			-- Held, then released all at once at 2.1s.
			V.tween(part, 0.6, { Transparency = 1, CFrame = part.CFrame * CFrame.new(0, -2, 0) },
				Enum.EasingStyle.Quad, Enum.EasingDirection.In, 2.1)
		end
	end)
	scope:after(2.05, function()
		-- Time resumes.
		V.play(scope, cf, { id = S.BOOM_DEEP, volume = 0.6, speed = 1.3, stopAfter = 1.2, fadeOut = 0.5 })
		V.play(scope, cf, { id = S.ZAP_TIGHT, volume = 0.4, speed = 0.8, stopAfter = 0.6, fadeOut = 0.2 })
		V.flash(scope, centre, { color = WHITE, brightness = 14, range = 28, duration = 0.25 })
		V.shake(0.3, 0.35)
		V.disc(scope, cf, { color = accent, endRadius = 7, duration = 0.4, thin = true })
	end)
end }

-- A body, not a burst. Segments chase each other in a coil, then the head
-- breathes a cone of embers. The only goal effect with a creature silhouette.
GOAL.dragon = { lifetime = 4.5, build = function(scope, cf)
	local scale = rgb(255, 106, 60)
	local ember = rgb(255, 206, 110)
	local centre = cf * CFrame.new(0, 1.2, 0)

	V.play(scope, cf, { id = S.SYNTH_B, volume = 0.5, speed = 0.85, stopAfter = 1.6, fadeOut = 0.6 })
	V.flash(scope, centre, { color = scale, brightness = 8, range = 20, duration = 0.35 })

	-- Coiling body: each segment trails the one before it around a rising helix.
	scope:after(0.06, function()
		local segments = 10
		for index = 1, segments do
			local part = scope:part()
			if not part then break end
			part.Shape = Enum.PartType.Ball
			part.Color = index == 1 and ember or scale
			part.Size = Vector3.new(1, 1, 1) * (0.62 - index * 0.035)
			part.CFrame = centre

			local lead = (index - 1) * 0.26
			local a0 = scope:attachment(part, Vector3.new(0, 0.2, 0))
			local a1 = scope:attachment(part, Vector3.new(0, -0.2, 0))
			local trail = Instance.new("Trail")
			trail.Attachment0, trail.Attachment1 = a0, a1
			trail.Color = ColorSequence.new(ember, scale)
			trail.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.2),
				NumberSequenceKeypoint.new(1, 1),
			})
			trail.Lifetime = 0.4
			trail.LightEmission = 0.9
			trail.FaceCamera = true
			trail.Parent = part

			local elapsed = 0
			scope:bind(RunService.RenderStepped:Connect(function(dt)
				elapsed += dt
				local t = math.max(elapsed - lead * 0.12, 0)
				local angle = t * 4.5
				local radius = 2.6 - math.min(t, 1.4) * 0.9
				part.CFrame = centre * CFrame.new(
					math.cos(angle) * radius,
					math.min(t, 1.6) * 2.2,
					math.sin(angle) * radius
				)
			end))
			V.tween(part, 0.5, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 1.7)
		end
	end)

	scope:after(1.75, function()
		-- The breath.
		V.play(scope, cf, { id = S.BOOM_DEEP, volume = 0.65, speed = 1.1, stopAfter = 1.6, fadeOut = 0.6 })
		V.shake(0.3, 0.45)
		V.streaks(scope, centre * CFrame.new(0, 3.4, 0), {
			count = 14, color = ember, trailColor = ColorSequence.new(ember, scale),
			reach = 8, rise = -2.4, duration = 0.8, headSize = 0.4, trailLifetime = 0.5,
		})
		V.flash(scope, centre * CFrame.new(0, 3, 0), { color = ember, brightness = 14, range = 28, duration = 0.4 })
	end)
	scope:after(2.2, function()
		V.disc(scope, cf, { color = scale, endRadius = 8, duration = 0.6, thin = true })
	end)
end }

-- The top of the set. Implode, blinding flash, then four layers of expansion
-- staged so the eye reads them in order rather than as one mush.
GOAL.supernova = { lifetime = 5, build = function(scope, cf)
	local core = rgb(255, 252, 224)
	local mid = rgb(255, 172, 92)
	local outer = rgb(120, 152, 255)
	local centre = cf * CFrame.new(0, 1.6, 0)

	V.play(scope, cf, { id = S.RISER, volume = 0.55, speed = 0.8, stopAfter = 0.85, fadeOut = 0.15 })
	V.sphere(scope, centre, { color = core, startRadius = 3, endRadius = 0.4, duration = 0.6,
		startTransparency = 0.8, endTransparency = 0,
		style = Enum.EasingStyle.Quart, direction = Enum.EasingDirection.In })
	V.ring(scope, centre, { color = outer, count = 18, startRadius = 6, endRadius = 0.5,
		duration = 0.6, size = Vector3.new(0.14, 0.14, 0.9),
		style = Enum.EasingStyle.Quart })

	scope:after(0.62, function()
		V.play(scope, cf, { id = S.BOOM_HUGE, volume = 0.85, speed = 0.85, stopAfter = 3, fadeOut = 1.2 })
		V.play(scope, cf, { id = S.ZAP_LONG, volume = 0.4, speed = 0.7, stopAfter = 1.2, fadeOut = 0.5 })
		V.flash(scope, centre, { color = WHITE, brightness = 26, range = 46, duration = 0.5 })
		V.shake(0.6, 0.75, 20)
		V.sphere(scope, centre, { color = core, startRadius = 0.3, endRadius = 5, duration = 0.35 })
	end)
	-- Layer 2: spokes.
	scope:after(0.7, function()
		V.rays(scope, centre, { count = 16, reach = 12, color = core, width = 0.9, duration = 0.7 })
	end)
	-- Layer 3: the wide slow wave.
	scope:after(0.8, function()
		V.disc(scope, centre, { color = mid, endRadius = 14, duration = 1, thin = true, startTransparency = 0.25 })
		V.disc(scope, cf, { color = outer, endRadius = 10, duration = 0.8, thin = true, startTransparency = 0.4 })
	end)
	-- Layer 4: matter thrown clear.
	scope:after(0.9, function()
		V.streaks(scope, centre, { count = 16, color = core, trailColor = ColorSequence.new(core, outer),
			reach = 11, rise = 6, duration = 1.1, headSize = 0.36, trailLifetime = 0.55 })
	end)
	scope:after(1.4, function()
		V.orbit(scope, centre, { count = 8, radius = 4.5, speed = 1.6, color = mid,
			size = Vector3.new(0.3, 0.3, 0.3), height = 0.5, duration = 2.4, shrink = 0.5 })
		V.motes(scope, centre, { color = ColorSequence.new(core, outer), count = 44, size = 0.24,
			speed = NumberRange.new(2, 9), lifetime = NumberRange.new(1.5, 3),
			drag = 1.5, lightEmission = 1, acceleration = Vector3.new(0, -1, 0) })
	end)
end }

-- ==========================================================================
-- VICTORY EFFECTS
-- ==========================================================================
-- These play over the whole table at match end and get a longer leash than a
-- goal: three to five seconds, built to be watched rather than felt.

-- COMMON -------------------------------------------------------------------

-- Free default. A clean arena flourish that says "match over" without
-- pretending to be a legendary.
WIN.default = { lifetime = 4, build = function(scope, cf)
	local gold = rgb(255, 206, 96)
	V.play(scope, cf, { id = S.STING_FUNK, volume = 0.6, spatial = false, stopAfter = 3.4, fadeOut = 0.8 })
	V.play(scope, cf, { id = S.CROWD_APPLAUSE, volume = 0.35, stopAfter = 3, fadeOut = 1, delay = 0.15 })
	V.flash(scope, cf, { color = gold, brightness = 10, range = 30, duration = 0.5 })
	V.pillar(scope, cf, { color = gold, height = 14, radius = 2, endRadius = 3.4,
		grow = true, duration = 1.1, startTransparency = 0.45 })

	scope:after(0.1, function()
		V.disc(scope, cf, { color = WHITE, endRadius = 9, duration = 0.7, thin = true })
	end)
	scope:after(0.35, function()
		V.disc(scope, cf, { color = gold, endRadius = 12, duration = 0.9, thin = true, startTransparency = 0.4 })
		V.ring(scope, cf, { color = gold, count = 16, endRadius = 7, duration = 0.9,
			size = Vector3.new(0.16, 0.16, 0.9), rise = 1.5 })
	end)
	scope:after(0.8, function()
		V.motes(scope, cf * CFrame.new(0, 2, 0), { color = gold, count = 30, size = 0.3,
			speed = NumberRange.new(2, 6), lifetime = NumberRange.new(1.4, 2.6),
			acceleration = Vector3.new(0, -1.5, 0), drag = 1.5 })
	end)
end }

-- Falls from above for two and a half seconds. The identity is duration and
-- density, not a bang.
WIN.confettirain = { lifetime = 5, build = function(scope, cf)
	local colors = { rgb(255, 107, 107), rgb(255, 201, 60), rgb(94, 222, 158), rgb(62, 168, 245), rgb(198, 134, 245) }
	V.play(scope, cf, { id = S.STING_FUNK2, volume = 0.55, spatial = false, stopAfter = 3.6, fadeOut = 0.9 })
	V.play(scope, cf, { id = S.CROWD_SURGE, volume = 0.4, stopAfter = 3, fadeOut = 1 })

	for wave = 0, 6 do
		scope:after(wave * 0.32, function()
			for index = 1, 8 do
				local part = scope:part()
				if not part then break end
				local drop = cf * CFrame.new(
					(index - 4.5) * 1.3 + (wave % 2) * 0.6,
					13,
					(wave - 3) * 1.4
				)
				part.Shape = Enum.PartType.Block
				part.Material = Enum.Material.SmoothPlastic
				part.Color = colors[((index + wave) % #colors) + 1]
				part.Size = Vector3.new(0.32, 0.05, 0.2)
				part.CFrame = drop
				-- Slow flutter, not a straight drop.
				V.tween(part, 2.2, {
					CFrame = drop * CFrame.new((index % 3) - 1, -13, (wave % 3) - 1)
						* CFrame.Angles(9, 6, 4),
					Transparency = 1,
				}, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
			end
		end)
	end
end }

-- Warm and quiet: no debris at all, just a breathing light and rising motes
-- under a real ovation.
WIN.applause = { lifetime = 5, build = function(scope, cf)
	local warm = rgb(255, 224, 168)
	V.play(scope, cf, { id = S.CROWD_OVATION, volume = 0.6, stopAfter = 4.2, fadeOut = 1.2 })
	V.play(scope, cf, { id = S.STING_CORP, volume = 0.35, spatial = false, stopAfter = 3.8, fadeOut = 1 })

	-- Three slow light swells.
	for pulse = 0, 2 do
		scope:after(pulse * 1.1, function()
			V.flash(scope, cf * CFrame.new(0, 3, 0), { color = warm, brightness = 7, range = 32, duration = 0.9 })
			V.disc(scope, cf, { color = warm, endRadius = 8 + pulse * 2, duration = 1.1,
				thin = true, startTransparency = 0.55, style = Enum.EasingStyle.Sine })
		end)
	end
	scope:after(0.3, function()
		V.motes(scope, cf, { color = warm, count = 40, size = 0.26,
			speed = NumberRange.new(1.5, 4), lifetime = NumberRange.new(2, 3.4),
			acceleration = Vector3.new(0, 1.5, 0), drag = 1, spreadAngle = Vector2.new(35, 35) })
	end)
end }

-- Four flares fired in sequence around the rim. Reads as a countdown, so it
-- has a rhythm the other commons don't.
WIN.flares = { lifetime = 4.5, build = function(scope, cf)
	local tints = { rgb(255, 96, 96), rgb(255, 201, 60), rgb(94, 222, 158), rgb(62, 168, 245) }
	V.play(scope, cf, { id = S.STING_ROOF, volume = 0.5, spatial = false, stopAfter = 2, fadeOut = 0.5 })

	for index = 1, 4 do
		scope:after(index * 0.28, function()
			local angle = (index / 4) * math.pi * 2 + 0.7
			local base = cf * CFrame.new(math.cos(angle) * 3, 0, math.sin(angle) * 3)
			local tint = tints[index]

			V.play(scope, base, { id = S.STATIC_SHORT, volume = 0.4, speed = 1.5 + index * 0.1,
				stopAfter = 0.4, fadeOut = 0.15 })
			V.streaks(scope, base, { count = 1, color = tint, reach = 0.4, rise = 11,
				duration = 0.55, headSize = 0.42, trailLifetime = 0.5 })

			scope:after(0.55, function()
				local burst = base * CFrame.new(0, 11, 0)
				V.play(scope, burst, { id = S.WOOD_CRACK, volume = 0.35, speed = 1.7, stopAfter = 0.4, fadeOut = 0.2 })
				V.flash(scope, burst, { color = tint, brightness = 8, range = 20, duration = 0.35 })
				V.ring(scope, burst, { color = tint, count = 12, endRadius = 3, duration = 0.6,
					size = Vector3.new(0.14, 0.14, 0.5) })
			end)
		end)
	end
end }

-- Retro scoreboard energy: blocky columns snapping up one at a time, no
-- easing curves anywhere softer than Back.
WIN.pixelwin = { lifetime = 4.5, build = function(scope, cf)
	local colors = { rgb(255, 92, 92), rgb(255, 201, 60), rgb(94, 222, 158), rgb(62, 168, 245), rgb(198, 134, 245) }
	V.play(scope, cf, { id = S.STING_MECH, volume = 0.5, spatial = false, stopAfter = 3.2, fadeOut = 0.7 })

	for index = 1, 9 do
		scope:after(index * 0.11, function()
			local part = scope:part()
			if not part then return end
			local x = (index - 5) * 0.9
			local height = 3 + ((index * 7) % 5) * 1.6
			part.Shape = Enum.PartType.Block
			part.Material = Enum.Material.SmoothPlastic
			part.Color = colors[(index % #colors) + 1]
			part.Size = Vector3.new(0.7, 0.3, 0.7)
			part.CFrame = cf * CFrame.new(x, 0.2, 0)
			V.play(scope, cf, { id = S.STATIC_SHORT, volume = 0.22,
				speed = 1.4 + index * 0.12, stopAfter = 0.2, fadeOut = 0.08 })
			V.tween(part, 0.22, {
				Size = Vector3.new(0.7, height, 0.7),
				CFrame = cf * CFrame.new(x, height / 2, 0),
			}, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			V.tween(part, 0.5, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 1.6)
		end)
	end
	scope:after(1.3, function()
		V.disc(scope, cf, { color = colors[4], endRadius = 8, duration = 0.5, thin = true })
	end)
end }

-- Soft and floral. Pastel glass spheres open upward in tiers; nothing here is
-- allowed to be sharp.
WIN.bloom = { lifetime = 4.5, build = function(scope, cf)
	local petals = { rgb(255, 178, 208), rgb(255, 226, 168), rgb(178, 226, 255), rgb(198, 246, 214) }
	V.play(scope, cf, { id = S.STING_SPARKLE, volume = 0.5, spatial = false, stopAfter = 3.8, fadeOut = 1.2 })

	for tier = 1, 3 do
		scope:after(tier * 0.3, function()
			local count = 4 + tier * 2
			for index = 1, count do
				local angle = (index / count) * math.pi * 2 + tier * 0.4
				local radius = tier * 1.5
				local spot = cf * CFrame.new(math.cos(angle) * radius, tier * 1.1, math.sin(angle) * radius)
				V.sphere(scope, spot, {
					color = petals[((index + tier) % #petals) + 1],
					material = Enum.Material.Glass,
					startRadius = 0.08, endRadius = 0.75, duration = 1.2,
					startTransparency = 0.25, endTransparency = 1,
					style = Enum.EasingStyle.Back,
				})
			end
		end)
	end
	scope:after(0.5, function()
		V.motes(scope, cf, { color = petals[1], count = 32, size = 0.22,
			speed = NumberRange.new(1, 3.5), lifetime = NumberRange.new(1.8, 3),
			acceleration = Vector3.new(0, 1.2, 0), drag = 1.5 })
	end)
end }

-- RARE ---------------------------------------------------------------------

-- Five shells over three seconds at staggered heights and colours, each with
-- a real launch-then-burst arc rather than a burst in place.
WIN.fireworks = { lifetime = 6, build = function(scope, cf)
	local tints = { rgb(255, 96, 120), rgb(255, 206, 96), rgb(120, 226, 255), rgb(180, 140, 255), rgb(120, 240, 176) }
	V.play(scope, cf, { id = S.CROWD_PYRO, volume = 0.5, stopAfter = 4.5, fadeOut = 1.4 })

	for index = 1, 5 do
		scope:after((index - 1) * 0.55, function()
			local angle = index * 1.7
			local spread = 2.6 + (index % 3)
			local base = cf * CFrame.new(math.cos(angle) * spread, 0, math.sin(angle) * spread)
			local peak = 9 + (index % 3) * 3
			local tint = tints[index]

			V.play(scope, base, { id = S.SWISH, volume = 0.3, speed = 1.6, stopAfter = 0.5, fadeOut = 0.2 })
			V.streaks(scope, base, { count = 1, color = tint, reach = 0.5, rise = peak,
				duration = 0.6, headSize = 0.34, trailLifetime = 0.55 })

			scope:after(0.62, function()
				local burst = base * CFrame.new(0, peak, 0)
				V.play(scope, burst, { id = S.BOOM_DEEP, volume = 0.45, speed = 1.6,
					stopAfter = 0.9, fadeOut = 0.4 })
				V.flash(scope, burst, { color = tint, brightness = 12, range = 26, duration = 0.4 })
				V.streaks(scope, burst, { count = 14, color = tint, reach = 4.5, rise = 0,
					duration = 0.9, headSize = 0.24, trailLifetime = 0.45 })
				V.motes(scope, burst, { color = tint, count = 22, size = 0.2,
					speed = NumberRange.new(5, 12), lifetime = NumberRange.new(0.8, 1.6),
					acceleration = Vector3.new(0, -8, 0), drag = 2 })
			end)
		end)
	end
end }

-- An actual object, assembled from primitives, that rises and holds. The only
-- win effect with a readable silhouette you could screenshot.
WIN.trophy = { lifetime = 5.5, build = function(scope, cf)
	local gold = rgb(255, 198, 74)
	local shine = rgb(255, 240, 190)
	local top = cf * CFrame.new(0, 4.2, 0)

	V.play(scope, cf, { id = S.STING_EMERGE, volume = 0.55, spatial = false, stopAfter = 4.2, fadeOut = 1 })
	V.pillar(scope, cf, { color = shine, height = 12, radius = 1.4, grow = true,
		duration = 0.9, startTransparency = 0.6 })

	scope:after(0.35, function()
		local pieces = {}
		local function piece(shape, size, offset)
			local part = scope:part()
			if not part then return end
			part.Shape = shape
			part.Material = Enum.Material.Metal
			part.Color = gold
			part.Size = size
			part.CFrame = cf * CFrame.new(0, 0.2, 0) * offset
			table.insert(pieces, { part = part, offset = offset })
		end

		-- cup, stem, base, two handles
		piece(Enum.PartType.Ball, Vector3.new(1.8, 1.5, 1.8), CFrame.new(0, 1.5, 0))
		piece(Enum.PartType.Cylinder, Vector3.new(1, 0.35, 0.35), CFrame.new(0, 0.6, 0) * CFrame.Angles(0, 0, math.pi / 2))
		piece(Enum.PartType.Cylinder, Vector3.new(0.3, 1.5, 1.5), CFrame.new(0, 0.15, 0) * CFrame.Angles(0, 0, math.pi / 2))
		piece(Enum.PartType.Block, Vector3.new(0.16, 0.9, 0.16), CFrame.new(1, 1.6, 0))
		piece(Enum.PartType.Block, Vector3.new(0.16, 0.9, 0.16), CFrame.new(-1, 1.6, 0))

		-- Rises, spins once, then holds before fading.
		for _, entry in ipairs(pieces) do
			V.tween(entry.part, 1, { CFrame = top * entry.offset },
				Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			V.tween(entry.part, 1.4, { CFrame = top * CFrame.Angles(0, math.pi * 1.6, 0) * entry.offset },
				Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 1)
			V.tween(entry.part, 0.8, { Transparency = 1 },
				Enum.EasingStyle.Quad, Enum.EasingDirection.In, 3.4)
		end

		V.play(scope, cf, { id = S.CROWD_OVATION, volume = 0.45, stopAfter = 3.4, fadeOut = 1.2 })
	end)
	scope:after(1.3, function()
		V.flash(scope, top, { color = shine, brightness = 14, range = 30, duration = 0.6 })
		V.rays(scope, top, { count = 12, reach = 7, color = shine, width = 0.5, duration = 0.9, tilt = 0.25 })
		V.motes(scope, top, { color = gold, count = 26, size = 0.2,
			speed = NumberRange.new(1, 4), lifetime = NumberRange.new(1.5, 2.8),
			acceleration = Vector3.new(0, -0.8, 0), drag = 1.5 })
	end)
end }

-- Theatre lighting: four wide cones sweep in from the rim and converge, then
-- the crowd comes up under them.
WIN.spotlight = { lifetime = 5, build = function(scope, cf)
	local beam = rgb(255, 248, 220)
	V.play(scope, cf, { id = S.STING_HEADLINE, volume = 0.5, spatial = false, stopAfter = 3.8, fadeOut = 1 })

	for index = 1, 4 do
		local angle = (index / 4) * math.pi * 2 + 0.5
		local part = scope:part()
		if part then
			part.Shape = Enum.PartType.Cylinder
			part.Color = beam
			part.Size = Vector3.new(16, 2.4, 2.4)
			part.Transparency = 0.72
			local from = cf * CFrame.new(math.cos(angle) * 9, 8, math.sin(angle) * 9)
			part.CFrame = CFrame.lookAt(from.Position, cf.Position) * CFrame.new(0, 0, -8) * CFrame.Angles(0, math.pi / 2, 0)
			-- Sweeps in to sit vertically over the table.
			V.tween(part, 1.4, {
				CFrame = cf * CFrame.new(0, 8, 0) * CFrame.Angles(0, 0, math.pi / 2),
				Size = Vector3.new(16, 1.2, 1.2),
			}, Enum.EasingStyle.Quint, Enum.EasingDirection.InOut)
			V.tween(part, 1.2, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 2.6)
		end
	end

	scope:after(1.45, function()
		V.play(scope, cf, { id = S.CROWD_APPLAUSE, volume = 0.55, stopAfter = 3, fadeOut = 1.2 })
		V.flash(scope, cf * CFrame.new(0, 2, 0), { color = beam, brightness = 16, range = 34, duration = 0.7 })
		V.disc(scope, cf, { color = beam, endRadius = 10, duration = 0.8, thin = true })
	end)
end }

-- Assembles rather than bursts: eight points fly in from outside, lock into a
-- ring, then settle down onto the table like a crown being placed.
WIN.crown = { lifetime = 5, build = function(scope, cf)
	local gold = rgb(255, 202, 84)
	local jewel = rgb(120, 200, 255)
	local centre = cf * CFrame.new(0, 5, 0)
	local points = 8

	V.play(scope, cf, { id = S.STING_DIVINE, volume = 0.5, spatial = false, stopAfter = 4, fadeOut = 1.2 })
	V.play(scope, cf, { id = S.SWORD_SWISH, volume = 0.3, speed = 1.3, stopAfter = 1, fadeOut = 0.4 })

	local built = {}
	for index = 0, points - 1 do
		local angle = (index / points) * math.pi * 2
		local seat = CFrame.new(math.cos(angle) * 1.9, 0, math.sin(angle) * 1.9) * CFrame.Angles(0, -angle, 0)
		local part = scope:part()
		if part then
			part.Shape = Enum.PartType.Block
			part.Material = Enum.Material.Metal
			part.Color = index % 2 == 0 and gold or jewel
			part.Size = Vector3.new(0.3, index % 2 == 0 and 1.5 or 1, 0.3)
			part.CFrame = centre * CFrame.new(math.cos(angle) * 12, 4, math.sin(angle) * 12)
			V.tween(part, 0.6 + index * 0.04, { CFrame = centre * seat },
				Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
			table.insert(built, { part = part, seat = seat })
		end
	end

	local band = scope:part()
	if band then
		band.Shape = Enum.PartType.Cylinder
		band.Material = Enum.Material.Metal
		band.Color = gold
		band.Size = Vector3.new(0.5, 4.2, 4.2)
		band.Transparency = 1
		band.CFrame = centre * CFrame.new(0, -0.75, 0) * CFrame.Angles(0, 0, math.pi / 2)
		V.tween(band, 0.4, { Transparency = 0.1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0.9)
	end

	scope:after(1.3, function()
		V.play(scope, cf, { id = S.BOOM_DEEP, volume = 0.4, speed = 1.5, stopAfter = 1, fadeOut = 0.4 })
		V.flash(scope, centre, { color = gold, brightness = 14, range = 30, duration = 0.6 })
		V.rays(scope, centre, { count = 10, reach = 8, color = gold, width = 0.45, duration = 1 })
		-- Settles down onto the table.
		for _, entry in ipairs(built) do
			V.tween(entry.part, 0.9, { CFrame = cf * CFrame.new(0, 2.4, 0) * entry.seat },
				Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
			V.tween(entry.part, 0.7, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 2.6)
		end
		if band then
			V.tween(band, 0.9, { CFrame = cf * CFrame.new(0, 1.65, 0) * CFrame.Angles(0, 0, math.pi / 2) },
				Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
			V.tween(band, 0.7, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 2.6)
		end
	end)
end }

-- Six strikes around the rim on a tightening beat, then one on the centre.
-- Rhythm is the whole design.
WIN.stormwin = { lifetime = 5, build = function(scope, cf)
	local electric = rgb(168, 226, 255)
	V.play(scope, cf, { id = S.STING_MECH, volume = 0.4, spatial = false, stopAfter = 3.6, fadeOut = 1 })

	local beats = { 0.1, 0.42, 0.68, 0.88, 1.02, 1.12 }
	for index, at in ipairs(beats) do
		scope:after(at, function()
			local angle = index * 2.1
			local ground = cf * CFrame.new(math.cos(angle) * 3.2, 0, math.sin(angle) * 3.2)
			V.play(scope, ground, { id = S.ZAP_TIGHT, volume = 0.4,
				speed = 0.9 + index * 0.08, stopAfter = 0.5, fadeOut = 0.2 })
			V.bolt(scope, ground.Position + Vector3.new(0, 14, 0), ground.Position,
				{ segments = 8, jitter = 0.6, color = electric, width = 0.3, duration = 0.2 })
			V.flash(scope, ground, { color = electric, brightness = 8, range = 18, duration = 0.25 })
			V.disc(scope, ground, { color = electric, endRadius = 2.6, duration = 0.35, thin = true })
			V.shake(0.12, 0.18)
		end)
	end

	scope:after(1.35, function()
		V.play(scope, cf, { id = S.BOOM_HUGE, volume = 0.7, speed = 1, stopAfter = 2.4, fadeOut = 1 })
		V.play(scope, cf, { id = S.ZAP_LONG, volume = 0.45, speed = 0.85, stopAfter = 1.4, fadeOut = 0.5 })
		for fork = 1, 3 do
			V.bolt(scope, cf.Position + Vector3.new(fork - 2, 18, 0), cf.Position,
				{ segments = 11, jitter = 0.9, color = WHITE, width = 0.5, duration = 0.35 })
		end
		V.flash(scope, cf, { color = WHITE, brightness = 22, range = 40, duration = 0.45 })
		V.disc(scope, cf, { color = electric, endRadius = 12, duration = 0.7, thin = true })
		V.shake(0.45, 0.55, 20)
	end)
end }

-- Fast, sharp, and over quickly: crossing slashes that resolve into a star.
-- The one rare that does not linger.
WIN.bladewin = { lifetime = 4, build = function(scope, cf)
	local steel = rgb(226, 244, 255)
	local edge = rgb(96, 190, 255)
	local centre = cf * CFrame.new(0, 2.6, 0)

	V.play(scope, cf, { id = S.STING_HEADLINE, volume = 0.45, spatial = false, stopAfter = 3, fadeOut = 0.8 })

	for index = 1, 6 do
		scope:after(index * 0.11, function()
			local angle = index * (math.pi / 6) + 0.3
			local reach = 7
			local from = centre.Position + Vector3.new(math.cos(angle) * -reach, 0, math.sin(angle) * -reach)
			local to = centre.Position + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
			V.play(scope, cf, { id = S.SWORD_SWISH, volume = 0.28,
				speed = 1.5 + index * 0.1, stopAfter = 0.35, fadeOut = 0.15 })
			V.bolt(scope, from, to, { segments = 1, jitter = 0, color = steel, width = 0.42, duration = 0.4 })
		end)
	end

	scope:after(0.85, function()
		V.play(scope, cf, { id = S.GLASS, volume = 0.5, speed = 1.2, stopAfter = 0.9, fadeOut = 0.4 })
		V.flash(scope, centre, { color = steel, brightness = 16, range = 30, duration = 0.35 })
		V.rays(scope, centre, { count = 12, reach = 8, color = edge, width = 0.5, duration = 0.55 })
		V.shake(0.28, 0.3)
		V.shards(scope, centre, { count = 18, color = steel, material = Enum.Material.Glass,
			size = Vector3.new(0.12, 0.5, 0.12), startTransparency = 0.2,
			spread = 6, lift = 2, fall = 4, riseTime = 0.3, fallTime = 1.1 })
	end)
end }

-- Slow drifting curtains of colour. No impact beat at all, which makes it the
-- calmest thing in the shop and a deliberate counterweight to the loud rares.
WIN.aurora = { lifetime = 6, build = function(scope, cf)
	local bands = { rgb(120, 255, 198), rgb(120, 200, 255), rgb(186, 140, 255) }
	V.play(scope, cf, { id = S.STING_SPARKLE, volume = 0.45, spatial = false, stopAfter = 5, fadeOut = 1.5 })
	V.play(scope, cf, { id = S.RISER, volume = 0.25, speed = 0.6, stopAfter = 3, fadeOut = 1.2 })

	for index = 1, 9 do
		scope:after(index * 0.09, function()
			local part = scope:part()
			if not part then return end
			local x = (index - 5) * 1.15
			part.Shape = Enum.PartType.Block
			part.Color = bands[(index % #bands) + 1]
			part.Size = Vector3.new(0.9, 0.4, 0.12)
			part.Transparency = 0.45
			part.CFrame = cf * CFrame.new(x, 1, 0)
			-- Grows into a tall sheet and drifts sideways.
			V.tween(part, 1.6, {
				Size = Vector3.new(0.9, 9 + (index % 3) * 2, 0.12),
				CFrame = cf * CFrame.new(x, 5.5, 0),
				Transparency = 0.62,
			}, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
			V.tween(part, 2.6, {
				CFrame = cf * CFrame.new(x + math.sin(index) * 1.6, 6.5, math.cos(index) * 1.2)
					* CFrame.Angles(0, math.sin(index) * 0.4, 0),
				Transparency = 1,
			}, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 1.7)
		end)
	end
	scope:after(1, function()
		V.motes(scope, cf * CFrame.new(0, 4, 0), { color = bands[2], count = 30, size = 0.16,
			speed = NumberRange.new(0.5, 2), lifetime = NumberRange.new(2.5, 4),
			acceleration = Vector3.new(0, 0.4, 0), drag = 0.8, lightEmission = 1 })
	end)
end }

-- Erupts once, hard, then rains for two seconds. Vertical throw plus a long
-- fall is the identity.
WIN.geyser = { lifetime = 5, build = function(scope, cf)
	local water = rgb(140, 214, 255)
	local foam = rgb(232, 248, 255)

	V.play(scope, cf, { id = S.RISER, volume = 0.45, speed = 1.1, stopAfter = 1, fadeOut = 0.3 })
	V.play(scope, cf, { id = S.BOOM_DEEP, volume = 0.5, speed = 1.5, stopAfter = 1.4, fadeOut = 0.6, delay = 0.15 })
	V.pillar(scope, cf, { color = water, height = 15, radius = 0.9, endRadius = 1.8,
		grow = true, duration = 0.7, startTransparency = 0.35 })

	scope:after(0.2, function()
		V.shake(0.2, 0.6, 12)
		V.disc(scope, cf, { color = foam, endRadius = 6, duration = 0.6, thin = true })
		V.streaks(scope, cf, { count = 16, color = foam, trailColor = water,
			reach = 3.5, rise = 13, duration = 1, headSize = 0.28, trailLifetime = 0.5 })
	end)
	scope:after(1.1, function()
		-- The fall.
		V.shards(scope, cf * CFrame.new(0, 13, 0), {
			count = 30, color = water, material = Enum.Material.Glass, startTransparency = 0.25,
			size = Vector3.new(0.16, 0.3, 0.16),
			spread = 7, lift = 1, fall = 14, riseTime = 0.25, fallTime = 1.6,
		})
		V.motes(scope, cf * CFrame.new(0, 10, 0), { color = foam, count = 30, size = 0.2,
			speed = NumberRange.new(2, 6), lifetime = NumberRange.new(1.2, 2.2),
			acceleration = Vector3.new(0, -16, 0), drag = 1 })
	end)
end }

-- LEGENDARY ----------------------------------------------------------------

-- Everything rises. A galaxy assembles overhead while star motes climb from
-- the ice; five full seconds and no impact beat until the very end.
WIN.cosmic = { lifetime = 6.5, build = function(scope, cf)
	local deep = rgb(92, 72, 190)
	local star = rgb(220, 206, 255)
	local hot = rgb(255, 176, 236)
	local centre = cf * CFrame.new(0, 7, 0)

	V.play(scope, cf, { id = S.STING_DIVINE, volume = 0.55, spatial = false, stopAfter = 5.5, fadeOut = 1.6 })
	V.play(scope, cf, { id = S.RISER, volume = 0.35, speed = 0.65, stopAfter = 2.4, fadeOut = 1 })

	V.pillar(scope, cf, { color = deep, height = 16, radius = 2.6, endRadius = 4,
		grow = true, duration = 1.5, startTransparency = 0.62 })
	scope:after(0.3, function()
		V.streaks(scope, cf, { count = 14, color = star, trailColor = ColorSequence.new(star, deep),
			reach = 2, rise = 12, duration = 1.4, headSize = 0.26, trailLifetime = 0.8 })
	end)

	scope:after(1.4, function()
		V.flash(scope, centre, { color = hot, brightness = 16, range = 38, duration = 0.8 })
		V.orbit(scope, centre, { count = 9, radius = 4.5, speed = 1.5, color = star,
			size = Vector3.new(0.36, 0.36, 0.36), height = 0, duration = 3.6, shrink = 0.25 })
		V.orbit(scope, centre, { count = 6, radius = 2.8, speed = -2.4, color = hot,
			size = Vector3.new(0.28, 0.28, 0.28), height = 0.8, duration = 3.6, shrink = 0.2 })
		V.disc(scope, centre, { color = deep, endRadius = 11, duration = 1.4, thin = true, startTransparency = 0.5 })
	end)
	scope:after(3.4, function()
		V.play(scope, cf, { id = S.BOOM_HUGE, volume = 0.6, speed = 0.95, stopAfter = 2.4, fadeOut = 1.2 })
		V.flash(scope, centre, { color = WHITE, brightness = 22, range = 44, duration = 0.6 })
		V.rays(scope, centre, { count = 16, reach = 12, color = star, width = 0.7, duration = 0.9 })
		V.shake(0.3, 0.5)
	end)
end }

-- Ember column, then wings sweeping out of it, then ash falling for two
-- seconds. The wings are the reason this one exists.
WIN.phoenix = { lifetime = 6, build = function(scope, cf)
	local ember = rgb(255, 148, 48)
	local hot = rgb(255, 228, 150)
	local centre = cf * CFrame.new(0, 5, 0)

	V.play(scope, cf, { id = S.RISER, volume = 0.5, speed = 0.8, stopAfter = 1.5, fadeOut = 0.4 })
	V.play(scope, cf, { id = S.STING_EMERGE, volume = 0.5, spatial = false, stopAfter = 4.6, fadeOut = 1.2 })
	V.pillar(scope, cf, { color = ember, height = 13, radius = 1.6, endRadius = 2.6,
		grow = true, duration = 1.1, startTransparency = 0.35 })

	scope:after(1.15, function()
		V.play(scope, cf, { id = S.BOOM_HUGE, volume = 0.7, speed = 1, stopAfter = 2.6, fadeOut = 1.1 })
		V.flash(scope, centre, { color = hot, brightness = 20, range = 40, duration = 0.6 })
		V.shake(0.4, 0.5, 15)

		-- Wings: two arcs of feathers sweeping out and up from the core.
		for side = -1, 1, 2 do
			for index = 1, 7 do
				local part = scope:part()
				if not part then break end
				local spread = index / 7
				part.Shape = Enum.PartType.Block
				part.Color = index > 4 and ember or hot
				part.Size = Vector3.new(0.18, 0.18, 1.6)
				part.CFrame = centre
				V.tween(part, 0.7, {
					CFrame = centre
						* CFrame.new(side * spread * 6, math.sin(spread * 2.2) * 3.2, 0)
						* CFrame.Angles(0, side * spread * 1.4, side * 0.5),
					Size = Vector3.new(0.14, 0.14, 2.6),
				}, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
				V.tween(part, 0.9, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0.8)
			end
		end
		V.rays(scope, centre, { count = 10, reach = 7, color = hot, width = 0.5, duration = 0.7 })
	end)
	scope:after(2.1, function()
		-- Ash.
		V.shards(scope, centre * CFrame.new(0, 2, 0), {
			count = 26, colors = { ember, rgb(120, 82, 70), hot },
			material = Enum.Material.SmoothPlastic, size = Vector3.new(0.14, 0.05, 0.14),
			spread = 7, lift = 1.5, fall = 9, riseTime = 0.5, fallTime = 2.2,
		})
		V.motes(scope, centre, { color = ColorSequence.new(ember, rgb(70, 56, 54)),
			count = 24, size = NumberSequence.new(0.4, 1.6),
			speed = NumberRange.new(1, 3), lifetime = NumberRange.new(1.6, 3),
			acceleration = Vector3.new(0, 1.5, 0), drag = 2.5, lightEmission = 0.2,
			texture = "rbxasset://textures/particles/smoke_main.dds" })
	end)
end }

-- The arena cracks. Fracture lines spread across the ice from a single point,
-- hold, then snap shut with a white flash.
WIN.dimension = { lifetime = 6, build = function(scope, cf)
	local rift = rgb(196, 130, 255)
	local glow = rgb(255, 236, 255)

	V.play(scope, cf, { id = S.GLASS_STRESS, volume = 0.55, speed = 0.8, stopAfter = 1.8, fadeOut = 0.5 })
	V.play(scope, cf, { id = S.STING_MECH, volume = 0.45, spatial = false, stopAfter = 4.4, fadeOut = 1.2 })

	-- Fractures crawling outward, each branching from the last.
	for index = 1, 9 do
		scope:after(0.1 + index * 0.08, function()
			local angle = index * 2.4
			local inner = cf.Position + Vector3.new(math.cos(angle) * 0.6, 0.12, math.sin(angle) * 0.6)
			local outer = cf.Position + Vector3.new(math.cos(angle) * 7, 0.12, math.sin(angle) * 7)
			V.bolt(scope, inner, outer, { segments = 5, jitter = 0.8, color = rift,
				width = 0.22, duration = 1.6, hold = 0.9 })
			V.play(scope, cf, { id = S.WOOD_CRACK, volume = 0.22,
				speed = 0.8 + index * 0.07, stopAfter = 0.4, fadeOut = 0.2 })
		end)
	end

	scope:after(1.1, function()
		V.pillar(scope, cf, { color = rift, height = 18, radius = 0.6, endRadius = 2.2,
			grow = true, duration = 1.2, startTransparency = 0.3 })
		V.shake(0.18, 1.2, 9)
	end)
	scope:after(2.4, function()
		-- Snap shut.
		V.play(scope, cf, { id = S.BOOM_HUGE, volume = 0.8, speed = 0.9, stopAfter = 2.6, fadeOut = 1.2 })
		V.flash(scope, cf * CFrame.new(0, 3, 0), { color = glow, brightness = 26, range = 48, duration = 0.5 })
		V.shake(0.55, 0.6, 22)
		V.disc(scope, cf, { color = glow, endRadius = 14, duration = 0.7, thin = true })
		V.ring(scope, cf, { color = rift, count = 20, startRadius = 8, endRadius = 0.4,
			duration = 0.5, size = Vector3.new(0.18, 0.18, 1.2), style = Enum.EasingStyle.Quart })
	end)
end }

-- On theme for a game played for a pot: coins pour down, bounce, and the jazz
-- comes up under them.
WIN.goldrush = { lifetime = 6, build = function(scope, cf)
	local gold = rgb(255, 198, 64)
	local pale = rgb(255, 236, 168)

	V.play(scope, cf, { id = S.STING_JAZZ2, volume = 0.6, spatial = false, stopAfter = 5, fadeOut = 1.4 })
	V.flash(scope, cf * CFrame.new(0, 4, 0), { color = gold, brightness = 12, range = 32, duration = 0.6 })

	for wave = 0, 5 do
		scope:after(wave * 0.28, function()
			V.play(scope, cf, { id = S.STATIC_SHORT, volume = 0.3,
				speed = 1.8 + (wave % 3) * 0.2, stopAfter = 0.3, fadeOut = 0.15 })
			for index = 1, 7 do
				local part = scope:part()
				if not part then break end
				local drop = cf * CFrame.new((index - 4) * 1.1, 12, (wave - 2.5) * 1.1)
				part.Shape = Enum.PartType.Cylinder
				part.Material = Enum.Material.Metal
				part.Color = index % 3 == 0 and pale or gold
				part.Size = Vector3.new(0.09, 0.5, 0.5)
				part.CFrame = drop * CFrame.Angles(0, 0, math.pi / 2)
				-- Falls, then a short bounce so the coins read as solid.
				V.tween(part, 0.55, {
					CFrame = drop * CFrame.new(0, -11.6, 0) * CFrame.Angles(index, 0, math.pi / 2),
				}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
				V.tween(part, 0.28, {
					CFrame = drop * CFrame.new((index % 3) - 1, -10.6, (index % 2) - 0.5)
						* CFrame.Angles(index * 1.5, 0, math.pi / 2),
				}, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0.55)
				V.tween(part, 0.6, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 1.1)
			end
		end)
	end

	scope:after(0.5, function()
		V.disc(scope, cf, { color = gold, endRadius = 9, duration = 0.8, thin = true })
		V.rays(scope, cf * CFrame.new(0, 1, 0), { count = 12, reach = 8, color = pale,
			width = 0.4, duration = 1, tilt = 0.15 })
	end)
end }

-- Three ground strikes with real weight behind them. The heaviest camera work
-- in the set, and nothing decorative at all.
WIN.titan = { lifetime = 5.5, build = function(scope, cf)
	local stone = rgb(122, 112, 104)
	local heat = rgb(255, 148, 66)

	V.play(scope, cf, { id = S.STING_MECH, volume = 0.45, spatial = false, stopAfter = 4.2, fadeOut = 1.2 })

	for step = 1, 3 do
		scope:after((step - 1) * 0.75, function()
			local scale = 0.7 + step * 0.35
			V.play(scope, cf, { id = S.BOOM_HUGE, volume = 0.4 + step * 0.15,
				speed = 1.2 - step * 0.12, stopAfter = 1.6, fadeOut = 0.7 })
			V.shake(0.2 * scale, 0.4, 13)
			V.flash(scope, cf, { color = heat, brightness = 6 * scale, range = 20 + step * 6, duration = 0.35 })
			V.disc(scope, cf, { color = heat, endRadius = 4 * scale, duration = 0.5, thin = true })
			V.ring(scope, cf, { color = stone, count = 10 + step * 3, endRadius = 3.4 * scale,
				duration = 0.55, rise = 0.8 * scale, material = Enum.Material.Slate,
				size = Vector3.new(0.4, 0.4, 0.7), spin = 1.4 })
			V.shards(scope, cf, { count = 10 + step * 4, color = stone, material = Enum.Material.Slate,
				size = Vector3.new(0.34, 0.28, 0.34),
				spread = 4 * scale, lift = 2.5 * scale, fall = 3.5, riseTime = 0.35, fallTime = 1 })
		end)
	end

	scope:after(2.4, function()
		V.play(scope, cf, { id = S.CROWD_PYRO, volume = 0.5, stopAfter = 2.6, fadeOut = 1 })
		V.pillar(scope, cf, { color = heat, height = 16, radius = 2.4, endRadius = 4.4,
			grow = true, duration = 1.1, startTransparency = 0.4 })
		V.shake(0.5, 0.7, 18)
	end)
end }

-- The top of the shop: a five second choreographed sequence that reuses the
-- best beat from every tier below it, staged so nothing overlaps.
WIN.eternal = { lifetime = 7, build = function(scope, cf)
	local gold = rgb(255, 204, 88)
	local white = rgb(255, 250, 232)
	local sky = rgb(126, 200, 255)
	local high = cf * CFrame.new(0, 6.5, 0)

	-- 0.0  anticipation
	V.play(scope, cf, { id = S.RISER, volume = 0.5, speed = 0.7, stopAfter = 1.6, fadeOut = 0.3 })
	V.play(scope, cf, { id = S.STING_DIVINE, volume = 0.6, spatial = false, stopAfter = 6, fadeOut = 1.6 })
	V.ring(scope, cf, { color = sky, count = 20, startRadius = 9, endRadius = 1,
		duration = 1.2, size = Vector3.new(0.14, 0.14, 1), style = Enum.EasingStyle.Quart })

	-- 1.2  the hit
	scope:after(1.2, function()
		V.play(scope, cf, { id = S.BOOM_HUGE, volume = 0.8, speed = 0.9, stopAfter = 3, fadeOut = 1.2 })
		V.flash(scope, cf, { color = white, brightness = 24, range = 46, duration = 0.5 })
		V.shake(0.5, 0.6, 20)
		V.disc(scope, cf, { color = white, endRadius = 13, duration = 0.8, thin = true })
		V.pillar(scope, cf, { color = gold, height = 18, radius = 2.2, endRadius = 3.6,
			grow = true, duration = 1.2, startTransparency = 0.4 })
	end)

	-- 1.6  the crown assembles
	scope:after(1.6, function()
		for index = 0, 9 do
			local angle = (index / 10) * math.pi * 2
			local seat = CFrame.new(math.cos(angle) * 2.2, 0, math.sin(angle) * 2.2) * CFrame.Angles(0, -angle, 0)
			local part = scope:part()
			if not part then break end
			part.Shape = Enum.PartType.Block
			part.Material = Enum.Material.Metal
			part.Color = index % 2 == 0 and gold or white
			part.Size = Vector3.new(0.28, index % 2 == 0 and 1.7 or 1.1, 0.28)
			part.CFrame = high * CFrame.new(math.cos(angle) * 14, 3, math.sin(angle) * 14)
			V.tween(part, 0.7, { CFrame = high * seat }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
			V.tween(part, 2.4, { CFrame = high * CFrame.Angles(0, math.pi * 2, 0) * seat },
				Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, 0.8)
			V.tween(part, 0.8, { Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 3.6)
		end
		V.rays(scope, high, { count = 16, reach = 10, color = gold, width = 0.55, duration = 1.1, tilt = 0.2 })
	end)

	-- 2.4  fireworks over the top
	for index = 1, 4 do
		scope:after(2.4 + index * 0.42, function()
			local angle = index * 1.9
			local burst = cf * CFrame.new(math.cos(angle) * 4.5, 10 + (index % 2) * 3, math.sin(angle) * 4.5)
			V.play(scope, burst, { id = S.BOOM_DEEP, volume = 0.4, speed = 1.7, stopAfter = 0.8, fadeOut = 0.35 })
			V.flash(scope, burst, { color = index % 2 == 0 and gold or sky, brightness = 10, range = 24, duration = 0.35 })
			V.streaks(scope, burst, { count = 12, color = index % 2 == 0 and gold or sky,
				reach = 4, rise = 0, duration = 0.8, headSize = 0.22, trailLifetime = 0.4 })
		end)
	end

	-- 4.2  aftermath
	scope:after(4.2, function()
		V.play(scope, cf, { id = S.CROWD_OVATION, volume = 0.55, stopAfter = 2.2, fadeOut = 1 })
		V.motes(scope, cf * CFrame.new(0, 3, 0), { color = ColorSequence.new(gold, white),
			count = 44, size = 0.24, speed = NumberRange.new(1, 5),
			lifetime = NumberRange.new(2, 3.5), acceleration = Vector3.new(0, -1, 0),
			drag = 1.2, lightEmission = 1 })
	end)
end }

VFXLibrary.GOAL = GOAL
VFXLibrary.WIN = WIN

-- Shop metadata -----------------------------------------------------------
-- The single source of truth for what exists, what it costs and how rare it
-- is. The folders under AirHockeyFXPackage are generated from this table, so
-- adding a cosmetic means adding a recipe above and a row here — never both
-- plus hand-built instances that can drift out of sync.
--
-- `order` is a stable index and must never be reused or reshuffled: the
-- inventory codec packs ownership into a bitmask keyed on it, so changing an
-- order value would silently hand players a different item than they bought.
-- Append new cosmetics with the next free number.
--
-- Pricing ladder is tuned to the live economy: players start on 250, and the
-- wager tables pay out 50 / 250 / 1000 a match. Commons are a couple of
-- Bronze wins, rares are a Silver grind, legendaries are a Gold-table trophy.

VFXLibrary.RARITY_COMMON = "Common"
VFXLibrary.RARITY_RARE = "Rare"
VFXLibrary.RARITY_LEGENDARY = "Legendary"

local COMMON, RARE, LEGENDARY = "Common", "Rare", "Legendary"

VFXLibrary.RARITY_ORDER = { COMMON, RARE, LEGENDARY }
VFXLibrary.RARITY_COLORS = {
	Common    = Color3.fromRGB(126, 142, 168),
	Rare      = Color3.fromRGB(62, 168, 245),
	Legendary = Color3.fromRGB(255, 176, 46),
}

VFXLibrary.META = {
	-- Goal explosions. The visual half of a goal; pairs with a GoalSFX crowd
	-- reaction, and carries its own impact audio inside the recipe.
	GoalVFX = {
		{ order = 1,  id = "flash",      name = "Puck Flash",           rarity = COMMON,    price = 0,
		  defaultOwned = true,
		  desc = "The house effect. One clean burst in your team's colour." },
		{ order = 2,  id = "sparks",     name = "Spark Burst",          rarity = COMMON,    price = 150,
		  desc = "Hot metal skittering low across the ice." },
		{ order = 3,  id = "confetti",   name = "Confetti Cannon",      rarity = COMMON,    price = 200,
		  desc = "Party streamers, fired point blank." },
		{ order = 4,  id = "pixel",      name = "Pixel Burst",          rarity = COMMON,    price = 250,
		  desc = "Sixteen-bit shrapnel. Not a smooth edge anywhere." },
		{ order = 5,  id = "bubbles",    name = "Bubble Pop",           rarity = COMMON,    price = 300,
		  desc = "Ten bubbles drift up and pop on their own beat." },
		{ order = 6,  id = "paint",      name = "Paint Splash",         rarity = COMMON,    price = 350,
		  desc = "Heavy, wet, and impossible to clean up." },

		{ order = 7,  id = "wave",       name = "Energy Wave",          rarity = RARE,      price = 600,
		  desc = "Three shockwaves, each one faster than the last." },
		{ order = 8,  id = "bolt",       name = "Lightning Strike",     rarity = RARE,      price = 700,
		  desc = "Called down from above, then it forks across the ice." },
		{ order = 9,  id = "fire",       name = "Fire Burst",           rarity = RARE,      price = 800,
		  desc = "A column of flame that climbs before it spreads." },
		{ order = 10, id = "frost",      name = "Ice Crystal Shatter",  rarity = RARE,      price = 900,
		  desc = "The crystal forms, stresses, then goes everywhere." },
		{ order = 11, id = "plasma",     name = "Plasma Detonation",    rarity = RARE,      price = 1000,
		  desc = "Pure energy. No debris, no smoke, no mercy." },
		{ order = 12, id = "prism",      name = "Prism Shatter",        rarity = RARE,      price = 1100,
		  desc = "White light broken into seven colours at once." },
		{ order = 13, id = "portal",     name = "Portal Collapse",      rarity = RARE,      price = 1200,
		  desc = "It opens, it waits, then it takes the moment back." },
		{ order = 14, id = "tornado",    name = "Cyclone",              rarity = RARE,      price = 1400,
		  desc = "A funnel that tightens as it climbs." },

		{ order = 15, id = "meteor",     name = "Meteor Impact",        rarity = LEGENDARY, price = 2500,
		  desc = "You see it coming. That is entirely the point." },
		{ order = 16, id = "galaxy",     name = "Galaxy Rift",          rarity = LEGENDARY, price = 3000,
		  desc = "A cosmic explosion tears through the arena." },
		{ order = 17, id = "timefreeze", name = "Time Freeze",          rarity = LEGENDARY, price = 3500,
		  desc = "Everything stops. Then, all at once, it doesn't." },
		{ order = 18, id = "dragon",     name = "Emberwyrm",            rarity = LEGENDARY, price = 4000,
		  desc = "It coils up out of the ice and breathes." },
		{ order = 19, id = "blackhole",  name = "Event Horizon",        rarity = LEGENDARY, price = 5000,
		  desc = "It takes before it gives." },
		{ order = 20, id = "supernova",  name = "Supernova",            rarity = LEGENDARY, price = 7500,
		  desc = "The last thing a goalkeeper ever sees." },
	},

	-- Victory shows. Slot key stays WinSFX for save-data compatibility, but an
	-- entry is now a full audiovisual celebration rather than a lone sound.
	WinSFX = {
		{ order = 1,  id = "default",      name = "Victory Horn",         rarity = COMMON,    price = 0,
		  defaultOwned = true,
		  desc = "Lights up, horn sounds, match over." },
		{ order = 2,  id = "applause",     name = "Crowd Pleaser",        rarity = COMMON,    price = 150,
		  desc = "The house lights swell and the crowd does the rest." },
		{ order = 3,  id = "flares",       name = "Victory Flares",       rarity = COMMON,    price = 200,
		  desc = "Four flares up the rim, one after another." },
		{ order = 4,  id = "confettirain", name = "Confetti Rain",        rarity = COMMON,    price = 250,
		  desc = "Two and a half seconds of falling paper." },
		{ order = 5,  id = "pixelwin",     name = "Pixel Victory",        rarity = COMMON,    price = 300,
		  desc = "Blocks snap up like an old scoreboard." },
		{ order = 6,  id = "bloom",        name = "Bloom Burst",          rarity = COMMON,    price = 350,
		  desc = "Pastel glass opening in tiers." },

		{ order = 7,  id = "bladewin",     name = "Blade Dance",          rarity = RARE,      price = 600,
		  desc = "Six slashes cross and resolve into a star." },
		{ order = 8,  id = "fireworks",    name = "Fireworks Show",       rarity = RARE,      price = 700,
		  desc = "Five shells, staggered, at three different heights." },
		{ order = 9,  id = "geyser",       name = "Geyser",               rarity = RARE,      price = 800,
		  desc = "It erupts once, then it rains for two seconds." },
		{ order = 10, id = "spotlight",    name = "Champion Spotlight",   rarity = RARE,      price = 900,
		  desc = "Four beams sweep in from the rim and find you." },
		{ order = 11, id = "stormwin",     name = "Thunder Ovation",      rarity = RARE,      price = 1000,
		  desc = "Six strikes around the rim, then one down the middle." },
		{ order = 12, id = "aurora",       name = "Aurora Curtain",       rarity = RARE,      price = 1100,
		  desc = "Slow light. The quietest thing in the shop." },
		{ order = 13, id = "crown",        name = "Coronation",           rarity = RARE,      price = 1200,
		  desc = "Eight points fly in, lock together, and settle." },
		{ order = 14, id = "trophy",       name = "Trophy Presentation",  rarity = RARE,      price = 1400,
		  desc = "It rises, it turns once, and it holds." },

		{ order = 15, id = "titan",        name = "Titan's Ovation",      rarity = LEGENDARY, price = 2500,
		  desc = "Three steps. The table feels every one of them." },
		{ order = 16, id = "goldrush",     name = "Gold Rush",            rarity = LEGENDARY, price = 3000,
		  desc = "The whole pot, falling on you, for four seconds." },
		{ order = 17, id = "phoenix",      name = "Phoenix Rising",       rarity = LEGENDARY, price = 3500,
		  desc = "Wings out of the ember column, then falling ash." },
		{ order = 18, id = "dimension",    name = "Dimension Break",      rarity = LEGENDARY, price = 4000,
		  desc = "The arena cracks, then thinks better of it." },
		{ order = 19, id = "cosmic",       name = "Cosmic Ascension",     rarity = LEGENDARY, price = 5000,
		  desc = "A galaxy assembles itself over the table." },
		{ order = 20, id = "eternal",      name = "Eternal Champion",     rarity = LEGENDARY, price = 7500,
		  desc = "Everything, in order, for five straight seconds." },
	},

	-- Goal crowd reactions. Purely audio, layered *over* whatever the goal
	-- explosion is doing, so these are reactions rather than impacts.
	-- soundId values are all licensed Roblox library audio; stopAfter trims
	-- the long source recordings down to a goal-sized moment.
	GoalSFX = {
		{ order = 1, id = "default",  name = "Arena Surge",       rarity = COMMON,    price = 0,
		  defaultOwned = true, soundId = S.CROWD_SURGE, volume = 0.55, stopAfter = 2.2,
		  desc = "The room reacts. Included with every account." },
		{ order = 2, id = "cheer",    name = "Crowd Cheer",       rarity = COMMON,    price = 150,
		  soundId = S.CROWD_APPLAUSE, volume = 0.55, stopAfter = 2.6,
		  desc = "Honest applause from the cheap seats." },
		{ order = 3, id = "bass",     name = "Bass Drop",         rarity = COMMON,    price = 300,
		  soundId = S.BASS_DROP, volume = 0.6, stopAfter = 2.4,
		  desc = "Sub-bass straight through the table." },
		{ order = 4, id = "boo",      name = "Boo Birds",         rarity = RARE,      price = 600,
		  soundId = S.CROWD_BOO, volume = 0.55, stopAfter = 3,
		  desc = "For scoring on someone who deserved it." },
		{ order = 5, id = "ovation",  name = "Standing Ovation",  rarity = RARE,      price = 900,
		  soundId = S.CROWD_OVATION, volume = 0.6, stopAfter = 3.2,
		  desc = "They are on their feet before the puck settles." },
		{ order = 6, id = "arena",    name = "Arena Pyro",        rarity = LEGENDARY, price = 2500,
		  soundId = S.CROWD_PYRO, volume = 0.65, stopAfter = 3.6,
		  desc = "Cheers with the pyrotechnics still going off." },
	},
}

-- Resolves a recipe for a slot, tolerating an unknown id by falling back to
-- the free default rather than playing nothing at all.
function VFXLibrary.getRecipe(slot: string, id: string)
	local bucket = slot == "WinSFX" and WIN or (slot == "GoalVFX" and GOAL or nil)
	if not bucket then
		return nil
	end
	return bucket[id] or bucket[slot == "WinSFX" and "default" or "flash"]
end

-- Runs a recipe. Client-only by contract: these parent parts to workspace and
-- drive the local camera, neither of which the server has any business doing.
function VFXLibrary.play(slot: string, id: string, worldCFrame: CFrame, ctx: { [string]: any }?)
	if not RunService:IsClient() then
		return
	end

	local recipe = VFXLibrary.getRecipe(slot, id)
	if not recipe then
		return
	end

	local scope = V.beginScope(slot .. "_" .. id, recipe.lifetime)
	local ok, err = pcall(recipe.build, scope, level(worldCFrame), ctx or {})
	if not ok then
		-- One bad recipe must not take the match's whole FX pipeline down.
		warn(string.format("[VFXLibrary] %s.%s failed: %s", slot, id, tostring(err)))
		scope:destroy()
	end
end

return VFXLibrary
