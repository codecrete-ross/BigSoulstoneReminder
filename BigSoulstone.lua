local addonName = ...

local ADDON = CreateFrame("Frame")

local SOULSTONE_SPELL_ID = 20707
local SOULSTONE_FALLBACK_ICON = 136210
local ACTIONABLE_COOLDOWN_THRESHOLD = 30

local state = {
    refreshPending = false,
    wasRestricted = false,
}

local banner

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
        return true
    end

    local inInstance = IsInInstance()
    return inInstance
end

local function IsEligible()
    return IsWarlock() and KnowsSoulstone() and IsGroupedContextEligible()
end

local function IsRestricted()
    return C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() or false
end

local function IsActionable()
    return GetCooldownRemaining() <= ACTIONABLE_COOLDOWN_THRESHOLD
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

local function HasProvenSoulstone()
    return ForEachRelevantUnit(HasOwnedSoulstone)
end

local function SetBannerVisible(visible, cooldownRemaining)
    if visible then
        local spellName, spellIcon = GetSoulstoneInfo()
        local titleText
        local subtitleText

        banner.icon:SetTexture(spellIcon)

        if cooldownRemaining > 0.5 then
            titleText = string.format("%s Ready Soon", spellName)
            subtitleText = string.format("Ready in %ds", math.ceil(cooldownRemaining))
            banner.title:SetTextColor(1.00, 0.82, 0.00)
        else
            titleText = string.format("%s Missing", spellName)
            subtitleText = "Place Soulstone before combat"
            banner.title:SetTextColor(1.00, 0.30, 0.30)
        end

        banner.title:SetText(titleText)
        banner.subtitle:SetText(subtitleText)
        banner:Show()
        return
    end

    banner:Hide()
end

local function RefreshState()
    local restricted = IsRestricted()

    if restricted then
        state.wasRestricted = true
        return
    end

    state.wasRestricted = false

    if not IsEligible() then
        SetBannerVisible(false, 0)
        return
    end

    if HasProvenSoulstone() then
        SetBannerVisible(false, 0)
        return
    end

    if not IsActionable() then
        SetBannerVisible(false, GetCooldownRemaining())
        return
    end

    SetBannerVisible(true, GetCooldownRemaining())
end

local function QueueRefresh()
    if state.refreshPending then
        return
    end

    state.refreshPending = true
    C_Timer.After(0, function()
        state.refreshPending = false
        RefreshState()
    end)
end

local function CreateBanner()
    local spellName, spellIcon = GetSoulstoneInfo()

    banner = CreateFrame("Frame", addonName .. "Banner", UIParent)
    banner:SetSize(320, 48)
    banner:SetPoint("TOP", UIParent, "TOP", 0, -160)
    banner:SetFrameStrata("MEDIUM")
    banner:EnableMouse(false)
    banner:Hide()

    banner.background = banner:CreateTexture(nil, "BACKGROUND")
    banner.background:SetAllPoints()
    banner.background:SetColorTexture(0.05, 0.05, 0.07, 0.78)

    banner.highlight = banner:CreateTexture(nil, "BORDER")
    banner.highlight:SetPoint("TOPLEFT", 1, -1)
    banner.highlight:SetPoint("BOTTOMRIGHT", -1, 1)
    banner.highlight:SetColorTexture(0.16, 0.16, 0.20, 0.85)

    banner.topBorder = banner:CreateTexture(nil, "ARTWORK")
    banner.topBorder:SetPoint("TOPLEFT")
    banner.topBorder:SetPoint("TOPRIGHT")
    banner.topBorder:SetHeight(1)
    banner.topBorder:SetColorTexture(0.92, 0.73, 0.20, 0.90)

    banner.bottomBorder = banner:CreateTexture(nil, "ARTWORK")
    banner.bottomBorder:SetPoint("BOTTOMLEFT")
    banner.bottomBorder:SetPoint("BOTTOMRIGHT")
    banner.bottomBorder:SetHeight(1)
    banner.bottomBorder:SetColorTexture(0.92, 0.73, 0.20, 0.90)

    banner.leftBorder = banner:CreateTexture(nil, "ARTWORK")
    banner.leftBorder:SetPoint("TOPLEFT")
    banner.leftBorder:SetPoint("BOTTOMLEFT")
    banner.leftBorder:SetWidth(1)
    banner.leftBorder:SetColorTexture(0.92, 0.73, 0.20, 0.90)

    banner.rightBorder = banner:CreateTexture(nil, "ARTWORK")
    banner.rightBorder:SetPoint("TOPRIGHT")
    banner.rightBorder:SetPoint("BOTTOMRIGHT")
    banner.rightBorder:SetWidth(1)
    banner.rightBorder:SetColorTexture(0.92, 0.73, 0.20, 0.90)

    banner.icon = banner:CreateTexture(nil, "ARTWORK")
    banner.icon:SetSize(24, 24)
    banner.icon:SetPoint("LEFT", banner, "LEFT", 12, 0)
    banner.icon:SetTexture(spellIcon)

    banner.title = banner:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    banner.title:SetPoint("TOPLEFT", banner.icon, "TOPRIGHT", 10, 2)
    banner.title:SetJustifyH("LEFT")
    banner.title:SetText(spellName)

    banner.subtitle = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    banner.subtitle:SetPoint("TOPLEFT", banner.title, "BOTTOMLEFT", 0, -2)
    banner.subtitle:SetPoint("RIGHT", banner, "RIGHT", -12, 0)
    banner.subtitle:SetJustifyH("LEFT")
    banner.subtitle:SetTextColor(0.82, 0.82, 0.86)
end

ADDON:SetScript("OnEvent", function(_, event, ...)
    if event == "UNIT_AURA" then
        local unit = ...
        if not IsRelevantUnitToken(unit) then
            return
        end
    end

    QueueRefresh()
end)

CreateBanner()

ADDON:RegisterEvent("PLAYER_ENTERING_WORLD")
ADDON:RegisterEvent("GROUP_ROSTER_UPDATE")
ADDON:RegisterEvent("ZONE_CHANGED_NEW_AREA")
ADDON:RegisterEvent("SPELLS_CHANGED")
ADDON:RegisterEvent("SPELL_UPDATE_COOLDOWN")
ADDON:RegisterEvent("UNIT_AURA")
ADDON:RegisterEvent("PLAYER_REGEN_DISABLED")
ADDON:RegisterEvent("PLAYER_REGEN_ENABLED")
