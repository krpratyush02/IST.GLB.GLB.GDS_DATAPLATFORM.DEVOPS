param(
    [ValidateNotNullOrEmpty()]
    [string] $FileFilter = "*",

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $AssetsDirectory,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $StorageAccountUri,

    [ValidateNotNullOrEmpty()]
    [string] $StorageAccountContainer = "project",

    [ValidateNotNullOrEmpty()]
    [string] $StorageAccountFolder = "data-observability/data-product-registry",

    [ValidateNotNullOrEmpty()]
    [ValidateSet("AD", "Key")]
    [string] $AuthenticationType = "AD"
)
# wait 60 seconds to propagate changes
Start-Sleep 60

function Run-AzCopyWithRetry([string] $source, [string] $destination){
    $attempts=5
    $sleepInSeconds=15
    $ErrorActionPreference = "Stop"

    do {
        try {
            $result = azcopy cp $source $destination
            if ($result -like "*Final Job Status: Completed*" -gt 0) {
                Write-Output $result
                break
            } else {
                Write-Error $([string]$result)
            }
        } catch [Exception] {
            Write-Output $_.Exception.Message
        }            
        $attempts--
        if ($attempts -gt 0) { Start-Sleep $sleepInSeconds }
        else { Write-Error "Copy failed for $source. Exiting."; exit 1 }
    } while ($attempts -gt 0)
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Error "Powershell version is less than 7. Aborting job due to compatibility reasons."
    exit 1
}

# check if uri ends with slash to avoid issues
if ($StorageAccountUri[-1] -eq "/") {
    $StorageAccountUri = $StorageAccountUri.Substring(0, $StorageAccountUri.Length-1)
}

# prepare files to deploy
Write-Output "Preparing files to deploy."
$filesToDeploy = @()

Get-ChildItem -Path $AssetsDirectory -Recurse -Filter "*.json" -Include $FileFilter | ForEach-Object {
    # Read the content of the JSON file
    $jsonContent = Get-Content -Path $_.FullName | ConvertFrom-Json -ErrorAction SilentlyContinue

    # Route files based on environment key
    if ($null -ne $jsonContent -and $jsonContent.environment) {
        $environment = $jsonContent.environment.ToLower()

        switch ($environment) {
            "prod" { $envFolder = "production" }
            "uat"  { $envFolder = "uat" }
            "dev"  { $envFolder = "development" }
            default {
                Write-Output "Skipping file: $($_.FullName) (unknown environment: $environment)"
                continue
            }
        }

        # Split delimiters must be casted to char array as per https://github.com/PowerShell/PowerShell/issues/7585
        $storageAccountPathList = $_.FullName.Split([char[]]"/\")
        $storageAccountPath = $storageAccountPathList[8..($storageAccountPathList.Length-1)] -join "/"

        # Append environment folder to destination path
        $dataAsset = @{ 
            Source      = $_.FullName
            Destination = @(
                $StorageAccountUri,
                $StorageAccountContainer,
                $StorageAccountFolder,
                $envFolder,
                $storageAccountPath
            ) -Join "/"
        }
        $filesToDeploy += $dataAsset

        Write-Output "$($dataAsset.Source) => $($dataAsset.Destination)"
    } else {
        Write-Output "Skipping file: $($_.FullName) (environment key missing or invalid)"
    }
}

# authenticate azcopy
if ($AuthenticationType -eq "AD") {
    $env:AZCOPY_SPA_CLIENT_SECRET = $env:servicePrincipalKey
    az
