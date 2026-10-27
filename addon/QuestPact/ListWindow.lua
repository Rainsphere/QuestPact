local _, ns = ...

-- A movable, resizable window holding a scrolling list of pooled rows.
-- Row specs passed to SetRows:
--   { kind = "heading", text, color = {r,g,b} }
--   { kind = "sub",     text, color }
--   { kind = "note",    text }                         -- grey, wraps
--   { kind = "spacer",  h }
--   { kind = "quest",   text, id, right, color, indent,
--     check = { checked, enabled, onClick = function(checked) end },
--     tooltip = function(tt) end, onClick = function(button) end }

local BACKDROP = {
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function RowHeights()
    local size = ns.GetSetting("textSize")
    if size == "large" then return 20, 28, 22 end
    if size == "small" then return 14, 20, 16 end
    return 16, 24, 18 -- quest, heading, sub
end

local function SavePosition(frame, key)
    local p, _, rp, x, y = frame:GetPoint()
    local pos = ns.db.positions[key] or {}
    pos.point, pos.relativePoint, pos.x, pos.y = p, rp, x, y
    pos.w, pos.h = frame:GetWidth(), frame:GetHeight()
    ns.db.positions[key] = pos
end

local function AcquireRow(w, i)
    local row = w.rows[i]
    if row then return row end
    row = CreateFrame("Button", nil, w.child)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row:GetHighlightTexture():SetAlpha(0.35)

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(16, 16)

    row.text = row:CreateFontString(nil, "OVERLAY")
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)

    row.right = row:CreateFontString(nil, "OVERLAY")
    row.right:SetJustifyH("RIGHT")
    row.right:SetPoint("RIGHT", -4, 0)

    row:SetScript("OnEnter", function(self)
        if not self.spec or not self.spec.tooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        self.spec.tooltip(GameTooltip)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row:SetScript("OnClick", function(self, button)
        if self.spec and self.spec.onClick then self.spec.onClick(button) end
    end)
    row.check:SetScript("OnClick", function(self)
        local spec = self:GetParent().spec
        if spec and spec.check and spec.check.onClick then spec.check.onClick(self:GetChecked()) end
    end)

    w.rows[i] = row
    return row
end

local function Layout(w)
    local fontSmall, fontNormal, fontLarge = ns.GetFonts()
    local hQuest, hHeading, hSub = RowHeights()
    local width = math.max(w.scroll:GetWidth(), 200)
    w.child:SetWidth(width)

    local y = 0
    local used = 0
    for _, spec in ipairs(w.specs) do
        if spec.kind == "spacer" then
            y = y + (spec.h or 8)
        else
            used = used + 1
            local row = AcquireRow(w, used)
            row.spec = spec
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -y)
            row:SetPoint("RIGHT", w.child, "RIGHT", 0, 0)
            row.check:Hide()
            row.right:SetText("")
            row.text:ClearAllPoints()
            row:EnableMouse(spec.kind == "quest")

            local c = spec.color
            if spec.kind == "heading" then
                row.text:SetFontObject(fontLarge)
                row.text:SetPoint("LEFT", 2, 0)
                row.text:SetPoint("RIGHT", -4, 0)
                row.text:SetWordWrap(false)
                row.text:SetTextColor(c and c[1] or 0.3, c and c[2] or 1, c and c[3] or 0.3)
                row:SetHeight(hHeading)
            elseif spec.kind == "sub" then
                row.text:SetFontObject(fontNormal)
                row.text:SetPoint("LEFT", 10, 0)
                row.text:SetPoint("RIGHT", -4, 0)
                row.text:SetWordWrap(false)
                row.text:SetTextColor(c and c[1] or 1, c and c[2] or 0.82, c and c[3] or 0)
                row:SetHeight(hSub)
            elseif spec.kind == "note" then
                row.text:SetFontObject(fontSmall)
                row.text:SetPoint("TOPLEFT", 10, 0)
                row.text:SetPoint("RIGHT", -8, 0)
                row.text:SetWordWrap(true)
                row.text:SetTextColor(0.7, 0.7, 0.7)
            else -- quest
                local x = 4 + (spec.indent or 0)
                if spec.check then
                    row.check:ClearAllPoints()
                    row.check:SetPoint("LEFT", x, 0)
                    row.check:SetChecked(spec.check.checked and true or false)
                    row.check:SetEnabled(spec.check.enabled ~= false)
                    row.check:Show()
                    x = x + 20
                end
                row.text:SetFontObject(fontNormal)
                row.text:SetPoint("LEFT", x, 0)
                row.right:SetFontObject(fontSmall)
                row.right:SetText(spec.right or "")
                row.text:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
                row.text:SetWordWrap(false)
                row.text:SetTextColor(c and c[1] or 1, c and c[2] or 1, c and c[3] or 1)
                row:SetHeight(hQuest)
            end
            row.text:SetText(spec.text or "")
            if spec.kind == "note" then
                row.text:SetWidth(width - 18)
                row:SetHeight(math.max(hQuest, row.text:GetStringHeight() + 4))
            end
            row:Show()
            y = y + row:GetHeight() + (spec.kind == "quest" and 1 or 2)
        end
    end
    for i = used + 1, #w.rows do w.rows[i]:Hide() end
    w.child:SetHeight(math.max(y + 4, 1))
