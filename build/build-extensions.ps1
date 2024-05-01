param (
  [string]$buildNumber = "0",
  [string]$suffix = "",
  [ValidateSet("6", "8", "")][string]$minorVersionPrefix = "",
  [string]$hashesForHardlinksFile = "hashesForHardlinks.txt"
)

Import-Module "$PSScriptRoot\Get-AzureFunctionsVersion.psm1" -Force
$rootDir = Split-Path -Parent $PSScriptRoot
$outDir = "$rootDir\out"
$publishDir = "$outDir\pub\WebJobs.Script.WebHost"

$extensionVersion = Get-AzureFunctionsVersion $buildNumber $suffix $minorVersionPrefix
Write-Host "Site extension version: $extensionVersion"

# Construct variables for strings like "4.1.0-15898" and "4.1.0"
$versionParts = ($extensionVersion -Split "-")[0] -Split "\."
$majorMinorVersion = $versionParts[0] + "." + $versionParts[1]
$patchVersion = [int]$versionParts[2]
$isPatch = $patchVersion -gt 0
Write-Host "MajorMinorVersion is '$majorMinorVersion'. Patch version is '$patchVersion'. IsPatch: '$isPatch'"

function ZipContent([string] $sourceDirectory, [string] $target) {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host "======================================"
    Write-Host "Zipping $sourceDirectory into $target"

    if (Test-Path $target) {
      Remove-Item $target
    }

    Add-Type -assembly "system.io.compression.filesystem"
    [IO.Compression.ZipFile]::CreateFromDirectory($sourceDirectory, $target)

    Write-Host "Done zipping $target. Elapsed: $($stopwatch.Elapsed)"
    Write-Host "======================================"
    Write-Host ""
}

function BuildRuntime([string] $targetRid, [string] $targetFramework, [bool] $isSelfContained) {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    $publishTarget = "$publishDir\release_$targetRid"
    $projectPath = "$rootDir\src\WebJobs.Script.WebHost\WebJobs.Script.WebHost.csproj"
    if (-not (Test-Path $projectPath))
    {
        throw "Project path '$projectPath' does not exist."
    }

    $cmd = "publish", $projectPath , "-r", "$targetRid", "-f", "$targetFramework", "--self-contained", "$isSelfContained", "-v", "m", "-c", "Release", "-p:IsPackable=false", "-p:BuildNumber=$buildNumber", "-p:MinorVersionPrefix=$minorVersionPrefix"

    Write-Host "======================================"
    Write-Host "Building $targetRid using target framework $targetFramework"
    Write-Host "  Self-Contained:    $isSelfContained"
    Write-Host "  Publish Directory:  $publishTarget"
    Write-Host ""
    Write-Host "dotnet $cmd"
    Write-Host ""

    & dotnet $cmd

    if ($LASTEXITCODE -ne 0)
    {
      exit $LASTEXITCODE
    }

    Write-Host ""
    $symbols = Get-ChildItem -Path $publishTarget -Filter *.pdb
    Write-Host "Zipping symbols: $($symbols.Count) symbols found"

    $symbolsPath = "$publishDir\Symbols"
    if (!(Test-Path -PathType Container $symbolsPath)) {
        New-Item -ItemType Directory -Path $symbolsPath | Out-Null
    }

    $symbols | Compress-Archive -DestinationPath "$symbolsPath\Functions.Symbols.$extensionVersion.$targetRid.zip" | Out-Null
    $symbols | Remove-Item | Out-Null

    Write-Host ""
    CleanOutput $publishTarget
    Write-Host ""
    Write-Host "Done building $targetRid using target framework $targetFramework. Elapsed: $($stopwatch.Elapsed)"
    Write-Host "======================================"
    Write-Host ""
}

function GetFolderSizeInMb([string] $rootPath) {
  return [math]::Round((Get-ChildItem $rootPath -Recurse | Measure-Object -Property Length -Sum -ErrorAction Stop).Sum / 1Mb, 2)
}

