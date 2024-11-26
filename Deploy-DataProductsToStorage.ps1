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

    do{
        try{
            $result = azcopy cp $source $destination
            if($result -like "*Final Job Status: Completed*" -gt 0){
                Write-Output $result
                break;
            }
            else{
                Write-Error $([string]$result)
            }
        }
        catch [Exception]{
            Write-Output $_.Exception.Message
        }            
        $attempts--
        if ($attempts -gt 0) { Start-Sleep $sleepInSeconds }
        else { Write-Error "Copy failed for DA $source. Exitting"; exit 1 }
    } while ($attempts -gt 0)
}

if($PSVersionTable.PSVersion.Major -lt 7){
    Write-Error "Powershell version is less than 7. Aborting job due to compability reasons."
    exit 1
}
# check if uri ends with slash to avoid issues
if($StorageAccountUri[-1] -eq "/"){
    $StorageAccountUri = $StorageAccountUri.Substring(0, $StorageAccountUri.Length-1)
}

# prepare files to deploy
Write-Output "Preparing files to deploy."
$filesToDeploy = @()

Get-ChildItem -Path $AssetsDirectory -Recurse -Filter "*.json" -Include $FileFilter | ForEach-Object {
    # Split delimeters must be casted to char array as per https://github.com/PowerShell/PowerShell/issues/7585
    $storageAccountPathList = $_.FullName.Split([char[]] "/\")
    $storageAccountPath = $storageAccountPathList[8..($storageAccountPathList.Length-1)] -join "/"
    $dataAsset = @{ 
        Source=$_.FullName;
        Destination= @(
            $StorageAccountUri,
            $StorageAccountContainer,
            $StorageAccountFolder,
            $storageAccountPath
        ) -Join "/"
    }
    $filesToDeploy += $dataAsset

    Write-Output "$($dataAsset.Source) => $($dataAsset.Destination)"
}

# authenticate azcopy
if($AuthenticationType -eq "AD"){
    $env:AZCOPY_SPA_CLIENT_SECRET = $env:servicePrincipalKey
    azcopy login --service-principal --application-id $env:servicePrincipalId --tenant-id=$env:tenantId
}
else{
    $storageAccountName = $StorageAccountUri.Replace("https://", "").Split(".")[0]
    $accountKey = az storage account keys list -n $storageAccountName --query [0].value -o tsv
    $sasExpiryDate =  Get-Date (Get-Date).AddMinutes("10") -UFormat "+%Y-%m-%dT%H:%MZ"
    $sasKey = az storage account generate-sas --account-key $accountKey --account-name $storageAccountName --expiry $sasExpiryDate -o tsv --https-only --permissions acuw --resource-types co --services b

    $filesToDeploy | ForEach-Object {
        $_.Destination += "?$sasKey"
    }
}

# solution to pass custom function to -paralell foreach
$funcDef = ${function:Run-AzCopyWithRetry}.ToString()

# Copy each asset into right directory
# Added parallel feature to speed up the process
# Added retry logic to mitigate firewall issues
$filesToDeploy | ForEach-Object -Parallel {
    ${function:Run-AzCopyWithRetry} = $using:funcDef
    Run-AzCopyWithRetry $_.Source $_.Destination
} -ThrottleLimit 8
