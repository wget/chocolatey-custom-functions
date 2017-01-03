# To test function outside of chocolatey, just copy them to another file and
# run the following command:
# powershell -ExecutionPolicy Unrestricted -File .\yourFile.ps1

# This function is based on part of the code of the command
# Install-ChocolateyPackage
# src.: https://goo.gl/jUpwOQ
function GetTempDirChocoPackage {
<#
.DESCRIPTION
Create a temporary folder in current user temporary location. The folder name
has the name of the package name and version (if any).

.OUTPUTS
The location to the created directory
#>
    $chocTempDir = $env:TEMP
    $tempDir = Join-Path $chocTempDir "$($env:chocolateyPackageName)"
    if ($env:chocolateyPackageVersion -ne $null) {
        $tempDir = Join-Path $tempDir "$($env:chocolateyPackageVersion)"
    }
    $tempDir = $tempDir -replace '\\chocolatey\\chocolatey\\', '\chocolatey\'

    if (![System.IO.Directory]::Exists($tempDir)) {
        [System.IO.Directory]::CreateDirectory($tempDir) | Out-Null
    }

    return $tempDir
}

function PrintWhenChocoVerbose {
<#
.DESCRIPTION
Display the string passed as argument if chocolatey has been run in debug or
verbose mode. The string argument is cut automatically and each line is
prefixed by the "VERBOSE: " statement thanks to the call of Write-Verbose
cmdlet.

.PARAMETER string
The string to display in verbose mode
#>
    param (
        [Parameter(Position=0)]
        [string]
        $string
    )

    # Display the output of the executables if chocolatey is run either in debug
    # or in verbose mode.
    if ($env:ChocolateyEnvironmentDebug -eq 'true' -or
        $env:ChocolateyEnvironmentVerbose -eq 'true') {

        $stringReader = New-Object System.IO.StringReader("$string")
        while (($line = $stringReader.ReadLine()) -ne $null) {
           Write-Verbose "$line"
        }
    }
}

function GetServiceProperties {
<#
.DESCRIPTION
Get service properties

.OUTPUTS
An object made of the following fields:
- name (string)
- status (string)
- startupType (string)
- delayedStart (bool)
#>
    param (
        [Parameter(Mandatory=$true)][string]$name
    )

    # Lets return our own object.
    # src.: http://stackoverflow.com/a/12621314
    $properties = "" | Select-Object -Property name,status,startupType,delayedStart

    # Get-Service is not throwing an exception when the service name
    # contains * (asterisks) and the service is not found. Prevent that.
    if ($name -cmatch "\*") {
        Write-Warning "Asterisks have been discarded from the service name '$name'"
        $name = $name -Replace "\*",""
    }

    # The Get-Service Cmdlet returns a System.ServiceProcess.ServiceController
    # Get-Service throws an exception when the exact case insensitive service
    # is not found. Therefore, there is no need to make any further checks.
    $service = Get-Service "$name" -ErrorAction Stop

    # Correct to the exact service name
    if ($name -cnotmatch $service.Name) {
        Write-Warning "The case sensitive service name is '$($service.Name)' not '$name'"
    }
    $properties.name = $service.Name

    # Get the service status. The Status property returns an enumeration
    # ServiceControllerStatus src.: https://goo.gl/oq8Bbx
    # This cannot be tested directly from CLI as the .NET assembly is not
    # loaded, we get an exception
    [array]$statusAvailable = [enum]::GetValues([System.ServiceProcess.ServiceControllerStatus])
    if ($statusAvailable -notcontains "$($service.Status)") {
        $errorString = "The status '$service.status' must be '"
        $errorString += $statusAvailable -join "', '"
        $errorString += "'"
        throw "$errorString"
    }

    $properties.status = $service.Status

    # The property StartType of the class System.ServiceProcess.ServiceController
    # might not available in the .NET Framework when used with PowerShell 2.0
    # (cf. https://goo.gl/5NDtZJ). This property has been made available since
    # .NET 4.6.1 (src.: https://goo.gl/ZSvO7B).
    # Since we cannot rely on this property, we need to find another solution.
    # While WMI is widely available and working, let's parse the registry;
    # later we will need an info exclusively storred in it.

    # To list all the properties of an object:
    # $services[0] | Get-ItemProperty
    $service = Get-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\$name
    if (!$service) {
        throw "The service '$name' was not found using the registry"
    }

    # The values are the ones defined in
    # [enum]::GetValues([System.ServiceProcess.ServiceStartMode])
    switch ($service.Start) {
        2 { $properties.startupType = "Automatic" }
        3 { $properties.startupType = "Manual" }
        4 { $properties.startupType = "Disabled" }
        default { throw "The startup type is invalid" }
    }

    # If the delayed flag is not set, there is no record DelayedAutoStart to the
    # object.
    if ($service.DelayedAutoStart) {
        $properties.delayedStart = $true
    } else {
        $properties.delayedStart = $false
    }

    return $properties
}

