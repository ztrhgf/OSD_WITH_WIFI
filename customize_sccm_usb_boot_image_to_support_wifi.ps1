#Requires -RunAsAdministrator

<#

script for customization of boot.wim file placed on USB flash drive
to support Wi-Fi in SCCM OSD Task Sequence

boot.wim has to be created using OSDCloud module with explicit Wi-Fi support enabled

#>

param (
    [Parameter(Mandatory = $true, HelpMessage = "Enter path to empty folder to which boot.wim will be mounted")]
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
    $wimMountPath = "C:\temp\boot"
    ,
    [Parameter(Mandatory = $false, HelpMessage = "Enter path to boot.wim to modify")]
    [ValidateScript( {
            If ((Test-Path -Path $_) -and ($_ -match "\.wim$")) {
                $true
            } else {
                Throw "$_ doesn't exist, or is not a wim file"
            }
        })]
    $imagePath = ""
)

$ErrorActionPreference = "Stop"

if (! ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    throw "Run as administrator!"
}

try {
    #region mount SCCM boot.wim
    if (!$imagePath) {
        "- Searching for boot.wim on connected USB flash drives"
        # search for path to SCCM boot.wim image on USB drive
        while (1) {
            $USBDriveLetter = Get-Volume | ? { $_.DriveType -eq "Removable" } | select -exp DriveLetter

            if (!$USBDriveLetter) {
                Write-Warning "Connect SCCM USB boot drive"
                Start-Sleep 10
                continue
            }

            $USBImagePath = @()

            $USBDriveLetter | % {
                $imagePath = "$_`:\sources\boot.wim"
                if (Test-Path $imagePath) {
                    $USBImagePath += $imagePath
                }
            }

            if ($USBImagePath.count -eq 1) {
                " - $imagePath will be used"
                $imagePath = $USBImagePath[0]
                break
            } elseif ($USBImagePath.count -gt 1) {
                Write-Warning "More than one SCCM USB boot drive was found ($($USBDriveLetter -join ', ')).`nDisconnect all except the one, you want to customize"
                Start-Sleep 10
                continue
            } else {
                Write-Warning "None of connected USB drives ($($USBDriveLetter -join ', ')) is SCCM boot drive`n`nConnect it"
                Start-Sleep 10
            }
        }
    }

    "- Mounting '$imagePath' to '$wimMountPath'"
    Mount-WindowsImage -ImagePath $imagePath -Path $wimMountPath -Index 1 | Out-Null
    #endregion mount SCCM boot.wim

    #region customize winpeshl.ini (to initialize Wi-Fi ASAP)
    $winpeshl = "$wimMountPath\Windows\System32\winpeshl.ini"
    "- Customizing '$winpeshl' (to initialize Wi-Fi ASAP)"
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
        # save modified content back to winpeshl.ini
        $newContent | Out-File $winpeshl -Force
    }
    #endregion customize winpeshl.ini (to initialize Wi-Fi ASAP)

    #region customize Set-WinREWiFi (to omit removal of Wi-Fi xml profile)
    $WinREWiFi = Get-Item "$wimMountPath\Program Files\WindowsPowerShell\Modules\OSD\*\Public\WinREWiFi.ps1" | select -ExpandProperty FullName
    "- Customizing Set-WinREWiFi function saved in '$WinREWiFi' (to omit removal of Wi-Fi xml profile)"
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
    $startnet = "$wimMountPath\Windows\System32\startnet.cmd"
    "- Customizing '$startnet' (to omit OSDCloud builtin attempt to initialize Wi-Fi)"
    Set-Content -Path $startnet -Value (Get-Content $startnet | % {
            # comment the line
            ":: $_"
        })
    #endregion customize startnet.cmd (to omit OSDCloud builtin attempt to initialize Wi-Fi)

    #region dismount SCCM boot.wim
    "- Saving and dismounting '$imagePath' from '$wimMountPath'"
    Dismount-WindowsImage -Path $wimMountPath -Save | Out-Null
    #endregion dismount SCCM boot.wim
} catch {
    $err = $_
    #region dismount SCCM boot.wim
    "- Discarding and dismounting '$imagePath' from '$wimMountPath'"
    Dismount-WindowsImage -Path $wimMountPath -Discard | Out-Null
    #endregion dismount SCCM boot.wim

    throw $err
}