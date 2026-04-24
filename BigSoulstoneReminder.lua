local addonName = ...

local ADDON = CreateFrame("Frame")

local SOULSTONE_SPELL_ID = 20707
local SOULSTONE_FALLBACK_ICON = 136210
local ICON_SIZE = 36
local TITLE_FONT_SIZE = 21
local BORDER_THICKNESS = 2
local CONTENT_SPACING = 10

local DEFAULT_BANNER_POSITION = {
    point = "TOP",
    relPoint = "TOP",
    x = 0,
    y = -160,
}

local DEFAULT_SETTINGS = {
    enableSoloReminder = true,
    enablePartyReminder = true,
    enableRaidReminder = true,
    allowGroupReminderOutsideInstances = false,
    soonThreshold = 30,
    unlockBannerPosition = false,
    bannerScale = 1.0,
    debugLogging = false,
    bannerPosition = {
        point = DEFAULT_BANNER_POSITION.point,
        relPoint = DEFAULT_BANNER_POSITION.relPoint,
        x = DEFAULT_BANNER_POSITION.x,
        y = DEFAULT_BANNER_POSITION.y,
    },
}

local state = {
    initialized = false,
    refreshPending = false,
    wasRestricted = false,
    debugEnabled = false,
    demoMode = nil,
    demoDeadline = nil,
    cooldownTimer = nil,
    lastTrigger = "startup",
    lastReason = "Starting up",
    lastVisible = false,
    lastCooldownRemaining = 0,
    lastOwnedUnit = nil,
    settingsCategory = nil,
    settingsRefreshers = {},
}

local banner
local QueueRefresh
local ScheduleLiveCooldownRefresh
local ScheduleDemoCooldownRefresh
local RefreshSettingsPanel
local OpenSettings
local SetDemoMode

local function CloneValue(value)
    if type(value) ~= "table" then
        return value
    end

    local copy = {}
    for key, nestedValue in pairs(value) do
        copy[key] = CloneValue(nestedValue)
    end
    return copy
end

local function MergeDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = CloneValue(value)
            else
                MergeDefaults(target[key], value)
            end
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

local function MigrateSettings(settings)
    if type(settings) ~= "table" then
        return
    end

    if settings.enableGroupReminder ~= nil then
        local groupReminderEnabled = settings.enableGroupReminder and true or false

        if settings.enablePartyReminder == nil then
            settings.enablePartyReminder = groupReminderEnabled
        end

        if settings.enableRaidReminder == nil then
            settings.enableRaidReminder = groupReminderEnabled
        end
    end
end

local function Chat(message)
    print(string.format("|cff9f7fffBig Soulstone Reminder|r: %s", message))
end

local function Debug(message)
    if state.debugEnabled then
        Chat(message)
    end
end

local function DebugState()
    Debug(string.format("Update: %s", state.lastReason))
end

local function GetSetting(key)
    if type(BigSoulstoneReminderDB) ~= "table" then
        return DEFAULT_SETTINGS[key]
    end

    local value = BigSoulstoneReminderDB[key]
    if value == nil then
        return DEFAULT_SETTINGS[key]
    end

    return value
end

local function SetSetting(key, value)
    if type(BigSoulstoneReminderDB) ~= "table" then
        BigSoulstoneReminderDB = CloneValue(DEFAULT_SETTINGS)
    end

    BigSoulstoneReminderDB[key] = value
end

local function GetSoonThreshold()
    return GetSetting("soonThreshold") or DEFAULT_SETTINGS.soonThreshold
end

local function GetSoulstoneInfo()
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(SOULSTONE_SPELL_ID)
        if type(info) == "table" then
            return info.name or "Soulstone", info.iconID or info.originalIconID or SOULSTONE_FALLBACK_ICON
        end
    end

    if GetSpellInfo then
        local name, _, icon = GetSpellInfo(SOULSTONE_SPELL_ID)
        return name or "Soulstone", icon or SOULSTONE_FALLBACK_ICON
    end

    return "Soulstone", SOULSTONE_FALLBACK_ICON
end