function SetServiceProperties {
<#
.DESCRIPTION
Set service properties supporting delayed services

.PARAMETER name
The service name

.PARAMETER status
One of the following service status:
- 'Stopped'
- 'StartPending'
- 'StopPending'
- 'Running'
- 'ContinuePending'
- 'PausePending'
- 'Paused'

.PARAMETER startupType
One of the following service startup type:
- 'Automatic (Delayed Start)'
- 'Automatic'
- 'Manual'
- 'Disabled'
#>
    param (
        # By default parameter are positional, this means the parameter name
        # can be omitted, but needs to repect the order in which the arguments
        # are declared, except if the PositionalBinding is set to false.
        # src.: https://goo.gl/UpOU62
        [Parameter(Mandatory=$true)][string]$name,
        [Parameter(Mandatory=$true)][string]$status,
        [Parameter(Mandatory=$true)][string]$startupType
    )

    try {
        $service = GetServiceProperties "$name"
    } catch {
        throw "The service '$name' cannot be found"
    }

    if ($env:ChocolateyEnvironmentDebug -eq 'true' -or
        $env:ChocolateyEnvironmentVerbose -eq 'true') {
        Write-Verbose "Before SetServicesProperties:"
        if ($service.delayedStart) {
            Write-Verbose "Service '$($service.name)' now '$($service.status)', with '$($service.startupType)' startup type and delayed"
        } else {
            Write-Verbose "Service '$($service.name)' now '$($service.status)', with '$($service.startupType)' startup type"
        }
    }

    # src.: https://goo.gl/oq8Bbx
    [array]$statusAvailable = [enum]::GetValues([System.ServiceProcess.ServiceControllerStatus])
    if ($statusAvailable -notcontains "$status") {
        $errorString = "The status '$status' must be '"
        $errorString += $statusAvailable -join "', '"
        $errorString += "'"
        throw "$errorString"
    }

    if ($startupType -ne "Automatic (Delayed Start)" -and
        $startupType -ne "Automatic" -and
        $startupType -ne "Manual" -and
        $startupType -ne "Disabled") {
        throw "The startupType '$startupType' must either be 'Automatic (Delayed Start)', 'Automatic', 'Manual' or 'Disabled'"
    }

    # Set delayed auto start
    if ($startupType -eq "Automatic (Delayed Start)") {

        # (src.: https://goo.gl/edhCxm and https://goo.gl/NyVXxM)
        # Modifying the registry does not change the value in services.msc,
        # using sc.exe does. sc.exe uses the Windows NT internal functions
        # OpenServiceW and ChangeServiceConfigW. We could use it in PowerShell,
        # but it would requires a C++ wrapper imported in C# code with
        # DllImport, the same C# code imported in PowerShell. While this is
        # doable, this is way slower than calling the sc utility directly.
        # Set-ItemProperty -Path "Registry::HKLM\System\CurrentControlSet\Services\$($service.Name)" -Name DelayedAutostart -Value 1 -Type DWORD
        # An .exe can be called directly but ensuring the exit code and
        # stdout/stderr are properly redirected can only be checked with
        # this code.
        $psi = New-object System.Diagnostics.ProcessStartInfo
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        $psi.FileName = 'sc.exe'
        $psi.Arguments = "Config ""$($service.Name)"" Start= Delayed-Auto"
        # The [void] casting is actually needed to avoid True or False to be displayed
        # on stdout.
        [void]$process.Start()
        #PrintWhenChocoVerbose $process.StandardOutput.ReadToEnd()
        #PrintWhenChocoVerbose $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if (!($process.ExitCode -eq 0)) {
            throw "Unable to set the service '$($service.Name)' to a delayed autostart."
        }
    } else {
        # Make sure the property DelayedAutostart is reset otherwise
        # GetServiceProperties could report a service as Manual and delayed
        # which is not possible.
        Set-ItemProperty `
        -Path "Registry::HKLM\System\CurrentControlSet\Services\$($service.Name)" `
        -Name DelayedAutostart -Value 1 -Type DWORD -ErrorAction Stop
    }

    # Cast "Automatic (Delayed Start)" to "Automatic" to have a valid name
    if ($startupType -match "Automatic") {
        $startupType = "Automatic"
    }

    # Set-Service cannot stop services properly and complains the service is
    # dependent on other services, which seems to be wrong.
    # src.: http://stackoverflow.com/a/39811972/3514658
    if ($status -eq "Stopped") {
        Stop-Service "$service.Name" -ErrorAction Stop
    }

    Set-Service -Name "$service.Name" -StartupType "$startupType" -Status "$status" -ErrorAction Stop

    if ($env:ChocolateyEnvironmentDebug -eq 'true' -or
        $env:ChocolateyEnvironmentVerbose -eq 'true') {
        $service = GetServiceProperties "$name"
        Write-Verbose "After SetServicesProperties:"
        if ($service.delayedStart) {
            Write-Verbose "Service '$($service.name)' now '$($service.status)', with '$($service.startupType)' startup type and delayed"
        } else {
            Write-Verbose "Service '$($service.name)' now '$($service.status)', with '$($service.startupType)' startup type"
        }
    }
}

