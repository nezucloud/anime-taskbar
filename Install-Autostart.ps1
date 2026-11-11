# Starts the taskbar overlay automatically at sign-in (a shortcut in the user's Startup folder).
# Usage:  .\Install-Autostart.ps1            install and start now
#         .\Install-Autostart.ps1 -Uninstall remove the shortcut
param([switch]$Uninstall)

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Taskbar Mood Overlay.lnk'
$overlayScript = Join-Path $PSScriptRoot 'TaskbarGif.ps1'

if ($Uninstall) {
    Remove-Item $shortcutPath -ErrorAction SilentlyContinue
    Write-Host "Autostart removed. Use the tray icon's Exit to stop the running overlay."
    return
}

# conhost --headless runs PowerShell with no console window, so nothing flashes at sign-in.
$arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File `"$overlayScript`""
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\conhost.exe'
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.Description = 'Animated anime heads on the taskbar that react to CPU/RAM load'
$shortcut.Save()

Start-Process $shortcut.TargetPath -ArgumentList $arguments -WorkingDirectory $PSScriptRoot
Write-Host "Autostart installed: $shortcutPath"