local function GetCooldownRemaining()
    if C_Spell and C_Spell.GetSpellCooldown then
        local cooldown = C_Spell.GetSpellCooldown(SOULSTONE_SPELL_ID)
        if type(cooldown) == "table" then
            local duration = cooldown.duration or 0
            local startTime = cooldown.startTime or 0

            if duration <= 0 or startTime <= 0 then
                return 0
            end

            return math.max(0, (startTime + duration) - GetTime())
        end
    end

    if GetSpellCooldown then
        local startTime, duration = GetSpellCooldown(SOULSTONE_SPELL_ID)

        if not startTime or not duration or duration <= 0 or startTime <= 0 then
            return 0
        end

        return math.max(0, (startTime + duration) - GetTime())
    end

    return 0
end

local function GetDemoCooldownRemaining()
    if not state.demoDeadline then
        return 0
    end

    return math.max(0, state.demoDeadline - GetTime())
end

local function GetStatusCooldownRemaining()
    if state.demoMode == "soon" then
        return GetDemoCooldownRemaining()
    end

    return GetCooldownRemaining()
end

local function CancelCooldownTimer()
    if state.cooldownTimer then
        state.cooldownTimer:Cancel()
        state.cooldownTimer = nil
    end
end

local function IsCastingSoulstone()
    local _, _, _, _, _, _, _, _, spellID = UnitCastingInfo("player")
    if spellID == SOULSTONE_SPELL_ID then
        return true
    end

    local _, _, _, _, _, _, _, _, channelSpellID = UnitChannelInfo("player")
    return channelSpellID == SOULSTONE_SPELL_ID
end

local function KnowsSoulstone()
    if C_SpellBook and C_SpellBook.IsSpellKnownOrInSpellBook then
        return C_SpellBook.IsSpellKnownOrInSpellBook(SOULSTONE_SPELL_ID, nil, true)
    end

    if IsPlayerSpell then
        return IsPlayerSpell(SOULSTONE_SPELL_ID)
    end

    return false
end

local function IsWarlock()
    return select(2, UnitClass("player")) == "WARLOCK"
end

local function IsGroupedContextEligible()
    if not IsInGroup() then
        return GetSetting("enableSoloReminder")
    end

    local groupReminderEnabled
    if IsInRaid() then
        groupReminderEnabled = GetSetting("enableRaidReminder")
    else
        groupReminderEnabled = GetSetting("enablePartyReminder")
    end

    if not groupReminderEnabled then
        return false
    end

    if GetSetting("allowGroupReminderOutsideInstances") then
        return true
    end

    return IsInInstance()
end

local function IsEligible()
    return IsWarlock() and KnowsSoulstone() and IsGroupedContextEligible()
end

local function IsRestricted()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() or false
end

local function IsRelevantUnitToken(unit)
    if unit == "player" then
        return true
    end

    if type(unit) ~= "string" then
        return false
    end

    return unit:match("^party%d+$") ~= nil or unit:match("^raid%d+$") ~= nil
end

local function GetUnitLabel(unit)
    local name = UnitName(unit)
    if not name or name == "" then
        return unit
    end

    return string.format("%s (%s)", name, unit)
end

local function ForEachRelevantUnit(callback)
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i

            if UnitExists(unit) and callback(unit) then
                return true
            end
        end

        return false
    end

    if IsInGroup() then
        if UnitExists("player") and callback("player") then
            return true
        end

        for i = 1, GetNumSubgroupMembers() do
            local unit = "party" .. i

            if UnitExists(unit) and callback(unit) then
                return true
            end
        end

        return false
    end

    return UnitExists("player") and callback("player") or false
end

local function GetSoulstoneAura(unit)
    if unit == "player" and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
        local aura = C_UnitAuras.GetPlayerAuraBySpellID(SOULSTONE_SPELL_ID)
        if aura then
            return aura
        end
    end

    if C_UnitAuras and C_UnitAuras.GetUnitAuraBySpellID then
        local aura = C_UnitAuras.GetUnitAuraBySpellID(unit, SOULSTONE_SPELL_ID)
        if aura then
            return aura
        end
    end

    if C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName then
        local spellName = GetSoulstoneInfo()
        if spellName then
            return C_UnitAuras.GetAuraDataBySpellName(unit, spellName, "HELPFUL")
        end
    end

    return nil
end

local function HasOwnedSoulstone(unit)
    local aura = GetSoulstoneAura(unit)
    if not aura or not aura.sourceUnit then
        return false
    end

    if not UnitExists(aura.sourceUnit) then
        return false
    end

    return UnitIsUnit(aura.sourceUnit, "player")
end

local function FindOwnedSoulstoneUnit()
    local ownedUnit

    ForEachRelevantUnit(function(unit)
        if HasOwnedSoulstone(unit) then
            ownedUnit = unit
            return true
        end

        return false
    end)

    return ownedUnit
