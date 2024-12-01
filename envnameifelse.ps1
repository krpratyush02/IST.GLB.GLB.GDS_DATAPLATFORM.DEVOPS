param( 
    [Parameter(Mandatory)] 
    [ValidateNotNullOrEmpty()] 
    [string] $EnvironmentName
)

# Ensure $AssetsDirectory and $FileFilter variables are defined before running the script
$filesToDeploy = @()

if ($EnvironmentName -eq 'DEV' -or $EnvironmentName -eq 'UAT') {
    # Logic for DEV and UAT environments
    Get-ChildItem -Path $AssetsDirectory -Recurse -Filter "*.json" -Include $FileFilter | ForEach-Object {
        # Split delimiters must be casted to char array as per https://github.com/PowerShell/PowerShell/issues/7585
        $storageAccountPathList = $_.FullName.Split([char[]] "/\")
        $storageAccountPath = $storageAccountPathList[8..($storageAccountPathList.Length-1)] -join "/"
        $dataAsset = @{ 
            Source = $_.FullName;
            Destination = @(
                $StorageAccountUri,
                $StorageAccountContainer,
                $StorageAccountFolder,
                $storageAccountPath
            ) -Join "/"
        }
        $filesToDeploy += $dataAsset

        Write-Output "$($dataAsset.Source) => $($dataAsset.Destination)"
    }
} elseif ($EnvironmentName -eq 'PROD') {
    # Logic for PROD environment
    Get-ChildItem -Path $AssetsDirectory -Recurse -Filter "*.json" -Include $FileFilter | ForEach-Object {
        # Read the content of the JSON file
        $jsonContent = Get-Content -Path $_.FullName | ConvertFrom-Json -ErrorAction SilentlyContinue

        # Filter files by "environment": "PROD"
        if ($null -ne $jsonContent -and $jsonContent.environment -eq "PROD") {
            # Split delimiters must be casted to char array as per https://github.com/PowerShell/PowerShell/issues/7585
            $storageAccountPathList = $_.FullName.Split([char[]] "/\")
            $storageAccountPath = $storageAccountPathList[8..($storageAccountPathList.Length-1)] -join "/"
            $dataAsset = @{ 
                Source = $_.FullName;
                Destination = @(
                    $StorageAccountUri,
                    $StorageAccountContainer,
                    $StorageAccountFolder,
                    $storageAccountPath
                ) -Join "/"
            }
            $filesToDeploy += $dataAsset

            Write-Output "$($dataAsset.Source) => $($dataAsset.Destination)"
        } else {
            Write-Output "Skipping file: $($_.FullName) (environment is not PROD)"
        }
    }
} else {
    Write-Output "Invalid EnvironmentName specified. Please use 'DEV', 'UAT', or 'PROD'."
}

# Additional logic can be added here if needed
