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

    $kong_version = & kubectl exec -it $kong_pod -n $namespace -c proxy -- kong version

    if ($kong_version -match '\d+(\.\d+)+') {
        $kong_version_number = $Matches[0]
    }
    else {
        throw "Could not extract version from: $kong_version"
    }

    Write-Host "Kong dataplane version: $kong_version_number"

    $currentVersion = [NuGet.Versioning.NuGetVersion]::Parse($kong_version_number)

    try {

        $releases = Invoke-RestMethod `
            -Uri 'https://api.github.com/repos/Kong/kong/releases?per_page=100' `
            -Headers @{
                Accept = 'application/vnd.github+json'
            }

        $latestVersionObject = $releases |
            Where-Object { -not $_.prerelease } |
            ForEach-Object {
                [NuGet.Versioning.NuGetVersion]::Parse(
                    ($_.tag_name -replace '^v', '')
                )
            } |
            Sort-Object -Descending |
            Select-Object -First 1

        if (-not $latestVersionObject) {
            throw "Unable to determine latest Kong version."
        }

        Write-Host "Latest Kong version: $latestVersionObject"

        $currentVersion | Should -Be $latestVersionObject `
            -Because "Cluster should be running the latest Kong release"
    }
        catch {
            throw "Failed to determine latest Kong version from GitHub. $_"
             }
        }
    }
}

