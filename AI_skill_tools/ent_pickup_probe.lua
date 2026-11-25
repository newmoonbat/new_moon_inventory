--[[ ==========================================================================
    ent_pickup_probe.lua —— 掉落物面板 + PickUp 客户端预测探针
    覆盖 lua/inventory/cl_ui.lua 里新增的部分：
      · DropLayout 的自动打包（列数/行数/宽物品）
      · RefreshDropItems 的 72 单位过滤与未知类过滤
      · DropHitTest 的鼠标命中
      · StartEntityDrag → drag.kind == "ent"，R 不旋转
      · FinishEntityDrag：预测 InventoryAddItem(classname) + 发 PickUp{ index }
      · 没空位 / 不在容器面板上 / 实体已失效 → 不发包
      · 容器面板 Paint 里"自动找位落点"的蓝色预览

    运行： C:\LuaJIT\luajit.exe ent_pickup_probe.lua
   ========================================================================== ]]

local here = (arg and arg[0] or ""):match("^(.*[\\/])") or ""
if here ~= "" then package.path = here .. "?.lua;" .. package.path end
local T = require("nm_test")

local log = { tex = {}, rect = {}, colors = {}, net = nil }

-- ==================== GMod API 桩 ====================
KEY_R, KEY_ESCAPE, KEY_D = 45, 11, 32
MOUSE_LEFT, MOUSE_RIGHT = 1, 2
LEFT, TOP = 3, 5

function ScrW() return 1920 end
function ScrH() return 1080 end
local PADY = 1080 * 0.005   -- 容器页内上下留白（= ScrH()*0.01 的一半）
function Color(r, g, b, a) return { r = r, g = g, b = b, a = a } end
function IsValid(v) return v ~= nil and v ~= false end
function Material(p) return { IsError = function() return false end, path = p } end

