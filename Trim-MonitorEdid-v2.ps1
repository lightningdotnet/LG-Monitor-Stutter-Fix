#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Trims bloated mode lists from monitor EDIDs to fix the Windows stutter bug
    caused by NtGdiDdDDIGetDisplayModeList enumeration overhead.

.DESCRIPTION
    Some monitors (notably LG ultrawides and OLEDs) report enormous mode lists
    in their EDID. Windows enumerates the full list on every display-mode query,
    which happens continuously during desktop use and at every application
    startup. On affected hardware this manifests as system-wide stutter.

    This script writes EDID overrides to the documented Microsoft mechanism:

        HKLM\...\Device Parameters\EDID_OVERRIDE\
            0  (REG_BINARY, 128 bytes) - override for base EDID block
            1  (REG_BINARY, 128 bytes) - override for extension block 1
            ... etc

    The monitor driver merges overridden blocks from the registry with
    non-overridden blocks from the monitor's EEPROM during initialization.

    What this script does:
      1. Locates the target monitor in the registry by manufacturer code
      2. Reads the monitor's actual EDID (cache value) for analysis
      3. Backs up the original EDID to a .bak file
      4. Builds a trimmed override:
         - Zeros Established Timings (legacy modes: 640x480, 800x600, etc.)
         - Marks Standard Timings as unused
         - (Optional, -Aggressive) Trims Video Data Blocks in CTA-861 extension
      5. Recalculates EDID checksums for any modified block
      6. Writes overrides to the EDID_OVERRIDE sub-key

    Detailed Timing Descriptors are PRESERVED, so high-refresh-rate modes
    (e.g. 3440x1440 @ 240Hz on LG 34GX900A-B) remain intact.

    NOTE: A REBOOT is required to apply EDID_OVERRIDE changes. Driver-only
    restarts (Ctrl+Shift+Win+B) are NOT sufficient because EDID_OVERRIDE
    is read by the monitor driver during device initialization.

.PARAMETER ManufacturerCode
    3-letter PNP manufacturer code. Default 'GSM' (LG).
    Common: GSM=LG, SAM=Samsung, ACR=Acer, DEL=Dell, AUS=ASUS, MSI=MSI.

.PARAMETER Aggressive
    Also override extension block 1 (CTA-861) with trimmed Video Data Blocks.
    Default: off. Conservative mode (default) overrides only the base block.

.PARAMETER Restore
    Remove all EDID_OVERRIDE sub-keys for matched monitors. Reverts to using
    EEPROM data unchanged.

.PARAMETER WhatIf
    Show what would change without writing.

.EXAMPLE
    .\Trim-MonitorEdid-v2.ps1
    Conservative trim: override base block only.

.EXAMPLE
    .\Trim-MonitorEdid-v2.ps1 -Aggressive
    Also trim CTA-861 video data blocks.

.EXAMPLE
    .\Trim-MonitorEdid-v2.ps1 -Restore
    Remove the override sub-key, return to EEPROM-only EDID.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ManufacturerCode = 'GSM',
    [switch]$Aggressive,
    [switch]$Restore
)

# =============================================================================
# CONSTANTS
# =============================================================================

$DisplayKey = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
$BackupDir  = Join-Path $PSScriptRoot 'edid-backups'

# VESA E-EDID 1.4 base block offsets
$OFFSET_MFG_ID             = 0x08
$OFFSET_ESTABLISHED_TIMING = 0x23
$OFFSET_STANDARD_TIMINGS   = 0x26
$OFFSET_DTD_BLOCKS         = 0x36
$OFFSET_EXTENSION_COUNT    = 0x7E
$OFFSET_BASE_CHECKSUM      = 0x7F

$EDID_BLOCK_SIZE = 128
$EDID_HEADER     = [byte[]](0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00)

# CTA-861 extension block fields
$CTA_TAG              = 0x02
$CTA_DTD_OFFSET_FIELD = 0x02
$CTA_DBC_START        = 0x04
$CTA_VIDEO_BLOCK_TYPE = 0x02

# =============================================================================
# HELPERS
# =============================================================================

function Validate-EdidHeader {
    param([byte[]]$Edid)
    if (-not $Edid -or $Edid.Length -lt $EDID_BLOCK_SIZE) { return $false }
    for ($i = 0; $i -lt 8; $i++) {
        if ($Edid[$i] -ne $EDID_HEADER[$i]) { return $false }
    }
    return $true
}

function Compute-Checksum {
    param([byte[]]$Block)
    $sum = 0
    for ($i = 0; $i -lt 127; $i++) { $sum = ($sum + $Block[$i]) -band 0xFF }
    return [byte](((256 - $sum) -band 0xFF))
}