end

local function SaveBannerPosition()
    if not banner or type(BigSoulstoneReminderDB) ~= "table" then
        return
    end

    local bannerCenterX, bannerCenterY = banner:GetCenter()
    local parentCenterX, parentCenterY = UIParent:GetCenter()

    if not bannerCenterX or not bannerCenterY or not parentCenterX or not parentCenterY then
        return
    end

    BigSoulstoneReminderDB.bannerPosition = {
        point = "CENTER",
        relPoint = "CENTER",
        x = bannerCenterX - parentCenterX,
        y = bannerCenterY - parentCenterY,
    }
end

local function ApplyBannerPosition()
    if not banner then
        return
    end

    local position = GetSetting("bannerPosition")
    if type(position) ~= "table" then
        position = DEFAULT_BANNER_POSITION
    end

    local function AnchorToCenter(offsetX, offsetY)
        banner:ClearAllPoints()
        banner:SetPoint("CENTER", UIParent, "CENTER", offsetX or 0, offsetY or 0)
    end

    local point = position.point or DEFAULT_BANNER_POSITION.point
    local relPoint = position.relPoint or DEFAULT_BANNER_POSITION.relPoint
    local x = position.x or DEFAULT_BANNER_POSITION.x
    local y = position.y or DEFAULT_BANNER_POSITION.y

    if point == "CENTER" and relPoint == "CENTER" then
        AnchorToCenter(x, y)
        return
    end

    banner:ClearAllPoints()
    banner:SetPoint(point, UIParent, relPoint, x, y)

    local bannerCenterX, bannerCenterY = banner:GetCenter()
    local parentCenterX, parentCenterY = UIParent:GetCenter()

    if bannerCenterX and bannerCenterY and parentCenterX and parentCenterY then
        local offsetX = bannerCenterX - parentCenterX
        local offsetY = bannerCenterY - parentCenterY
        AnchorToCenter(offsetX, offsetY)

        if type(BigSoulstoneReminderDB) == "table" then
            BigSoulstoneReminderDB.bannerPosition = {
                point = "CENTER",
                relPoint = "CENTER",
                x = offsetX,
                y = offsetY,
            }
        end
    end
end

local function ResetBannerPosition()
    SetSetting("bannerPosition", CloneValue(DEFAULT_SETTINGS.bannerPosition))

    if banner then
        banner:StopMovingOrSizing()
        ApplyBannerPosition()
    end
end

local function ApplyBannerScale()
    if not banner then
        return
    end

    banner:SetScale(GetSetting("bannerScale") or DEFAULT_SETTINGS.bannerScale)
end

local function ApplyBannerUnlockState()
    if not banner then
        return
    end

    local unlocked = GetSetting("unlockBannerPosition")

    if not unlocked then
        banner:StopMovingOrSizing()
    end

    banner:EnableMouse(unlocked)
end

local function SetBannerVisible(visible, cooldownRemaining)
    if not banner then
        return
    end

    if visible then
        local spellName, spellIcon = GetSoulstoneInfo()
        local titleText

        banner.icon:SetTexture(spellIcon)

        if cooldownRemaining > 0.5 then
            titleText = string.format("%s Ready in %ds", spellName, math.ceil(cooldownRemaining))
            banner.title:SetTextColor(1.00, 0.82, 0.00)
        else
            titleText = string.format("%s Missing", spellName)
            banner.title:SetTextColor(1.00, 0.30, 0.30)
        end

        banner.title:SetText(titleText)
        banner.textContainer:SetWidth(math.ceil(banner.title:GetUnboundedStringWidth()))
        banner.contentContainer:SetWidth(banner.icon:GetWidth() + CONTENT_SPACING + banner.textContainer:GetWidth())
        banner:Show()
        state.lastVisible = true
        state.lastCooldownRemaining = cooldownRemaining
        return
    end

    banner:Hide()
    state.lastVisible = false
    state.lastCooldownRemaining = cooldownRemaining or 0
end

local function GetPreviewLabel(mode)
    if mode == "soon" then
        return "Ready Soon"
    end

    if mode == "missing" then
        return "Missing"
    end

    if mode == "hide" then
        return "Hidden"
    end

    return "Off"
end

