#Requires -RunAsAdministrator

<#

script for customization of boot.wim file placed on USB flash drive
to support Wi-Fi in SCCM OSD Task Sequence

boot.wim has to be created using OSDCloud module with explicit Wi-Fi support enabled

#>

param (
    [Parameter(Mandatory = $true)]
    [ValidateScript( {
            If (Test-Path -Path $_ -PathType Container) {
                $true
            } else {
                Throw "$_ doesn't exist, or is not a folder"
            }

            If (Get-ChildItem -Path $_) {
                Throw "$_ has to be empty folder"
            } else {
                $true
            }
        })]
    $mountPath = "C:\temp\boot"
    ,
    [ValidateScript( {
            If ((Test-Path -Path $_) -and ($_ -match "\.wim$")) {
                $true
            } else {
                Throw "$_ doesn't exist, or is not a wim file"
            }
        })]
    $imagePath = ""
)

Write-Warning "Don't run this on already modified USB drive!"
$choice = ""
while ($choice -notmatch "^[Y|N]$") {
    $choice = Read-Host "Continue? (Y|N)"
}
if ($choice -eq "N") {
    break
}

#region mount SCCM boot.wim
if (!$imagePath) {
    # search for path to SCCM boot.wim image on USB drive
    while (1) {
        $USBDriveLetter = Get-Volume | ? { $_.DriveType -eq "Removable" } | select -exp DriveLetter

        if (!$USBDriveLetter) {
            Write-Warning "Connect SCCM USB boot drive"
            Start-Sleep 10
            continue
        }

        $USBDriveLetter | % {
            $imagePath = "$_`:\sources\boot.wim"
            if (Test-Path $imagePath) {
                "$imagePath will be used"
                break
            }
        }

        Write-Warning "None of connected USB drives ($($USBDriveLetter -join ', ')) is SCCM boot drive`n`nConnect it"
        Start-Sleep 10
    }
}

Mount-WindowsImage -ImagePath $imagePath -Path $mountPath -Index 1
#endregion mount SCCM boot.wim

#region customize winpeshl.ini (to initialize Wi-Fi ASAP)
$winpeshl = "$mountPath\Windows\System32\winpeshl.ini"
$currentContent = Get-Content $winpeshl
if (!($currentContent -match "Start-WinREWiFi")) {
    # not yet modified

    $newContent = @"
[LaunchApps]
Wpeinit.exe
PowerShell.exe, -NoL -C Start-WinREWiFi
"@

    # add original commands
    $currentContent | ? { $_ -ne "[LaunchApps]" } | % { $newContent += "`r`n$_`r`n" }
    $newContent | Out-File $winpeshl -Force
}
#endregion customize winpeshl.ini (to initialize Wi-Fi ASAP)

#region customize Set-WinREWiFi (to omit removal of Wi-Fi xml profile)
$WinREWiFi = Get-Item "$mountPath\Program Files\WindowsPowerShell\Modules\OSD\*\Public\WinREWiFi.ps1" | select -ExpandProperty FullName
Set-Content -Path $WinREWiFi -Value (Get-Content $WinREWiFi | % {
        if ($_ -match '^\s*Remove-Item \$WlanConfig -ErrorAction SilentlyContinue') {
            # comment the line
            "# commented so I can use it to make Wi-Fi connection persistent, via importing it again after the restart to installed OS"
            "# $_"
        } else {
            # leave it as it is
            $_
        }
    })
#endregion customize Set-WinREWiFi (to omit removal of Wi-Fi xml profile)

#region customize startnet.cmd (to omit OSDCloud builtin attempt to initialize Wi-Fi)
$startnet = "$mountPath\Windows\System32\startnet.cmd"
Set-Content -Path $startnet -Value (Get-Content $startnet | % {
        # comment the line
        ":: $_"
    })
#endregion customize startnet.cmd (to omit OSDCloud builtin attempt to initialize Wi-Fi)

#region dismount SCCM boot.wim
Dismount-WindowsImage -Path $mountPath -Save
#endregion dismount SCCM boot.wim