function Decode-MfgId {
    param([byte[]]$Edid)
    $bits = ($Edid[$OFFSET_MFG_ID] -shl 8) -bor $Edid[$OFFSET_MFG_ID + 1]
    $c1 = [char](64 + (($bits -shr 10) -band 0x1F))
    $c2 = [char](64 + (($bits -shr 5)  -band 0x1F))
    $c3 = [char](64 + ($bits           -band 0x1F))
    return "$c1$c2$c3"
}

function Decode-MonitorName {
    param([byte[]]$Edid)
    for ($i = 0; $i -lt 4; $i++) {
        $base = $OFFSET_DTD_BLOCKS + ($i * 18)
        if ($Edid[$base] -eq 0 -and $Edid[$base + 1] -eq 0 -and $Edid[$base + 3] -eq 0xFC) {
            $name = ''
            for ($j = 5; $j -le 17; $j++) {
                $b = $Edid[$base + $j]
                if ($b -eq 0x0A) { break }
                $name += [char]$b
            }
            return $name.Trim()
        }
    }
    return '(unknown)'
}

function Count-EstablishedTimings {
    param([byte[]]$Edid)
    $count = 0
    for ($i = 0; $i -lt 3; $i++) {
        $b = $Edid[$OFFSET_ESTABLISHED_TIMING + $i]
        for ($bit = 0; $bit -lt 8; $bit++) {
            if (($b -shr $bit) -band 1) { $count++ }
        }
    }
    return $count
}

function Count-StandardTimings {
    param([byte[]]$Edid)
    $count = 0
    for ($i = 0; $i -lt 8; $i++) {
        $a = $Edid[$OFFSET_STANDARD_TIMINGS + ($i * 2)]
        $b = $Edid[$OFFSET_STANDARD_TIMINGS + ($i * 2) + 1]
        if (-not ($a -eq 0x01 -and $b -eq 0x01)) { $count++ }
    }
    return $count
}

function Find-MonitorEdids {
    param([string]$MfgCode)
    $results = @()
    Get-ChildItem $DisplayKey -ErrorAction Stop | ForEach-Object {
        $mfgKey = $_
        if ($mfgKey.PSChildName -like "$MfgCode*") {
            Get-ChildItem $mfgKey.PSPath | ForEach-Object {
                $instance = $_
                $devParams = Join-Path $instance.PSPath 'Device Parameters'
                if (Test-Path $devParams) {
                    $edid = (Get-ItemProperty -Path $devParams -Name 'EDID' -ErrorAction SilentlyContinue).EDID
                    if ($edid -and $edid.Length -ge $EDID_BLOCK_SIZE) {
                        $results += [PSCustomObject]@{
                            RegistryPath = $devParams
                            MonitorId    = $mfgKey.PSChildName
                            InstanceId   = $instance.PSChildName
                            EdidBytes    = [byte[]]$edid
                            OverrideKey  = Join-Path $devParams 'EDID_OVERRIDE'
                        }
                    }
                }
            }
        }
    }
    # Force array even on single result (avoids PS auto-unwrap)
    return @($results)
}

function Trim-CtaVideoDataBlocks {
    param(
        [byte[]]$Edid,
        [int]$BlockOffset
    )
    if ($Edid[$BlockOffset] -ne $CTA_TAG) { return 0 }

    $dtdOffset = $Edid[$BlockOffset + $CTA_DTD_OFFSET_FIELD]
    if ($dtdOffset -le $CTA_DBC_START) { return 0 }

    $dbcStart    = $BlockOffset + $CTA_DBC_START
    $dbcEnd      = $BlockOffset + $dtdOffset
    $bytesZeroed = 0
    $cursor      = $dbcStart

    while ($cursor -lt $dbcEnd) {
        $tagByte   = $Edid[$cursor]
        $blockType = ($tagByte -shr 5) -band 0x07
        $blockLen  = $tagByte -band 0x1F

        if ($blockLen -eq 0 -and $blockType -eq 0) {
            $cursor++
            continue
        }

        if ($blockType -eq $CTA_VIDEO_BLOCK_TYPE) {
            for ($i = 0; $i -le $blockLen; $i++) {
                $Edid[$cursor + $i] = 0x00
            }
            $bytesZeroed += ($blockLen + 1)
        }

        $cursor += ($blockLen + 1)
    }

    return $bytesZeroed
}