local function ApplyDemoMode()
    if state.demoMode == "soon" then
        local remaining = GetDemoCooldownRemaining()

        if remaining <= 0.5 then
            state.demoMode = "missing"
            state.demoDeadline = nil
        else
            state.lastReason = string.format("Preview: Ready Soon (%ds)", math.ceil(remaining))
            state.lastOwnedUnit = nil
            SetBannerVisible(true, remaining)
            ScheduleDemoCooldownRefresh(remaining)
            return true
        end
    end

    if state.demoMode == "missing" then
        CancelCooldownTimer()
        state.lastReason = "Preview: Missing"
        state.lastOwnedUnit = nil
        SetBannerVisible(true, 0)
        return true
    end

    if state.demoMode == "hide" then
        CancelCooldownTimer()
        state.lastReason = "Preview hidden"
        state.lastOwnedUnit = nil
        SetBannerVisible(false, 0)
        return true
    end

    return false
end

local function RefreshState()
    if ApplyDemoMode() then
        DebugState()
        return
    end

    local restricted = IsRestricted()

    if restricted then
        CancelCooldownTimer()
        state.wasRestricted = true
        state.lastReason = "Waiting for the game to show Soulstone details"
        state.lastOwnedUnit = nil
        DebugState()
        return
    end

    state.wasRestricted = false

    if not IsEligible() then
        CancelCooldownTimer()
        state.lastReason = "Reminder off here"
        state.lastOwnedUnit = nil
        SetBannerVisible(false, 0)
        DebugState()
        return
    end

    local ownedUnit = FindOwnedSoulstoneUnit()
    if ownedUnit then
        CancelCooldownTimer()
        state.lastReason = string.format("Soulstone active on %s", GetUnitLabel(ownedUnit))
        state.lastOwnedUnit = ownedUnit
        SetBannerVisible(false, 0)
        DebugState()
        return
    end

    if IsCastingSoulstone() then
        CancelCooldownTimer()
        state.lastReason = "Casting Soulstone"
        state.lastOwnedUnit = nil
        SetBannerVisible(false, 0)
        DebugState()
        return
    end

    local cooldownRemaining = GetCooldownRemaining()
    local soonThreshold = GetSoonThreshold()

    state.lastOwnedUnit = nil

    if cooldownRemaining > soonThreshold then
        state.lastReason = string.format("Soulstone on cooldown (%ds left)", math.ceil(cooldownRemaining))
        ScheduleLiveCooldownRefresh(cooldownRemaining)
        SetBannerVisible(false, cooldownRemaining)
        DebugState()
        return
    end

    if cooldownRemaining > 0.5 then
        state.lastReason = string.format("Soulstone ready soon (%ds left)", math.ceil(cooldownRemaining))
        SetBannerVisible(true, cooldownRemaining)
        ScheduleLiveCooldownRefresh(cooldownRemaining)
        DebugState()
        return
    end

    CancelCooldownTimer()
    state.lastReason = "Soulstone missing"
    SetBannerVisible(true, 0)
    DebugState()
end

QueueRefresh = function(trigger)
    state.lastTrigger = trigger or "unknown"

    if state.refreshPending then
        return
    end

    state.refreshPending = true
    C_Timer.After(0, function()
        state.refreshPending = false
        RefreshState()
    end)
end

local function GetNextDisplayChangeDelay(remaining)
    local displayedSeconds = math.ceil(remaining)
    local nextBoundary = displayedSeconds - 1
    local delay = remaining - nextBoundary

    return math.max(0.01, delay)
end

local function ScheduleCooldownRefresh(delay, trigger)
    CancelCooldownTimer()

    if not delay or delay <= 0 then
        QueueRefresh(trigger)
        return
    end

    state.cooldownTimer = C_Timer.NewTimer(delay, function()
        state.cooldownTimer = nil
        QueueRefresh(trigger)
    end)
end

ScheduleLiveCooldownRefresh = function(remaining)
    local soonThreshold = GetSoonThreshold()

    if remaining <= 0.5 then
        CancelCooldownTimer()
        return
    end

    if remaining > soonThreshold then
        ScheduleCooldownRefresh(remaining - soonThreshold, "cooldown-threshold")
        return
    end

    ScheduleCooldownRefresh(GetNextDisplayChangeDelay(remaining), "cooldown-tick")
end

ScheduleDemoCooldownRefresh = function(remaining)
    if remaining <= 0.5 then
        CancelCooldownTimer()
        return
    end

    ScheduleCooldownRefresh(GetNextDisplayChangeDelay(remaining), "demo-tick")
