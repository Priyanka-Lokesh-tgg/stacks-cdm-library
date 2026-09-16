param (
    [Parameter(Mandatory = $true)]
    [hashtable] $parentConfiguration
)

BeforeDiscovery {
    # installing dependencies
    Install-PowerShellModules -moduleNames ("AWS.Tools.Installer")

    Install-AWSToolsModule AWS.Tools.Common, AWS.Tools.EKS -Force
    Import-Module -Name "AWS.Tools.Common" -Force
    Import-Module -Name "AWS.Tools.EKS" -Force

    # to avoid a potential clash with the YamlDotNet libary always load the module 'powershell-yaml' last
    Install-PowerShellModules -moduleNames ("powershell-yaml")

    # Install versioning package
    Install-Package -Name NuGet.Versioning -Source nuget.org -Scope CurrentUser -Force
    Add-Type -Path (Join-Path (Split-Path (Get-Package NuGet.Versioning).Source) 'lib/net8.0/NuGet.Versioning.dll')

    # configuration
    $configurationFile = $parentConfiguration.configurationFile
    $stageName = $parentConfiguration.stageName
    $checkConfiguration = (Get-Content -Path $configurationFile | ConvertFrom-Yaml).($parentConfiguration.checkName)

    # building the discovery objects
    $discovery = $checkConfiguration
    $targets = $discovery.stages | Where-Object { $_.name -eq $stageName } | Select-Object -ExpandProperty targets
}

Describe $parentConfiguration.checkDisplayName -ForEach $discovery {

    BeforeAll {
        $versionThreshold = $_.versionThreshold
    }

    Context "Target: <_.namespace>/<_.resourceRegion>/<_.resourceName>" -ForEach $targets {
        BeforeAll {
            # Update kubeconfig for EKS cluster
            $updateKubeconfig = & aws eks update-kubeconfig --name $resourceName --region $resourceRegion 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "Error updating kubeconfig:"
                $updateKubeconfig | ForEach-Object { Write-Host $_ }
                throw "Failed to update kubeconfig for EKS cluster $resourceName in region $resourceRegion"
            }
        }

    It "Resolve Kong version" {

    $kong_pod = kubectl get pods -n $namespace --no-headers -o custom-columns=":metadata.name" |
        Select-Object -First 1

    $kong_version = & kubectl exec $kong_pod -n $namespace -c proxy -- kong version

    if ($kong_version -match '\d+(\.\d+)+') {
        $kong_version_number = $Matches[0]
    }
    else {
        throw "Could not extract version from: $kong_version"
    }

    Write-Host "Kong dataplane version: $kong_version_number"

    $currentVersion = [NuGet.Versioning.NuGetVersion]::Parse($kong_version_number)

    try {
        $latestRelease = Invoke-RestMethod `
            -Uri 'https://api.github.com/repos/Kong/kong/releases/latest' `
            -Headers @{
                    Accept = 'application/vnd.github+json'
            }
        $latestVersion = $latestRelease.tag_name -replace '^v',''
    }
    catch {
        throw "Failed to retrieve the latest Kong release: $_"
    }

        $latestVersionObject = [NuGet.Versioning.NuGetVersion]::Parse($latestVersion)

        Write-Host "Current Kong Version: $currentVersion"
        Write-Host "Latest Kong Version: $latestVersionObject"
        Write-Host "Version Threshold: $versionThreshold"

        $majorVersionsBehind = $latestVersionObject.Major - $currentVersion.Major
        $minorVersionsBehind = $latestVersionObject.Minor - $currentVersion.Minor
        $patchVersionsBehind = $latestVersionObject.Patch - $currentVersion.Patch

        $inUpdateRange = $false

        if (
            $majorVersionsBehind -eq 0 -and
            $minorVersionsBehind -eq 0
        ) {
            if (
                $patchVersionsBehind -ge 0 -and
                $patchVersionsBehind -lt $versionThreshold
            ) {
                $inUpdateRange = $true
            }
        }

Write-Host "Major Versions Behind: $majorVersionsBehind"
Write-Host "Minor Versions Behind: $minorVersionsBehind"
Write-Host "Patch Versions Behind: $patchVersionsBehind"

            $inUpdateRange | Should -Be $true `
                -Because "Kong version $currentVersion is outside the supported threshold from latest version $latestVersionObject"
        }
    }
}


