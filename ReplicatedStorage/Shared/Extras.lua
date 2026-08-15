-- Extras
-- Definitions for the pass-gated cosmetics that are *not* part of the FX
-- catalog: paddle skins, name-tag titles, and emotes.
--
-- These live outside FXCatalog on purpose. That catalog is a shop with a
-- currency price, a rarity ladder and a bitmask ownership codec keyed on
-- catalog order; these three are flat lists whose only gate is "do you own the
-- pass". Forcing them into the same structure would mean a per-item price that
-- is always zero and an ownership record that duplicates the pass.

local Monetization = require(script.Parent:WaitForChild("Monetization"))

local Extras = {}

-- ── Paddle skins ──────────────────────────────────────────────────────────────
-- Applied by PaddleService to a clone of ReplicatedStorage.Paddles.DefaultPaddle.
-- A skin is a restyle, never new geometry: the paddle's radius feeds the swept
-- collision test in PaddleService, so a skin that changed the silhouette would
-- quietly change how the game plays.

export type PaddleSkin = {
	id: string,
	name: string,
	description: string,
	requiresPass: string?,
	color: Color3,
	material: Enum.Material,
	reflectance: number?,
	-- Colour of the glow cast onto the ice. nil for no light.
	glow: Color3?,
	order: number,
}

local PADDLE_SKINS: { PaddleSkin } = {
	{
		id = "default", order = 1,
		name = "Standard",
		description = "House mallet. Does the job.",
		color = Color3.fromRGB(240, 240, 245),
		material = Enum.Material.SmoothPlastic,
	},
	{
		id = "chrome", order = 2, requiresPass = "PaddlePack",
		name = "Chrome",
		description = "Mirror-polished steel.",
		color = Color3.fromRGB(200, 208, 220),
		material = Enum.Material.Metal,
		reflectance = 0.7,
	},
	{
		id = "neon", order = 3, requiresPass = "PaddlePack",
		name = "Neon",
		description = "Cyan tube light on a stick.",
		color = Color3.fromRGB(80, 240, 255),
		material = Enum.Material.Neon,
		glow = Color3.fromRGB(80, 240, 255),
	},
	{
		id = "magma", order = 4, requiresPass = "PaddlePack",
		name = "Magma",
		description = "Still cooling.",
		color = Color3.fromRGB(255, 110, 40),
		material = Enum.Material.Neon,
		glow = Color3.fromRGB(255, 120, 30),
	},
	{
		id = "void", order = 5, requiresPass = "PaddlePack",
		name = "Void",
		description = "Light goes in. Nothing comes out.",
		color = Color3.fromRGB(18, 14, 30),
		material = Enum.Material.Glass,
		reflectance = 0.15,
		glow = Color3.fromRGB(120, 60, 255),
	},
	{
		id = "gold", order = 6, requiresPass = "PaddlePack",
		name = "Solid Gold",
		description = "Heavier than it looks. It isn't.",
		color = Color3.fromRGB(255, 200, 70),
		material = Enum.Material.Metal,
		reflectance = 0.5,
		glow = Color3.fromRGB(255, 190, 60),
	},
	{
		id = "ice", order = 7, requiresPass = "PaddlePack",
		name = "Glacier",
		description = "Carved from the rink itself.",
		color = Color3.fromRGB(190, 235, 255),
		material = Enum.Material.Glass,
		reflectance = 0.35,
		glow = Color3.fromRGB(150, 220, 255),
	},
}

-- ── Name-tag titles ───────────────────────────────────────────────────────
-- A fixed list rather than free text: anything a player types over their head
-- is a moderation surface, and this is a cosmetic, not a chat feature.

export type Title = {
	id: string,
	text: string,
	color: Color3,
	order: number,
}