end

local function CreateBanner()
    local spellName, spellIcon = GetSoulstoneInfo()

    banner = CreateFrame("Frame", addonName .. "Banner", UIParent)
    banner:SetSize(336, 56)
    banner:SetFrameStrata("MEDIUM")
    banner:SetMovable(true)
    banner:SetClampedToScreen(true)
    banner:RegisterForDrag("LeftButton")
    banner:Hide()

    banner:SetScript("OnDragStart", function(self)
        if not GetSetting("unlockBannerPosition") then
            return
        end

        self:StartMoving()
    end)

    banner:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveBannerPosition()
    end)

    banner.background = banner:CreateTexture(nil, "BACKGROUND")
    banner.background:SetAllPoints()
    banner.background:SetColorTexture(0.05, 0.05, 0.07, 0.78)

    banner.highlight = banner:CreateTexture(nil, "BORDER")
    banner.highlight:SetPoint("TOPLEFT", BORDER_THICKNESS, -BORDER_THICKNESS)
    banner.highlight:SetPoint("BOTTOMRIGHT", -BORDER_THICKNESS, BORDER_THICKNESS)
    banner.highlight:SetColorTexture(0.16, 0.16, 0.20, 0.85)

    banner.topBorder = banner:CreateTexture(nil, "ARTWORK")
    banner.topBorder:SetPoint("TOPLEFT")
    banner.topBorder:SetPoint("TOPRIGHT")
    banner.topBorder:SetHeight(BORDER_THICKNESS)
    banner.topBorder:SetColorTexture(0.92, 0.73, 0.20, 0.90)

    banner.bottomBorder = banner:CreateTexture(nil, "ARTWORK")
    banner.bottomBorder:SetPoint("BOTTOMLEFT")
    banner.bottomBorder:SetPoint("BOTTOMRIGHT")
    banner.bottomBorder:SetHeight(BORDER_THICKNESS)
    banner.bottomBorder:SetColorTexture(0.92, 0.73, 0.20, 0.90)

    banner.leftBorder = banner:CreateTexture(nil, "ARTWORK")
    banner.leftBorder:SetPoint("TOPLEFT")
    banner.leftBorder:SetPoint("BOTTOMLEFT")
    banner.leftBorder:SetWidth(BORDER_THICKNESS)
    banner.leftBorder:SetColorTexture(0.92, 0.73, 0.20, 0.90)

    banner.rightBorder = banner:CreateTexture(nil, "ARTWORK")
    banner.rightBorder:SetPoint("TOPRIGHT")
    banner.rightBorder:SetPoint("BOTTOMRIGHT")
    banner.rightBorder:SetWidth(BORDER_THICKNESS)
    banner.rightBorder:SetColorTexture(0.92, 0.73, 0.20, 0.90)

    banner.icon = banner:CreateTexture(nil, "ARTWORK")
    banner.icon:SetSize(ICON_SIZE, ICON_SIZE)
    banner.icon:SetTexture(spellIcon)

    banner.contentContainer = CreateFrame("Frame", nil, banner)
    banner.contentContainer:SetPoint("CENTER")
    banner.contentContainer:SetSize(258, 40)

    banner.icon:SetParent(banner.contentContainer)
    banner.icon:SetPoint("LEFT", banner.contentContainer, "LEFT", 0, 0)

    banner.textContainer = CreateFrame("Frame", nil, banner.contentContainer)
    banner.textContainer:SetPoint("LEFT", banner.icon, "RIGHT", CONTENT_SPACING, 0)
    banner.textContainer:SetPoint("CENTER", banner.contentContainer, "CENTER", 12, 0)
    banner.textContainer:SetSize(200, 40)

    banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    banner.title:SetParent(banner.textContainer)
    banner.title:SetPoint("CENTER", banner.textContainer, "CENTER", 0, 0)
    banner.title:SetJustifyH("CENTER")
    banner.title:SetText(spellName)
    do
        local font, _, flags = banner.title:GetFont()
        banner.title:SetFont(font, TITLE_FONT_SIZE, flags)
    end

    ApplyBannerScale()
    ApplyBannerPosition()
    ApplyBannerUnlockState()
end

local function RoundToStep(value, step)
    if not step or step == 0 then
        return value
    end

    local rounded = math.floor((value / step) + 0.5) * step

    if step >= 1 then
        return math.floor(rounded + 0.5)
    end

    return tonumber(string.format("%.2f", rounded))
