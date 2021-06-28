#Requires -RunAsAdministrator

<#
    .SYNOPSIS
    script for customization of boot.wim file placed on USB flash drive
    to support Wi-Fi in SCCM OSD Task Sequence

    boot.wim has to be created using OSDCloud module with explicit Wi-Fi support enabled (check NOTES)!

    What it does:
    - mount given/searched boot.wim
    - create helper connectWifi.ps1 script
    - create Wi-Fi xml profile for making unattend connection 
    - customize winpeshl.ini (to initialize Wi-Fi ASAP)
    - customize OSDCLoud function Set-WinREWiFi (to omit removal of Wi-Fi xml profile)
    - customize startnet.cmd (to omit OSDCloud builtin attempt to initialize Wi-Fi)
    - save & dismount boot.wim

    .PARAMETER wimMountPath
    Optional parameter.
    Path to empty folder, where boot.wim should be mounted.
    If not specified, random folder will be created in SYSTEM TEMP.

    .PARAMETER imagePath
    Optional parameter.
    Path to boot.wim which should be customized.
    If not specified, USB drives will be automatically searched.

    .PARAMETER wifiCredential
    Optional parameter.
    Wi-Fi credentials (SSID and password), that should be used for automatic Wi-Fi connection.
     - SSID is CASE SENSITIVE!
     - Password will be saved in plaintext!

    .PARAMETER xmlWiFiProfile
    Optional parameter.
    Path to exported Wi-Fi XML profile, that should be used for automatic Wi-Fi connection.
     - has to be exported with plaintext password!
      - netsh wlan export profile name=`"MyWifiSSID`" key=clear folder=C:\Wifi
    
    .PARAMETER pauseBeforeUnmount
    Switch for pausing the customization process before unmounting the boot.wim.
    So you can easily make another modifications of your choice.

    .EXAMPLE
    customize_sccm_usb_boot_image_to_support_wifi.ps1

    Search for boot.wim on connected USB drives, mount and customize it, to support interactive Wi-Fi connection. 

    .EXAMPLE
    customize_sccm_usb_boot_image_to_support_wifi.ps1 -wimMountPath C:\temp\boot -wifiCredential (Get-Credential)

    Search for boot.wim on connected USB drives, mount and customize it, to support unattended Wi-Fi connection. 
    Entered SSID and password will be stored as XML wifi profile in boot.wim and automatically used to make connection. 

    .EXAMPLE
    customize_sccm_usb_boot_image_to_support_wifi.ps1 -imagePath E:\Sources\boot.wim -wimMountPath C:\temp\boot -xmlWiFiProfile C:\temp\mywifi.xml

    Mount given boot.wim and customize it, to support unattended Wi-Fi connection. 
    Given wifi XML profile will be stored in boot.wim and automatically used to make connection. 

    .NOTES
    How to create Wi-Fi enabled boot.wim:

    Install-Module OSD -Force
    Import-Module OSD -Force

    # WinRE instead of WinPE to support Wi-Fi
    New-OSDCloud.template -WinRE -Verbose
    # create OSDCloud workspace folder
    $WorkspacePath = "C:\temp\OSDCloud"
    New-OSDCloud.workspace -WorkspacePath $WorkspacePath

    # add general Wi-Fi NIC drivers to boot image
    Edit-OSDCloud.winpe -CloudDriver Dell, HP, Nutanix, VMware, WiFi
    # if you need to add some custom drivers, use
    # Edit-OSDCloud.winpe -DriverPath "C:\myCustomDrivers"
#>