function CheckPGPSignature {
<#
.DESCRIPTION
Check the signature of a file using the public key and signatures provided.

.PARAMETER pgpKey
The path and file name to PGP public key to check the signature.

.PARAMETER signatureFile
The path and file name to the signature file. The signature file must keep
its original filename if the argument 'file' is not specified.

.PARAMETER file (optional)
GPG can find the filename of the file to check by itself, only if the
signatureFile has its original file name. What GnuPG does is to retrieve the
filename of the file to check is to remove the .asc suffix from the
signature file.
#>
    param (
        [Parameter(Mandatory=$true)][string]$pgpKey,
        [Parameter(Mandatory=$true)][string]$signatureFile,
        [Parameter(Mandatory=$false)][string]$file
    )

    # Get-Command throws an error message but continues execution, ask to
    # continue without message at all.
    if (!(Get-Command 'gpg.exe' -ErrorAction SilentlyContinue)) {
        throw "Unable to find the GnuPG executable 'gpg.exe'."
    }

    # Check if folder or path exists. Work for files as well.
    if (!(Test-Path "$pgpKey")) {
        throw "Unable to find the PGP key '$pgpKey'."
    }

    if (!(Test-Path "$signatureFile")) {
        throw "Unable tofind the PGP signature file '$signatureFile'."
    }

    if ($file -and !(Test-Path "$file")) {
        throw "Unable to find the file '$file'."
    }

    # Get temporary folder for the keyring
    # src.: http://stackoverflow.com/a/34559554/3514658
    $tempDirKeyring = Join-Path $(Split-Path $pgpKey) $([System.Guid]::NewGuid())

    $psi = New-object System.Diagnostics.ProcessStartInfo
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    Write-Debug "Importing PGP key '$pgpKey' in the temporary keyring ($tempDirKeyring\pubring.gpg)..."
    # Simply invoing the command gpg.exe and checking the value of $? was not
    # enough. Using the following method worked and was indeed more reliable.
    # src.: https://goo.gl/Ungugv
    $psi.FileName = 'gpg.exe'
    # Surrounding filenames by 2 double quotes is needed, otherwise of the user
    # folder has a space in it, the space is not taken into account and gpg cannot
    # find the signed data to verify.
    if ($env:ChocolateyEnvironmentDebug -eq 'true' -or
        $env:ChocolateyEnvironmentVerbose -eq 'true') {
        $psi.Arguments = "-v --homedir ""$tempDirKeyring"" --import ""$pgpKey"""
    } else {
        $psi.Arguments = "--homedir ""$tempDirKeyring"" --import ""$pgpKey"""
    }
    # The [void] casting is actually needed to avoid True or False to be displayed
    # on stdout.
    [void]$process.Start()
    PrintWhenChocoVerbose $process.StandardOutput.ReadToEnd()
    PrintWhenChocoVerbose $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if (!($process.ExitCode -eq 0)) {
        throw "Unable to import PGP key '$pgpKey' in the temporary keyring ($tempDirKeyring\pubring.gpg)."
    }

    # This step is actually facultative. It avoids to have this kind of warning
    # by trusting ultimately the key with the highest level available (level 5,
    # number 6, used for the ultimate/owner trust, a level used for own keys.
    # gpg: WARNING: This key is not certified with a trusted signature!
    # gpg:          There is no indication that the signature belongs to the owner.
    Write-Debug "Getting the fingerprint of the PGP key '$pgpKey'..."
    $psi.FileName = 'gpg.exe'
    if ($env:ChocolateyEnvironmentDebug -eq 'true' -or
        $env:ChocolateyEnvironmentVerbose -eq 'true') {
        $psi.Arguments = "-v --homedir ""$tempDirKeyring"" --with-fingerprint --with-colons ""$pgpKey"""
    } else {
        $psi.Arguments = "--homedir ""$tempDirKeyring"" --with-fingerprint --with-colons ""$pgpKey"""
    }
    # Get the full fingerprint of the key
    [void]$process.Start()
    # src.: http://stackoverflow.com/a/8762068/3514658
    $pgpFingerprint = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    $pgpFingerprint = $pgpFingerprint -split ':'
    $pgpFingerprint = $pgpFingerprint[18]

    Write-Debug "Trusting the PGP key '$pgpKey' ultimately based on its fingerprint '$pgpFingerprint'..."
    $psi.FileName = 'gpg.exe'
    if ($env:ChocolateyEnvironmentDebug -eq 'true' -or
        $env:ChocolateyEnvironmentVerbose -eq 'true') {
        $psi.Arguments = "-v --import-ownertrust"
    } else {
        $psi.Arguments = "--import-ownertrust"
    }
    [void]$process.Start()
    # Specify the fingerprint and the trust level to stdin
    # e.g.: ABCDEF01234567890ABCDEF01234567890ABCDEF:6:
    $input = $process.StandardInput
    $input.WriteLine($pgpFingerprint + ":6:")
    # Not written until the stream is closed. If not closed, the process will still
    # run and the software will hang.
    # src.: https://goo.gl/5oYgk4
    $input.Close()
    $process.WaitForExit()

    Write-Debug "Checking PGP signature..."
    $psi.FileName = 'gpg.exe'
    if ($env:ChocolateyEnvironmentDebug -eq 'true' -or
        $env:ChocolateyEnvironmentVerbose -eq 'true') {
        if ($file) {
            $psi.Arguments = "-v --verify ""$signatureFile"" ""$file"""
        } else {
            $psi.Arguments = "-v --verify ""$signatureFile"""
        }
    } else {
        if ($file) {
            $psi.Arguments = "--verify ""$signatureFile"" ""$file"""
        } else {
            $psi.Arguments = "--verify ""$signatureFile"""
        }
    }
    [void]$process.Start()
    PrintWhenChocoVerbose $process.StandardOutput.ReadToEnd()
    PrintWhenChocoVerbose $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if (!($process.ExitCode -eq 0)) {
        throw "The signature does not match."
    }
}