end

local function CreateSectionHeader(parent, x, y, titleText, bodyText)
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOPLEFT", x, y)
    title:SetText(titleText)

    if bodyText and bodyText ~= "" then
        local body = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
        body:SetWidth(640)
        body:SetJustifyH("LEFT")
        body:SetText(bodyText)
        return title, body
    end

    return title
end

local function RegisterSettingsRefresher(refresher)
    state.settingsRefreshers[#state.settingsRefreshers + 1] = refresher
end

RefreshSettingsPanel = function()
    for _, refresher in ipairs(state.settingsRefreshers) do
        refresher()
    end
end

local function CreateSettingsCheckbox(parent, x, y, labelText, getter, setter)
    local checkButton = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    checkButton:SetPoint("TOPLEFT", x, y)
    checkButton:SetHitRectInsets(0, -300, 0, 0)
    checkButton:SetScript("OnClick", function(self)
        setter(self:GetChecked())
    end)

    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", checkButton, "RIGHT", 4, 1)
    label:SetWidth(520)
    label:SetJustifyH("LEFT")
    label:SetText(labelText)

    RegisterSettingsRefresher(function()
        checkButton:SetChecked(getter())
    end)

    return checkButton
end

local function CreateSettingsSlider(parent, sliderName, x, y, labelText, minValue, maxValue, step, formatter, getter, setter)
    local slider = CreateFrame("Slider", addonName .. sliderName, parent, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", x, y)
    slider:SetWidth(260)
    slider:SetMinMaxValues(minValue, maxValue)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    local text = _G[slider:GetName() .. "Text"]
    local low = _G[slider:GetName() .. "Low"]
    local high = _G[slider:GetName() .. "High"]

    if text then
        text:SetText(labelText)
    end

    if low then
        low:SetText(formatter(minValue))
    end

    if high then
        high:SetText(formatter(maxValue))
    end

    slider.valueText = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    slider.valueText:SetPoint("LEFT", slider, "RIGHT", 18, 0)

    slider:SetScript("OnValueChanged", function(self, value)
        if self.isRefreshing then
            return
        end

        local roundedValue = RoundToStep(value, step)
        if math.abs(roundedValue - value) > 0.0001 then
            self:SetValue(roundedValue)
            return
        end

        self.valueText:SetText(formatter(roundedValue))
        setter(roundedValue)
    end)

    RegisterSettingsRefresher(function()
        local value = getter()
        slider.isRefreshing = true
        slider:SetValue(value)
        slider.valueText:SetText(formatter(value))
        slider.isRefreshing = false
    end)

    return slider
end

local function CreateSettingsButton(parent, x, y, width, text, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 24)
    button:SetPoint("TOPLEFT", x, y)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function CreateSettingsPanel()
    if not Settings or not Settings.RegisterCanvasLayoutCategory or not Settings.RegisterAddOnCategory then
        return
    end

    state.settingsRefreshers = {}

    local frame = CreateFrame("Frame")
    frame:Hide()

    local scrollFrame = CreateFrame("ScrollFrame", addonName .. "SettingsScrollFrame", frame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -8)
    scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 8)

    local content = CreateFrame("Frame", nil, scrollFrame)
    content:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 16, -8)
    content:SetSize(700, 860)
    scrollFrame:SetScrollChild(content)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Big Soulstone Reminder")

    local description = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    description:SetWidth(640)
    description:SetJustifyH("LEFT")
    description:SetText("A simple Soulstone reminder.")

    CreateSectionHeader(content, 18, -78, "Behavior", "Choose when the reminder shows up and when \"Ready Soon\" starts.")
    CreateSectionHeader(content, 18, -318, "Appearance", "Move the banner and change its size.")
    CreateSectionHeader(content, 18, -522, "Testing", "Preview the banner and turn on extra chat details.")

    CreateSettingsCheckbox(content, 14, -122, "Show While Solo", function()
        return GetSetting("enableSoloReminder")
    end, function(value)
        SetSetting("enableSoloReminder", value)
        QueueRefresh("setting:solo")
    end)

    CreateSettingsCheckbox(content, 14, -148, "Show In Party", function()
        return GetSetting("enablePartyReminder")
    end, function(value)
        SetSetting("enablePartyReminder", value)
        QueueRefresh("setting:party")
    end)

    CreateSettingsCheckbox(content, 14, -174, "Show In Raid", function()
        return GetSetting("enableRaidReminder")
    end, function(value)
        SetSetting("enableRaidReminder", value)
        QueueRefresh("setting:raid")
    end)

    CreateSettingsCheckbox(content, 14, -200, "Show In Open-World Groups", function()
        return GetSetting("allowGroupReminderOutsideInstances")
    end, function(value)
        SetSetting("allowGroupReminderOutsideInstances", value)
        QueueRefresh("setting:open-world")
    end)

    CreateSettingsSlider(content, "SoonThresholdSlider", 24, -252, "Show \"Ready Soon\" At", 10, 60, 1, function(value)
        return string.format("%ds", value)
    end, function()
        return GetSoonThreshold()
    end, function(value)
        SetSetting("soonThreshold", value)
        QueueRefresh("setting:soon-threshold")
    end)

    CreateSettingsCheckbox(content, 14, -362, "Move Banner", function()
        return GetSetting("unlockBannerPosition")
    end, function(value)
        SetSetting("unlockBannerPosition", value)
        ApplyBannerUnlockState()
    end)

    CreateSettingsButton(content, 42, -398, 220, "Reset Banner Position", function()
        ResetBannerPosition()
        RefreshSettingsPanel()
    end)

    CreateSettingsSlider(content, "BannerScaleSlider", 24, -460, "Banner Size", 0.8, 1.5, 0.05, function(value)
        return string.format("%d%%", math.floor((value * 100) + 0.5))
    end, function()
        return GetSetting("bannerScale")
    end, function(value)
        SetSetting("bannerScale", value)
        ApplyBannerScale()
        ApplyBannerPosition()
    end)

    CreateSettingsCheckbox(content, 14, -566, "Extra Chat Details", function()
        return GetSetting("debugLogging")
    end, function(value)
        SetSetting("debugLogging", value)
        state.debugEnabled = value
    end)

    CreateSettingsButton(content, 42, -602, 220, "Preview \"Missing\"", function()
        SetDemoMode("missing", nil, true)
    end)

    CreateSettingsButton(content, 42, -636, 220, "Preview \"Ready Soon\"", function()
        SetDemoMode("soon", 15, true)
    end)

    CreateSettingsButton(content, 42, -670, 220, "Stop Preview", function()
        SetDemoMode(nil, nil, true)
    end)

    CreateSettingsButton(content, 42, -722, 220, "Reset Settings", function()
        BigSoulstoneReminderDB = CloneValue(DEFAULT_SETTINGS)
        state.debugEnabled = BigSoulstoneReminderDB.debugLogging
        SetDemoMode(nil, nil, true)
        ResetBannerPosition()
        ApplyBannerScale()
        ApplyBannerUnlockState()
        RefreshSettingsPanel()
        QueueRefresh("setting:reset")
        Chat("Settings reset.")
    end)

    frame:SetScript("OnShow", function()
        RefreshSettingsPanel()
    end)

    local category = Settings.RegisterCanvasLayoutCategory(frame, "Big Soulstone Reminder")
    Settings.RegisterAddOnCategory(category)
    state.settingsCategory = category
