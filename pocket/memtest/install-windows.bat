<# : batch launcher: cmd runs these lines, PowerShell skips them as a block comment
@echo off
setlocal
set "MT_DIR=%~dp0"
set "MT_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Expression (Get-Content -LiteralPath $env:MT_SELF -Raw)"
echo.
pause
exit /b
#>
# Copy the PSX memory test core onto the Pocket's SD card. Double-click it.
# It takes memtest-135.zip / memtest-101.zip (or defgenx.PSXMemTest.zip) from its own folder: docs/pocket/MEMTEST.md, Install.
$ErrorActionPreference = 'Stop'
function Die($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# ---- which variant
$zips = @('memtest-135.zip', 'memtest-101.zip', 'defgenx.PSXMemTest.zip' |
    ForEach-Object { Join-Path $env:MT_DIR $_ } | Where-Object { Test-Path -LiteralPath $_ })
if ($zips.Count -eq 0) { Die 'no memtest zip next to this script; run pocket/memtest/build.sh package 135 (and 101) first' }
$zip = $zips[0]
if ($zips.Count -gt 1) {
    Write-Host 'Which variant?'
    for ($i = 0; $i -lt $zips.Count; $i++) {
        $note = ''; if ($zips[$i] -like '*-135.zip') { $note = '  (run this one first: the PSX core''s clock)' }
        Write-Host ("  {0}) {1}{2}" -f ($i + 1), (Split-Path $zips[$i] -Leaf), $note)
    }
    $n = Read-Host 'Number [1]'; if (-not $n) { $n = '1' }
    if ($n -notmatch '^\d+$' -or [int]$n -lt 1 -or [int]$n -gt $zips.Count) { Die "no such choice: $n" }
    $zip = $zips[[int]$n - 1]
}

# ---- which SD card: removable drives, plus any other drive that already has a Cores folder
$cands = @(Get-CimInstance Win32_LogicalDisk | Where-Object {
    $_.DeviceID -ne $env:SystemDrive -and ($_.DriveType -eq 2 -or
        ($_.DriveType -eq 3 -and (Test-Path -LiteralPath "$($_.DeviceID)\Cores" -ErrorAction SilentlyContinue)))
})
Write-Host ''
Write-Host "Which drive is the Pocket's SD card?"
for ($i = 0; $i -lt $cands.Count; $i++) {
    $d = $cands[$i]
    $mark = ''; if (Test-Path -LiteralPath "$($d.DeviceID)\Cores" -ErrorAction SilentlyContinue) { $mark = '  <- has a Cores folder (looks like a Pocket card)' }
    $size = ''; if ($d.Size) { $size = '{0:N1} GB' -f ($d.Size / 1GB) }
    Write-Host ("  {0}) {1}\  {2}  {3}{4}" -f ($i + 1), $d.DeviceID, $d.VolumeName, $size, $mark)
}
if ($cands.Count -eq 0) { Write-Host '  (no removable drive found: insert the card, or type its drive letter)' }
$n = Read-Host 'Number, or a drive letter'
if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $cands.Count) { $root = $cands[[int]$n - 1].DeviceID + '\' }
elseif ($n -match '^[A-Za-z]:?\\?$') { $root = $n.Substring(0, 1).ToUpper() + ':\' }
else { Die "no such choice: $n" }
if ($root.Substring(0, 2) -eq $env:SystemDrive) { Die "$root is the Windows drive, not the SD card" }
if (-not (Test-Path -LiteralPath $root)) { Die "$root is not ready (no card in the reader?)" }

Write-Host ''
Write-Host ("Copy {0} onto {1}" -f (Split-Path $zip -Leaf), $root)
Write-Host '(it writes only Cores\defgenx.PSXMemTest, Platforms\psxmemtest.json and Assets\psxmemtest; nothing else is touched)'
$a = Read-Host 'Go? [y/N]'
if ($a -notmatch '^(y|yes)$') { Die 'cancelled, nothing copied' }

Expand-Archive -LiteralPath $zip -DestinationPath $root -Force
try { Write-VolumeCache -DriveLetter $root.Substring(0, 1) } catch { }
if (-not (Test-Path -LiteralPath (Join-Path $root 'Cores\defgenx.PSXMemTest\memtest.rbf_r'))) { Die 'copy failed: memtest.rbf_r missing on the card' }

Write-Host ''
Write-Host 'Done. Eject the card safely, put it in the Pocket and start "PSX Memory Test".' -ForegroundColor Green
Write-Host 'Photograph the screen after row 0 says DONE, and again after 30 minutes. What to look at:'
Write-Host '  - every error count 0 (green)'
Write-Host '  - row 7: eye width 10 or more, flags 0 or 2'
Write-Host '  - rows 8-9: 0 late lines'
