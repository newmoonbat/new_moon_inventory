<#
    run_all.ps1 - run every *_probe.lua in this folder (AI_skill_tools).

    Usage (from any working directory):
        powershell -NoProfile -ExecutionPolicy Bypass -File "<addon>\AI_skill_tools\run_all.ps1"
        powershell -NoProfile -ExecutionPolicy Bypass -File "<addon>\AI_skill_tools\run_all.ps1" cl_drag_probe

    luajit lookup order: -LuaJit arg -> env LUAJIT -> C:\LuaJIT\luajit.exe -> luajit on PATH
    Exit code = number of failed probes (0 = all passed).

    NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 as ANSI,
    so non-ASCII text here gets mangled and can break parsing.
#>
[CmdletBinding()]
param(
    [string]$LuaJit,
    [Parameter(Position = 0)][string]$Probe
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------- locate luajit ----------
$exe = $null
foreach ($cand in @($LuaJit, $env:LUAJIT, 'C:\LuaJIT\luajit.exe', 'luajit')) {
    if ([string]::IsNullOrWhiteSpace($cand)) { continue }
    if (Test-Path $cand) { $exe = (Resolve-Path $cand).Path; break }
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) { $exe = $cmd.Source; break }
}
if (-not $exe) { throw 'luajit.exe not found. Use -LuaJit <path> or set env LUAJIT.' }

# ---------- collect probes ----------
if ($Probe) {
    $name = if ($Probe -like '*.lua') { $Probe } else { "$Probe.lua" }
    $probes = @(Get-Item (Join-Path $here $name))
} else {
    $probes = @(Get-ChildItem $here -Filter '*_probe.lua' | Sort-Object Name)
}
if ($probes.Count -eq 0) { throw "no *_probe.lua found in $here" }

Write-Host "luajit : $exe" -ForegroundColor DarkGray
Write-Host "probes : $($probes.Count)" -ForegroundColor DarkGray

$failedProbes = @()
foreach ($p in $probes) {
    Write-Host ""
    Write-Host "===== $($p.Name) =====" -ForegroundColor Cyan
    & $exe $p.FullName
    if ($LASTEXITCODE -ne 0) { $failedProbes += $p.Name }
}

Write-Host ""
if ($failedProbes.Count -eq 0) {
    Write-Host "ALL PROBES PASSED ($($probes.Count))" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($failedProbes -join ', ')" -ForegroundColor Red
    exit $failedProbes.Count
}