end

local function GetSettingsCategoryID()
    if not state.settingsCategory then
        return nil
    end

    if state.settingsCategory.GetID then
        return state.settingsCategory:GetID()
    end

    return state.settingsCategory.ID
end

local function PrintHelp()
    Chat("Use /bsr to open settings.")
    Chat("Other commands: /bsr help, /bsr status, /bsr refresh, /bsr debug")
    Chat("Preview the banner: /bsr demo missing, /bsr demo soon 15, /bsr demo hide, /bsr demo off")
end

local function PrintStatus()
    local cooldownRemaining = GetStatusCooldownRemaining()
    local eligible = IsEligible()
    local previewLabel = GetPreviewLabel(state.demoMode)

    Chat(string.format("Preview: %s", previewLabel))
    Chat(string.format("Reminder active here: %s", eligible and "Yes" or "No"))
    Chat(string.format("Banner visible: %s", (banner and banner:IsShown()) and "Yes" or "No"))
    Chat(string.format("Soulstone cooldown: %ds", math.ceil(cooldownRemaining)))
    Chat(string.format("\"Ready Soon\" starts at: %ds", GetSoonThreshold()))
    Chat(string.format("Current state: %s", state.lastReason))
end

SetDemoMode = function(mode, cooldownRemaining, suppressChat)
    CancelCooldownTimer()
    state.demoMode = mode
    state.demoDeadline = nil

    if mode == "soon" then
        state.demoDeadline = GetTime() + (cooldownRemaining or 15)
    end

    if not suppressChat then
        if mode then
            Chat(string.format("Preview: %s", GetPreviewLabel(mode)))
        else
            Chat("Preview off.")
        end
    end

    QueueRefresh("slash")
