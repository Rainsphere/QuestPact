local _, ns = ...

-- Optional Questie bridge: quest names for IDs we've never seen, plus
-- "can this character take it" checks. Everything degrades to nil without Questie.

local Q = {}
ns.Questie = Q

local db, player
local function Modules()
    if db ~= nil then return db, player end
    db, player = false, false
    if QuestieLoader and QuestieLoader.ImportModule then
        local ok1, qdb = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestieDB")
        local ok2, qp = pcall(QuestieLoader.ImportModule, QuestieLoader, "QuestiePlayer")
        if ok1 and qdb and qdb.QueryQuestSingle then db = qdb end
        if ok2 and qp then player = qp end
    end
    return db, player
end

function Q.Query(questID, field)
    local qdb = Modules()
    if not qdb then return nil end
    local ok, v = pcall(qdb.QueryQuestSingle, questID, field)
    if ok then return v end
end

function Q.Name(questID)
    return Q.Query(questID, "name")
end

function Q.Level(questID)
    return Q.Query(questID, "questLevel")
end

-- Returns false only when Questie positively says this character can't take the quest
function Q.AvailableToMe(questID)
    local qdb, qp = Modules()
    if not qdb or not qp then return true end
    local races = Q.Query(questID, "requiredRaces")
    local classes = Q.Query(questID, "requiredClasses")
    if races and races ~= 0 and qp.HasRequiredRace then
        local ok, has = pcall(qp.HasRequiredRace, races)
        if ok and has == false then return false end
    end
    if classes and classes ~= 0 and qp.HasRequiredClass then
        local ok, has = pcall(qp.HasRequiredClass, classes)
        if ok and has == false then return false end
    end
    return true
end

function Q.IsRepeatable(questID)
    local qdb = Modules()
    if not qdb or not qdb.IsRepeatable then return false end
    local ok, r = pcall(qdb.IsRepeatable, questID)
    return ok and r or false
end

function Q.Loaded()
    return Modules() and true or false
end

-- Best available title for a quest ID
function ns.QuestTitle(questID, known)
    if known and known ~= "" then return known end
    local t = C_QuestLog.GetTitleForQuestID and ns.Safe(C_QuestLog.GetTitleForQuestID(questID))
    return t or Q.Name(questID) or ("Quest #" .. questID)
end
