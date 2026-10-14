# Desinstalador de 247 Time Clock (pide permisos de administrador)
$EsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $EsAdmin) {
    Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $MyInvocation.MyCommand.Path + '"') -Verb RunAs
    exit
}
$Nombre  = '247 Time Clock'
$Destino = Join-Path $env:ProgramFiles '247 Time Clock'
Write-Host "Desinstalando $Nombre ..." -ForegroundColor Cyan
Get-Process -Name 'TimeClock247' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'TimeClock247' -ErrorAction SilentlyContinue
Remove-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\TimeClock247' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$Nombre.lnk") -Force -ErrorAction SilentlyContinue
Remove-Item -Path (Join-Path $env:PUBLIC "Desktop\$Nombre.lnk") -Force -ErrorAction SilentlyContinue
Remove-Item -Path $Destino -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Listo. (La sesion y los ajustes de cada usuario quedan en %LOCALAPPDATA%\247TimeClock; se pueden borrar a mano.)" -ForegroundColor Green
Start-Sleep -Seconds 4