end

OpenSettings = function()
    local categoryID = GetSettingsCategoryID()
    if categoryID and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(categoryID)
        return
    end

    Chat("Settings are unavailable on this client.")
end

local function HandleSlashCommand(input)
    local command, remainder = input:match("^(%S+)%s*(.-)$")
    command = command and command:lower() or ""

    if command == "" or command == "settings" or command == "options" then
        OpenSettings()
        return
    end

    if command == "help" then
        PrintHelp()
        return
    end

    if command == "status" then
        PrintStatus()
        return
    end

    if command == "refresh" then
        Chat("Checking Soulstone again.")
        QueueRefresh("slash")
        return
    end

    if command == "debug" then
        local enabled = not GetSetting("debugLogging")
        SetSetting("debugLogging", enabled)
        state.debugEnabled = enabled
        if RefreshSettingsPanel then
            RefreshSettingsPanel()
        end
        Chat(string.format("Extra chat details %s.", enabled and "on" or "off"))
        QueueRefresh("slash")
        return
    end

    if command == "live" then
        SetDemoMode(nil)
        return
    end

    if command == "demo" then
        local mode, value = remainder:match("^(%S+)%s*(.-)$")
        mode = mode and mode:lower() or ""

        if mode == "missing" then
            SetDemoMode("missing")
            return
        end

        if mode == "soon" then
            local seconds = tonumber(value) or 15
            seconds = math.max(1, math.floor(seconds))
            SetDemoMode("soon", seconds)
            return
        end

        if mode == "hide" then
            SetDemoMode("hide")
            return
        end

        if mode == "off" then
            SetDemoMode(nil)
            return
        end
    end

    PrintHelp()
end

local function RegisterRuntimeEvents()
    ADDON:RegisterEvent("PLAYER_ENTERING_WORLD")
    ADDON:RegisterEvent("GROUP_ROSTER_UPDATE")
    ADDON:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    ADDON:RegisterEvent("SPELLS_CHANGED")
    ADDON:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    ADDON:RegisterEvent("UNIT_AURA")
    ADDON:RegisterEvent("UNIT_SPELLCAST_START")
    ADDON:RegisterEvent("UNIT_SPELLCAST_STOP")
    ADDON:RegisterEvent("UNIT_SPELLCAST_FAILED")
    ADDON:RegisterEvent("UNIT_SPELLCAST_FAILED_QUIET")
    ADDON:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
    ADDON:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    ADDON:RegisterEvent("PLAYER_REGEN_DISABLED")
    ADDON:RegisterEvent("PLAYER_REGEN_ENABLED")
end

local function InitializeAddon()
    if type(BigSoulstoneReminderDB) ~= "table" then
        BigSoulstoneReminderDB = {}
    end

    MigrateSettings(BigSoulstoneReminderDB)
    MergeDefaults(BigSoulstoneReminderDB, DEFAULT_SETTINGS)
    state.debugEnabled = BigSoulstoneReminderDB.debugLogging

    CreateBanner()
    CreateSettingsPanel()
    RegisterRuntimeEvents()

    state.initialized = true
    QueueRefresh("ADDON_LOADED")
end

ADDON:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddonName = ...
        if loadedAddonName ~= addonName then
            return
        end

        ADDON:UnregisterEvent("ADDON_LOADED")
        InitializeAddon()
        return
    end

    if event == "UNIT_AURA" then
        local unit = ...
        if not IsRelevantUnitToken(unit) then
            return
        end

        QueueRefresh(string.format("%s:%s", event, unit))
        return
    end

    if event:match("^UNIT_SPELLCAST_") then
        local unit, _, spellID = ...
        if unit ~= "player" or spellID ~= SOULSTONE_SPELL_ID then
            return
        end

        QueueRefresh(string.format("%s:%s", event, spellID))
        return
    end

    QueueRefresh(event)
end)

ADDON:RegisterEvent("ADDON_LOADED")

SLASH_BIGSOULSTONEREMINDER1 = "/bsr"
SlashCmdList.BIGSOULSTONEREMINDER = HandleSlashCommand
