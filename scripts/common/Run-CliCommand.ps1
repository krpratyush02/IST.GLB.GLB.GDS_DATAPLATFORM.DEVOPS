function Run-CliCommand([string] $azCommand, [bool] $failOnError = $true){
    $output = (Invoke-Expression -Command $azCommand 2>&1)
    if($LASTEXITCODE -ne 0){
        Write-Error "Command failed`nOutput: $output`nError: $($Error[0])"
        if($failOnError){
            exit 1
        }
    }
    return $output
}

try{ 
    $ErrorActionPreference='Stop'
    Run-CliCommand "data-asset-builder -h" 
} 
catch{
    Write-Error "data-asset-builder is not installed, exiting."
    exit 1 
}
