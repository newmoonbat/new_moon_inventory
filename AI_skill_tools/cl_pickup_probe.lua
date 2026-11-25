--[[ ==========================================================================
    cl_pickup_probe.lua —— 客户端预测 InventoryAddItem 的 OnPickUp 判定
    这个探针加载的是"真实"的 lua/autorun/inventory_sys_item.lua 与
    lua/autorun/client/inventory_cl_init.lua，只把 GMod 运行时换成桩，
    所以 ITEM / ITEM_LIST / table.Copy/Merge 的继承语义都是真的。

    覆盖：
      · OnPickUp 返回 true → 正常写入锚点格 { classname, r }
      · OnPickUp 返回 false → 拒绝，且不留占位格、不刷新锚点缓存
      · 自动找位模式被拒绝 → 整张网格不动
      · 旋转（宽高互换）后被拒绝 → 占位格正确还原
      · OnPickUp 内部能读到与服务端一致的 pos / OWNER
      · move2 的 table.Copy(self) 快照形态同样带出 func

    运行： C:\LuaJIT\luajit.exe cl_pickup_probe.lua
   ========================================================================== ]]

local here = (arg and arg[0] or ""):match("^(.*[\\/])") or ""
if here ~= "" then package.path = here .. "?.lua;" .. package.path end
local T = require("nm_test")

-- ==================== 运行时桩 ====================
SERVER, CLIENT = nil, true
function AddCSLuaFile() end
function istable(v) return type(v) == "table" end
function isstring(v) return type(v) == "string" end
function IsValid(v) return v ~= nil end
function include() end

-- GMod 的 table.Copy / table.Merge 是递归版，必须照抄语义，
-- 否则 ITEM:new 的类继承（container_base 从 item_base 继承 func）就是假的
function table.Copy(t, lookup)
    if type(t) ~= "table" then return t end
    if lookup and lookup[t] then return lookup[t] end
    local copy = {}
    lookup = lookup or {}
    lookup[t] = copy
    for k, v in pairs(t) do copy[table.Copy(k, lookup)] = table.Copy(v, lookup) end
    return setmetatable(copy, debug.getmetatable(t))
end

function table.Merge(dst, src, lookup)
    if type(dst) ~= "table" or type(src) ~= "table" then return dst end
    lookup = lookup or {}
    if lookup[src] and lookup[src] == dst then return dst end
    lookup[src] = dst
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            table.Merge(dst[k], v, lookup)
        else
            dst[k] = table.Copy(v, lookup)
        end
    end
    return dst
end

local playerMeta = {}
function FindMetaTable(name) assert(name == "Player") return playerMeta end
function LocalPlayer() return nil end

net = { Receive = function() end }
concommand = { Add = function() end }

-- 真实实现在 cl_ui.lua 里，这里只记录调用次数
local clearCount = 0
function inventory_cl_clear_anchor_cache() clearCount = clearCount + 1 end
function inventory_cl_sync_containers() end
function inventory_cl_inventory_ui() end

-- ==================== 加载被测文件 ====================
T.load("autorun/inventory_sys_item.lua")            -- 共享层：ITEM / ITEM_LIST / ITEM:OnPickUp
T.load("autorun/client/inventory_cl_init.lua")      -- 被测：meta:InventoryAddItem

-- 探针自己注册一个"永远拒绝拾取"的类，不依赖注册表里 item_test 的当前配置
ITEM:new({ classname = "item_reject", X = 2, Y = 2,
    func = { OnPickUp = function() return false end } })

-- ==================== 假玩家 ====================
local function NewPlayer()
    local p = setmetatable({ sid = "76561190000000000" }, { __index = playerMeta })
    function p:IsPlayer() return true end
    function p:SteamID64() return self.sid end
    function p:message_inventory_full() end
    return p
end
local ply = NewPlayer()

