-- ShopController
-- Drives StarterGui.ShopUI. Opened by the HUD shop button, by the shopkeeper's
-- ProximityPrompt, or by pressing B. All item data comes from InventoryClient,
-- which is kept current by the server's InventorySync remote — this file never
-- decides what a player owns.

local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local UserInputService    = game:GetService("UserInputService")
local TweenService        = game:GetService("TweenService")

local Shared          = ReplicatedStorage:WaitForChild("Shared")
local Remotes         = require(Shared:WaitForChild("Remotes"))
local Constants       = require(Shared:WaitForChild("Constants"))
local InventoryClient = require(Shared:WaitForChild("InventoryClient"))
local FXCatalog       = require(Shared:WaitForChild("FXCatalog"))
local FXPlayer        = require(Shared:WaitForChild("FXPlayer"))
local VFXLibrary      = require(Shared:WaitForChild("VFXLibrary"))
local Monetization    = require(Shared:WaitForChild("Monetization"))
local Extras          = require(Shared:WaitForChild("Extras"))

local PassController  = require(script.Parent:WaitForChild("PassController"))

local ShopController = {}

-- Goal explosion first: it is the cosmetic players actually shop for. The two
-- non-FX tabs go last because they are browsed occasionally, not every visit.
--
-- `name` must match the TextButton's Name under ShopUI.Root.Tabs — that is how
-- a click resolves back to a tab.
local TABS = {
	{ name = "GoalVFX", kind = "fx" },
	{ name = "GoalSFX", kind = "fx" },
	{ name = "WinSFX",  kind = "fx" },
	-- Named "Cosmetics" rather than "Style": the tab buttons live under a Frame,
	-- and a child called Style is shadowed by the Frame's own Style property, so
	-- tabs.Style hands back an Enum instead of the button.
	{ name = "Cosmetics", kind = "style" },
	{ name = "Passes",    kind = "passes" },
}

local TAB_KIND: { [string]: string } = {}
for _, tab in ipairs(TABS) do
	TAB_KIND[tab.name] = tab.kind
end

local SHOP_PROMPT_NAME = "ShopPrompt"

-- Long enough that double-clicking PREVIEW can't stack effects, short enough
-- that browsing doesn't feel gated.
local PREVIEW_COOLDOWN = 0.5

local INK             = Color3.fromRGB(22, 35, 58)
local INK_SOFT        = Color3.fromRGB(104, 120, 150)
local WHITE           = Color3.fromRGB(255, 255, 255)
local ACCENT_ACTIVE   = Color3.fromRGB(62, 168, 245)
local ACCENT_IDLE     = Color3.fromRGB(255, 255, 255)
local BUY_COLOR       = Color3.fromRGB(94, 222, 158)
local EQUIP_COLOR     = Color3.fromRGB(62, 168, 245)
local DISABLED_COLOR  = Color3.fromRGB(206, 216, 230)
local OWNED_COLOR     = Color3.fromRGB(94, 222, 158)
local SHORT_COLOR     = Color3.fromRGB(255, 107, 107)

-- Arcade button feel: brighten on hover, press into the plate on click.
local function wirePress(button: TextButton, baseGetter: () -> Color3)
	local home = button.Position
	local quick = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	button.MouseEnter:Connect(function()
		TweenService:Create(button, quick,
			{ BackgroundColor3 = baseGetter():Lerp(WHITE, 0.35) }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, quick, { BackgroundColor3 = baseGetter() }):Play()
		button.Position = home
	end)
	button.MouseButton1Down:Connect(function()
		button.Position = home + UDim2.fromOffset(3, 3)
		FXPlayer.playUi("click")
	end)
	button.MouseButton1Up:Connect(function()
		button.Position = home
	end)
end

local ROBUX_COLOR = Color3.fromRGB(94, 222, 158)
local LOCKED_COLOR = Color3.fromRGB(160, 170, 190)

-- Matches the UIListLayout padding authored on ShopUI.Root.Tabs.
local TAB_GUTTER = 8

