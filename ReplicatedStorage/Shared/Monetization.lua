-- Monetization
-- The single source of truth for every game pass and developer product.
--
-- SETUP: every id below is live on the Creator Dashboard for universe
-- 10323596305. To add a new entry, create it on the dashboard and paste its
-- asset id here — nothing else needs editing, every consumer reads this table.
--
-- An id of 0 is handled everywhere rather than being an error: the pass simply
-- reads as unowned, the shop row renders as COMING SOON, and no purchase prompt
-- is sent. That way a new entry can be built and playtested before its asset
-- exists.
--
-- Testing without publishing: set the DevGrantAllPasses attribute on
-- ServerScriptService (Explorer > ServerScriptService > Attributes > add a
-- boolean) to own every pass for the session. Unlike the FX dev grant this is
-- deliberately NOT automatic in Studio, because the locked state is the thing
-- that usually needs looking at.

local Monetization = {}

export type PassKey =
	"Cash2x" | "LoserRefund" | "StartingBonus" | "DailyStipend"
	| "VIPTable" | "PrioritySeating" | "Spectate"
	| "FXCollector" | "PaddlePack" | "GoldenPuck" | "NameTag"
	| "RematchReady" | "EmotePack" | "PrivateTable"

export type PassDef = {
	key: PassKey,
	id: number,
	name: string,
	description: string,
	category: string,
	robux: number,   -- suggested price; the real one is set on the dashboard
	order: number,
}

export type ProductDef = {
	key: string,
	id: number,
	name: string,
	description: string,
	cash: number,
	robux: number,
	order: number,
	best: boolean?,
}

-- ── Tunables ──────────────────────────────────────────────────────────────────
-- Everything a pass actually *does*, in one place, so balance changes never
-- require hunting through the services that apply them.

-- Cash2x multiplies the winner's profit, not the whole pot. The pot is two
-- stakes, one of which the winner put in themselves; doubling all of it would
-- pay 4x the stake and read as "4x Cash" to anyone doing the arithmetic.
Monetization.CASH_MULTIPLIER = 2

-- Fraction of their own stake a losing pass holder gets back. Applied on top of
-- Constants.LOSER_REFUND_RATE, never instead of it.
Monetization.LOSER_REFUND_RATE = 0.5

-- One-time top-up. A player is brought *up to* this floor rather than being
-- handed the difference on top of a fortune, so buying it late is not a way to
-- print money and buying it early is still the intended big head start.
Monetization.STARTING_BONUS_FLOOR = 5000

-- Daily claim. DAY_SECONDS is a rolling 24h window rather than a calendar day
-- so the reset does not depend on the server's timezone.
Monetization.DAILY_STIPEND = 1000
Monetization.DAY_SECONDS = 24 * 60 * 60

-- After a table frees up, non-holders are held off for this long so a pass
-- holder waiting for it actually gets the seat. Short enough that an empty
-- lounge never feels broken.
Monetization.PRIORITY_WINDOW = 10

-- How long the win card is held open when a seated player owns Instant
-- Rematch, instead of Constants.MATCH_OVER_LINGER. The default 8s is barely
-- enough to read the card, let alone agree to run it back.
Monetization.REMATCH_LINGER = 20

-- Wagers a Private Table owner may choose from. Deliberately a fixed ladder
-- rather than a free number: an arbitrary stake is a laundering primitive.
Monetization.PRIVATE_WAGERS = { 0, 25, 100, 500, 2500, 10000, 50000, 250000 }

-- Attribute names mirrored onto the Player so clients can read entitlements
-- without a round trip. Server writes, client reads only.
Monetization.PASS_ATTR_PREFIX = "AH_Pass_"
Monetization.LOADOUT_ATTR_PADDLE = "AH_PaddleSkin"
Monetization.LOADOUT_ATTR_TITLE = "AH_Title"

-- Table attributes read by TableManager.
Monetization.TABLE_ATTR_REQUIRES_PASS = "RequiresPass"
Monetization.TABLE_ATTR_OWNER = "PrivateOwnerId"
Monetization.TABLE_ATTR_PRIVATE = "IsPrivate"

function Monetization.attrFor(key: string): string
	return Monetization.PASS_ATTR_PREFIX .. key
end

-- ── Game passes ───────────────────────────────────────────────────────────────