param (
    [Parameter(Mandatory = $false, HelpMessage = "Enter path to empty folder to which boot.wim will be mounted")]
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
    [string] $wimMountPath,

    [Parameter(Mandatory = $false, HelpMessage = "Enter path to boot.wim to modify")]
    [ValidateScript( {
            If ((Test-Path -Path $_) -and ($_ -match "\.wim$")) {
                $true
            } else {
                Throw "$_ doesn't exist, or is not a wim file"
            }
        })]
    [string] $imagePath,

    [Parameter(Mandatory = $false, HelpMessage = "Enter credentials (SSID and password) for Wi-Fi to connect. Password will be stored in plaintext though!")]
    [System.Management.Automation.PSCredential] $wifiCredential,

    [ValidateScript( {
            if (Test-Path -Path $_) {
                $true
            } else {
                throw "$_ doesn't exists"
            }
            if ($_ -notmatch "\.xml$") {
                throw "$_ isn't xml file"
            }
            if (!(([xml](Get-Content $_ -Raw)).WLANProfile.Name)) {
                throw "$_ isn't valid Wi-Fi XML profile. Use command like this, to create it: netsh wlan export profile name=`"MyWifiSSID`" key=clear folder=C:\Wifi"
            }
            if ((([xml](Get-Content $_ -Raw)).WLANProfile.MSM.security.sharedKey.protected) -ne "false") {
                throw "$_ isn't valid Wi-Fi XML profile. Password is not in plaintext. Use command like this, to create it: netsh wlan export profile name=`"MyWifiSSID`" key=clear folder=C:\Wifi"
            }
        })]
    [string] $xmlWiFiProfile,

    [switch] $pauseBeforeUnmount
)

$ErrorActionPreference = "Stop"

if ($wifiCredential -and $xmlWiFiProfile) {
    throw "Don't user wifiCredential and xmlWiFiProfile at the same time. Pick one of them!"
}

if (! ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    throw "Run as administrator!"
}

