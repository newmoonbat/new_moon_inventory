local COL_EMPTY  = Color(55, 55, 55, 255)
local COL_FULL   = Color(80, 180, 80, 255)
local COL_BG     = Color(80, 80, 80, 255)
local COL_TEXT   = Color(225, 225, 225, 255)

-- 背包名字体：沿用 DermaDefault 的字体文件（Tahoma），字号 = 屏幕高度 * 0.015
local NAME_FONT      = "NM_InventoryName"
local name_font_size = nil

local function GetNameFont()
    local size = math.max( 1, math.floor( ScrH() * 0.015 + 0.5 ) )
    if name_font_size ~= size then
        name_font_size = size
        surface.CreateFont( NAME_FONT, {
            font      = "Tahoma",
            size      = size,
            weight    = 500,
            antialias = true,
            additive  = false,
            shadow    = false,
        } )
    end
    return NAME_FONT
end

local function PanelH()
    return ScrH() * 0.8
end

local function CellMax()
    return PanelH() * 0.05
end

-- 容器页内部的上下留白：每页总高增加 ScrH()*0.01，上下各一半
local function PagePad()
    return ScrH() * 0.005
end

-- 每个容器面板左侧预留 2x2 格的背包图标区，网格整体右移这么多格
-- 图标下方再留 1 行显示背包名字
local ICON_COLS = 2
local ICON_ROWS = 2
local NAME_ROWS = 1

local icon_cache = {}

-- 容器现在是 ITEM 实例，类名在 .classname；这里兼容旧纯表的 .containerclassname
local function ContainerClass( grid )
    if type( grid ) ~= "table" then return end
    return grid.classname or grid.containerclassname
end

local function ContainerDef( grid )
    local classname = ContainerClass( grid )
    return classname and ITEM_LIST[ classname ]
end

local function GetIcon( path )
    if not path or path == "" then return end

    local mat = icon_cache[ path ]
    if mat == nil then
        mat = Material( path )
        icon_cache[ path ] = mat
    end

    if not mat or mat:IsError() then return end
    return mat
end

-- 网格里只有锚点格存 classname，true 是多格物品的占位格
-- 锚点索引按 grid 表缓存（弱键），避免每次右键都全表扫描。
-- 客户端预测会就地修改格子，所以预测后必须调用 inventory_cl_clear_anchor_cache()。
local anchor_cache = setmetatable( {}, { __mode = "k" } )

function inventory_cl_clear_anchor_cache()
    for grid in pairs( anchor_cache ) do
        anchor_cache[ grid ] = nil
    end
end

-- 客户端格子：锚点格是 { classname = "...", r = bool }，占位格是 true，空格是 false
-- 兼容旧的纯字符串格式
local function CellItem( cell )
    if type( cell ) == "table" then
        return cell.classname, cell.r == true
    elseif type( cell ) == "string" then
        return cell, false
    end
end

local function AnchorList( grid )
    local list = anchor_cache[ grid ]
    if list then return list end

    list = {}
    for ax = 1, #grid do
        local column = grid[ ax ]
        if column then
            for ay = 1, #column do
                local classname, rot = CellItem( column[ ay ] )
                if classname then
                    local def = ITEM_LIST[ classname ]
                    local w, h = ( def and def.X ) or 1, ( def and def.Y ) or 1
                    if rot then w, h = h, w end        -- 旋转后宽高互换
                    list[ #list + 1 ] = {
                        x = ax, y = ay,
                        w = w, h = h,
                        rot = rot,
                        classname = classname,
                        def = def,
                    }
                end
            end
        end
    end

    anchor_cache[ grid ] = list
    return list
end

-- 按坐标反查锚点，返回 锚点x, 锚点y, classname, 类定义, 是否旋转
local function ItemAnchorAt( grid, x, y )
    local list = AnchorList( grid )
    for i = 1, #list do
        local a = list[ i ]
        if x >= a.x and x < a.x + a.w and y >= a.y and y < a.y + a.h then
            return a.x, a.y, a.classname, a.def, a.rot
        end
    end
end

local DROP_METHOD = "drop"   -- D 键触发的 methon id（不是显示名）

