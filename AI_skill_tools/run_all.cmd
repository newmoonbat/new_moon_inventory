@echo off
rem run_all.cmd - calls run_all.ps1 with execution policy bypassed.
rem Usage:  run_all.cmd                 run all probes
rem         run_all.cmd cl_drag_probe   run one probe
setlocal
set HERE=%~dp0
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%run_all.ps1" %*
exit /b %ERRORLEVEL%