local CATEGORY_COLORS = {
	Economy  = Color3.fromRGB(94, 222, 158),
	Access   = Color3.fromRGB(62, 168, 245),
	Cosmetic = Color3.fromRGB(200, 120, 255),
	Utility  = Color3.fromRGB(255, 201, 60),
	Cash     = Color3.fromRGB(255, 150, 56),
	Paddle   = Color3.fromRGB(62, 168, 245),
	Title    = Color3.fromRGB(200, 120, 255),
}

local player = Players.LocalPlayer
local ui
local activeSlot = TABS[1].name
local itemRows: { Frame } = {}
local cash = 0
local lastPreviewAt = 0
local previewToken = 0

local function money(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	out = out:gsub("^,", "")
	return "$" .. out
end

local function getUI()
	local gui = player:WaitForChild("PlayerGui"):WaitForChild("ShopUI")
	local root = gui:WaitForChild("Root")
	local header = root:WaitForChild("Header")
	local list = root:WaitForChild("List")
	return {
		gui = gui,
		root = root,
		cash = header:WaitForChild("Cash") :: TextLabel,
		close = header:WaitForChild("Close") :: TextButton,
		tabs = root:WaitForChild("Tabs"),
		list = list,
		template = list:WaitForChild("ItemTemplate") :: Frame,
		footer = root:WaitForChild("Footer") :: TextLabel,
		backdrop = gui:WaitForChild("Backdrop") :: Frame,
	}
end

local function setFooter(message: string, isError: boolean?)
	ui.footer.Text = message
	ui.footer.TextColor3 = isError and SHORT_COLOR or Color3.fromRGB(170, 190, 220)
end

-- Previews play in the world, so the panel gets out of the way for exactly as
-- long as the effect runs and then comes back on its own. The shop stays open
-- throughout: this is a peek, not a mode.
local function runPreview(record)
	if os.clock() - lastPreviewAt < PREVIEW_COOLDOWN then
		return
	end
	lastPreviewAt = os.clock()

	if record.slot == "GoalSFX" then
		local entry = FXCatalog.getEntry(record.slot, record.id)
		if entry then
			FXPlayer.playSfx(ui.gui, entry, 0.8)
		end
		setFooter("PLAYING " .. string.upper(record.displayName) .. ".")
		return
	end

	local recipe = VFXLibrary.getRecipe(record.slot, record.id)
	local camera = workspace.CurrentCamera
	if not (recipe and camera) then
		return
	end

	-- Staged in front of the camera at roughly the distance a table is viewed
	-- from, so what you see here is what you get on a goal.
	VFXLibrary.play(record.slot, record.id, camera.CFrame * CFrame.new(0, -3.5, -17), {
		teamColor = ACCENT_ACTIVE,
	})

	previewToken += 1
	local token = previewToken
	ui.root.Visible = false
	ui.backdrop.BackgroundTransparency = 0.85

	task.delay(recipe.lifetime, function()
		-- A newer preview (or a close) owns the panel now; don't fight it.
		if token ~= previewToken then
			return
		end
		ui.root.Visible = true
		ui.backdrop.BackgroundTransparency = 0.45
	end)
end

local function refreshTabs()
	for _, tab in ipairs(ui.tabs:GetChildren()) do
		if tab:IsA("TextButton") then
			local isActive = tab.Name == activeSlot
			tab.BackgroundColor3 = isActive and ACCENT_ACTIVE or ACCENT_IDLE
			tab.TextColor3 = isActive and WHITE or INK_SOFT
			-- The selected cabinet tab sits proud of the others. The offset is the
			-- list layout's padding shared out across the tabs, so they still fill
			-- the bar exactly however many there are.
			local width = 1 / #TABS
			local gutter = -(TAB_GUTTER * (#TABS - 1)) / #TABS
			tab.Size = isActive and UDim2.new(width, gutter, 1, 0) or UDim2.new(width, gutter, 1, -6)
		end
	end
end

local function clearRows()
	for _, row in ipairs(itemRows) do
		row:Destroy()
	end
	table.clear(itemRows)
end

-- Every tab renders through one row builder fed a normalised spec, so the FX
-- catalog, the cosmetic pickers and the Robux storefront cannot drift into
-- three different-looking lists. A spec that omits onPreview simply hides the
-- preview button — only effects have something to preview.
type RowSpec = {
	key: string,
	name: string,
	description: string?,
	tag: string?,
	tagColor: Color3?,
	priceText: string?,
	priceColor: Color3?,
	badgeText: string?,
	badgeColor: Color3?,
	actionText: string,
	actionColor: Color3,
	actionTextColor: Color3,
	actionEnabled: boolean?,
	onAction: (() -> ())?,
	onPreview: (() -> ())?,
}

local function buildRow(spec: RowSpec, order: number)
	local row = ui.template:Clone()
	row.Name = spec.key
	row.LayoutOrder = order
	row.Visible = true

	local nameLabel = row:WaitForChild("ItemName") :: TextLabel
	local priceLabel = row:WaitForChild("Price") :: TextLabel
	local badge = row:WaitForChild("Badge") :: TextLabel
	local action = row:WaitForChild("Action") :: TextButton
	local rarityLabel = row:WaitForChild("Rarity") :: TextLabel
	local descLabel = row:WaitForChild("Description") :: TextLabel
	local preview = row:WaitForChild("Preview") :: TextButton

	nameLabel.Text = spec.name
	descLabel.Text = spec.description or ""

	-- The tag owns the accent bar rather than the buy/equip state: rarity on
	-- the FX tabs, category everywhere else. You should be able to spot a
	-- legendary while scrolling without reading a word.
	local tagColor = spec.tagColor or INK_SOFT
	rarityLabel.Text = string.upper(spec.tag or "")
	rarityLabel.TextColor3 = tagColor
	local accent = row:FindFirstChild("Accent")
	if accent then
		accent.BackgroundColor3 = tagColor
	end

	priceLabel.Text = spec.priceText or ""
	priceLabel.TextColor3 = spec.priceColor or INK_SOFT

	badge.Text = spec.badgeText or ""
	badge.TextColor3 = spec.badgeColor or INK_SOFT

	action.Text = spec.actionText
	action.BackgroundColor3 = spec.actionColor
	action.TextColor3 = spec.actionTextColor
	action.AutoButtonColor = false

	if spec.onPreview then
		preview.Visible = true
		preview.MouseButton1Click:Connect(spec.onPreview)
		wirePress(preview, function() return WHITE end)
	else
		preview.Visible = false
	end

	if spec.actionEnabled and spec.onAction then
		wirePress(action, function() return spec.actionColor end)
		action.MouseButton1Click:Connect(spec.onAction)
	end

	row.Parent = ui.list
	table.insert(itemRows, row)
end

-- ── Row builders ────────────────────────────────────────────────────────────

local function fxRows(slot: string): { RowSpec }
	local records = InventoryClient.getItemsForSlot(slot)

	-- Catalog order, which is the rarity ladder: commons at the top, the
	-- legendary you are saving for at the bottom. Sorting owned items to the
	-- top instead would reshuffle the list every purchase and lose the sense
	-- of a collection with an end.
	local sorted = table.clone(records)
	table.sort(sorted, function(a, b)
		if (a.order or 0) ~= (b.order or 0) then return (a.order or 0) < (b.order or 0) end
		return a.displayName < b.displayName
	end)

	local specs: { RowSpec } = {}
	for _, record in ipairs(sorted) do
		local affordable = cash >= record.price
		local spec: RowSpec = {
			key = record.slot .. "_" .. record.id,
			name = record.displayName,
			description = record.description,
			tag = record.rarity or "COMMON",
			tagColor = FXCatalog.getRarityColor(record.rarity),
			actionText = "BUY",
			actionColor = DISABLED_COLOR,
			actionTextColor = INK_SOFT,
			onPreview = function() runPreview(record) end,
		}

		if record.owned then
			spec.priceText = record.defaultOwned and "INCLUDED" or "OWNED"
			spec.priceColor = INK_SOFT
		else
			spec.priceText = money(record.price)
			spec.priceColor = affordable and INK_SOFT or SHORT_COLOR
		end

		if record.equipped then
			spec.badgeText, spec.badgeColor = "EQUIPPED", OWNED_COLOR
			spec.actionText = "IN USE"
		elseif record.owned then
			spec.badgeText, spec.badgeColor = "OWNED", INK_SOFT
			spec.actionText, spec.actionColor, spec.actionTextColor = "EQUIP", EQUIP_COLOR, WHITE
			spec.actionEnabled = true
			spec.onAction = function()
				InventoryClient.requestEquip(record.slot, record.id)
			end
		else
			spec.actionColor = affordable and BUY_COLOR or DISABLED_COLOR
			spec.actionTextColor = affordable and INK or INK_SOFT
			spec.actionEnabled = true
			spec.onAction = function()
				if cash < record.price then
					setFooter("YOU NEED " .. money(record.price - cash) .. " MORE.", true)
					FXPlayer.playUi("denied")
				else
					InventoryClient.requestBuy(record.slot, record.id)
				end
			end
		end

		table.insert(specs, spec)
	end
	return specs
end

-- Shared by both halves of the Style tab: an item you cannot use yet turns its
-- action button into a shortcut to the pass that unlocks it, rather than a
-- dead "LOCKED" label that leaves you to go and find it.
local function lockedSpecFields(spec: RowSpec, passKey: string)
	local def = Monetization.getPass(passKey)
	spec.priceText = def and string.upper(def.name) or "LOCKED"
	spec.priceColor = LOCKED_COLOR
	if def and Monetization.isConfigured(def) then
		spec.actionText, spec.actionColor, spec.actionTextColor = "GET PASS", ROBUX_COLOR, INK
		spec.actionEnabled = true
		spec.onAction = function() PassController.promptPass(passKey) end
	else
		spec.actionText, spec.actionColor, spec.actionTextColor = "COMING SOON", DISABLED_COLOR, INK_SOFT
	end
end

local function styleRows(): { RowSpec }
	local specs: { RowSpec } = {}
	local hasPass = PassController.predicate()

	-- Marked against the *effective* loadout, not the stored choice. Someone
	-- whose Paddle Pack has lapsed keeps Solid Gold as their choice but plays
	-- with Standard; showing the badge on the locked row would tell them they
	-- are using something they demonstrably are not.
	local equipped = PassController.getLoadout().effective

	for _, skin in ipairs(Extras.PADDLE_SKINS) do
		local unlocked = Extras.canUseSkin(skin, hasPass)
		local selected = equipped.paddleSkin == skin.id
		local spec: RowSpec = {
			key = "paddle_" .. skin.id,
			name = skin.name,
			description = skin.description,
			tag = "Paddle",
			tagColor = skin.color,
			actionText = "EQUIP",
			actionColor = EQUIP_COLOR,
			actionTextColor = WHITE,
		}

		-- Nothing here has a cash price, so the price column carries the state
		-- instead of repeating "OWNED" down the whole list.
		if not unlocked then
			lockedSpecFields(spec, skin.requiresPass or "PaddlePack")
		elseif selected then
			spec.priceText, spec.priceColor = "EQUIPPED", OWNED_COLOR
			spec.actionText, spec.actionColor, spec.actionTextColor = "IN USE", DISABLED_COLOR, INK_SOFT
		else
			spec.actionEnabled = true
			spec.onAction = function() PassController.selectPaddle(skin.id) end
		end

		table.insert(specs, spec)
	end

	for _, title in ipairs(Extras.TITLES) do
		local unlocked = Extras.canUseTitle(title, hasPass)
		local selected = equipped.title == title.id
		local spec: RowSpec = {
			key = "title_" .. title.id,
			name = title.text ~= "" and title.text or "NO TITLE",
			description = title.text ~= ""
				and ("Fly \"" .. title.text .. "\" over your mallet.")
				or "Show your name with no title.",
			tag = "Title",
			tagColor = title.color,
			actionText = "EQUIP",
			actionColor = EQUIP_COLOR,
			actionTextColor = WHITE,
		}

		if not unlocked then
			lockedSpecFields(spec, Extras.TITLE_PASS)
		elseif selected then
			spec.priceText, spec.priceColor = "EQUIPPED", OWNED_COLOR
			spec.actionText, spec.actionColor, spec.actionTextColor = "IN USE", DISABLED_COLOR, INK_SOFT
		else
			spec.actionEnabled = true
			spec.onAction = function() PassController.selectTitle(title.id) end
		end

		table.insert(specs, spec)
	end

	return specs
end

-- Fills in the price column and buy button for a published asset. `info` is nil
-- while the Roblox lookup is still in flight, and carries forSale = false for
-- something that exists but has been left off sale — that one must not offer a
-- buy button, because the prompt it opens cannot complete.
local function applyStorePrice(spec: RowSpec, info, onBuy: () -> ())
	if not info then
		spec.priceText, spec.priceColor = "R$ …", ROBUX_COLOR
		spec.actionText, spec.actionColor, spec.actionTextColor = "…", DISABLED_COLOR, INK_SOFT
		return
	end

	if not info.forSale or not info.price then
		spec.priceText, spec.priceColor = "OFF SALE", LOCKED_COLOR
		spec.actionText, spec.actionColor, spec.actionTextColor = "UNAVAILABLE", DISABLED_COLOR, INK_SOFT
		return
	end

	spec.priceText = "R$ " .. info.price
	spec.priceColor = ROBUX_COLOR
	spec.actionText, spec.actionColor, spec.actionTextColor = "BUY", ROBUX_COLOR, INK
	spec.actionEnabled = true
	spec.onAction = onBuy
end

local function passRows(): { RowSpec }
	local specs: { RowSpec } = {}

	for _, def in ipairs(Monetization.PASSES) do
		local spec: RowSpec = {
			key = "pass_" .. def.key,
			name = def.name,
			description = def.description,
			tag = def.category,
			tagColor = CATEGORY_COLORS[def.category] or ACCENT_ACTIVE,
			actionText = "BUY",
			actionColor = ROBUX_COLOR,
			actionTextColor = INK,
		}

		if PassController.owns(def.key) then
			-- No badge: the price line and the button would otherwise both say a
			-- version of "you have this", and the badge sits under the button.
			spec.priceText, spec.priceColor = "OWNED", OWNED_COLOR
			spec.actionText, spec.actionColor, spec.actionTextColor = "ACTIVE", DISABLED_COLOR, INK_SOFT
		elseif not Monetization.isConfigured(def) then
			-- Not published yet. Deliberately not wired to a prompt: Marketplace
			-- throws on asset id 0.
			spec.priceText, spec.priceColor = "—", LOCKED_COLOR
			spec.actionText, spec.actionColor, spec.actionTextColor = "COMING SOON", DISABLED_COLOR, INK_SOFT
		else
			applyStorePrice(spec, PassController.priceInfoForPass(def.key), function()
				PassController.promptPass(def.key)
			end)
		end

		table.insert(specs, spec)
	end

	for _, def in ipairs(Monetization.PRODUCTS) do
		local spec: RowSpec = {
			key = "product_" .. def.key,
			name = def.name,
			description = def.description,
			tag = "Cash",
			tagColor = CATEGORY_COLORS.Cash,
			badgeText = def.best and "BEST VALUE" or "",
			badgeColor = CATEGORY_COLORS.Cash,
			actionText = "BUY",
			actionColor = ROBUX_COLOR,
			actionTextColor = INK,
		}

		if not Monetization.isConfigured(def) then
			spec.priceText, spec.priceColor = "—", LOCKED_COLOR
			spec.actionText, spec.actionColor, spec.actionTextColor = "COMING SOON", DISABLED_COLOR, INK_SOFT
		else
			applyStorePrice(spec, PassController.priceInfoForProduct(def.key), function()
				PassController.promptProduct(def.key)
			end)
		end

		table.insert(specs, spec)
	end

	return specs
end

local function render()
	if not ui then return end
	ui.cash.Text = money(cash)
	refreshTabs()
	clearRows()

	local kind = TAB_KIND[activeSlot] or "fx"
	local specs
	if kind == "style" then
		specs = styleRows()
	elseif kind == "passes" then
		specs = passRows()
	else
		specs = fxRows(activeSlot)
	end

	if #specs == 0 then
		setFooter("NOTHING IN THIS CATEGORY YET.")
		return
	end

	for index, spec in ipairs(specs) do
		buildRow(spec, index)
	end
end

local FOOTER_BY_KIND = {
	fx     = "PREVIEW ANYTHING. BUY ONCE, EQUIP FOREVER.",
	style  = "YOUR MALLET, YOUR NAME. PICK ONE OF EACH.",
	passes = "PERMANENT UNLOCKS AND CASH PACKS.",
}

function ShopController.isOpen(): boolean
	return ui ~= nil and ui.gui.Enabled
end

function ShopController.setOpen(open: boolean)
	if not ui then return end
	ui.gui.Enabled = open
	if not open then
		-- Closing mid-preview must not leave the panel hidden next time.
		previewToken += 1
		ui.root.Visible = true
		ui.backdrop.BackgroundTransparency = 0.45
	end
	if open then
		setFooter(FOOTER_BY_KIND[TAB_KIND[activeSlot] or "fx"] or "")
		render()
		ui.root.Size = UDim2.new(0.5, 0, 0.68, 0)
		TweenService:Create(ui.root, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = UDim2.new(0.56, 0, 0.76, 0),
		}):Play()
	end
end

function ShopController.toggle()
	ShopController.setOpen(not ShopController.isOpen())
end

function ShopController.init()
	ui = getUI()
	cash = tonumber(player:GetAttribute(Constants.CASH_ATTR)) or 0
	refreshTabs()

	for _, tab in ipairs(ui.tabs:GetChildren()) do
		if tab:IsA("TextButton") then
			tab.MouseButton1Click:Connect(function()
				activeSlot = tab.Name
				FXPlayer.playUi("select")
				setFooter(FOOTER_BY_KIND[TAB_KIND[activeSlot] or "fx"] or "")
				render()
			end)
		end
	end

	ui.close.MouseButton1Click:Connect(function()
		ShopController.setOpen(false)
	end)
	wirePress(ui.close, function() return Color3.fromRGB(255, 107, 107) end)

	for _, tab in ipairs(ui.tabs:GetChildren()) do
		if tab:IsA("TextButton") then
			wirePress(tab, function()
				return tab.Name == activeSlot and ACCENT_ACTIVE or ACCENT_IDLE
			end)
		end
	end

	-- HUD button
	local hud = player:WaitForChild("PlayerGui"):WaitForChild("AirHockeyUI"):WaitForChild("HUD")
	local shopButton = hud:WaitForChild("ShopButton") :: TextButton
	shopButton.MouseButton1Click:Connect(ShopController.toggle)

	-- Shopkeeper prompt
	ProximityPromptService.PromptTriggered:Connect(function(prompt, promptPlayer)
		if promptPlayer ~= player then return end
		if prompt.Name ~= SHOP_PROMPT_NAME then return end
		ShopController.setOpen(true)
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.B then
			ShopController.toggle()
		elseif input.KeyCode == Enum.KeyCode.Escape and ShopController.isOpen() then
			ShopController.setOpen(false)
		end
	end)

	InventoryClient.Changed:Connect(function()
		if ShopController.isOpen() then render() end
	end)

	-- Covers pass purchases, loadout changes, and Robux prices arriving from
	-- the async GetProductInfo fetches.
	PassController.Changed:Connect(function()
		if ShopController.isOpen() then render() end
	end)

	Remotes.CashSync.OnClientEvent:Connect(function(newCash: number)
		cash = tonumber(newCash) or 0
		if ShopController.isOpen() then render() end
	end)

	Remotes.ShopResult.OnClientEvent:Connect(function(result)
		if typeof(result) ~= "table" then return end
		setFooter(result.message or "", not result.ok)
		FXPlayer.playUi(result.ok and "buy" or "denied")
	end)

	-- Playing a match takes the whole screen; don't let the shop sit on top of it.
	Remotes.State.OnClientEvent:Connect(function(state: string)
		if state == Constants.STATE_COUNTDOWN or state == Constants.STATE_PLAYING then
			ShopController.setOpen(false)
		end
	end)
end

return ShopController