function Build-TrimmedBlocks {
    # Returns a hashtable: { BlockNumber -> 128-byte modified block }
    # Only includes blocks that are actually being modified.
    param(
        [byte[]]$Edid,
        [switch]$AggressiveMode
    )

    $modified = [byte[]]::new($Edid.Length)
    [Array]::Copy($Edid, $modified, $Edid.Length)
    $changedBlocks = @{}

    # ---- Block 0: base EDID ----
    for ($i = 0; $i -lt 3; $i++) {
        $modified[$OFFSET_ESTABLISHED_TIMING + $i] = 0x00
    }
    for ($i = 0; $i -lt 8; $i++) {
        $modified[$OFFSET_STANDARD_TIMINGS + ($i * 2)]     = 0x01
        $modified[$OFFSET_STANDARD_TIMINGS + ($i * 2) + 1] = 0x01
    }
    $baseBlock = [byte[]]::new($EDID_BLOCK_SIZE)
    [Array]::Copy($modified, 0, $baseBlock, 0, $EDID_BLOCK_SIZE)
    $baseBlock[$OFFSET_BASE_CHECKSUM] = Compute-Checksum -Block $baseBlock
    $changedBlocks[0] = $baseBlock

    # ---- Extension blocks (only if aggressive) ----
    if ($AggressiveMode) {
        $extCount = $modified[$OFFSET_EXTENSION_COUNT]
        for ($e = 0; $e -lt $extCount; $e++) {
            $extOffset = $EDID_BLOCK_SIZE * ($e + 1)
            if ($extOffset + $EDID_BLOCK_SIZE -gt $modified.Length) { continue }
            $zeroed = Trim-CtaVideoDataBlocks -Edid $modified -BlockOffset $extOffset
            if ($zeroed -gt 0) {
                $extBlock = [byte[]]::new($EDID_BLOCK_SIZE)
                [Array]::Copy($modified, $extOffset, $extBlock, 0, $EDID_BLOCK_SIZE)
                $extBlock[$EDID_BLOCK_SIZE - 1] = Compute-Checksum -Block $extBlock
                $changedBlocks[$e + 1] = $extBlock
            }
        }
    }

    return $changedBlocks
}

function Get-BackupPath {
    param($Monitor)
    $safeInstance = $Monitor.InstanceId -replace '[\\/:*?"<>|]', '_'
    return Join-Path $BackupDir "$($Monitor.MonitorId)_$safeInstance.bak"
}

function Write-Banner {
    param([string]$Text)
    $line = '-' * $Text.Length
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host $line  -ForegroundColor Cyan
}

# =============================================================================
# MAIN
# =============================================================================

if (-not (Test-Path $BackupDir)) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

Write-Banner "Searching for monitors with manufacturer code '$ManufacturerCode'"

$monitors = Find-MonitorEdids -MfgCode $ManufacturerCode

if ($monitors.Count -eq 0) {
    Write-Error "No monitors found with manufacturer code '$ManufacturerCode'."
    exit 1
}

Write-Host ''
Write-Host "Found $($monitors.Count) monitor(s):"

for ($i = 0; $i -lt $monitors.Count; $i++) {
    $m = $monitors[$i]
    if (-not (Validate-EdidHeader -Edid $m.EdidBytes)) {
        Write-Warning "  [$i] Invalid EDID header at $($m.RegistryPath) - will skip"
        continue
    }
    $mfg  = Decode-MfgId             -Edid $m.EdidBytes
    $name = Decode-MonitorName       -Edid $m.EdidBytes
    $est  = Count-EstablishedTimings -Edid $m.EdidBytes
    $std  = Count-StandardTimings    -Edid $m.EdidBytes
    $ext  = $m.EdidBytes[$OFFSET_EXTENSION_COUNT]
    $hasOverride = Test-Path $m.OverrideKey

    Write-Host ''
    Write-Host "  [$i] $mfg '$name'"
    Write-Host "      MonitorId         : $($m.MonitorId)"
    Write-Host "      EDID size         : $($m.EdidBytes.Length) bytes ($ext extension blocks)"
    Write-Host "      Est. Timings      : $est / 17"
    Write-Host "      Std. Timings      : $std / 8"
    Write-Host "      EDID_OVERRIDE key : $(if ($hasOverride) { 'EXISTS' } else { 'absent' })"
}

# =============================================================================
# RESTORE
# =============================================================================