end

function ns.CreateListWindow(opts)
    local w = { rows = {}, specs = {} }
    local f = CreateFrame("Frame", opts.name, UIParent, "BackdropTemplate")
    w.frame = f
    f:SetFrameStrata("MEDIUM")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:SetResizable(true)
    f:SetResizeBounds(300, 220)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetBackdrop(BACKDROP)
    f:SetBackdropColor(0, 0, 0, 0.88)
    f:Hide()
    tinsert(UISpecialFrames, opts.name) -- close on Escape

    local pos = ns.db.positions[opts.posKey]
    f:SetSize(pos and pos.w or opts.width or 420, pos and pos.h or opts.height or 360)
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.relativePoint, pos.x, pos.y)
    else
        f:SetPoint("CENTER", opts.offsetX or 0, opts.offsetY or 0)
    end

    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self, opts.posKey)
    end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText(opts.title)
    w.title = title

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)

    -- Area between the title and the list for window-specific controls
    local toolbarHeight = opts.toolbarHeight or 0
    w.toolbar = CreateFrame("Frame", nil, f)
    w.toolbar:SetPoint("TOPLEFT", 12, -32)
    w.toolbar:SetPoint("TOPRIGHT", -12, -32)
    w.toolbar:SetHeight(math.max(toolbarHeight, 1))

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -36 - toolbarHeight)
    scroll:SetPoint("BOTTOMRIGHT", -30, 14)
    w.scroll = scroll

    local child = CreateFrame("Frame", nil, scroll)
    child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    w.child = child

    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        SavePosition(f, opts.posKey)
        Layout(w)
    end)
    f:SetScript("OnSizeChanged", function() if f:IsShown() then Layout(w) end end)

    function w:SetRows(specs)
        self.specs = specs or {}
        Layout(self)
    end

    function w:Relayout() Layout(self) end
    function w:IsShown() return f:IsShown() end
    function w:Show() f:Show() end
    function w:Hide() f:Hide() end

    return w
end

-- Shared quest-row helpers used by both windows

function ns.ObjectiveLines(tt, obj)
    for _, o in ipairs(obj or {}) do
        local text = (o.text and o.text ~= "") and o.text or string.format("%d/%d", o.have or 0, o.need or 0)
        if o.done then
            tt:AddLine("  " .. text, 0.5, 0.5, 0.5)
        else
            tt:AddLine("  " .. text, 1, 1, 1)
        end
    end
end

function ns.ProgressText(q)
    if not q then return "" end
    if q.failed then return "|cffff4040failed|r" end
    if q.ready then return "|cff40ff40ready|r" end
    local have, need = 0, 0
    for _, o in ipairs(q.obj or {}) do
        have = have + math.min(o.have or 0, o.need or 0)
        need = need + (o.need or 0)
    end
    if need == 0 then return "" end
    return string.format("%d/%d", have, need)
end

function ns.QuestMenu(questID, title)
    if not MenuUtil then return end
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        root:CreateTitle(title or ns.QuestTitle(questID))
        local inLog = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(questID)
        if inLog then
            local watched = C_QuestLog.GetQuestWatchType and C_QuestLog.GetQuestWatchType(questID) ~= nil
            root:CreateButton(watched and "Untrack" or "Track", function()
                if watched then C_QuestLog.RemoveQuestWatch(questID) else C_QuestLog.AddQuestWatch(questID) end
            end)
            if QuestLogPushQuest and IsInGroup() then
                root:CreateButton("Share with party", function()
                    C_QuestLog.SetSelectedQuest(questID)
                    QuestLogPushQuest()
                end)
            end
        end
        root:CreateButton("Print quest ID", function()
            ns:Print(string.format("%s: %d", title or ns.QuestTitle(questID), questID))
        end)
    end)
end