function CleanOutput([string] $rootPath) {
    Write-Host "Cleaning build output under $rootPath"
    Write-Host "  Current size: $(GetFolderSizeInMb $rootPath) Mb"

    Write-Host "  Removing any linux and osx runtimes"
    Remove-Item -Recurse -Force "$privateSiteExtensionPath\$bitness\runtimes\linux" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "$privateSiteExtensionPath\$bitness\runtimes\osx" -ErrorAction SilentlyContinue

    Write-Host "  Removing python worker"
    Remove-Item -Recurse -Force "$rootPath\workers\python" -ErrorAction SilentlyContinue

    $keepRuntimes = @('win', 'win-x86', 'win10-x86', 'win-x64', 'win10-x64')
    Write-Host "  Removing all powershell runtimes except $keepRuntimes"
    Get-ChildItem "$rootPath\workers\powershell" -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Get-ChildItem "$($_.FullName)\runtimes" -Directory -Exclude $keepRuntimes } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "  Current size: $(GetFolderSizeInMb $rootPath) Mb"
}

function CreatePatchedSiteExtension([string] $siteExtensionPath) {
  try {
    Write-Host "SiteExtensionPath is $siteExtensionPath"
    $officialSiteExtensionPath = "$siteExtensionPath\$extensionVersion"
    $baseVersion = "$majorMinorVersion.0"
    $baseZipPath = "$publishDir\BaseZipDirectory"
    $baseExtractedPath = "$publishDir\BaseZipDirectory\Extracted"

    # Try to download base version
    New-Item -Itemtype "directory" -path "$baseZipPath" -Force > $null
    New-Item -Itemtype "directory" -path "$baseExtractedPath" -Force > $null
    $baseZipUrl = "https://github.com/Azure/azure-functions-host/releases/download/v$majorMinorVersion.0/Functions.$majorMinorVersion.0.zip"

    Write-Host "Downloading from $baseZipUrl"
    (New-Object System.Net.WebClient).DownloadFile($baseZipUrl, "$baseZipPath\Functions.$majorMinorVersion.0.zip")
    Write-Host "Download complete"

    # Extract zip
    Expand-Archive -LiteralPath "$baseZipPath\Functions.$majorMinorVersion.0.zip" -DestinationPath "$baseExtractedPath"
    
    # Create directory for patch
    $zipOutput = "$publishDir\ZippedPatchSiteExtension"
    New-Item -Itemtype directory -path $zipOutput -Force > $null

    # Copy extensions.xml as is
    Copy-Item "$siteExtensionPath\extension.xml" -Destination "$patchedContentDirectory\extension.xml"

    # Read hashes.txt for base
    $hashForBase = @{}
    foreach($line in Get-Content "$baseExtractedPath\$baseVersion\hashesForHardlinks.txt") {
      $lineContents = $line.Split(" ")
      $hashKey = $lineContents[1].Split(":")[1]
      $hashValue = $lineContents[0].Split(":")[1]
  
      $hashForBase.Add($hashKey, $hashValue)
    }

    # Read hashes.txt for patched
    $hashForPatched = @{}
    foreach($line in Get-Content "$officialSiteExtensionPath\hashesForHardlinks.txt") {
      $lineContents = $line.Split(" ")
      $hashKey = $lineContents[1].Split(":")[1]
      $hashValue = $lineContents[0].Split(":")[1]
  
      $hashForPatched.Add($hashKey, $hashValue)
    }

    # Iterate over patched to generate the appropriate set of files
    $informationJson = New-Object System.Collections.ArrayList
    foreach($key in $hashForPatched.Keys) {
      $infoKeyValuePairs = @{}
      
      # If key doesn't exist in base, or if the keys exists but their hashes don't match, copy over.
      if((!$hashForBase.ContainsKey($key)) -or ($hashForPatched[$key] -ne $hashForBase[$key])) {
        $filePath = $key.Replace(".\","")
        $sourcePath = "$officialSiteExtensionPath\$filePath"
        $destinationPath = "$patchedContentDirectory\$extensionVersion\$filePath"
        Write-Host "Copying $sourcePath to $destinationPath"
        $ValidPath = Test-Path "$destinationPath"

        If ($ValidPath -eq $False){
            New-Item -Path "$destinationPath" -Force > $null
        }

        Copy-Item "$sourcePath" "$destinationPath" -Force > $null

        # Get it into info
        $infoKeyValuePairs.Add("FileName", $key)
        $infoKeyValuePairs.Add("SourceVersion", $extensionVersion)
        $infoKeyValuePairs.Add("HashValue", $hashForPatched[$key])
        $informationJson.Add($infoKeyValuePairs)
        continue
      }

      # Add info that would help get this file from base
      $infoKeyValuePairs.Add("FileName", $key)
      $infoKeyValuePairs.Add("SourceVersion", $baseVersion)
      $infoKeyValuePairs.Add("HashValue", $hashForBase[$key])
      $informationJson.Add($infoKeyValuePairs)
    }
    $informationJson | ConvertTo-Json -depth 100 | Out-File "$patchedContentDirectory\$extensionVersion\HardlinksMetadata.json"

    # Zip it up
    ZipContent $patchedContentDirectory "$zipOutput\Functions.$extensionVersion.zip"

    # Clean up
    Remove-Item $patchedContentDirectory -Recurse -Force > $null
  }
  catch {
    Write-Host $_.Exception
    $statusCode = $_.Exception.Response.StatusCode.Value__
    Write-Host "Invoking url $baseZipUrl returned status code of $statusCode which could mean that no base version exists. The full version needs to be deployed"
  }
}

function CreateSiteExtensions() {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $siteExtensionPath = "$publishDir\temp_extension"

    if (Test-Path $siteExtensionPath) {
        Write-Host "  Existing site extension path found. Deleting."
        Remove-Item $siteExtensionPath -Recurse -Force | Out-Null
    }

    # The official site extension needs to be nested inside a folder with its version.
    # Not using the suffix (eg: '-ci') here as it may not work correctly in a private stamp
    $officialSiteExtensionPath = "$siteExtensionPath\$extensionVersion"
    
    Write-Host "======================================"
    Write-Host "Copying build to temp directory to prepare for zipping official site extension."
    Copy-Item -Path $publishDir\release_win-x86\ -Destination $officialSiteExtensionPath\32bit -Force -Recurse > $null
    Copy-Item -Path $publishDir\release_win-x64 -Destination $officialSiteExtensionPath\64bit -Force -Recurse > $null
    Copy-Item -Path $officialSiteExtensionPath\32bit\applicationHost.xdt -Destination $officialSiteExtensionPath -Force > $null
    Write-Host "  Deleting workers directory: $officialSiteExtensionPath\32bit\workers" 
    Remove-Item -Recurse -Force "$officialSiteExtensionPath\32bit\workers" -ErrorAction SilentlyContinue
    Write-Host "  Moving workers directory: $officialSiteExtensionPath\64bit\workers to $officialSiteExtensionPath\workers"
    Move-Item -Path "$officialSiteExtensionPath\64bit\workers" -Destination "$officialSiteExtensionPath\workers" 
     
    # This goes in the root dir
    Copy-Item $rootDir\src\WebJobs.Script.WebHost\extension.xml $siteExtensionPath > $null
    
    Write-Host "Done copying. Elapsed: $($stopwatch.Elapsed)"
    Write-Host "======================================"
    Write-Host ""

    Write-Host "======================================"
    Write-Host "Generating hashes for hard links"
    WriteHashesFile $siteExtensionPath/$extensionVersion
    Write-Host "Done generating hashes for hard links into $siteExtensionPath/$extensionVersion"
    Write-Host "======================================"
    Write-Host

    $zipOutput = "$publishDir\SiteExtension"
    $hashesForHardLinksPath = "$siteExtensionPath\$extensionVersion\$hashesForHardlinksFile"
    New-Item -Itemtype directory -path $zipOutput -Force > $null
    if ($minorVersionPrefix -eq "") {
        ZipContent $siteExtensionPath "$zipOutput\Functions.$extensionVersion.zip"
    } elseif ($minorVersionPrefix -eq "8") {
        Write-Host "======================================"
        # Only the "Functions" site extension supports hard links
        Write-Host "MinorVersionPrefix is '8'. Removing $hashesForHardLinksPath before zipping."
        Remove-Item -Force "$hashesForHardLinksPath" -ErrorAction Stop
        # The .NET 8 host doesn't require any workers. Doing this to save space.
        Write-Host "Removing workers before zipping."
        # The host requires that this folder exists and it cannot be empty
        Remove-Item -Recurse -Force "$siteExtensionPath\$extensionVersion\workers" -ErrorAction Stop 
        New-Item -Path "$siteExtensionPath\$extensionVersion" -Name "workers" -ItemType Directory -ErrorAction Stop | Out-Null
        Set-Content -Force -Path "$siteExtensionPath\$extensionVersion\workers\this_folder_intentionally_empty.txt" -Value ".NET 8 builds do not have workers. However, this folder must contain at least one file." -ErrorAction Stop
        Write-Host "======================================"
        Write-Host
        ZipContent $siteExtensionPath "$zipOutput\FunctionsInProc8.$extensionVersion.zip"
    } elseif ($minorVersionPrefix -eq "6") {
        # Only the "Functions" site extension supports hard links
        Write-Host "======================================"
        Write-Host "MinorVersionPrefix is '6'. Removing $hashesForHardLinksPath before zipping."
        Remove-Item -Force "$hashesForHardLinksPath" -ErrorAction Stop
        Write-Host "======================================"
        Write-Host
        ZipContent $siteExtensionPath "$zipOutput\FunctionsInProc.$extensionVersion.zip"
    }

    # Create directory for content even if there is no patch build. This makes artifact uploading easier.
    $patchedContentDirectory = "$publishDir\PatchedSiteExtension"
    New-Item -Itemtype directory -path $patchedContentDirectory -Force > $null

    # Construct patch
    if($isPatch)
    {
      Write-Host "======================================"
      Write-Host "Generating patch file"
      CreatePatchedSiteExtension $siteExtensionPath
      Write-Host "Done generating patch files"
      Write-Host "======================================"
      Write-Host
    }

    Remove-Item $siteExtensionPath -Recurse -Force > $null

    Write-Host "======================================"
    $stopwatch.Reset()
    Write-Host "Copying build to temp directory to prepare for zipping private site extension."
    Copy-Item -Path $publishDir\release_win-x86\ -Destination $siteExtensionPath\SiteExtensions\Functions\32bit -Force -Recurse > $null
    Copy-Item -Path $siteExtensionPath\SiteExtensions\Functions\32bit\applicationHost.xdt -Destination $siteExtensionPath\SiteExtensions\Functions -Force > $null
    Write-Host "Done copying. Elapsed: $($stopwatch.Elapsed)"
    Write-Host "======================================"
    Write-Host ""

    $zipOutput = "$publishDir\PrivateSiteExtension"
    New-Item -Itemtype directory -path $zipOutput -Force > $null
    ZipContent $siteExtensionPath "$zipOutput\Functions.Private.$extensionVersion.win-x32.inproc.zip"
    
    Remove-Item $siteExtensionPath -Recurse -Force > $null
}

function WriteHashesFile([string] $directoryPath) {
  New-Item -Path "$directoryPath/../temp_hashes" -ItemType Directory | Out-Null
  $temp_current = (Get-Location)
  Set-Location $directoryPath
  Get-ChildItem -Recurse $directoryPath | Where-Object { $_.PsIsContainer -eq $false } | Foreach-Object { "Hash:" + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-FileHash -Algorithm MD5 $_.FullName).Hash)) + " FileName:" + (Resolve-Path -Relative -Path $_.FullName) } | Out-File -FilePath "$directoryPath\..\temp_hashes\$hashesForHardlinksFile"
  Move-Item -Path "$directoryPath/../temp_hashes/$hashesForHardlinksFile" -Destination "$directoryPath" -Force
  Set-Location $temp_current
  Remove-Item "$directoryPath/../temp_hashes" -Recurse -Force > $null
}

Write-Host "Output directory: $publishDir"
if (Test-Path $publishDir) {
    Write-Host "  Existing build output found. Deleting."
    Remove-Item $publishDir -Recurse -Force -ErrorAction Stop
}

Write-Host "Extensions version: $extensionVersion"
Write-Host ""

BuildRuntime "win-x86" "net6.0"
BuildRuntime "win-x64" "net6.0"
BuildRuntime "win-x86" "net8.0"
BuildRuntime "win-x64" "net8.0"

CreateSiteExtensions