local TITLES: { Title } = {
	{ id = "none",      order = 1,  text = "",           color = Color3.fromRGB(255, 255, 255) },
	{ id = "champion",  order = 2,  text = "CHAMPION",   color = Color3.fromRGB(255, 200, 70) },
	{ id = "hustler",   order = 3,  text = "HUSTLER",    color = Color3.fromRGB(94, 222, 158) },
	{ id = "shark",     order = 4,  text = "TABLE SHARK",color = Color3.fromRGB(62, 168, 245) },
	{ id = "rookie",    order = 5,  text = "ROOKIE",     color = Color3.fromRGB(160, 170, 190) },
	{ id = "highroller",order = 6,  text = "HIGH ROLLER",color = Color3.fromRGB(255, 110, 40) },
	{ id = "legend",    order = 7,  text = "LEGEND",     color = Color3.fromRGB(200, 120, 255) },
	{ id = "menace",    order = 8,  text = "MENACE",     color = Color3.fromRGB(255, 107, 107) },
	{ id = "ghost",     order = 9,  text = "GHOST",      color = Color3.fromRGB(220, 235, 255) },
	{ id = "undefeated",order = 10, text = "UNDEFEATED", color = Color3.fromRGB(255, 235, 120) },
}

-- ── Emotes ─────────────────────────────────────────────────────────────────
-- Fixed strings for the same reason as titles. Keyed 1-6 on the number row.

export type Emote = {
	id: string,
	key: number,
	text: string,
	color: Color3,
}

local EMOTES: { Emote } = {
	{ id = "gg",     key = 1, text = "GG!",        color = Color3.fromRGB(94, 222, 158) },
	{ id = "nice",   key = 2, text = "NICE SHOT",  color = Color3.fromRGB(62, 168, 245) },
	{ id = "oof",    key = 3, text = "OOF",        color = Color3.fromRGB(255, 201, 60) },
	{ id = "close",  key = 4, text = "SO CLOSE",   color = Color3.fromRGB(255, 150, 56) },
	{ id = "tooslow",key = 5, text = "TOO SLOW",   color = Color3.fromRGB(255, 107, 107) },
	{ id = "rematch",key = 6, text = "RUN IT BACK",color = Color3.fromRGB(200, 120, 255) },
}

-- ── Lookups ──────────────────────────────────────────────────────────────

local skinById: { [string]: PaddleSkin } = {}
for _, skin in ipairs(PADDLE_SKINS) do skinById[skin.id] = skin end

local titleById: { [string]: Title } = {}
for _, title in ipairs(TITLES) do titleById[title.id] = title end

local emoteById: { [string]: Emote } = {}
local emoteByKey: { [number]: Emote } = {}
for _, emote in ipairs(EMOTES) do
	emoteById[emote.id] = emote
	emoteByKey[emote.key] = emote
end

Extras.PADDLE_SKINS = PADDLE_SKINS
Extras.TITLES = TITLES
Extras.EMOTES = EMOTES

Extras.DEFAULT_PADDLE_SKIN = "default"
Extras.DEFAULT_TITLE = "none"

function Extras.getPaddleSkin(id: string?): PaddleSkin
	return skinById[id or ""] or skinById[Extras.DEFAULT_PADDLE_SKIN]
end

function Extras.getTitle(id: string?): Title
	return titleById[id or ""] or titleById[Extras.DEFAULT_TITLE]
end

function Extras.getEmote(id: string?): Emote?
	return emoteById[id or ""]
end

function Extras.getEmoteByKey(key: number): Emote?
	return emoteByKey[key]
end

-- Titles are one pass for the whole list, so this is a single check rather
-- than a per-item `requiresPass` like the skins carry.
Extras.TITLE_PASS = "NameTag"

-- True when `player` may select this skin. Both sides call this — the client to
-- grey out a row, the server to reject a forged selection — so the rule lives
-- here once. `hasPass` is injected because the client reads attributes and the
-- server reads PassService; only the caller knows which is trustworthy.
function Extras.canUseSkin(skin: PaddleSkin?, hasPass: (string) -> boolean): boolean
	if not skin then return false end
	if not skin.requiresPass then return true end
	return hasPass(skin.requiresPass) == true
end

function Extras.canUseTitle(title: Title?, hasPass: (string) -> boolean): boolean
	if not title then return false end
	if title.id == Extras.DEFAULT_TITLE then return true end
	return hasPass(Extras.TITLE_PASS) == true
end

Extras.PASS_ATTR_PREFIX = Monetization.PASS_ATTR_PREFIX

return Extras