local PASSES: { PassDef } = {
	{
		key = "Cash2x", id = 1944084824, order = 1, robux = 199,
		category = "Economy",
		name = "2x Cash",
		description = "Double the winnings from every match you take.",
	},
	{
		key = "LoserRefund", id = 1940060229, order = 2, robux = 149,
		category = "Economy",
		name = "Table Insurance",
		description = "Get half your stake back whenever you lose.",
	},
	{
		key = "StartingBonus", id = 1942004116, order = 3, robux = 99,
		category = "Economy",
		name = "Big Bankroll",
		description = "A one-time top-up to $5,000 so you can skip the grind.",
	},
	{
		key = "DailyStipend", id = 1941368218, order = 4, robux = 149,
		category = "Economy",
		name = "Daily Payday",
		description = "Collect $1,000 every day you play.",
	},
	{
		key = "VIPTable", id = 1943420109, order = 5, robux = 249,
		category = "Access",
		name = "VIP Lounge",
		description = "Unlock the members-only tables at the back of the hall.",
	},
	{
		key = "PrioritySeating", id = 1944600763, order = 6, robux = 129,
		category = "Access",
		name = "Priority Seating",
		description = "First claim on any table that frees up, and a crown on your seat.",
	},
	{
		key = "Spectate", id = 1940390107, order = 7, robux = 79,
		category = "Access",
		name = "Spectator Cam",
		description = "Watch any live table from the stands. Press V.",
	},
	{
		key = "FXCollector", id = 1941836186, order = 8, robux = 399,
		category = "Cosmetic",
		name = "FX Collector",
		description = "Every legendary goal explosion and win jingle, unlocked at once.",
	},
	{
		key = "PaddlePack", id = 1944162794, order = 9, robux = 199,
		category = "Cosmetic",
		name = "Paddle Pack",
		description = "Six mallet skins: chrome, neon, magma, void, gold and ice.",
	},
	{
		key = "GoldenPuck", id = 1945162460, order = 10, robux = 149,
		category = "Cosmetic",
		name = "Golden Puck",
		description = "Your table plays with a solid gold puck. Everyone sees it.",
	},
	{
		key = "NameTag", id = 1944980476, order = 11, robux = 99,
		category = "Cosmetic",
		name = "Name Tag",
		description = "Fly a glowing title over your mallet. Ten to choose from.",
	},
	{
		key = "RematchReady", id = 1938220540, order = 12, robux = 99,
		category = "Utility",
		name = "Instant Rematch",
		description = "Skip the win screen and run it back immediately.",
	},
	{
		key = "EmotePack", id = 1944054801, order = 13, robux = 99,
		category = "Utility",
		name = "Emote Pack",
		description = "Six taunts on the number keys. Use them responsibly.",
	},
	{
		key = "PrivateTable", id = 1941200260, order = 14, robux = 299,
		category = "Utility",
		name = "Private Table",
		description = "Claim any open table, set your own stake, and lock out strangers.",
	},
}

-- ── Developer products (cash) ─────────────────────────────────────────────────
-- The ladder is roughly one tier of the table list per pack, so every pack has
-- an obvious thing it buys you rather than being an abstract number.

local PRODUCTS: { ProductDef } = {
	{
		key = "Cash1k", id = 3707673313, order = 1, robux = 25, cash = 1000,
		name = "Pocket Change",
		description = "$1,000 — a few rounds at the Silver tables.",
	},
	{
		key = "Cash10k", id = 3707677625, order = 2, robux = 99, cash = 10000,
		name = "Stack of Chips",
		description = "$10,000 — buys you a seat at Emerald.",
	},
	{
		key = "Cash100k", id = 3707680131, order = 3, robux = 499, cash = 100000,
		name = "Briefcase",
		description = "$100,000 — Sapphire money.",
		best = true,
	},
	{
		key = "Cash1m", id = 3707682224, order = 4, robux = 1999, cash = 1000000,
		name = "Vault",
		description = "$1,000,000 — sit down at Obsidian.",
	},
	{
		key = "Cash10m", id = 3707683641, order = 5, robux = 9999, cash = 10000000,
		name = "Whale Tank",
		description = "$10,000,000 — Celestial, twice over.",
	},
}

local passByKey: { [string]: PassDef } = {}
for _, def in ipairs(PASSES) do
	passByKey[def.key] = def
end

local productByKey: { [string]: ProductDef } = {}
local productById: { [number]: ProductDef } = {}
for _, def in ipairs(PRODUCTS) do
	productByKey[def.key] = def
	if def.id > 0 then
		productById[def.id] = def
	end
end

table.sort(PASSES, function(a, b) return a.order < b.order end)
table.sort(PRODUCTS, function(a, b) return a.order < b.order end)

Monetization.PASSES = PASSES
Monetization.PRODUCTS = PRODUCTS

function Monetization.getPass(key: string): PassDef?
	return passByKey[key]
end

function Monetization.getProduct(key: string): ProductDef?
	return productByKey[key]
end

function Monetization.getProductById(id: number): ProductDef?
	return productById[id]
end

-- Whether this entry has a real asset behind it yet.
function Monetization.isConfigured(def): boolean
	return typeof(def) == "table" and typeof(def.id) == "number" and def.id > 0
end

function Monetization.passIsConfigured(key: string): boolean
	return Monetization.isConfigured(passByKey[key])
end

-- Client-side read of an entitlement. Server-side code must use
-- PassService.owns instead: attributes are replicated state, and trusting them
-- for anything that moves money would be trusting the client's own copy.
function Monetization.playerHasPass(player: Player, key: string): boolean
	return player:GetAttribute(Monetization.attrFor(key)) == true
end

return Monetization