if ($Restore) {
    Write-Banner 'Restore mode: removing EDID_OVERRIDE'
    foreach ($m in $monitors) {
        if (Test-Path $m.OverrideKey) {
            if ($PSCmdlet.ShouldProcess($m.OverrideKey, 'Remove EDID_OVERRIDE sub-key')) {
                Remove-Item -Path $m.OverrideKey -Recurse -Force
                Write-Host "  Removed EDID_OVERRIDE for $($m.MonitorId)" -ForegroundColor Green
            }
        } else {
            Write-Host "  No EDID_OVERRIDE present for $($m.MonitorId) (already restored)" -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host 'REBOOT to apply.' -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# APPLY OVERRIDE
# =============================================================================

Write-Banner 'Applying EDID override'
if ($Aggressive) {
    Write-Host '  Mode: Aggressive (overrides base block + extension blocks)' -ForegroundColor Yellow
} else {
    Write-Host '  Mode: Conservative (overrides base block only)' -ForegroundColor Yellow
}

foreach ($m in $monitors) {
    if (-not (Validate-EdidHeader -Edid $m.EdidBytes)) { continue }

    Write-Host ''
    Write-Host "Processing $($m.MonitorId)..." -ForegroundColor Cyan

    # Backup original (cache) EDID
    $bak = Get-BackupPath $m
    if (-not (Test-Path $bak)) {
        if ($PSCmdlet.ShouldProcess($bak, 'Save backup of original EDID')) {
            [System.IO.File]::WriteAllBytes($bak, $m.EdidBytes)
            Write-Host "  Backup written : $bak" -ForegroundColor Green
        }
    } else {
        Write-Host "  Backup exists  : $bak (preserved)" -ForegroundColor Yellow
    }

    # Build trimmed blocks
    $changedBlocks = Build-TrimmedBlocks -Edid $m.EdidBytes -AggressiveMode:$Aggressive

    # Validate each modified block before writing
    $allValid = $true
    foreach ($blockNum in $changedBlocks.Keys) {
        $block = $changedBlocks[$blockNum]
        if ($blockNum -eq 0 -and -not (Validate-EdidHeader -Edid $block)) {
            Write-Error "  Modified base block has invalid header - aborting"
            $allValid = $false
            break
        }
        if ($block.Length -ne $EDID_BLOCK_SIZE) {
            Write-Error "  Modified block $blockNum has wrong size $($block.Length) - aborting"
            $allValid = $false
            break
        }
    }
    if (-not $allValid) { continue }

    # Show summary of changes for base block
    $estBefore = Count-EstablishedTimings -Edid $m.EdidBytes
    $stdBefore = Count-StandardTimings    -Edid $m.EdidBytes
    $estAfter  = Count-EstablishedTimings -Edid $changedBlocks[0]
    $stdAfter  = Count-StandardTimings    -Edid $changedBlocks[0]
    Write-Host "  Established    : $estBefore -> $estAfter"
    Write-Host "  Standard       : $stdBefore -> $stdAfter"
    if ($Aggressive) {
        $extKeys = @($changedBlocks.Keys | Where-Object { $_ -gt 0 })
        Write-Host "  Ext. blocks modified : $($extKeys.Count) ($($extKeys -join ', '))"
    }

    # Create EDID_OVERRIDE sub-key if needed
    if (-not (Test-Path $m.OverrideKey)) {
        if ($PSCmdlet.ShouldProcess($m.OverrideKey, 'Create EDID_OVERRIDE sub-key')) {
            New-Item -Path $m.OverrideKey -Force | Out-Null
        }
    }

    # Write each modified block as a numbered REG_BINARY value
    foreach ($blockNum in ($changedBlocks.Keys | Sort-Object)) {
        $block    = $changedBlocks[$blockNum]
        $valName  = "$blockNum"
        if ($PSCmdlet.ShouldProcess("$($m.OverrideKey)\$valName", "Write override block $blockNum")) {
            # Use New-ItemProperty to ensure REG_BINARY type, with -Force to overwrite
            New-ItemProperty -Path $m.OverrideKey -Name $valName -Value ([byte[]]$block) `
                -PropertyType Binary -Force | Out-Null
            Write-Host "  Wrote block $blockNum to $($m.OverrideKey)\$valName" -ForegroundColor Green
        }
    }

    # Verify by reading back
    foreach ($blockNum in ($changedBlocks.Keys | Sort-Object)) {
        $valName = "$blockNum"
        try {
            $readBack = (Get-ItemProperty -Path $m.OverrideKey -Name $valName -ErrorAction Stop).$valName
            if ($readBack.Length -ne $EDID_BLOCK_SIZE) {
                Write-Warning "  Verify: block $blockNum read back as $($readBack.Length) bytes"
            } else {
                Write-Host "  Verify block $blockNum : OK ($($readBack.Length) bytes REG_BINARY)" -ForegroundColor DarkGreen
            }
        } catch {
            Write-Warning "  Verify failed for block $blockNum : $_"
        }
    }
}

Write-Host ''
Write-Banner 'Next steps'
Write-Host '  1. REBOOT the system. Driver-only restart is NOT enough -' -ForegroundColor Yellow
Write-Host '     EDID_OVERRIDE is read by the monitor driver during device init.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  2. After reboot, open NVIDIA Control Panel -> Change Resolution.' -ForegroundColor Yellow
Write-Host '     The mode list for the LG should be substantially shorter.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  3. Test desktop usability and RuneLite. The stutter should be gone.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  To revert: .\Trim-MonitorEdid-v2.ps1 -Restore  (then reboot)' -ForegroundColor Yellow