surface = {
    CreateFont = function() end,
    SetMaterial = function() end,
    SetFont = function() end,
    SetDrawColor = function(r, g, b, a) log.colors[#log.colors + 1] = { r, g, b, a } end,
    DrawRect = function(x, y, w, h)
        log.rect[#log.rect + 1] = { x = x, y = y, w = w, h = h, color = log.colors[#log.colors] }
    end,
    DrawTexturedRect = function(x, y, w, h)
        log.tex[#log.tex + 1] = { kind = "rect", x = x, y = y, w = w, h = h }
    end,
    DrawTexturedRectRotated = function(cx, cy, w, h, a)
        log.tex[#log.tex + 1] = { kind = "rot", cx = cx, cy = cy, w = w, h = h, a = a }
    end,
    GetTextSize = function(t) return #t * 5, 10 end,
}
local texts = {}
draw = { RoundedBox = function() end, SimpleText = function(t) texts[#texts + 1] = t end }
render = { SetScissorRect = function() end }

local keys, mouse, ctrl = {}, false, false
input = {
    IsKeyDown = function(k) return keys[k] == true end,
    IsMouseDown = function() return mouse end,
    IsControlDown = function() return ctrl end,
}

net = {
    Start = function(n) log.net = { name = n } end,
    WriteString = function(s) log.net.op = s end,
    WriteTable = function(t) log.net.tbl = t end,
    SendToServer = function() log.net.sent = true end,
}

-- 极简 DPanel：几何 API 真实（ScreenToLocal/LocalToScreen），其余空实现
local function NewPanel(kind, parent)
    local p = { _kind = kind, _parent = parent, _w = 0, _h = 0, _sx = 0, _sy = 0 }
    setmetatable(p, { __index = {
        GetWide = function(s) return s._w end,
        GetTall = function(s) return s._h end,
        SetWide = function(s, v) s._w = v end,
        SetTall = function(s, v) s._h = v end,
        SetSize = function(s, w, h) s._w, s._h = w, h end,
        GetParent = function(s) return s._parent end,
        SetParent = function(s, v) s._parent = v end,
        ScreenToLocal = function(s, mx, my) return mx - s._sx, my - s._sy end,
        LocalToScreen = function(s, lx, ly) return lx + s._sx, ly + s._sy end,
        SetPos = function(s, vx, vy) s._x, s._y = vx, vy end,
        SetZPos = function() end,
        Dock = function() end,
        DockMargin = function(s, l, t, r, b) s._dm = { l = l, t = t, r = r, b = b } end,
        SetMouseInputEnabled = function() end, SetKeyboardInputEnabled = function() end,
        SetDepressImage = function() end, SetCursor = function() end,
        SetImage = function() end, SetVisible = function() end,
        SetText = function() end, SetFont = function() end,
        MakePopup = function() end, Remove = function() end, Close = function() end,
        Center = function() end, SetTitle = function() end,
        SetDraggable = function() end, ShowCloseButton = function() end,
        InvalidateLayout = function() end,
        AddItem = function() end,
        Add = function(s, k) return NewPanel(k, s) end,
    } })
    return p
end

local hovered, created = nil, {}
vgui = {
    GetHoveredPanel = function() return hovered end,
    Create = function(kind, parent)
        local p = NewPanel(kind, parent)
        created[#created + 1] = p
        return p
    end,
}

local thinkFn
hook = { Add = function(name, _, fn) if name == "Think" then thinkFn = fn end end }

local mouseX, mouseY = 0, 0
gui = { MouseX = function() return mouseX end, MouseY = function() return mouseY end }

-- ==================== 实体与玩家 ====================
-- 向量桩：只需要 减法 + LengthSqr（RefreshDropItems 用它算 72 单位距离）
local VecMT = {}
VecMT.__index = VecMT
VecMT.__sub = function( a, b )
    return setmetatable( { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, VecMT )
end
function VecMT:LengthSqr()
    return self.x * self.x + self.y * self.y + self.z * self.z
end
local function Vec( x, y, z ) return setmetatable( { x = x, y = y, z = z }, VecMT ) end

local curTime = 100
function CurTime() return curTime end

local nextIndex = 100
local function NewEnt(classname, pos)
    local e = {
        _class = "prop_item", _itemclass = classname, _pos = pos, _index = nextIndex,
        _nw = classname and { ITEMclass = classname } or {},
    }
    nextIndex = nextIndex + 1
    function e:GetNWString(k, d) return self._nw[k] or d or "" end
    function e:GetPos() return self._pos end
    function e:EntIndex() return self._index end
    return e
end

local world = {}
ents = {
    FindByClass = function(cls)
        local out = {}
        for _, e in ipairs(world) do
            if e._class == cls then out[#out + 1] = e end
        end
        return out
    end,
}

-- 假玩家：InventoryValid 用与服务端同构的"自动找第一个空位"
local function NewPlayer()
    local p = { pos = Vec( 0, 0, 0 ), sid = "76561190000000000", added = 0, fullmsg = 0 }
    function p:IsPlayer() return true end
    function p:SteamID64() return self.sid end
    function p:GetPos() return self.pos end
    function p:message_inventory_full() self.fullmsg = self.fullmsg + 1 end

    function p:InventoryValid(classname, n, x, y, r)
        local def = ITEM_LIST[classname]
        if not def then return false end
        r = r and true or false
        local w, h = def.X or 1, def.Y or 1
        if r then w, h = h, w end

        if n and x and y then
            local grid = INVENTORY[n]
            if not grid then return false end
            for yy = y, y + h - 1 do
                for xx = x, x + w - 1 do
                    if not grid[xx] or grid[xx][yy] then return false end
                end
            end
            return n, x, y, r
        end

        for i = 1, #INVENTORY do
            local grid = INVENTORY[i]
            local gw, gh = #grid, #grid[1]
            if gw >= w and gh >= h then
                for py = 1, gh - h + 1 do
                    for px = 1, gw - w + 1 do
                        local free = true
                        for yy = py, py + h - 1 do
                            for xx = px, px + w - 1 do
                                if grid[xx][yy] then free = false break end
                            end
                            if not free then break end
                        end
                        if free then return i, px, py, r end
                    end
                end
            end
        end
        return false
    end

    -- 与服务端一致：自动找位；OnPickUp 由被测代码里的真 ITEM 处理（此处用桩简化）
    function p:InventoryAddItem(classname, n, x, y, r)
        if self.reject and self.reject[classname] then return false end
        local rn, rx, ry = self:InventoryValid(classname, n, x, y, r)
        if not rn then self:message_inventory_full() return false end
        local def = ITEM_LIST[classname]
        local w, h = def.X or 1, def.Y or 1
        for xx = rx, rx + w - 1 do
            for yy = ry, ry + h - 1 do
                INVENTORY[rn][xx][yy] = true
            end
        end
        INVENTORY[rn][rx][ry] = { classname = classname, r = false }
        self.added = self.added + 1
        return true
    end

    return p
end

local ply = NewPlayer()
function LocalPlayer() return ply end

-- ==================== 物品表 / 背包 ====================
ITEM_LIST = {
    item_1x1 = { X = 1, Y = 1, icon = "1" },
    item_2x2 = { X = 2, Y = 2, icon = "2" },
    item_3x1 = { X = 3, Y = 1, icon = "3" },
}

function ITEM(classname)
    return { classname = classname, pos = nil,
             move2 = function() return true end }
end

local GW, GH = 6, 3
local function EmptyGrid()
    local g = { classname = "container_base" }
    for x = 1, GW do
        g[x] = {}
        for y = 1, GH do g[x][y] = false end
    end
    return g
end
INVENTORY = { [1] = EmptyGrid() }

-- ==================== 加载被测文件 ====================
T.load_with("inventory/cl_ui.lua", [[
_G.__PROBE = {
    DropLayout = DropLayout, DropView = DropView, DropHitTest = DropHitTest,
    PICKUP_RANGE = PICKUP_RANGE,
    DropItems = DropItems, RefreshDropItems = RefreshDropItems,
    PredictPickupSlot = PredictPickupSlot, CanPredictPickup = CanPredictPickup,
    StartEntityDrag = StartEntityDrag, FinishEntityDrag = FinishEntityDrag,
    TryPickupEntity = TryPickupEntity,
    CancelDrag = CancelDrag, StartDrag = StartDrag, RotateDrag = RotateDrag,
    DragFootprint = DragFootprint, CreateDropPanel = CreateDropPanel,
    get_drag = function() return drag end,
    get_picked = function() return picked_ents end,
    get_drop_board = function() return drop_board end,
    set_frame = function(f) inv_frame = f end,
    set_scroll = function(s) inv_scroll = s end,
}
]])
local P = _G.__PROBE

-- 建一个真实容器面板（Paint / PerformLayout 都是被测代码）
P.set_scroll(NewPanel("DScrollPanel"))
inventory_cl_sync_containers()
local cp
for _, p in ipairs(created) do
    if p.ContainerIndex == 1 then cp = p end
end
assert(cp, "容器面板没有创建")
cp._w, cp._h = 484, GH * 40
cp._sx, cp._sy = 100, 50
cp.PerformLayout(cp, cp._w, cp._h)
P.set_frame(cp)

local cell = cp.NMCell
local offsetX = cp.NMOffsetX
T.ok("容器格宽 = CellMax 与可用宽取的较小值", cell == math.min(ScrH() * 0.8 * 0.05, (484 - 4) / (GW + 2)), "cell=" .. cell)
T.eq("容器左侧图标区 = 2 格", offsetX, cell * 2)

local function ResetWorld()
    world = {}
    INVENTORY = { [1] = EmptyGrid() }
    ply.added, ply.fullmsg, ply.reject = 0, 0, {}
    log.net = nil
    hovered = nil
end

local function GridUsed(g)
    local c = 0
    for x = 1, #g do for y = 1, #g[x] do if g[x][y] then c = c + 1 end end end
    return c
end

-- ===== 1) DropLayout：3 个物品自动打包 =====
do
    local items = {
        { def = ITEM_LIST.item_1x1 },
        { def = ITEM_LIST.item_2x2 },
        { def = ITEM_LIST.item_3x1 },
    }
    local cols, c, rows, slots = P.DropLayout( 484, items )
    T.ok("列数 >= 3（容纳 3x1）", cols >= 3, "cols=" .. cols)
    T.eq("三件都排上了", #slots, 3)
    T.eq("1x1 在 (1,1)", slots[1].x .. "," .. slots[1].y, "1,1")
    T.eq("2x2 让开 (1,1) 后的位置", slots[2].x .. "," .. slots[2].y, "2,1")
    T.ok("总行数 = 2", rows == 2, "rows=" .. rows)
    T.ok("格宽不超过 CellMax", c <= 44, "cell=" .. c)
end

-- ===== 2) 72 单位过滤 =====
do
    ResetWorld()
    ply.pos = Vec( 0, 0, 0 )
    local near1 = NewEnt("item_1x1", Vec( 0, 0, 50 ) )    -- 50 单位：能捡
    local near2 = NewEnt("item_2x2", Vec( 60, 0, 0 ) )    -- 60 单位：能捡
    local far   = NewEnt("item_1x1", Vec( 0, 0, 150 ) )   -- 150 单位：超出
    local unk   = NewEnt("item_nope", Vec( 0, 0, 10 ) )   -- 未注册类
    world = { near1, near2, far, unk }

    local list = P.RefreshDropItems()
    T.eq("只保留 72 单位内已注册的物品", #list, 2)
    T.eq("第一件", list[1].classname, "item_1x1")
    T.eq("第二件", list[2].classname, "item_2x2")
end

-- ===== 2b) 客户端拾取半径必须与服务端 PickUp 的阈值一致 =====
do
    local sf = assert(io.open(T.root() .. "autorun/server/inventory_sys_inventory.lua", "rb"))
    local src = sf:read("*a")
    sf:close()
    local serverSqr = tonumber(src:match("DistToSqr%s*%(%s*entpos%s*%)%s*<=%s*(%d+)"))
    T.ok("服务端 PickUp 的阈值能解析出来", serverSqr ~= nil, "serverSqr=" .. tostring(serverSqr))
    T.eq("客户端拾取半径² = 服务端阈值", P.PICKUP_RANGE ^ 2, serverSqr)
end

-- ===== 3) DropHitTest 命中 + 网格居中 =====
do
    local items = { { def = ITEM_LIST.item_1x1 }, { def = ITEM_LIST.item_2x2 } }
    local BW, BH = 484, 400
    local cols, c, rows, slots, drawRows, ox, oy = P.DropView( BW, BH, items )

    -- 水平居中：左右留白相等
    local gw = cols * c
    T.near("网格水平居中", ox, ( BW - gw ) * 0.5 )
    T.near("左右留白相等", ox, BW - ( ox + gw ) )
    T.ok("网格不超出面板", ox >= 0 and ox + gw <= BW + 0.01, "ox=" .. ox .. " gw=" .. gw)
    T.ok("网格不压下标题行", oy >= c, "oy=" .. oy .. " titleH=" .. c)
    T.ok("物品少时行数补满可视区域", drawRows > rows, "drawRows=" .. drawRows .. " rows=" .. rows)

    -- 第 1 件在 (1,1)，取它格心
    local mx = ox + ( 1 - 1 ) * c + c * 0.5
    local my = oy + ( 1 - 1 ) * c + c * 0.5
    T.eq("命中第 1 件", P.DropHitTest( items, slots, c, ox, oy, mx, my), 1)

    local mx2 = ox + ( slots[2].x - 1 ) * c + c * 0.5
    local my2 = oy + ( slots[2].y - 1 ) * c + c * 0.5
    T.eq("命中第 2 件", P.DropHitTest( items, slots, c, ox, oy, mx2, my2 ), 2)
    T.eq("标题区域不命中", P.DropHitTest( items, slots, c, ox, oy, mx, c * 0.5 ), nil)
end

-- ===== 4) StartEntityDrag + R 不旋转 =====
do
    ResetWorld()
    local e = NewEnt("item_1x1", Vec( 0, 0, 10 ) )
    world = { e }
    P.RefreshDropItems()

    P.StartEntityDrag( { ent = e, classname = "item_1x1", def = ITEM_LIST.item_1x1 }, 40 )
    local d = P.get_drag()
    T.eq("drag.kind", d and d.kind, "ent")
    T.eq("drag.ent 指向实体", d and d.ent, e)
    T.eq("初始不旋转", d and d.rot, false)

    -- Think 里按住 R：实体拖拽不应该翻转朝向
    keys[KEY_R] = true
    mouse = true
    hovered = cp
    thinkFn()
    T.eq("按住 R 实体不旋转", P.get_drag() and P.get_drag().rot, false)
    keys[KEY_R] = nil

    P.CancelDrag()
    T.eq("取消后 drag 清空", P.get_drag(), nil)
end

-- ===== 5) FinishEntityDrag：预测 + 发包 =====
do
    ResetWorld()
    local e = NewEnt("item_1x1", Vec( 0, 0, 10 ) )
    world = { e }
    P.RefreshDropItems()

    local pn, px, py = P.PredictPickupSlot("item_1x1")
    T.eq("预测落点 = 自动找位", pn .. "," .. px .. "," .. py, "1,1,1")

    hovered = cp                                     -- 鼠标在背包面板上
    P.StartEntityDrag( { ent = e, classname = "item_1x1", def = ITEM_LIST.item_1x1 }, 40 )
    mouse = false
    log.net = nil
    thinkFn()                                        -- 松手

    T.eq("Move2/PickUp 已发送", log.net and log.net.sent, true)
    T.eq("op = PickUp", log.net and log.net.op, "PickUp")
    T.eq("index = 实体索引", log.net and log.net.tbl.index, e._index)
    T.eq("预测写入了一格", GridUsed(INVENTORY[1]), 1)
    T.eq("落在 (1,1)", INVENTORY[1][1][1].classname, "item_1x1")
    T.eq("实体被临时隐藏", P.DropItems() and #P.DropItems(), 0)

    -- 隐藏过期后重新出现（服务端可能拒绝了）
    curTime = curTime + 5
    T.eq("隐藏过期后重新出现", #P.DropItems(), 1)
end

-- ===== 6) 背包放不下 → 不发包、不写入 =====
do
    ResetWorld()
    for x = 1, GW do for y = 1, GH do INVENTORY[1][x][y] = true end end  -- 塞满
    local e = NewEnt("item_2x2", Vec( 0, 0, 10 ) )
    world = { e }
    P.RefreshDropItems()

    T.eq("没有空位时预测返回 false", P.PredictPickupSlot("item_2x2"), false)

    hovered = cp
    P.StartEntityDrag( { ent = e, classname = "item_2x2", def = ITEM_LIST.item_2x2 }, 40 )
    mouse = false
    log.net = nil
    thinkFn()

    T.eq("放不下不发包", log.net, nil)
    T.eq("背包没被改动", GridUsed(INVENTORY[1]), GW * GH)
end

-- ===== 7) 不在容器面板上松手 → 取消 =====
do
    ResetWorld()
    local e = NewEnt("item_1x1", Vec( 0, 0, 10 ) )
    world = { e }
    P.RefreshDropItems()

    hovered = nil                                    -- 空白处
    P.StartEntityDrag( { ent = e, classname = "item_1x1", def = ITEM_LIST.item_1x1 }, 40 )
    mouse = false
    log.net = nil
    thinkFn()

    T.eq("空白处松手不发包", log.net, nil)
    T.eq("背包没被改动", GridUsed(INVENTORY[1]), 0)
    T.eq("drag 已清空", P.get_drag(), nil)
end

-- ===== 8) OnPickUp 拒绝（模拟）→ 不发包 =====
do
    ResetWorld()
    ply.reject = { item_2x2 = true }
    local e = NewEnt("item_2x2", Vec( 0, 0, 10 ) )
    world = { e }
    P.RefreshDropItems()

    hovered = cp
    P.StartEntityDrag( { ent = e, classname = "item_2x2", def = ITEM_LIST.item_2x2 }, 40 )
    mouse = false
    log.net = nil
    thinkFn()

    T.eq("预测被拒 → 不发包", log.net, nil)
    T.eq("背包没被改动", GridUsed(INVENTORY[1]), 0)
end

-- ===== 9) 拖动过程中实体被删除 → 不发包 =====
do
    ResetWorld()
    local e = NewEnt("item_1x1", Vec( 0, 0, 10 ) )
    world = { e }
    P.RefreshDropItems()

    hovered = cp
    P.StartEntityDrag( { ent = e, classname = "item_1x1", def = ITEM_LIST.item_1x1 }, 40 )
    P.get_drag().ent = nil                           -- 模拟实体没了
    mouse = false
    log.net = nil
    thinkFn()

    T.eq("实体失效不发包", log.net, nil)
end

-- ===== 10) 容器面板 Paint：预测落点的蓝色预览 =====
do
    ResetWorld()
    hovered = cp
    -- item_2x2 会落到 (1,1)
    P.StartEntityDrag( { ent = NewEnt("item_2x2", Vec( 0, 0, 10 ) ),
                         classname = "item_2x2", def = ITEM_LIST.item_2x2 }, 40 )

    log.rect, log.colors, log.tex = {}, {}, {}
    cp.Paint(cp, cp._w, cp._h)

    local found
    for _, r in ipairs(log.rect) do
        if r.color and r.color[1] == 120 and r.color[2] == 200 then found = r end
    end
    T.ok("画了蓝色落点预览", found ~= nil)
    if found then
        T.eq("预览 X = 自动找位 (1,1)", found.x, offsetX + 2)
        T.eq("预览 Y = 自动找位 (1,1)", found.y, PADY + 2)
        T.eq("预览尺寸 = 2x2 格", found.w .. "x" .. found.h, (cell * 2 - 4) .. "x" .. (cell * 2 - 4))
    end

    P.CancelDrag()
end

-- ===== 11) 没空位时预览为红色 =====
do
    ResetWorld()
    for x = 1, GW do for y = 1, GH do INVENTORY[1][x][y] = true end end
    hovered = cp
    mouseX, mouseY = cp._sx + offsetX + 2 + cell * 0.5, cp._sy + PADY + 2 + cell * 0.5   -- 第 1 格
    P.StartEntityDrag( { ent = NewEnt("item_1x1", Vec( 0, 0, 10 ) ),
                         classname = "item_1x1", def = ITEM_LIST.item_1x1 }, 40 )

    log.rect, log.colors, log.tex = {}, {}, {}
    cp.Paint(cp, cp._w, cp._h)

    local red
    for _, r in ipairs(log.rect) do
        if r.color and r.color[1] == 230 and r.color[2] == 80 then red = r end
    end
    T.ok("背包满时画红色预览", red ~= nil)
    if red then T.eq("红框在鼠标所在格", red.x, offsetX + 2) end

    P.CancelDrag()
end

-- ===== 12) 整窗 UI 冒烟：面板位置 / 渲染 / 从面板拖出 =====
do
    ResetWorld()
    created = {}
    inventory_cl_inventory_ui()                     -- 建整个界面（含掉落物面板）

    local board = P.get_drop_board()
    T.ok("掉落物面板已创建", board ~= nil)
    assert(board, "掉落物面板没有创建")

    -- 版面：右侧预留区的下 60%
    local PANEL_W, PANEL_H = ScrW() * 0.95, ScrH() * 0.8
    local invScroll, scrollPanel
    for _, p in ipairs(created) do
        if p._kind == "DScrollPanel" then
            if p._dm then invScroll = p                       -- 容器区（有 DockMargin）
            elseif p._x then scrollPanel = p end              -- 掉落物面板（有 SetPos）
        end
    end
    T.ok("找到掉落物滚动容器", scrollPanel ~= nil)
    T.ok("找到容器区滚动容器", invScroll ~= nil)
    if scrollPanel and invScroll then
        -- 不写死比例：用容器区的实际右边缘反推，方便随时调 RESERVE_RIGHT / DROP_GAP
        local invRight = invScroll._dm.l + invScroll._w
        local gapL = scrollPanel._x - invRight
        local gapR = PANEL_W - ( scrollPanel._x + scrollPanel._w )

        T.ok("与左侧容器面板之间有间隙", gapL > 0, "gapL=" .. gapL)
        T.near("两侧留白相等", gapL, gapR)
        T.near("面板顶部 = 右侧区域的 40% 处", scrollPanel._y, PANEL_H * 0.02 + (PANEL_H - PANEL_H * 0.02 - PANEL_H * 0.009) * 0.4)
        T.near("面板高度 = 右侧区域的 55%", scrollPanel._h,
            (PANEL_H - PANEL_H * 0.02 - PANEL_H * 0.009) * 0.55)
        T.near("面板底边 = 顶部 + 55% 区域高", scrollPanel._y + scrollPanel._h,
            scrollPanel._y + (PANEL_H - PANEL_H * 0.02 - PANEL_H * 0.009) * 0.55)
    end

    -- 面板渲染 + 布局不报错
    board._w, board._h = 600, 100
    board._sx, board._sy = 1200, 360
    board.PerformLayout(board, board._w, board._h)
    T.ok("面板高度按内容自适应", board._h > 0, "tall=" .. board._h)

    local e = NewEnt("item_1x1", Vec( 0, 0, 10 ))
    world = { e }
    P.RefreshDropItems()
    board.PerformLayout(board, board._w, board._h)

    log.rect, log.colors, log.tex = {}, {}, {}
    board.Paint(board, board._w, board._h)
    T.ok("掉落实体在面板上画了图标", #log.tex >= 1, "tex=" .. #log.tex)

    -- 在面板上左键按住第 1 件
    local _, bcell, _, slots, _, box, boy = P.DropView(board:GetWide(), board:GetTall(), P.DropItems())
    mouseX = board._sx + box + (slots[1].x - 1) * bcell + bcell * 0.5
    mouseY = board._sy + boy + (slots[1].y - 1) * bcell + bcell * 0.5
    hovered = board
    board.OnMousePressed(board, MOUSE_LEFT)

    local d = P.get_drag()
    T.eq("从面板左键起拖", d and d.kind, "ent")
    T.eq("起拖的是那个实体", d and d.ent, e)

    -- 松手在容器面板上 → 预测 + 发包
    local cp2
    for _, p in ipairs(created) do
        if p.ContainerIndex == 1 then cp2 = p end
    end
    assert(cp2, "容器面板没有创建")
    cp2._w, cp2._h = 484, GH * 40
    cp2._sx, cp2._sy = 100, 50
    cp2.PerformLayout(cp2, cp2._w, cp2._h)

    -- 容器页内部上下留白：每页总高增加 ScrH()*0.01（上下各一半）
    local dm = cp2._dm or {}
    T.eq("页面上边距为 0（留白在页内）", dm.t or 0, 0)
    T.near("页面下边距仍是 PanelH()*0.01", dm.b or -1, ScrH() * 0.8 * 0.01)

    local wantTall = math.max(GH, 3) * cell + ScrH() * 0.01
    T.near("每页总高 = 内容高 + 1% 屏幕高", cp2:GetTall(), wantTall)

    INVENTORY = { [1] = EmptyGrid() }
    hovered = cp2
    mouseX, mouseY = cp2._sx + offsetX + 2 + cell * 0.5, cp2._sy + PADY + 2 + cell * 0.5
    mouse = false
    log.net = nil
    thinkFn()

    T.eq("整窗流程下发出 PickUp", log.net and log.net.op, "PickUp")
    T.eq("index 正确", log.net and log.net.tbl.index, e._index)

    -- ---------- 12a) 面板始终铺满可视区域 ----------
    T.ok("物品少时面板高度 = 可视高度（铺满）", math.abs(board:GetTall() - scrollPanel._h) < 1,
        "tall=" .. board:GetTall() .. " vis=" .. scrollPanel._h)

    board.Paint(board, board:GetWide(), board:GetTall())
    local _, cellNow, _, _, drawRowsNow = P.DropView(board:GetWide(), board:GetTall(), P.DropItems())
    local visRows = drawRowsNow
    T.ok("可视区域至少能铺 8 行格子", visRows >= 8, "visRows=" .. visRows)

    -- ---------- 12a2) 网格整体居中 + 不再有"没有可拾取物品"提示 ----------
    world = {}
    P.RefreshDropItems()
    board.PerformLayout(board, board:GetWide(), board:GetTall())

    log.rect, log.colors, log.tex, texts = {}, {}, {}, {}
    board.Paint(board, board:GetWide(), board:GetTall())

    local leftmost, rightmost
    for _, r in ipairs(log.rect) do
        if math.abs(r.w - (cellNow - 2)) < 0.01 then             -- 空格底板
            if not leftmost or r.x < leftmost then leftmost = r.x end
            if not rightmost or r.x + r.w > rightmost then rightmost = r.x + r.w end
        end
    end
    T.ok("画出了空格底板", leftmost ~= nil)
    if leftmost then
        local bw = board:GetWide()
        T.ok("左右留白相等（网格居中）", math.abs(leftmost - (bw - rightmost)) <= 2,
            "left=" .. leftmost .. " right=" .. (bw - rightmost))
    end

    local hasHint = false
    for _, t in ipairs(texts) do
        if tostring(t):find("没有") then hasHint = true end
    end
    T.eq("没有物品时不再画提示文字", hasHint, false)
    T.eq("只保留标题文字", #texts, 1)

    -- ---------- 12b) 掉落物更多时面板延长（可滚动） ----------
    local many = {}
    for i = 1, 200 do
        many[i] = NewEnt("item_1x1", Vec(0, 0, 5))
    end
    world = many
    P.RefreshDropItems()
    board.PerformLayout(board, board:GetWide(), board:GetTall())
    T.ok("掉落物多时面板变高（超出可视区域 → 滚动）", board:GetTall() > scrollPanel._h,
        "tall=" .. board:GetTall() .. " vis=" .. scrollPanel._h)

    -- ---------- 12c) Ctrl + 左键直接捡起 ----------
    world = { NewEnt("item_1x1", Vec(0, 0, 5)) }
    P.RefreshDropItems()
    P.CancelDrag()
    local e2 = world[1]
    local _, c2, _, s2, _, ox2, oy2 = P.DropView(board:GetWide(), board:GetTall(), P.DropItems())
    mouseX = board._sx + ox2 + (s2[1].x - 1) * c2 + c2 * 0.5
    mouseY = board._sy + oy2 + (s2[1].y - 1) * c2 + c2 * 0.5
    hovered = board
    INVENTORY = { [1] = EmptyGrid() }
    log.net = nil
    ctrl = true
    board.OnMousePressed(board, MOUSE_LEFT)
    ctrl = false

    T.eq("Ctrl+左键直接发 PickUp", log.net and log.net.op, "PickUp")
    T.eq("Ctrl+左键不经拖拽", P.get_drag(), nil)
    T.eq("Ctrl+左键已预测入库", GridUsed(INVENTORY[1]), 1)
    T.eq("实体索引正确", log.net and log.net.tbl.index, e2._index)

    -- ---------- 12d) 不带 Ctrl 仍然起拖、不立即发包 ----------
    world = { NewEnt("item_1x1", Vec(0, 0, 5)) }
    P.RefreshDropItems()
    P.CancelDrag()
    INVENTORY = { [1] = EmptyGrid() }
    local _, c3, _, s3, _, ox3, oy3 = P.DropView(board:GetWide(), board:GetTall(), P.DropItems())
    mouseX = board._sx + ox3 + (s3[1].x - 1) * c3 + c3 * 0.5
    mouseY = board._sy + oy3 + (s3[1].y - 1) * c3 + c3 * 0.5
    hovered = board
    log.net = nil
    board.OnMousePressed(board, MOUSE_LEFT)
    T.eq("普通左键起拖", P.get_drag() and P.get_drag().kind, "ent")
    T.eq("普通左键不立即发包", log.net, nil)
    P.CancelDrag()
end

T.finish("ent_pickup_probe")