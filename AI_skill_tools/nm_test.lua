--[[ ==========================================================================
    nm_test.lua —— LuaJIT 测试套组共享工具（放在 addon 的 AI_skill_tools\ 下）

    所有 *_probe.lua 都从这里取：路径解析、载入被测文件、断言、退出码。

    探针里的标准开头：
        local here = (arg and arg[0] or ""):match("^(.*[\\/])") or ""
        if here ~= "" then package.path = here .. "?.lua;" .. package.path end
        local T = require("nm_test")

    调用方式（任何 CWD 都可以）：
        C:\LuaJIT\luajit.exe D:\...\new_moon_inventory\AI_skill_tools\cl_drag_probe.lua
        或： AI_skill_tools\run_all.ps1            （跑全部 *_probe.lua）
        或： AI_skill_tools\run_all.ps1 cl_drag_probe（只跑一个）

    新增探针：在本目录新建 xxx_probe.lua，用上面的开头 + T.eq/T.near + T.finish()
    即可被 run_all.ps1 自动发现。不需要改任何配置。
   ========================================================================== ]]

local M = {}

local function fileExists(p)
    local f = io.open(p, "rb")
    if f then f:close() return true end
    return false
end

-- arg[0] 的目录部分（用完整路径调用时是绝对路径）
local function scriptDir()
    local a = (arg and arg[0]) or ""
    return a:match("^(.*[\\/])") or ""
end

local PROBE_FILE = "autorun/inventory_sys_item.lua"

-- addon 的 lua 根目录（末尾带分隔符）
local rootCache
function M.root()
    if rootCache then return rootCache end

    local candidates = {
        scriptDir() .. "../lua/",   -- 正常情况：探针在 AI_skill_tools\ 里
        "../lua/",                  -- 从 addon 根目录调用
        [[D:\steam\steamapps\common\GarrysMod\garrysmod\addons\new_moon_inventory\lua\]],
    }
    for _, c in ipairs(candidates) do
        if fileExists(c .. PROBE_FILE) then
            rootCache = c
            return c
        end
    end
    error("找不到 addon 的 lua 目录，尝试过：\n  " .. table.concat(candidates, "\n  "))
end

local function readFile(rel)
    local path = M.root() .. rel
    local f = assert(io.open(path, "rb"), "打不开被测文件：" .. path)
    local src = f:read("*a")
    f:close()
    return src, path
end

-- 载入 lua/<rel> 并执行（返回值透传）
function M.load(rel)
    local src, path = readFile(rel)
    return assert(loadstring(src, path))()
end

-- 载入 lua/<rel>，并把 extra 代码拼在文件末尾再执行。
-- 用途：文件里的 local（StartDrag / AnchorCellAtCursor 之类）外部拿不到，
-- 拼一段 export 代码就仍在同一 chunk 作用域里，可以直接引用它们。
--   T.load_with("inventory/cl_ui.lua", [[
--       _G.__P = { StartDrag = StartDrag, get_drag = function() return drag end }
--   ]])
function M.load_with(rel, extra)
    local src, path = readFile(rel)
    return assert(loadstring(src .. "\n" .. (extra or ""), path))()
end

-- ------------------------------------------------------------------ 断言
local failed, passed = 0, 0

function M.eq(name, got, want)
    local ok = got == want
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("%-42s %s  got=%s want=%s",
        name, ok and "PASS" or "FAIL", tostring(got), tostring(want)))
    return ok
end

function M.near(name, got, want, eps)
    local ok = type(got) == "number" and math.abs(got - want) <= (eps or 0.01)
    if ok then passed = passed + 1 else failed = failed + 1 end
    print(string.format("%-42s %s  got=%.2f want=%.2f",
        name, ok and "PASS" or "FAIL", got or -1, want))
    return ok
end

-- 自定义布尔断言（想自己打印细节时用）
function M.ok(name, cond, detail)
    if cond then passed = passed + 1 else failed = failed + 1 end
    print(string.format("%-42s %s  %s", name, cond and "PASS" or "FAIL", detail or ""))
    return cond
end

-- 打印汇总并以失败数决定退出码（run_all.ps1 靠这个判定）
function M.finish(title)
    print("")
    if failed == 0 then
        print(string.format("== %s：全部通过（%d 项）==", title or "probe", passed))
    else
        print(string.format("== %s：失败 %d 项 / 共 %d 项 ==", title or "probe", failed, passed + failed))
    end
    io.stdout:flush()
    os.exit(failed == 0 and 0 or 1)
end

return M
