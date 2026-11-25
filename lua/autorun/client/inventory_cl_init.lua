INVENTORY = {}--玩家自己的背包：INVENTORY[n] = 容器 ITEM 实例（数字索引是格子）
TARGET_INVENTORY = {} --客户端访问的其他容器的缓存
include("inventory/cl_ui.lua")

-- 服务端下发的容器视图 → 客户端 ITEM 实例
-- 视图结构：{ classname = "container_test", [x][y] = classname | true | false }
function inventory_cl_build_container( view )
    local classname = view.classname
    local container

    if classname and ITEM_LIST[ classname ] then
        container = ITEM( classname )          -- 容器类实例：带元表、name/icon/X/Y/DATA
    end

    if not container then
        container = {}                         -- 类未注册时兜底，避免整块 UI 消失
        container.classname = classname
    end

    -- 格子写回数字索引，与服务端 inv[n][x][y] 保持一致
    for x = 1, #view do
        local column = view[x]
        local cells = {}
        for y = 1, #column do
            cells[y] = column[y]
        end
        container[x] = cells
    end

    return container
end

net.Receive("inventory_sys_inventory_send",function()
    local clean = net.ReadBool()
    local update_list = net.ReadTable()
    local invs = net.ReadTable()
    if clean then INVENTORY = {} end

    for _, n in ipairs(update_list) do
        local view = invs[n]
        if view then
            local c = inventory_cl_build_container( view )
            c.pos = { n = n, x = 0, y = 0 }
            INVENTORY[n] = c
        end
    end
    inventory_cl_clear_anchor_cache()   -- 容器整只重建，旧锚点索引一并失效
    inventory_cl_sync_containers()
end)

concommand.Add("inv_open",function()
    inventory_cl_inventory_ui()
end)

local meta = FindMetaTable( "Player" )

function meta:message_inventory_full()
    print("没有足够的空间")
end

net.Receive("inventory_sys_inventory_full",function()
    LocalPlayer():message_inventory_full()
end)

-- 客户端预测版：格子里存的是服务端下发的 classname / true / false，
-- 判定只剩「格子是否被占」，其余逻辑与服务端逐字一致。
function meta:InventoryValid(itemClass, n, x, y)
    local def = ITEM_LIST[itemClass]
    if type(def) ~= "table" then return false end

    -- INVENTORY 恒为表；还没同步到任何容器时下面的循环自然返回 false
    local inv = INVENTORY

    local w, h = def.X or 1, def.Y or 1

    -- 指定位置模式：只测 (n, x, y) 这一块矩形
    if n and x and y then
        local grid = inv[n]
        if type(grid) ~= "table" or not grid[1] then return false end

        local gw, gh = #grid, #grid[1]
        if x < 1 or y < 1 or x + w - 1 > gw or y + h - 1 > gh then return false end

        for cy = y, y + h - 1 do
            for cx = x, x + w - 1 do
                if grid[cx] and grid[cx][cy] then return false end
            end
        end

        return n, x, y
    end

    -- 自动找位模式
    for i = 1, #inv do
        local grid = inv[i]
        if type(grid) == "table" and grid[1] then
            local gw, gh = #grid, #grid[1]
            if gw >= w and gh >= h then
                for py = 1, gh - h + 1 do          -- 逐行
                    for px = 1, gw - w + 1 do      -- 逐列
                        local free = true
                        for yy = py, py + h - 1 do  -- 矩形
                            for xx = px, px + w - 1 do
                                if grid[xx][yy] then free = false break end
                            end
                            if not free then break end
                        end
                        if free then
                            return i, px, py       -- 同一层拿到 3 个值
                        end
                    end
                end
            end
        end
        -- 这个容器放不下：不 break，继续看下一个容器
    end

    return false
end

-- 客户端预测版：与服务端 InventoryAddItem 同构。
-- 差异只有两处：
--   ① 网格里存 classname 字符串（客户端视图没有 ITEM 实例）
--   ② 没有 UpDateINV 可发，正好等服务端的权威包把整只容器覆盖回来
function meta:InventoryAddItem(INPUT,n,x,y)
    if not self:IsPlayer() then return false end

    -- ① 解析 classname：字符串或表
    local classname
    if type( INPUT ) == "string" then
        classname = INPUT
    elseif istable( INPUT ) then
        classname = INPUT.classname
    else
        return false
    end

    -- ② 类必须已注册，否则不建实例
    local def = ITEM_LIST[classname]
    if not def then return false end
    local w, h = def.X or 1, def.Y or 1

    -- ③ 建预测用实例：只为让 OnPickUp 这类 share 逻辑拿到与服务端相同的 self
    local overrides = {}
    if istable( INPUT ) then
        for k, v in pairs( INPUT ) do
            if type( k ) ~= "number"
                and k ~= "X" and k ~= "Y" and k ~= "classname"
                and k ~= "OWNER" and k ~= "pos" then
                overrides[k] = istable( v ) and table.Copy( v ) or v
            end
        end
    end
    overrides.classname = classname

    local writeitem = ITEM( overrides )
    if not writeitem then return false end
    writeitem.X, writeitem.Y = w, h

    -- ④ 找位置：传了 n/x/y 就只测那一处，否则自动找第一个空位
    local inv = INVENTORY

    local rn, rx, ry
    if n and x and y then
        rn, rx, ry = self:InventoryValid( classname, n, x, y )
    else
        rn, rx, ry = self:InventoryValid( classname )
    end

    if not rn then
        self:message_inventory_full()
        return false
    end
    n, x, y = rn, rx, ry

    -- ⑤ 写网格：占用格 true，锚点格写 classname
    local grid = inv[n]
    for cx = x, x + w - 1 do
        for cy = y, y + h - 1 do
            grid[cx][cy] = true
        end
    end
    grid[x][y] = classname
    inventory_cl_clear_anchor_cache()   -- 预测就地改了格子，锚点索引失效

    -- ⑥ 预测成功：面板每帧重读 INVENTORY[n]，不需要额外刷新
    writeitem.OWNER = self:SteamID64()
    writeitem.pos = {["n"] = n,["x"] = x,["y"] = y}
    writeitem:OnPickUp()   -- func.OnPickUp 是 share 的，与服务端一样跑一次

    return true
end