if (!$wimMountPath) {
    # remove parameter validations
    (Get-Variable wimMountPath).Attributes.Clear()
    # create random folder in system temp as a mount point
    do {
        $wimMountPath = "$env:windir\Temp\$(Get-Random)"
    } while (Test-Path $wimMountPath)
    [Void][System.IO.Directory]::CreateDirectory($wimMountPath)
    ++$mountCreated
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
                
                $choice = ""
                while ($choice -notmatch "^[Y|N]$") {
                        $choice = Read-Host "Continue? (Y|N)"
                }
                if ($choice -eq "N") {
                    break
                }

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

    #region create connectWifi script
    # helper PowerShell script, that will be used to making conection to Wi-Fi
    # will be called from winpeshl.ini
    # if there is in boot.wim stored Wi-Fi XML profile Windows\Temp\wprofile.xml, it will be automatically used for connection
    # otherwise, user will be prompted to choose the Wi-Fi to connect to 

    $connectWifi = "$wimMountPath\Windows\System32\connectWifi.ps1"

    "- Creating '$connectWifi' (helper script for ASAP initializion of Wi-Fi)"

    $connectWifiContent = @'
$Host.UI.RawUI.Windowtitle = "Making connection to Wi-Fi"

Start-Transcript "$env:TEMP\wreconnect.log"

# in case installation is running on ethernet cable i.e. is already connected to the internet
if (Test-WebConnection -Uri 'google.com') {
    "You are already connected to the Internet"
    return
}

$OSDrive = Get-Volume | ? { $_.FileSystemLabel -eq "Windows" } | select -exp DriveLetter | % {"$_`:"}
# location where the wifi profile should be stored
# start searching on installed OS, then WinPE
$WCFG = "$OSDrive\Windows\WCFG", "X:\Windows\Temp"

# search for wifi xml profile
$WCFG | % {
    $wifiProfile = "$_\wprofile.xml"
    if (Test-Path $wifiProfile) {
        return
    } else {
        $wifiProfile = ""
    }
}

# installs Plug and Play devices, processes Unattend.xml settings, and loads network resources
wpeinit.exe

if ($wifiProfile -and (Test-Path $wifiProfile)) {
    "Using existing wifi profile for making connection"

    try {
        Start-WinREWiFi -wifiProfile $wifiProfile -ErrorAction Stop
    } catch {
        # probably used old version of the OSDCloud module without support for wifiProfile parameter
        # simulating functionality of the Start-WinREWiFi

        if (Test-WebConnection -Uri 'google.com') {
            "You are already connected to the Internet"
            return
        }

        # get SSID
        $SSID = ([xml](Get-Content $wifiProfile)).WLANProfile.Name

        "Wi-Fi profile '$wifiProfile' will be used to connect to $SSID"

        # start wifi service
        if (Get-Service -Name WlanSvc) {
            if ((Get-Service -Name WlanSvc).Status -ne 'Running') {
                "Starting WlanSvc service"
                Get-Service -Name WlanSvc | Start-Service
                Start-Sleep -Seconds 10
            }
        }

        # just for sure
        $null = netsh wlan delete profile "$SSID"

        # import wifi profile
        $null = netsh wlan add profile filename="$wifiProfile"

        # connect to SSID
        $result = netsh wlan connect name="$SSID" ssid="$SSID"

        if ($result -ne "Connection request was completed successfully.") {
            Write-Warning "Connection to WIFI wasn't successful. Error was $result"
            # use OSDCloud function for making initial connection
            Start-WinREWiFi
        } else {
            # establishing connection takes time
            $i = 60
            while (!(test-connection "google.com" -Count 1 -Quiet) -and $i -gt 1) {
                "waiting for internet connection ($i)"
                sleep 1
                --$i
            }
        }
    }
} else {
    # there isn't any wifi profile to use
    # use OSDCloud function for making initial connection

    "No Wi-Fi profile was found, making initial connection" 

    Start-WinREWiFi
}
'@ 
    Set-Content -Value $connectWifiContent -Path $connectWifi -Force
    #endregion create connectWifi script

    #region create Wi-Fi xml profile for making unattend connection
    $wifiProfile = "$wimMountPath\Windows\Temp\wprofile.xml"
    if ($wifiCredential) {
        # TEMP is automatically searched by custom TASK SEQUENCE 'COPY Wi-Fi PROFILE TO OS DISK' step, that copies xml profile to installed OS for Wi-Fi persistence

        $SSID = $wifiCredential.UserName
        "- Generating Wi-Fi profile for '$SSID' (auth: WPA2PSK, enc: AES) and saving it at '$wifiProfile'"
        Write-Warning "Wi-Fi password will be stored in plaintext!"
        $SSIDHex = ($SSID.ToCharArray() | Foreach-Object { '{0:X}' -f ([int]$_) }) -join ''
        $wPassword = $wifiCredential.GetNetworkCredential().Password
        $wifiProfileXml = @"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
    <name>$SSID</name>
    <SSIDConfig>
        <SSID>
            <hex>$SSIDHex</hex>
            <name>$SSID</name>
        </SSID>
    </SSIDConfig>
    <connectionType>ESS</connectionType>
    <connectionMode>auto</connectionMode>
    <MSM>
        <security>
            <authEncryption>
                <authentication>WPA2PSK</authentication>
                <encryption>AES</encryption>
                <useOneX>false</useOneX>
            </authEncryption>
            <sharedKey>
                <keyType>passPhrase</keyType>
                <protected>false</protected>
                <keyMaterial>$wPassword</keyMaterial>
            </sharedKey>
        </security>
    </MSM>
</WLANProfile>        
"@

        Set-Content -Value $wifiProfileXml -Path $wifiProfile -Force
    } elseif ($xmlWiFiProfile) {
        "- Saving Wi-Fi profile '$xmlWiFiProfile' at '$wifiProfile'"
        Copy-Item $xmlWiFiProfile $wifiProfile -Force
    } else {
        # delete any existing XML profile
        if (Test-Path $wifiProfile) {
            $SSID = ([xml](Get-Content $wifiProfile)).WLANProfile.Name
            Write-Warning "Removing existing Wi-Fi profile '$wifiProfile' for connecting to '$SSID'"
            Remove-Item $wifiProfile -Force
        }

    }
    #endregion create Wi-Fi xml profile for making unattend connection
        
    #region customize winpeshl.ini (to initialize Wi-Fi ASAP)
    $winpeshl = "$wimMountPath\Windows\System32\winpeshl.ini"
    "- Customizing '$winpeshl' (to initialize Wi-Fi ASAP)"
    $currentContent = Get-Content $winpeshl
    if (!($currentContent -match "connectWifi\.ps1")) {
        # not yet modified

        $newContent = @"
[LaunchApps]
PowerShell.exe, -NoProfile -NoLogo -ExecutionPolicy Bypass -File %WINDIR%\System32\connectWifi.ps1
"@

        # add former commands
        $currentContent | ? { $_ -ne "[LaunchApps]" } | % { $newContent += "`r`n$_`r`n" }
        # save modified content back to winpeshl.ini
        $newContent | Out-File $winpeshl -Force
    }
    #endregion customize winpeshl.ini (to initialize Wi-Fi ASAP)

    #region customize OSDCLoud function Set-WinREWiFi (to omit removal of Wi-Fi xml profile)
    $WinREWiFi = Get-Item "$wimMountPath\Program Files\WindowsPowerShell\Modules\OSD\*\Public\WinREWiFi.ps1" | Select-Object -ExpandProperty FullName
    $replacedLine = 0
    $lineRegex = '\s*Remove-Item \$WlanConfig -ErrorAction SilentlyContinue'
    "- Customizing Set-WinREWiFi function defined in '$WinREWiFi' (to omit removal of Wi-Fi xml profile)"
    Set-Content -Path $WinREWiFi -Value (Get-Content $WinREWiFi | % {
            if ($_ -match "^$lineRegex") {
                # comment the line
                "# commented so I can use it to make Wi-Fi connection persistent, via importing it again after the restart to installed OS"
                "# $_"
                ++$replacedLine
            } elseif ($_ -match "^#$lineRegex") {
                # already commented
                ++$replacedLine
                # leave it as it is
                $_
            } else {
                # leave it as it is
                $_
            }
        })
    if (!$replacedLine) {
        Write-Warning "No modification to the function Set-WinREWiFi was made! Its content was probably changed. Check manually."
        $choice = ""
        while ($choice -notmatch "^[Y|N]$") {
            $choice = Read-Host "Continue? (Y|N)"
        }
        if ($choice -eq "N") {
            break
        }
    }
    if ($replacedLine -gt 1) {
        Write-Warning "Multiple lines were commented! Function content was probably changed. Check manually."
        $choice = ""
        while ($choice -notmatch "^[Y|N]$") {
            $choice = Read-Host "Continue? (Y|N)"
        }
        if ($choice -eq "N") {
            break
        }
    }
    #endregion customize OSDCLoud function Set-WinREWiFi (to omit removal of Wi-Fi xml profile)

    #region customize startnet.cmd (to omit OSDCloud builtin attempt to initialize Wi-Fi)
    $startnet = "$wimMountPath\Windows\System32\startnet.cmd"
    "- Customizing '$startnet' (to omit OSDCloud builtin attempt to initialize Wi-Fi)"
    Set-Content -Path $startnet -Value (Get-Content $startnet | % {
            # comment the line
            ":: $_"
        })
    #endregion customize startnet.cmd (to omit OSDCloud builtin attempt to initialize Wi-Fi)

    #region pause 
    if ($pauseBeforeUnmount) {
        Write-Warning "PAUSED"
        $choice = ""
        while ($choice -notmatch "^Y$") {
                $choice = Read-Host "Continue? (Y)"
        }
    }
    #endregion pause 

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
} finally {
    if ($mountCreated) {
        # remove created mount folder
        Remove-Item $wimMountPath -Recurse -Force
    }
}