-- methon 条目格式：{ name = "显示名", share = fn, sv = fn, cl = fn }
-- 返回按显示名排序的 { id, name } 列表；兼容旧的 "key = function" 写法
local function MethodList( methods )
    local list = {}
    for id, entry in pairs( methods ) do
        local label = id
        if type( entry ) == "table" and entry.name then label = entry.name end
        list[ #list + 1 ] = { id = id, name = label }
    end
    table.sort( list, function( a, b ) return a.name < b.name end )
    return list
end

-- 统一的格子尺寸来源：PerformLayout 算一次并缓存到面板上，
-- Paint（用 w 参数）与鼠标命中（GetWide）都读同一份，避免滚动条出现时错位
local function GridCell( pnl, w, gw )
    local cell = pnl.NMCell
    if cell and cell > 0 then return cell, pnl.NMOffsetX end

    cell = math.min( CellMax(), ( w - 4 ) / ( gw + ICON_COLS ) )
    if cell <= 0 then return end
    return cell, ICON_COLS * cell
end

-- 客户端预测：直接交给 ITEM:CallMethod（内部按 pos 自动选 methon / DATA.container.methon，
-- 并分发 share + cl；sv 只在服务端执行）
local function PredictCall( self, name )
    if not self then return end
    self:CallMethod( name )
    inventory_cl_clear_anchor_cache()      -- 预测会就地改格子，锚点索引必须失效
end

-- 从鼠标所在面板向上找容器面板（面板上带 ContainerIndex）
local function HoveredContainerPanel()
    local pnl = vgui.GetHoveredPanel()
    while IsValid(pnl) do
        if pnl.ContainerIndex and INVENTORY[pnl.ContainerIndex] then
            return pnl
        end
        pnl = pnl:GetParent()
    end
end

-- 返回鼠标当前指向的物品
-- { kind = "item", n, x, y, rot, cell, offsetX, classname, def }
-- x/y 是物品的锚点格（鼠标可能落在多格物品的非锚点格上）
-- 左侧背包图标是独立子面板，不会走到这里
local function ItemUnderCursor( pnl )
    local n = pnl.ContainerIndex
    local grid = n and INVENTORY[n]
    if not grid or not grid[1] then return end

    local cell, offsetX = GridCell( pnl, pnl:GetWide(), #grid )
    if not cell then return end

    local mx, my = pnl:ScreenToLocal(gui.MouseX(), gui.MouseY())
    local cx = math.floor((mx - 2 - offsetX) / cell) + 1
    local cy = math.floor((my - PagePad() - 2) / cell) + 1

    if cx < 1 then return end      -- 落在左侧图标区

    local ax, ay, classname, def, rot = ItemAnchorAt(grid, cx, cy)
    if not classname then return end

    return { kind = "item", n = n, x = ax, y = ay, rot = rot,
             cell = cell, offsetX = offsetX, classname = classname, def = def }
end

local function SendItemMethod( classname, id, n, x, y )
    -- 客户端预测：share / cl 分支在本地跑一遍（sv 只由服务端执行）
    if ITEM_LIST[ classname ] then
        local inst = ITEM( classname )
        if inst then
            inst.pos = { n = n, x = x, y = y }
            PredictCall( inst, id )
        end
    end

    local pack2sv = {["n"] = n,["x"] = x,["y"] = y,["methon"] = id}
    --配置服务器操作数据并发送
    net.Start( "inventory_sys_inventory_oprations" )
    net.WriteString("DoItemMethon")
    net.WriteTable(pack2sv)
    net.SendToServer()
end

-- 先 Open 再取宽：DMenu 未显示时布局没算完，GetWide 往往是默认值，
-- 会导致右侧翻边判断失准。Open 之后 SetPos 才是最终位置。
local function OpenMenuBeside( menu, rightX, leftX, topY )
    menu:InvalidateLayout( true )
    menu:Open( 0, 0 )

    local mw = menu:GetWide()
    local mx = rightX
    if mx + mw > ScrW() - 4 then
        mx = leftX - mw - 4
    end
    if mx < 4 then mx = 4 end

    menu:SetPos( mx, topY )
end

-- rightX / leftX / topY 是物品图标在屏幕上的右边缘、左边缘与顶部
local function OpenItemMenu( classname, n, x, y, rightX, leftX, topY )
    local def = ITEM_LIST[ classname ]
    if not def or type( def.methon ) ~= "table" then return end

    local list = MethodList( def.methon )
    if #list == 0 then return end

    local menu = vgui.Create( "DMenu" )
    for _, m in ipairs( list ) do
        local opt = menu:AddOption( m.name, function()
            SendItemMethod( classname, m.id, n, x, y )
        end )
        opt:SetFont( GetNameFont() )
    end

    -- 贴在物品图标右侧；右边放不下时翻到图标左侧
    OpenMenuBeside( menu, rightX, leftX, topY )
end

--[[
背包图标（容器）自己的右键菜单：方法来自 DATA.container.methon
（CallMethod 会因 pos = {n, 0, 0} 自动路由到这里），格式与物品相同：
{ name = "显示名", share = fn, sv = fn, cl = fn }

ITEM:new({
    classname = "container_test",
    DATA = { container = { methon = {
        ["disequip"] = { name = "解除装备", share = function(self) ... end },
    } } },
})
--]]
local function SendContainerMethod( classname, id, n )
    -- CLIENT 分支：预测执行（pos 的 x/y 为 0 即"容器本身"，CallMethod 会自动选容器方法）
    if ITEM_LIST[ classname ] then
        local inst = ITEM( classname )
        if inst then
            inst.pos = { n = n, x = 0, y = 0 }
            PredictCall( inst, id )
        end
    end

    -- SERVER 分支：x = 0, y = 0 表示"容器本身"
    net.Start( "inventory_sys_inventory_oprations" )
    net.WriteString("DoItemMethon")
    net.WriteTable( {["n"] = n,["x"] = 0,["y"] = 0,["methon"] = id} )
    net.SendToServer()

    -- 容器方法可能让本地 INVENTORY 减少一个容器（如解除装备），
    -- 面板按编号索引，必须同步一次才能删掉多出来的面板
    inventory_cl_sync_containers()
end

local function OpenContainerMenu( n, rightX, leftX, topY )
    local grid = INVENTORY[n]
    if not grid then return end

    local classname = ContainerClass( grid )

    -- GetMethods 会按 grid 的 pos 自动选 DATA.container.methon
    local methods = grid.GetMethods and grid:GetMethods()
    if type( methods ) ~= "table" then
        local def = ContainerDef( grid )     -- 兜底：纯表或未注册类
        methods = def and def.DATA and def.DATA.container and def.DATA.container.methon
    end
    if type( methods ) ~= "table" then return end

    local list = MethodList( methods )
    if #list == 0 then return end

    local menu = vgui.Create( "DMenu" )
    for _, m in ipairs( list ) do
        local opt = menu:AddOption( m.name, function()
            SendContainerMethod( classname, m.id, n )
        end )
        opt:SetFont( GetNameFont() )
    end

    OpenMenuBeside( menu, rightX, leftX, topY )
end

local inv_frame
local inv_scroll
local inv_panels = {}          -- 容器编号 -> DPanel

-- ============================ 拖拽物品 ============================
-- 左键按住物品开始，Think 里检测松开，覆盖面板里画跟随鼠标的图标。
-- 图标始终以「中心对准鼠标」的方式绘制，落点也按同一规则换算锚点。
-- 松开时把 { item = 来源, target = 目标 } 通过 Move2 发给服务端。
local drag = nil

local function StartDrag( hit, panel )
    if not hit or not hit.def then return end

    local grid = INVENTORY[ hit.n ]
    if not grid or not grid[1] then return end

    local cell = GridCell( panel, panel:GetWide(), #grid )
    if not cell then return end

    drag = {
        kind      = "item",                   -- 来源是背包格子
        classname = hit.classname,
        def       = hit.def,
        rot       = hit.rot == true,          -- 该物品当前是否旋转（拖动中可按 R 切换）
        rot0      = hit.rot == true,          -- 拖动开始时的朝向，用于判断是否需要下发
        cell      = cell,                     -- 来源面板的格宽（兜底用）
        n = hit.n, x = hit.x, y = hit.y,
    }
end

-- 拖动中按 R：顺时针旋转 90°（图标中心始终跟着鼠标，所以只需翻转朝向）
local function RotateDrag()
    if not drag then return end
    drag.rot = not drag.rot
end

-- 拖拽中物品的占格（旋转后宽高互换）
local function DragFootprint( d )
    local w, h = d.def.X or 1, d.def.Y or 1
    if d.rot then return h, w end
    return w, h
end

-- 鼠标下方的容器面板
local function ContainerPanelUnderCursor()
    local pnl = vgui.GetHoveredPanel()
    while IsValid( pnl ) do
        local n = pnl.ContainerIndex
        local grid = n and INVENTORY[ n ]
        if grid and grid[1] then return pnl, n end
        pnl = pnl:GetParent()
    end
end

-- 以「图标中心对准鼠标」的方式，算出锚点所在的格子（返回 cx, cy，可能越界）
local function AnchorCellAtCursor( pnl, n, fw, fh )
    local grid = INVENTORY[ n ]
    if not grid or not grid[1] then return end

    local cell, offsetX = GridCell( pnl, pnl:GetWide(), #grid )
    if not cell then return end

    local mx, my = pnl:ScreenToLocal( gui.MouseX(), gui.MouseY() )
    local left = mx - fw * cell * 0.5          -- 图标左上角
    local top  = my - fh * cell * 0.5

    -- 取「占格中心最接近鼠标」的那个锚点（偶数宽高时是半格取舍，四舍五入最贴合图标）
    local cx = math.floor( ( left - 2 - offsetX ) / cell + 0.5 ) + 1
    local cy = math.floor( ( top  - PagePad() - 2 ) / cell + 0.5 ) + 1
    return cx, cy
end

-- 目标位置能否放下：把「拖拽中的物品自己占的格子」视为空地，
-- 这样在自身范围内平移不会被自己挡住；其余被占的格子一律不行。
local function CanDropAt( n, tx, ty, d )
    local grid = INVENTORY[ n ]
    if not grid or not grid[1] or not d or not d.def then return false end

    local w, h = DragFootprint( d )                -- 旋转后宽高互换

    -- 豁免只针对「原来占的格子」：旋转后新覆盖到别人的格子不能被豁免
    local ow, oh = d.def.X or 1, d.def.Y or 1
    if d.rot0 then ow, oh = oh, ow end

    local gw, gh = #grid, #grid[1]
    if tx < 1 or ty < 1 or tx + w - 1 > gw or ty + h - 1 > gh then return false end

    local sameContainer = ( d.n == n )

    for cy = ty, ty + h - 1 do
        for cx = tx, tx + w - 1 do
            if grid[cx] and grid[cx][cy] then
                local ownCell = sameContainer
                    and cx >= d.x and cx < d.x + ow
                    and cy >= d.y and cy < d.y + oh
                if not ownCell then return false end
            end
        end
    end

    return true
end

local function CancelDrag()
    drag = nil
end

-- ======================= 掉落物面板 / 拾取（PickUp） =======================
-- 服务端已有 PickUp opration：{ index = 实体索引 }，内部走 ENT:Use →
-- InventoryAddItem(classname)，也就是"自动找第一个空位"，不接收指定格子。
-- 所以这里的预测和预览都用同一套自动找位，保证客户端预览 = 服务端落点。
local PICKUP_RANGE      = 104                     -- 与服务端 PickUp 的 72 单位一致
local PICKUP_HIDE_TIME  = 2                       -- 发包后先把实体藏这么久
local DROP_REFRESH      = 0.25                    -- 实体列表的刷新间隔

local drop_board                                  -- 面板本体（CreateDropPanel 里赋值）
local drop_items, drop_items_time = {}, -1

-- 刚发过 PickUp 的实体先不显示，等服务端把它删掉。
-- 弱键：实体被删后条目自动消失，不会留垃圾。
local picked_ents = setmetatable( {}, { __mode = "k" } )

local function LocalPly()
    local ply = LocalPlayer()
    if IsValid( ply ) then return ply end
end

-- 客户端还没有任何容器：不做预测，直接交给服务端
local function CanPredictPickup()
    return next( INVENTORY ) ~= nil
end

-- 预测这次拾取会落到哪个格：与服务端 ENT:Use → InventoryAddItem(classname) 等价
local function PredictPickupSlot( classname )
    local ply = LocalPly()
    if not ply or not classname then return end
    if not CanPredictPickup() then return end
    return ply:InventoryValid( classname, nil, nil, nil, false )
end

local function RefreshDropItems()
    local list = {}
    local now  = CurTime()

    local ply = LocalPly()
    if ply then
        local origin = ply:GetPos()
        local range  = PICKUP_RANGE^2

        for _, ent in ipairs( ents.FindByClass( "prop_item" ) ) do
            if IsValid( ent ) then
                local sent = picked_ents[ ent ]
                if sent and now - sent > PICKUP_HIDE_TIME then
                    picked_ents[ ent ] = nil      -- 服务端没删：可能被拒绝了，重新显示
                    sent = nil
                end

                if not sent then
                    local classname = ent:GetNWString( "ITEMclass", "" )
                    local def = ITEM_LIST[ classname ]
                    if def and ( ent:GetPos() - origin ):LengthSqr() <= range then
                        list[ #list + 1 ] = { ent = ent, classname = classname, def = def }
                    end
                end
            end
        end
    end

    drop_items, drop_items_time = list, now
    if IsValid( drop_board ) then drop_board:InvalidateLayout() end
    return list
end

local function DropItems()
    if CurTime() - drop_items_time >= DROP_REFRESH then return RefreshDropItems() end
    return drop_items
end

-- 把掉落物按阅读顺序打进一个虚拟网格（实体没有朝向，不旋转）
-- 返回 cols, cell, rows, slots（slots[i] = { x, y, w, h }）
local function DropLayout( w, items )
    local pad   = 4
    local avail = math.max( 1, w - pad )
    local unit  = math.max( 1, CellMax() )

    -- 列数：至少容纳最宽的物品，再按 CellMax 尽量多排几列
    local maxIw = 1
    for i = 1, #items do
        maxIw = math.max( maxIw, items[i].def.X or 1 )
    end

    local cols = math.max( maxIw, math.floor( avail / unit ) )
    if cols < 1 then cols = 1 end

    local cell = math.min( unit, avail / cols )
    if cell <= 0 then cell = 1 end

    local used, slots = {}, {}
    local rows = 0

    for i = 1, #items do
        local def = items[i].def
        local iw, ih = def.X or 1, def.Y or 1
        local place

        -- 逐行逐列找第一块放得下的矩形；rows+1 之后一定是空的
        for ty = 1, rows + 1 do
            for tx = 1, cols - iw + 1 do
                local free = true
                for yy = ty, ty + ih - 1 do
                    for xx = tx, tx + iw - 1 do
                        if used[xx] and used[xx][yy] then free = false break end
                    end
                    if not free then break end
                end
                if free then place = { x = tx, y = ty } break end
            end
            if place then break end
        end

        if place then
            for xx = place.x, place.x + iw - 1 do
                used[xx] = used[xx] or {}
                for yy = place.y, place.y + ih - 1 do
                    used[xx][yy] = i
                end
            end
            rows = math.max( rows, place.y + ih - 1 )
            slots[i] = { x = place.x, y = place.y, w = iw, h = ih }
        end
    end

    return cols, cell, rows, slots
end

-- 面板的一次可视布局：把网格整体摆到面板中央。
-- 返回 cols, cell, rows, slots, drawRows, ox, oy
--   drawRows：实际要画的行数（物品少时按可视区域补满）
--   ox / oy ：网格左上角在面板内的坐标（水平、垂直都居中）
local function DropView( bw, bh, items )
    local cols, cell, rows, slots = DropLayout( bw, items )

    local titleH   = cell                                     -- 顶部标题占 1 行
    local visRows  = math.floor( math.max( 0, bh - titleH ) / cell )
    local drawRows = math.max( rows, visRows )

    local gw = cols * cell
    local gh = drawRows * cell

    local ox = ( bw - gw ) * 0.5
    local oy = titleH + math.max( 0, ( bh - titleH - gh ) * 0.5 )

    return cols, cell, rows, slots, drawRows, ox, oy
end

-- 鼠标下的掉落物序号；没命中返回 nil（ox/oy 是网格原点）
local function DropHitTest( items, slots, cell, ox, oy, mx, my )
    local cx = math.floor( ( mx - ox ) / cell ) + 1
    local cy = math.floor( ( my - oy ) / cell ) + 1
    if cx < 1 or cy < 1 then return end

    for i = 1, #items do
        local s = slots[ i ]
        if s and cx >= s.x and cx < s.x + s.w and cy >= s.y and cy < s.y + s.h then
            return i
        end
    end
end

local function StartEntityDrag( entry, cell )
    if drag or not entry or not entry.def then return end
    if not IsValid( entry.ent ) then return end

    drag = {
        kind      = "ent",                -- 来源是地上的物品实体
        ent       = entry.ent,
        classname = entry.classname,
        def       = entry.def,
        rot       = false,                -- 实体没有朝向，拖动中按 R 无效
        rot0      = false,
        cell      = cell,
    }
end

-- 真正执行一次拾取：预测 + 发包。成功返回 true。
-- 拖拽松手（FinishEntityDrag）和 Ctrl+左键（面板 OnMousePressed）都走这里。
local function TryPickupEntity( ent, classname )
    if not IsValid( ent ) or not classname then return false end
    if picked_ents[ ent ] then return false end          -- 已经发过包，等结果

    local ply = LocalPly()
    if not ply then return false end

    if CanPredictPickup() then
        -- ① 先确认放得下（同时就是预览用的那份结果）
        if not PredictPickupSlot( classname ) then return false end
        -- ② 预测写入本地背包；OnPickUp 拒绝 / 没空位都会返回 false
        if not ply:InventoryAddItem( classname ) then return false end

        picked_ents[ ent ] = CurTime()
        RefreshDropItems()                                 -- 立刻从面板上消失
    end

    net.Start( "inventory_sys_inventory_oprations" )
    net.WriteString( "PickUp" )
    net.WriteTable( { index = ent:EntIndex() } )
    net.SendToServer()
    return true
end

-- 松手：必须落在某个容器面板上；预测和服务端一样"自动找第一个空位"
local function FinishEntityDrag( d )
    if not IsValid( d.ent ) then return end                -- 拖动过程中被别人捡走了
    if not ContainerPanelUnderCursor() then return end     -- 丢在界面空白处：取消
    TryPickupEntity( d.ent, d.classname )
end

local function FinishDrag()
    local d = drag
    drag = nil
    if not d then return end

    if d.kind == "ent" then return FinishEntityDrag( d ) end   -- 从掉落物面板拖来

    local pnl, n = ContainerPanelUnderCursor()
    if not pnl then return end                     -- 丢到界面外：取消

    local fw, fh = DragFootprint( d )
    local tx, ty = AnchorCellAtCursor( pnl, n, fw, fh )
    if not tx then return end

    -- 位置和朝向都没变：什么都不用做
    if n == d.n and tx == d.x and ty == d.y and d.rot == d.rot0 then return end
    if not CanDropAt( n, tx, ty, d ) then return end           -- 放不下：什么都不做

    -- 客户端预测：与服务端走同一套 move2
    if ITEM_LIST[ d.classname ] then
        local inst = ITEM( d.classname )
        if inst then
            inst.pos = { n = d.n, x = d.x, y = d.y, r = d.rot0 }
            inst:move2( n, tx, ty, d.rot )
            inventory_cl_clear_anchor_cache()      -- 预测改了格子
        end
    end

    net.Start( "inventory_sys_inventory_oprations" )
    net.WriteString( "Move2" )
    net.WriteTable( {
        item   = { n = d.n, x = d.x, y = d.y },
        target = { n = n,   x = tx,  y = ty, r = d.rot },
    } )
    net.SendToServer()
end

local rKeyDown = false      -- R 的边沿检测：按住只触发一次

hook.Add( "Think", "new_moon_inventory_drag", function()
    if not drag then rKeyDown = false return end

    if not IsValid( inv_frame ) then CancelDrag() return end
    if input.IsKeyDown( KEY_ESCAPE ) then CancelDrag() return end

    -- 拖动中按 R 旋转（实体没有朝向，按住 R 对掉落物无效）
    local down = input.IsKeyDown( KEY_R )
    if down and not rKeyDown and drag.kind ~= "ent" then RotateDrag() end
    rKeyDown = down

    if not input.IsMouseDown( MOUSE_LEFT ) then FinishDrag() end
end )

-- 跟随鼠标的图标画在一个挂在界面最上层的覆盖面板里（见 inventory_cl_inventory_ui）。
-- HUDPaint 会被 VGUI 面板盖住，所以不能用它画。
function inventory_cl_paint_drag( pnl )
    if not drag or not drag.def then return end

    local mat = GetIcon( drag.def.icon )
    if not mat then return end

    -- 格宽优先跟随鼠标所在的容器（换容器时尺寸也正确），否则用来源面板的
    local cell = drag.cell
    local hp = ContainerPanelUnderCursor()
    if hp then
        local grid = INVENTORY[ hp.ContainerIndex ]
        cell = GridCell( hp, hp:GetWide(), #grid ) or cell
    end

    local w, h = DragFootprint( drag )
    local pw, ph = w * cell, h * cell

    -- 图标中心始终对准鼠标
    local mx, my = pnl:ScreenToLocal( gui.MouseX(), gui.MouseY() )
    local x = mx - pw * 0.5
    local y = my - ph * 0.5

    surface.SetMaterial( mat )
    surface.SetDrawColor( 255, 255, 255, 210 )

    if drag.rot then
        -- 旋转 90°：传入 (ph, pw) 让旋转后的包围盒正好是 pw x ph
        surface.DrawTexturedRectRotated( x + pw * 0.5, y + ph * 0.5, ph, pw, 90 )
    else
        surface.DrawTexturedRect( x, y, pw, ph )
    end
end

local function CreateContainerPanel( n )
    local pnl = vgui.Create("DPanel")
    pnl:Dock(TOP)
    pnl:DockMargin(0, 0, 0, PanelH() * 0.01)

    -- 背包图标：独立子面板（DImageButton），不走物品的图标渲染路径
    local icon = vgui.Create("DImageButton", pnl)
    icon:SetMouseInputEnabled(true)
    icon:SetDepressImage(false)   -- 按下时不位移
    icon:SetCursor("arrow")       -- 不用手型光标
    icon.Paint = function() end   -- 只由内部 DImage 画图，按钮自身不画任何东西
    icon.DoRightClick = function(self)
        local rightX, topY = self:LocalToScreen(self:GetWide() + 4, 0)
        local leftX = self:LocalToScreen(0, 0)
        OpenContainerMenu(n, rightX, leftX, topY)
    end

    -- ① 每帧现取，不捕获旧表 → 拾取后立刻刷新
    pnl.Paint = function(self, w, h)
        local grid = INVENTORY[n]
        if not grid or not grid[1] then return end

        local gw, gh = #grid, #grid[1]

        -- 总列数 = 图标区 ICON_COLS 列 + 背包列数：面板宽度不变，网格整体右移
        local cell, offsetX = GridCell( self, w, gw )
        if not cell then return end

        local iconH = ICON_ROWS * cell
        local pad = math.min(4, cell * 0.5)      -- 小尺寸时避免出现负宽高
        local inner = math.max(1, cell - pad)
        local padY = PagePad()                   -- 页内上下留白

        draw.RoundedBox(2, 0, 0, w, h, COL_BG)

        -- 左侧：背包图标槽（2 行）+ 名字槽（1 行）
        draw.RoundedBox(2, 2, 2 + padY, math.max(1, offsetX - 4), math.max(1, iconH - 4), COL_EMPTY)

        local nameX, nameY = 2, iconH + 2 + padY
        local nameW, nameH = math.max(1, offsetX - 4), inner
        draw.RoundedBox(2, nameX, nameY, nameW, nameH, COL_EMPTY)

        local label = grid.name or ( ContainerDef( grid ) or {} ).name
        if label and label ~= "" then
            -- 用裁剪防止长名字溢出到背包格上
            local sx, sy = self:LocalToScreen(nameX, nameY)
            render.SetScissorRect(sx, sy, sx + nameW, sy + nameH, true)
            draw.SimpleText(label, GetNameFont(), nameX + nameW * 0.5, nameY + nameH * 0.5,
                COL_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            render.SetScissorRect(0, 0, 0, 0, false)
        end

        -- ② 背包格子
        for x = 1, gw do
            for y = 1, gh do
                surface.SetDrawColor(grid[x][y] and COL_FULL or COL_EMPTY)
                surface.DrawRect(
                    offsetX + (x - 1) * cell + 2,
                    padY + (y - 1) * cell + 2,
                    inner, inner
                )
            end
        end

        -- 物品图标：只在锚点格画一次；旋转的物品把图标也转 90°
        for x = 1, gw do
            local column = grid[x]
            for y = 1, gh do
                local classname, rot = CellItem( column and column[y] )
                if classname then
                    local idef = ITEM_LIST[classname]
                    local mat = idef and GetIcon(idef.icon)
                    if mat then
                        local w, h = ( idef and idef.X ) or 1, ( idef and idef.Y ) or 1
                        if rot then w, h = h, w end

                        local px = offsetX + (x - 1) * cell + 2
                        local py = padY + (y - 1) * cell + 2
                        local pw = math.max(1, w * cell - 4)
                        local ph = math.max(1, h * cell - 4)

                        surface.SetMaterial(mat)
                        surface.SetDrawColor(255, 255, 255, 255)

                        if rot then
                            -- 旋转 90°：传入 (ph, pw)，旋转后的包围盒正好是 pw x ph
                            surface.DrawTexturedRectRotated( px + pw * 0.5, py + ph * 0.5, ph, pw, 90 )
                        else
                            surface.DrawTexturedRect( px, py, pw, ph )
                        end
                    end
                end
            end
        end

        -- 拖拽时预览目标位置：可放蓝色，不可放红色
        if drag and drag.def and ContainerPanelUnderCursor() == pnl then
            local tx, ty = AnchorCellAtCursor( pnl, n, DragFootprint( drag ) )
            if tx then
                local ok = CanDropAt( n, tx, ty, drag )
                local iw, ih = DragFootprint( drag )

                -- 只画落在本容器内的部分，避免溢出到相邻面板
                local x1, y1 = math.max( tx, 1 ), math.max( ty, 1 )
                local x2, y2 = math.min( tx + iw - 1, gw ), math.min( ty + ih - 1, gh )
                if x2 >= x1 and y2 >= y1 then
                    if ok then
                        surface.SetDrawColor( 120, 200, 255, 90 )
                    else
                        surface.SetDrawColor( 230, 80, 80, 100 )
                    end
                    surface.DrawRect(
                        offsetX + ( x1 - 1 ) * cell + 2,
                        padY + ( y1 - 1 ) * cell + 2,
                        math.max(1, ( x2 - x1 + 1 ) * cell - 4),
                        math.max(1, ( y2 - y1 + 1 ) * cell - 4)
                    )
                end
            end
        end

        -- 从掉落物面板拖进来：预览服务端"自动找第一个空位"的真实落点。
        -- 服务端 PickUp 不接收指定格子，所以这里不跟随鼠标，只标出最终落点。
        if drag and drag.kind == "ent" and drag.def then
            local pn, px, py = PredictPickupSlot( drag.classname )
            local iw, ih = drag.def.X or 1, drag.def.Y or 1

            if pn then
                -- 落点在本容器：蓝框
                if pn == n then
                    local x1, y1 = math.max( px, 1 ), math.max( py, 1 )
                    local x2, y2 = math.min( px + iw - 1, gw ), math.min( py + ih - 1, gh )
                    if x2 >= x1 and y2 >= y1 then
                        surface.SetDrawColor( 120, 200, 255, 90 )
                        surface.DrawRect(
                            offsetX + ( x1 - 1 ) * cell + 2,
                            padY + ( y1 - 1 ) * cell + 2,
                            math.max(1, ( x2 - x1 + 1 ) * cell - 4),
                            math.max(1, ( y2 - y1 + 1 ) * cell - 4)
                        )
                    end
                end
            elseif ContainerPanelUnderCursor() == pnl then
                -- 整个背包都没地方：在鼠标下的格子上标红
                local mx, my = pnl:ScreenToLocal( gui.MouseX(), gui.MouseY() )
                local tx = math.floor( ( mx - 2 - offsetX ) / cell ) + 1
                local ty = math.floor( ( my - PagePad() - 2 ) / cell ) + 1
                local x1, y1 = math.max( tx, 1 ), math.max( ty, 1 )
                local x2, y2 = math.min( tx + iw - 1, gw ), math.min( ty + ih - 1, gh )
                if x2 >= x1 and y2 >= y1 then
                    surface.SetDrawColor( 230, 80, 80, 100 )
                    surface.DrawRect(
                        offsetX + ( x1 - 1 ) * cell + 2,
                        padY + ( y1 - 1 ) * cell + 2,
                        math.max(1, ( x2 - x1 + 1 ) * cell - 4),
                        math.max(1, ( y2 - y1 + 1 ) * cell - 4)
                    )
                end
            end
        end

        -- 左侧背包图标由 icon 子面板自己绘制，这里只画槽位底板
    end

    -- ③ 高度、图标尺寸都跟着 cell 走，所以放到 Layout 里算
    pnl.PerformLayout = function(self, w, h)
        local grid = INVENTORY[n]
        if not grid or not grid[1] then return end

        local gw, gh = #grid, #grid[1]
        local cell = math.min(CellMax(), (w - 4) / (gw + ICON_COLS))
        if cell <= 0 then return end

        local offsetX = ICON_COLS * cell
        local iconH = ICON_ROWS * cell          -- 图标固定 2x2 格

        -- 缓存给 Paint / 鼠标命中用，保证三处尺寸完全一致
        self.NMCell, self.NMOffsetX = cell, offsetX

        -- 左侧高度 = 图标 2 行 + 名字 1 行
        -- 在 PerformLayout 里改自身尺寸会再次触发布局，只在真的变了时才 SetTall，
        -- 否则每帧都会重排一次（DScrollPanel 的 Dock 布局会跟着抖动）
        -- 左侧高度 = 图标 2 行 + 名字 1 行；整页再上下各留 PagePad()
        local tall = math.max(gh, ICON_ROWS + NAME_ROWS) * cell + PagePad() * 2
        if math.abs(self:GetTall() - tall) >= 1 then
            self:SetTall(tall)
        end

        icon:SetPos(2, 2 + PagePad())
        icon:SetSize(math.max(1, offsetX - 4), math.max(1, iconH - 4))

        -- 容器类变化时才重新设图
        local classname = ContainerClass( grid )
        if icon.NMClassname ~= classname then
            icon.NMClassname = classname
            local path = grid.icon or ( ContainerDef( grid ) or {} ).icon
            if path and path ~= "" then
                icon:SetImage(path)
                icon:SetVisible(true)
            else
                icon:SetVisible(false)
            end
        end
    end

    -- ④ 左键拖动物品；右键弹菜单
    pnl.ContainerIndex = n
    pnl:SetMouseInputEnabled(true)
    pnl.OnMousePressed = function(self, key)
        if key == MOUSE_LEFT then
            local hit = ItemUnderCursor(self)
            if hit then StartDrag(hit, self) end
            return
        end

        if key ~= MOUSE_RIGHT then return end

        local hit = ItemUnderCursor(self)
        if not hit then return end

        local left = hit.offsetX + (hit.x - 1) * hit.cell + 2
        local top  = (hit.y - 1) * hit.cell + 2
        local iw   = ((hit.def and hit.def.X) or 1) * hit.cell

        local rightX, topY = self:LocalToScreen(left + iw + 2, top)
        local leftX = self:LocalToScreen(left, top)

        OpenItemMenu(hit.classname, hit.n, hit.x, hit.y, rightX, leftX, topY)
    end

    inv_scroll:AddItem(pnl)
    inv_panels[n] = pnl
    return pnl
end

-- 容器增删后同步界面：缺的补上，多的删掉（界面没开时直接返回）
function inventory_cl_sync_containers()
    if not IsValid(inv_scroll) then return end

    local maxIndex = 0
    for k in pairs(INVENTORY) do
        if type(k) == "number" and k > maxIndex then maxIndex = k end
    end

    for n = 1, maxIndex do
        if INVENTORY[n] and not IsValid(inv_panels[n]) then
            CreateContainerPanel(n)
        end
    end

    for n, pnl in pairs(inv_panels) do
        if not INVENTORY[n] then
            if IsValid(pnl) then pnl:Remove() end
            inv_panels[n] = nil
        end
    end
end

-- 掉落物面板：显示 PICKUP_RANGE 内的 prop_item 实体，可以在里面按住拖到背包上拾取。
-- 面板本身尺寸随可用区域变化（列数由宽度算），行数随物品数量增长，超出就滚动。
local function CreateDropPanel( parent, x, y, w, h )
    local scroll = vgui.Create( "DScrollPanel", parent )
    scroll:SetPos( x, y )
    scroll:SetSize( w, h )
    scroll.Paint = function( self, sw, sh )
        draw.RoundedBox( 2, 0, 0, sw, sh, COL_BG )
    end

    local board = vgui.Create( "DPanel" )
    board:Dock( TOP )
    board:SetMouseInputEnabled( true )
    scroll:AddItem( board )

    drop_board = board

    board.Paint = function( self, bw, bh )
        local items = DropItems()
        local cols, cell, _, slots, drawRows, ox, oy = DropView( bw, bh, items )

        draw.SimpleText( "      掉落物", GetNameFont(),
            4, cell * 0.5, COL_TEXT, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER )

        -- 空格底板：整块网格居中摆放，物品少时也把可视区域铺满
        for x2 = 1, cols do
            for y2 = 1, drawRows do
                surface.SetDrawColor( COL_EMPTY )
                surface.DrawRect(
                    ox + ( x2 - 1 ) * cell + 1,
                    oy + ( y2 - 1 ) * cell + 1,
                    math.max(1, cell - 2),
                    math.max(1, cell - 2)
                )
            end
        end

        if #items == 0 then return end

        -- 物品图标（实体没有朝向，不需要旋转绘制）
        for i = 1, #items do
            local s = slots[ i ]
            local mat = GetIcon( items[i].def.icon )
            if s and mat then
                local pw = math.max(1, s.w * cell - 4)
                local ph = math.max(1, s.h * cell - 4)

                surface.SetMaterial( mat )
                surface.SetDrawColor( 255, 255, 255, 255 )
                surface.DrawTexturedRect(
                    ox + ( s.x - 1 ) * cell + 2,
                    oy + ( s.y - 1 ) * cell + 2,
                    pw, ph
                )
            end
        end

        -- 鼠标下的那一项：高亮，提示可以拖
        local mx, my = self:ScreenToLocal( gui.MouseX(), gui.MouseY() )
        local hover = DropHitTest( items, slots, cell, ox, oy, mx, my )
        if hover then
            local s = slots[ hover ]
            surface.SetDrawColor( 120, 200, 255, 70 )
            surface.DrawRect(
                ox + ( s.x - 1 ) * cell + 1,
                oy + ( s.y - 1 ) * cell + 1,
                math.max(1, s.w * cell - 2),
                math.max(1, s.h * cell - 2)
            )
        end
    end

    board.PerformLayout = function( self, bw, bh )
        local items = DropItems()
        local _, cell, rows = DropLayout( bw, items )

        -- 标题 1 行 + 网格（没有物品时也留出标题行）
        local need = cell * ( math.max( rows, 1 ) + 1 )

        -- 物品少的时候把面板撑满可视区域（格子铺满），物品更多时才继续往下长
        local visH = 0
        if IsValid( scroll ) then visH = scroll:GetTall() end

        local tall = math.max( need, visH )
        if math.abs( self:GetTall() - tall ) >= 1 then
            self:SetTall( tall )
        end
    end

    -- 左键：按住 Ctrl 直接捡起；否则拖拽
    board.OnMousePressed = function( self, key )
        if key ~= MOUSE_LEFT then return end

        local items = DropItems()
        local _, cell, _, slots, _, ox, oy = DropView( self:GetWide(), self:GetTall(), items )
        local mx, my = self:ScreenToLocal( gui.MouseX(), gui.MouseY() )
        local hit = DropHitTest( items, slots, cell, ox, oy, mx, my )
        if not hit then return end

        local entry = items[ hit ]
        if input.IsControlDown() then
            TryPickupEntity( entry.ent, entry.classname )     -- 直接捡起，不用拖
            return
        end

        StartEntityDrag( entry, cell )
    end

    return scroll
end

function inventory_cl_inventory_ui()
    if IsValid(inv_frame) then inv_frame:Close() end

    local PANEL_W, PANEL_H = ScrW() * 0.95, ScrH() * 0.8

    local DermaPanel = vgui.Create("DFrame")
    inv_frame = DermaPanel
    DermaPanel:SetSize(PANEL_W, PANEL_H)
    DermaPanel:Center()
    DermaPanel:SetTitle("")
    DermaPanel:SetDraggable(false)
    DermaPanel:ShowCloseButton(false)
    DermaPanel:MakePopup()
    DermaPanel.Paint = function(self, w, h)
        draw.RoundedBox(2, 0, 0, w, h, Color(0, 0, 0, 200))
    end

    local quit = DermaPanel:Add("DButton")
    quit:SetText("exit")
    quit:SetFont(GetNameFont())
    quit:SetSize(PANEL_W * 0.05, PANEL_H * 0.03)
    quit:SetPos(DermaPanel:GetWide() - quit:GetWide() - 8, 8)
    quit.DoClick = function() DermaPanel:Close() end

    local RESERVE_RIGHT  = 0.36    -- 右侧预留空白区域，占整个面板宽度的比例
    local INVENTORY_LEFT = 0.35   -- 背包区左边界（与加入 40% 空白之前的左端对齐）

    local inventories = vgui.Create("DScrollPanel", DermaPanel)
    inventories:SetWide(PANEL_W * (1 - INVENTORY_LEFT - RESERVE_RIGHT))
    inventories:Dock(LEFT)
    inventories:DockMargin(PANEL_W * INVENTORY_LEFT, PANEL_H * 0.02, 0, PANEL_H * 0.009)

    -- ⑤ D 键：对指针指向的物品执行它的"丢弃"方法
    DermaPanel.OnKeyCodePressed = function(self, key)
        if key ~= KEY_D then return end

        local pnl = HoveredContainerPanel()
        if not pnl then return end

        local hit = ItemUnderCursor(pnl)
        if not hit or hit.kind ~= "item" then return end

        local def = ITEM_LIST[hit.classname]
        if not def or type(def.methon) ~= "table" or def.methon[DROP_METHOD] == nil then return end

        SendItemMethod(hit.classname, DROP_METHOD, hit.n, hit.x, hit.y)
    end

    inv_scroll = inventories
    inv_panels = {}

    inventory_cl_sync_containers()

    -- 右侧预留区的下 60%（再收掉 5% 主面板高度）：附近掉落物面板，拖到背包上即尝试拾取
    local DROP_GAP = PANEL_W * 0.006                                -- 与左侧容器面板、主面板右边缘各留这么多
    local RIGHT_X = PANEL_W * ( 1 - RESERVE_RIGHT ) + DROP_GAP
    local RIGHT_W = PANEL_W * RESERVE_RIGHT - DROP_GAP * 2
    local REGION_Y = PANEL_H * 0.02
    local REGION_H = PANEL_H - REGION_Y - PANEL_H * 0.009

    local DROP_Y = REGION_Y + REGION_H * 0.4      -- 右侧区域的下 60% 的顶边
    local DROP_H = REGION_H * 0.55                -- 下 60% 再收 5% 主面板高（基数差 1px，直接取 55%）

    CreateDropPanel( DermaPanel, RIGHT_X, DROP_Y, RIGHT_W, DROP_H )

    -- 拖拽图标层：盖住整个界面（鼠标穿透），保证拖动的图标不会被面板挡住
    local layer = vgui.Create( "DPanel", DermaPanel )
    layer:SetPos( 0, 0 )
    layer:SetSize( PANEL_W, PANEL_H )
    layer:SetZPos( 1000 )
    layer:SetMouseInputEnabled( false )
    layer:SetKeyboardInputEnabled( false )
    layer.Paint = inventory_cl_paint_drag
end