local function FreshGrid(gw, gh)
    local g = { classname = "container_test" }
    for x = 1, gw do
        g[x] = {}
        for y = 1, gh do g[x][y] = false end
    end
    INVENTORY = { [1] = g }
    return g
end

local function Occupied(g)
    local c = 0
    for x = 1, #g do for y = 1, #g[x] do if g[x][y] then c = c + 1 end end end
    return c
end

-- ===== 1) 普通物品（item_base.func.OnPickUp 返回 true）=====
local g = FreshGrid(6, 3)
clearCount = 0
local ok = ply:InventoryAddItem("item_base", 1, 1, 1)
T.eq("item_base 加入成功", ok, true)
T.eq("锚点格 = {classname, r}", g[1][1].classname .. ":" .. tostring(g[1][1].r), "item_base:false")
T.eq("锚点索引失效 1 次", clearCount, 1)
T.eq("占用格数", Occupied(g), 1)

-- ===== 2) OnPickUp 返回 false（item_reject 恒 false，2x2）=====
g = FreshGrid(6, 3)
clearCount = 0
ok = ply:InventoryAddItem("item_reject", 1, 2, 1)
T.eq("item_reject 被拒绝", ok, false)
T.eq("没留下占位格", Occupied(g), 0)
T.eq("(2,1) 仍是空格", g[2][1], false)
T.eq("(3,2) 仍是空格", g[3][2], false)
T.eq("拒绝时不刷新锚点缓存", clearCount, 0)

-- ===== 3) 自动找位被拒绝：整张网格不动 =====
g = FreshGrid(6, 3)
T.eq("自动找位也拒绝", ply:InventoryAddItem("item_reject"), false)
T.eq("网格零改动", Occupied(g), 0)

-- ===== 4) 旋转后被拒绝：宽高互换的占位也要还原 =====
ITEM:new({ classname = "item_pick3", X = 3, Y = 1,
    func = { OnPickUp = function() return false end } })
g = FreshGrid(6, 3)
T.eq("3x1 旋转成 1x3 后被拒绝", ply:InventoryAddItem("item_pick3", 1, 2, 2, true), false)
T.eq("旋转占位格已还原", Occupied(g), 0)

-- ===== 5) OnPickUp 里能读到与服务端一致的 self（pos / OWNER）=====
local seen
ITEM:new({ classname = "item_pick_probe", X = 1, Y = 1, func = {
    OnPickUp = function(self)
        seen = { n = self.pos.n, x = self.pos.x, y = self.pos.y, r = self.pos.r, owner = self.OWNER }
        return true
    end } })
g = FreshGrid(6, 3)
T.eq("probe 加入成功", ply:InventoryAddItem("item_pick_probe", 1, 4, 2), true)
T.eq("OnPickUp 里的 pos", seen.n .. "," .. seen.x .. "," .. seen.y .. "," .. tostring(seen.r), "1,4,2,false")
T.eq("OnPickUp 里的 OWNER", seen.owner, ply.sid)
T.eq("锚点格是表不是 true", type(g[4][2]), "table")

-- ===== 6) 拒绝之后状态干净：同一位置还能放别的 =====
g = FreshGrid(6, 3)
ply:InventoryAddItem("item_reject", 1, 1, 1)
T.eq("之后 item_base 自动找位成功", ply:InventoryAddItem("item_base"), true)
T.eq("落在 (1,1)", type(g[1][1]), "table")

-- ===== 7) move2 的 table.Copy(self) 快照形态同样带出 func =====
g = FreshGrid(6, 3)
local snap = ITEM("item_pick_probe"); snap.pos = nil
T.eq("快照形态加入成功", ply:InventoryAddItem(snap, 1, 5, 3), true)
local snap2 = ITEM("item_reject"); snap2.pos = nil
T.eq("快照形态 item_reject 被拒绝", ply:InventoryAddItem(snap2, 1, 1, 1), false)
T.eq("只剩 probe 那一格", Occupied(g), 1)

T.finish("cl_pickup_probe")
