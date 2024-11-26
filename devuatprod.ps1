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

Start-Sleep 60  # Wait 60 seconds to propagate changes

function Run-AzCopyWithRetry([string] $source, [string] $destination) {
    $attempts = 5
    $sleepInSeconds = 15
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
    Write-Error "PowerShell version is less than 7. Aborting job due to compatibility reasons."
    exit 1
}

# Check if the URI ends with a slash to avoid issues
if ($StorageAccountUri[-1] -eq "/") {
    $StorageAccountUri = $StorageAccountUri.Substring(0, $StorageAccountUri.Length-1)
}

Write-Output "Preparing files to deploy."
$filesToDeploy = @()

Get-ChildItem -Path $AssetsDirectory -Recurse -Filter "*.json" -Include $FileFilter | ForEach-Object {
    $jsonContent = Get-Content -Path $_.FullName | ConvertFrom-Json -ErrorAction SilentlyContinue

    # Default deployment is to dev and uat only
    $environmentsToDeploy = @("development", "uat")

    if ($null -ne $jsonContent -and $jsonContent.environment -and $jsonContent.environment.ToUpper() -eq "PROD") {
        # Add prod to deployment list if environment is PROD
        $environmentsToDeploy += "production"
    }

    # Prepare the files for all applicable environments
    foreach ($envFolder in $environmentsToDeploy) {
        $storageAccountPathList = $_.FullName.Split([char[]]"/\")
        $storageAccountPath = $storageAccountPathList[8..($storageAccountPathList.Length-1)] -join "/"

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
    }
}

# Authenticate azcopy
if ($AuthenticationType -eq "AD") {
    $env:AZCOPY_SPA_CLIENT_SECRET = $env:servicePrincipalKey
    azcopy login --service-principal --application-id $env:servicePrincipalId --tenant-id=$env:tenantId
} else {
    $storageAccountName = $StorageAccountUri.Replace("https://", "").Split(".")[0]
    $accountKey = az storage account keys list -n $storageAccountName --query [0].value -o tsv
    $sasExpiryDate = Get-Date (Get-Date).AddMinutes("10") -UFormat "+%Y-%m-%dT%H:%MZ"
    $sasKey = az storage account generate-sas --account-key $accountKey --account-name $storageAccountName --expiry $sasExpiryDate -o tsv --https-only --permissions acuw --resource-types co --services b

    $filesToDeploy | ForEach-Object {
        $_.Destination += "?$sasKey"
    }
}

# Solution to pass custom function to -parallel foreach
$funcDef = ${function:Run-AzCopyWithRetry}.ToString()

# Copy each asset into the right directory
$filesToDeploy | ForEach-Object -Parallel {
    ${function:Run-AzCopyWithRetry} = $using:funcDef
    Run-AzCopyWithRetry $_.Source $_.Destination
} -ThrottleLimit 8
