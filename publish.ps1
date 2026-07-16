[CmdletBinding()]
Param(
  [Parameter(Mandatory=$true, HelpMessage='Repository CSV file')]
  [string]$SourceCsv,
  
  [Parameter(Mandatory=$false, HelpMessage='Specific organization to select')]
  [string]$Organization,

  [Parameter(Mandatory=$false, HelpMessage='The starting index to process (starting at 1)')]
  [Nullable[int]]$StartIndex,

  [Parameter(Mandatory=$false, HelpMessage='The ending index to process')]
  [Nullable[int]]$EndIndex
)

$ErrorActionPreference="Continue" # continue on errors to match bash behavior

function Write-Info() {
  param(
    [string]$Message
  )

  if (-not $StartIndex -or -not $EndIndex) {
    $range = "all"
  } else {
    $range = "$StartIndex-$EndIndex"
  }
  Write-Host "[$script:InstanceId][$range] $Message"
}

function Write-Fatal() {
  param(
    [string]$Message
  )

  if (-not $StartIndex -or -not $EndIndex) {
    $range = "all"
  } else {
    $range = "$StartIndex-$EndIndex"
  }
  Write-Error "[$script:InstanceId][$range] $Message"
  exit 1
}

# Check if mod CLI version is >= required version (semver comparison)
# Returns $true if current version >= required version, $false otherwise
function Test-ModVersionAtLeast() {
  param(
    [string]$RequiredVersion
  )

  try {
    $versionOutput = mod --version 2>$null | Select-Object -First 1
    if ($versionOutput -match '(\d+)\.(\d+)\.(\d+)') {
      $curMajor = [int]$Matches[1]
      $curMinor = [int]$Matches[2]
      $curPatch = [int]$Matches[3]
    } else {
      return $false
    }
  } catch {
    return $false
  }

  $reqParts = $RequiredVersion -split '\.'
  $reqMajor = [int]$reqParts[0]
  $reqMinor = [int]$reqParts[1]
  $reqPatch = [int]$reqParts[2]

  # Compare major
  if ($curMajor -gt $reqMajor) { return $true }
  if ($curMajor -lt $reqMajor) { return $false }

  # Compare minor
  if ($curMinor -gt $reqMinor) { return $true }
  if ($curMinor -lt $reqMinor) { return $false }

  # Compare patch
  return $curPatch -ge $reqPatch
}

function Ingest-Repos() {
  Initialize-InstanceMetadata
  Configure-Credentials
  Prepare-Environment
  Configure-DotNetBuild
  Start-Monitoring

  # Resolve the CSV source (local path, s3://, or http(s)://) to a local file
  $LocalCsv = Resolve-SourceCsv "$SourceCsv"

  if ($Organization) {
    $CloneDir = "$env:DATA_DIR\$Organization"
    Write-Host "Organization: $Organization"
    New-Item -Type Directory "$CloneDir" -Force | Out-Null
    mod git sync csv "$CloneDir" "$LocalCsv" --organization "$Organization" --with-sources
    if (Test-ModVersionAtLeast "3.56.7") {
      mod log syncs add "$CloneDir" "$env:DATA_DIR\syncs.zip" --last-sync
    }
    mod git pull "$CloneDir"
    if (-not (Refresh-CodeArtifactToken)) { Write-Info "Token refresh failed; continuing with the existing token" }
    mod build "$CloneDir" --no-download
    if ($env:SKIP_PUBLISH -eq "true") {
      Write-Info "SKIP_PUBLISH=true: skipping publish for organization $Organization"
    } else {
      mod publish "$CloneDir"
      if (-not (Finalize-CodeArtifactVersions "$LocalCsv")) { Write-Info "Some CodeArtifact versions could not be finalized" }
    }
    mod log builds add "$CloneDir" "$env:DATA_DIR\log.zip" --last-build
    Send-Logs "org-$Organization"
  } else {
    Select-Repos "$LocalCsv"
    Split-IntoBatches "$env:DATA_DIR\selected-repos.csv"

    Get-ChildItem "$env:DATA_DIR\batches" -Filter *.csv | ForEach-Object {
      $PartitionName = $_.BaseName

      if (-not (Invoke-BuildAndUploadRepos "$PartitionName" "$($_.FullName)")) {
        Write-Info "Error building and uploading repositories from $PartitionName"
      } else {
        Write-Info "Successfully built and uploaded repositories from $PartitionName"
      }

      Remove-Item "$env:DATA_DIR\$PartitionName" -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item "$env:DATA_DIR\batches" -Recurse -Force -ErrorAction SilentlyContinue

    $indexRange = if ($StartIndex -and $EndIndex) { "$StartIndex-$EndIndex" } else { "all" }
    Send-Logs $indexRange
  }
  Stop-Monitoring
}

# Resolve a CSV source to a local file. Supports local paths, s3:// URLs (via the AWS
# CLI), and http(s):// URLs (downloaded to repos.csv), matching publish.sh.
function Resolve-SourceCsv() {
  param(
    [string]$Csv
  )

  if ($Csv.StartsWith("s3://")) {
    aws s3 cp "$Csv" "repos.csv" | Write-Host
    return "repos.csv"
  } elseif ($Csv.StartsWith("http://") -or $Csv.StartsWith("https://")) {
    Invoke-WebRequest -UseBasicParsing -Uri "$Csv" -OutFile "repos.csv"
    return "repos.csv"
  } elseif (Test-Path "$Csv" -PathType Leaf) {
    return "$Csv"
  } else {
    Write-Fatal "File '$Csv' does not exist"
  }
}

# Initialize instance if running on AWS EC2 (batch mode)
function Initialize-InstanceMetadata() {
  try {
    $Token = Invoke-RestMethod -Method Put -TimeoutSec 2 -Uri "http://169.254.169.254/latest/api/token" -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"}
    $script:InstanceId = Invoke-RestMethod -TimeoutSec 2 -Uri "http://169.254.169.254/latest/meta-data/instance-id" -Headers @{"X-aws-ec2-metadata-token"=$Token}
  } catch {
    $script:InstanceId = "localhost"
  }
}

# Configure credentials at runtime (passed via environment variables)
function Configure-Credentials() {
  Write-Info "Configuring credentials"

  if ($env:BATCH_SIZE -and $env:BATCH_SIZE -notmatch '^\d+$') {
    Write-Fatal "BATCH_SIZE must be a non-negative integer, not '$env:BATCH_SIZE'"
  }

  # Configure Moderne tenant if token provided
  if ($env:MODERNE_TOKEN -and $env:MODERNE_TENANT) {
    Write-Info "Configuring Moderne tenant: $env:MODERNE_TENANT"
    mod config moderne edit --token="$env:MODERNE_TOKEN" "$env:MODERNE_TENANT"
  }

  # Git credentials for cloning private repositories. `\n` escapes are expanded so
  # multi-line SSH keys can be passed through a single environment variable.
  if ($env:GIT_CREDENTIALS) {
    Set-Content -Path "$env:USERPROFILE\.git-credentials" -Value ($env:GIT_CREDENTIALS -replace '\\n', "`n") -NoNewline
  }

  if ($env:GIT_SSH_CREDENTIALS) {
    New-Item -Type Directory "$env:USERPROFILE\.ssh" -Force | Out-Null
    Set-Content -Path "$env:USERPROFILE\.ssh\private-key" -Value ($env:GIT_SSH_CREDENTIALS -replace '\\n', "`n") -NoNewline
  }

  # Configure artifact repository
  # Build-only mode: skip the publish target entirely (LSTs are built but not published)
  if ($env:SKIP_PUBLISH -eq "true") {
    Write-Info "SKIP_PUBLISH=true: build-only mode, no publish target configured (LSTs will be built but not published)"
  }
  # AWS CodeArtifact (Maven endpoint with a short-lived, rotating auth token)
  elseif ($env:CODEARTIFACT_DOMAIN) {
    Configure-CodeArtifact
  }
  # S3 configuration (S3 bucket URL should start with s3://)
  elseif ($env:PUBLISH_URL -and $env:PUBLISH_URL.StartsWith("s3://")) {
    Write-Info "Configuring S3 artifact repository: $env:PUBLISH_URL"

    # Build the command with proper arguments
    $S3ConfigCmd = @("mod", "config", "lsts", "artifacts", "s3", "edit", $env:PUBLISH_URL)

    # Add endpoint if provided (for S3-compatible services)
    if ($env:S3_ENDPOINT) {
      $S3ConfigCmd += "--endpoint"
      $S3ConfigCmd += $env:S3_ENDPOINT
    }

    # Add AWS profile if provided
    if ($env:S3_PROFILE) {
      $S3ConfigCmd += "--profile"
      $S3ConfigCmd += $env:S3_PROFILE
    }

    # Add region if provided (for cross-region access)
    if ($env:S3_REGION) {
      $S3ConfigCmd += "--region"
      $S3ConfigCmd += $env:S3_REGION
    }

    # Execute the command
    Write-Info "Running: $($S3ConfigCmd -join ' ')"
    & $S3ConfigCmd[0] $S3ConfigCmd[1..($S3ConfigCmd.Length-1)]
  }
  # Maven repository configuration
  elseif ($env:PUBLISH_URL -and $env:PUBLISH_USER -and $env:PUBLISH_PASSWORD) {
    Write-Info "Configuring Maven artifact repository with username/password"
    mod config lsts artifacts maven edit "$env:PUBLISH_URL" --user "$env:PUBLISH_USER" --password "$env:PUBLISH_PASSWORD"
  }
  # Artifactory configuration
  elseif ($env:PUBLISH_URL -and $env:PUBLISH_TOKEN) {
    Write-Info "Configuring Artifactory artifact repository with API token"
    mod config lsts artifacts artifactory edit "$env:PUBLISH_URL" --jfrog-api-token "$env:PUBLISH_TOKEN"
  } else {
    Write-Fatal "PUBLISH_URL must be supplied via environment variable. For S3, use s3:// URL format. For Maven/Artifactory, also provide PUBLISH_USER/PUBLISH_PASSWORD or PUBLISH_TOKEN"
  }
}

# CodeArtifact's Basic-auth token expires within 12h, so it is minted at runtime and
# refreshed before every batch; the same token reaches the build through
# maven/settings-codeartifact.xml and gradle/init-codeartifact.gradle, which both read
# ${CODEARTIFACT_AUTH_TOKEN}.
function Configure-CodeArtifact() {
  if (-not $env:PUBLISH_URL) {
    Write-Fatal "PUBLISH_URL must point at the CodeArtifact Maven endpoint when CODEARTIFACT_DOMAIN is set (e.g. https://<domain>-<owner>.d.codeartifact.<region>.amazonaws.com/maven/<repository>/)"
  }
  if (-not ($env:PUBLISH_URL.StartsWith("https://") -or $env:PUBLISH_URL.StartsWith("http://"))) {
    Write-Fatal "PUBLISH_URL must be the CodeArtifact Maven HTTPS endpoint, not '$env:PUBLISH_URL'. Unset CODEARTIFACT_DOMAIN to use S3/Artifactory instead."
  }
  Write-Info "Configuring AWS CodeArtifact Maven repository: $env:PUBLISH_URL"

  # The domain owner (12-digit account id) and region are embedded in the CodeArtifact
  # host (<domain>-<owner>.d.codeartifact.<region>.amazonaws.com).
  $host_ = ([Uri]$env:PUBLISH_URL).Host
  if ($host_ -match '-(\d{12})\.d\.codeartifact\.([a-z0-9-]+)\.') {
    if (-not $env:CODEARTIFACT_DOMAIN_OWNER) { $env:CODEARTIFACT_DOMAIN_OWNER = $Matches[1] }
    if (-not $env:CODEARTIFACT_REGION) { $env:CODEARTIFACT_REGION = $Matches[2] }
  }

  # Register the Maven settings at runtime, only when CodeArtifact is selected: its catch-all
  # mirror reads ${env.PUBLISH_URL}, so baking it in would break Maven builds in a
  # non-CodeArtifact run. A user-provided ~/.m2/settings.xml takes precedence.
  $UserMavenSettings = "$env:USERPROFILE\.m2\settings.xml"
  $RepoMavenSettings = "$PSScriptRoot\maven\settings-codeartifact.xml"
  $RepoGradleInit = "$PSScriptRoot\gradle\init-codeartifact.gradle"
  if (-not (Test-Path $UserMavenSettings) -and (Test-Path $RepoMavenSettings)) {
    mod config build maven settings edit "$RepoMavenSettings"
  }

  if (-not (Test-Path $UserMavenSettings) -and -not (Test-Path $RepoMavenSettings) -and -not (Test-Path $RepoGradleInit)) {
    Write-Info "WARNING: CodeArtifact is configured for publishing, but no build dependency configuration was found. Provide a Maven settings or Gradle init script so dependencies resolve from CodeArtifact rather than public repositories."
  }

  if ($Organization) {
    Write-Info "WARNING: org mode mints the CodeArtifact token once for the whole org. A build/publish that runs past the token lifetime will fail; raise CODEARTIFACT_TOKEN_DURATION or split the org if it is large."
  } elseif ([int]($env:BATCH_SIZE) -le 0) {
    Write-Info "WARNING: CodeArtifact tokens expire within 12h and are refreshed once per batch. Set BATCH_SIZE so each batch completes inside the token lifetime for long runs."
  }

  if (-not (Refresh-CodeArtifactToken)) { Write-Fatal "Unable to configure the CodeArtifact publish target" }
}

# No-op when CodeArtifact is not in use. A transient failure mid-run does not discard the
# remaining batches. Returns $true on success, $false on failure.
function Refresh-CodeArtifactToken() {
  if (-not $env:CODEARTIFACT_DOMAIN) { return $true }

  Write-Info "Refreshing AWS CodeArtifact authorization token"

  $GetTokenCmd = @("codeartifact", "get-authorization-token",
    "--domain", $env:CODEARTIFACT_DOMAIN,
    "--query", "authorizationToken", "--output", "text")
  if ($env:CODEARTIFACT_DOMAIN_OWNER) { $GetTokenCmd += @("--domain-owner", $env:CODEARTIFACT_DOMAIN_OWNER) }
  if ($env:CODEARTIFACT_REGION) { $GetTokenCmd += @("--region", $env:CODEARTIFACT_REGION) }
  if ($env:CODEARTIFACT_TOKEN_DURATION) { $GetTokenCmd += @("--duration-seconds", $env:CODEARTIFACT_TOKEN_DURATION) }

  $token = (aws @GetTokenCmd 2>$null)
  if ($LASTEXITCODE -ne 0) {
    Write-Info "Failed to obtain a CodeArtifact authorization token (check that the AWS CLI is installed and IAM permissions / CODEARTIFACT_* settings are correct)"
    return $false
  }
  if (-not $token -or $token -eq "None") {
    Write-Info "CodeArtifact returned an empty authorization token"
    return $false
  }

  # Capture output so it does not leak into this function's boolean return value.
  $configOutput = (mod config lsts artifacts maven add "$env:PUBLISH_URL" --user aws --password "$token" 2>&1)
  if ($LASTEXITCODE -ne 0) {
    Write-Info "Failed to apply the CodeArtifact token to the publish configuration: $configOutput"
    return $false
  }

  $env:CODEARTIFACT_AUTH_TOKEN = $token
  return $true
}

# CodeArtifact marks versions uploaded without a maven-metadata.xml as Unfinished, and its
# Maven endpoint returns 404 for every asset of an Unfinished version.
# see https://docs.aws.amazon.com/codeartifact/latest/ug/maven-curl.html
# No-op when CodeArtifact is not in use; a failure leaves the versions hidden but recoverable
# (rerun `aws codeartifact update-package-versions-status` manually), so callers only warn.
# Returns $true when all versions were finalized (or nothing to do), $false otherwise.
function Finalize-CodeArtifactVersions() {
  param(
    [string]$CsvFile
  )

  if (-not $env:CODEARTIFACT_DOMAIN) { return $true }

  Write-Info "Finalizing CodeArtifact package versions to Published status"

  # <domain>-<owner>.d.codeartifact.<region>.amazonaws.com/maven/<repository>/
  $repository = ($env:PUBLISH_URL -replace '.*/maven/', '') -replace '/.*', ''
  if (-not $repository) {
    Write-Info "Could not derive the CodeArtifact repository name from PUBLISH_URL '$env:PUBLISH_URL'"
    return $false
  }

  $AwsArgs = @("--domain", $env:CODEARTIFACT_DOMAIN, "--repository", $repository, "--format", "maven")
  if ($env:CODEARTIFACT_DOMAIN_OWNER) { $AwsArgs += @("--domain-owner", $env:CODEARTIFACT_DOMAIN_OWNER) }
  if ($env:CODEARTIFACT_REGION) { $AwsArgs += @("--region", $env:CODEARTIFACT_REGION) }

  # Build the list of namespace/package coordinates from the CSV `path` column,
  # plus the organization catalog packages `mod publish` maintains alongside the LSTs.
  $coordinates = New-Object System.Collections.Generic.List[object]
  $rows = @(Import-Csv "$CsvFile")
  $pathProp = $null
  if ($rows.Count -gt 0) {
    $pathProp = $rows[0].PSObject.Properties.Name | Where-Object { $_ -ieq 'path' } | Select-Object -First 1
  }
  if (-not $pathProp) {
    Write-Info "No path column found in $CsvFile; only finalizing the organization catalog packages"
  } else {
    foreach ($row in $rows) {
      $path = "$($row.$pathProp)".TrimEnd('/')
      $idx = $path.LastIndexOf('/')
      if ($idx -gt 0) {
        $coordinates.Add([pscustomobject]@{
          Namespace = $path.Substring(0, $idx).Replace('/', '.')
          Package   = $path.Substring($idx + 1)
        })
      }
    }
  }
  $coordinates.Add([pscustomobject]@{ Namespace = 'io.moderne.organization.sources'; Package = 'repos' })
  $coordinates.Add([pscustomobject]@{ Namespace = 'io.moderne.organization.sources'; Package = 'repos-lock' })

  $failed = $false
  foreach ($c in $coordinates) {
    if (-not $c.Package) { continue }
    # a package is absent when its repository failed to build, or on the catalog packages
    # before the first successful publish; both are expected, so a failed listing is skipped
    $versions = (aws codeartifact list-package-versions @AwsArgs `
      --namespace $c.Namespace --package $c.Package --status Unfinished `
      --query 'versions[?origin.originType==`INTERNAL`].version' --output text 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $versions -or $versions -eq "None") { continue }

    $versionList = @($versions -split '\s+' | Where-Object { $_ })
    aws codeartifact update-package-versions-status @AwsArgs `
      --namespace $c.Namespace --package $c.Package --versions $versionList `
      --target-status Published 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Info "Published CodeArtifact version(s) of $($c.Namespace):$($c.Package)"
    } else {
      Write-Info "Failed to finalize $($c.Namespace):$($c.Package) version(s) $($versionList -join ' '); they stay hidden from the Maven endpoint until published manually"
      $failed = $true
    }
  }

  return (-not $failed)
}

# Set up the .NET build environment. The moderne.yml `dotnet` build step is what makes
# `mod build` produce C#/.NET LSTs; this only reports the toolchain and wires up an
# optional private NuGet feed. On Windows building .NET needs just the NuGet CLI (no Mono),
# which cleanly restores both .NET Framework (packages.config) and .NET Core / SDK-style
# (PackageReference) projects.
function Configure-DotNetBuild() {
  # Apply an optional private-feed NuGet configuration to the user profile so both the
  # NuGet CLI and `dotnet restore` pick it up during the build. Mirrors the npm/.npmrc
  # and python/pip.conf pattern. See nuget/nuget.config for a template.
  if ($env:NUGET_CONFIG_FILE) {
    if (Test-Path $env:NUGET_CONFIG_FILE -PathType Leaf) {
      $NuGetDir = "$env:APPDATA\NuGet"
      New-Item -Type Directory "$NuGetDir" -Force | Out-Null
      Copy-Item $env:NUGET_CONFIG_FILE "$NuGetDir\NuGet.Config" -Force
      Write-Info "Applied NuGet configuration from $env:NUGET_CONFIG_FILE"
    } else {
      Write-Info "WARNING: NUGET_CONFIG_FILE '$env:NUGET_CONFIG_FILE' does not exist; using default NuGet configuration"
    }
  }

  # Report the .NET toolchain if it is present, so a .NET ingest logs which tools it found.
  # Absent tooling is not fatal here — a mixed Java/.NET ingest still builds the JVM repos,
  # and the CLI surfaces .NET build failures per repository.
  $nuget = Get-Command nuget -ErrorAction SilentlyContinue
  if ($nuget) {
    Write-Info "Found NuGet CLI: $($nuget.Source)"
  }

  $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
  if ($dotnet) {
    $sdkVersion = (& dotnet --version 2>$null)
    Write-Info "Found .NET SDK: $sdkVersion ($($dotnet.Source))"
  }
}

function Prepare-Environment() {
  Write-Info "Preparing environment"
  New-Item -Type Directory "$env:DATA_DIR" -Force | Out-Null
  Remove-Item "$env:DATA_DIR\*" -Recurse -Force
  New-Item -Type Directory "$env:USERPROFILE\.moderne\cli\metrics" -Force | Out-Null
  Remove-Item "$env:USERPROFILE\.moderne\cli\metrics\*" -Recurse -Force
}

function Start-Monitoring() {
  Write-Info "Starting monitoring"
  $Process = Start-Process -FilePath "mod" -ArgumentList "monitor --port 8080" -PassThru -WindowStyle Hidden
  $Process.Id | Out-File "$env:DATA_DIR\monitor.pid"
}

function Stop-Monitoring() {
  Write-Info "Cleaning up monitoring"
  if (Test-Path "$env:DATA_DIR\monitor.pid") {
    $ProcessId = Get-Content "$env:DATA_DIR\monitor.pid"
    Stop-Process -Id $ProcessId -Force
    Remove-Item "$env:DATA_DIR\monitor.pid"
  }
}

function Select-Repos() {
  param(
    [string]$CsvFile
  )

  if (-not (Test-Path "$CsvFile" -PathType Leaf)) {
    Write-Fatal "File $CsvFile does not exist"
  }

  if ($StartIndex -and $EndIndex) {
    Write-Info "Selecting repositories from $CsvFile starting at $StartIndex and ending at $EndIndex"

    $SelectedLines = (Import-Csv $CsvFile)[($StartIndex - 1)..($EndIndex - 1)]

    Export-Csv -Path "$env:DATA_DIR\selected-repos.csv" -InputObject $SelectedLines -NoTypeInformation
  } else {
    Write-Info "Selected all repositories from $CsvFile"

    Copy-Item "$CsvFile" "$env:DATA_DIR\selected-repos.csv"
  }
}

# Split a CSV into batch files under $DATA_DIR\batches\.
# When BATCH_SIZE is set, each file contains at most BATCH_SIZE rows.
# Without BATCH_SIZE the entire CSV is used as a single batch.
function Split-IntoBatches() {
  param(
    [string]$CsvFile
  )

  $BatchDir = "$env:DATA_DIR\batches"
  New-Item -Type Directory "$BatchDir" -Force | Out-Null

  $BatchSize = if ($env:BATCH_SIZE) { [int]$env:BATCH_SIZE } else { 0 }
  if ($BatchSize -gt 0) {
    $rows = @(Import-Csv "$CsvFile")

    $batchIndex = 0
    for ($i = 0; $i -lt $rows.Count; $i += $BatchSize) {
      $end = [Math]::Min($i + $BatchSize, $rows.Count) - 1
      $chunk = $rows[$i..$end]
      $name = "batch-{0:D5}" -f $batchIndex
      $chunk | Export-Csv -Path "$BatchDir\$name.csv" -NoTypeInformation
      $batchIndex++
    }

    Write-Info "Split $($rows.Count) repositories into $batchIndex batches of $BatchSize"
  } else {
    Copy-Item "$CsvFile" "$BatchDir\all.csv"
  }
}

function Invoke-BuildAndUploadRepos {
  param(
    [string]$PartitionName,

    [string]$PartitionFile
  )

  $CloneDir = "$env:DATA_DIR\$PartitionName"

  Write-Info "Building and uploading repositories into $CloneDir from $PartitionFile"

  # turn off color output and cursor movement in the CLI
  $env:NO_COLOR=$true

  # `mod git sync csv` reads the batch file as a file:// URI (backslashes normalized to /)
  $PartitionUri = "file:///" + ($PartitionFile -replace '\\', '/')
  mod git sync csv "$CloneDir" "$PartitionUri" --with-sources | Write-Host
  if (Test-ModVersionAtLeast "3.56.7") {
    mod log syncs add "$CloneDir" "$env:DATA_DIR\syncs.zip" --last-sync | Write-Host
  }

  if (-not (Refresh-CodeArtifactToken)) { Write-Info "Token refresh failed; continuing with the existing token" }

  # kill a build if it takes too long assuming it's hung indefinitely
  # defaults to 2700 seconds (45 minutes)
  $BuildTimeout = if ($env:BUILD_TIMEOUT) { [int]$env:BUILD_TIMEOUT } else { 2700 }
  $Process = Start-Process -FilePath "mod" -ArgumentList "build $CloneDir --no-download" -PassThru -NoNewWindow
  $Process | Wait-Process -Timeout $BuildTimeout -ErrorAction SilentlyContinue -ErrorVariable Timeout
  if ($Timeout) {
    Stop-Process -Id $Process.Id -Force
    Write-Host "`n* Build timed out after $BuildTimeout seconds`n`n"
    $BuildSuccess = $false
  } else {
    $BuildSuccess = $true
  }

  if ($env:SKIP_PUBLISH -eq "true") {
    Write-Info "SKIP_PUBLISH=true: skipping publish for $PartitionName"
  } else {
    mod publish "$CloneDir" | Write-Host
    if (-not (Finalize-CodeArtifactVersions "$PartitionFile")) { Write-Info "Some CodeArtifact versions could not be finalized" }
  }
  mod log builds add "$CloneDir" "$env:DATA_DIR\log.zip" --last-build | Write-Host
  return $BuildSuccess
}

function Send-Logs() {
  param(
    [string]$Index
  )

  $Timestamp = Get-Date -Format "yyyyMMddHHmm"

  if ($env:SKIP_PUBLISH -eq "true") {
    Write-Info "SKIP_PUBLISH=true: skipping log upload"
    return
  }

  if ($env:CODEARTIFACT_DOMAIN) {
    Write-Info "Skipping build-log upload: AWS CodeArtifact does not accept non-Maven log artifacts"
    return
  }

  # Upload logs to S3
  if ($env:PUBLISH_URL -and $env:PUBLISH_URL.StartsWith("s3://")) {
    # Construct S3 path for build logs
    $LogsPath = "$env:PUBLISH_URL/.logs/$Index/$Timestamp/ingest-log-cli-$Timestamp-$Index.zip"
    Write-Info "Uploading logs to $LogsPath"

    # Build AWS S3 command with optional parameters
    $S3Cmd = @("aws", "s3", "cp", "$env:DATA_DIR\log.zip", $LogsPath)

    # Add profile if specified
    if ($env:S3_PROFILE) {
      $S3Cmd += "--profile"
      $S3Cmd += $env:S3_PROFILE
    }

    # Add region if specified
    if ($env:S3_REGION) {
      $S3Cmd += "--region"
      $S3Cmd += $env:S3_REGION
    }

    # Add endpoint if specified (for S3-compatible services)
    if ($env:S3_ENDPOINT) {
      $S3Cmd += "--endpoint-url"
      $S3Cmd += $env:S3_ENDPOINT
    }

    # Execute the upload
    & $S3Cmd[0] $S3Cmd[1..($S3Cmd.Length-1)]
    if (-not $?) {
      Write-Info "Failed to upload logs to S3"
    }

    # Upload sync logs to S3 (if they exist)
    if (Test-Path "$env:DATA_DIR\syncs.zip") {
      $SyncLogsPath = "$env:PUBLISH_URL/.logs/$Index/$Timestamp/ingest-sync-log-cli-$Timestamp-$Index.zip"
      Write-Info "Uploading sync logs to $SyncLogsPath"

      $S3Cmd = @("aws", "s3", "cp", "$env:DATA_DIR\syncs.zip", $SyncLogsPath)

      if ($env:S3_PROFILE) {
        $S3Cmd += "--profile"
        $S3Cmd += $env:S3_PROFILE
      }
      if ($env:S3_REGION) {
        $S3Cmd += "--region"
        $S3Cmd += $env:S3_REGION
      }
      if ($env:S3_ENDPOINT) {
        $S3Cmd += "--endpoint-url"
        $S3Cmd += $env:S3_ENDPOINT
      }

      & $S3Cmd[0] $S3Cmd[1..($S3Cmd.Length-1)]
      if (-not $?) {
        Write-Info "Failed to upload sync logs to S3"
      }
    }
  }
  # if PUBLISH_USER and PUBLISH_PASSWORD are set, publish logs
  elseif ($env:PUBLISH_USER -and $env:PUBLISH_PASSWORD) {
    $SecurePassword = ConvertTo-SecureString -String $env:PUBLISH_PASSWORD -AsPlainText -Force
    $Credential = New-Object PSCredential($env:PUBLISH_USER, $SecurePassword)
    $LogsUrl = "$env:PUBLISH_URL/io/moderne/ingest-log/$Index/$Timestamp/ingest-log-cli-$Timestamp-$Index.zip"
    Write-Info "Uploading logs to $LogsUrl"
    Invoke-WebRequest -Credential $Credential -Method PUT -UseBasicParsing `
        -Uri "$LogsUrl" `
        -InFile "$env:DATA_DIR\log.zip"
    if (-not $?) {
      Write-Info "Failed to publish logs"
    }

    # Upload sync logs (if they exist)
    if (Test-Path "$env:DATA_DIR\syncs.zip") {
      $SyncLogsUrl = "$env:PUBLISH_URL/io/moderne/ingest-sync-log/$Index/$Timestamp/ingest-sync-log-cli-$Timestamp-$Index.zip"
      Write-Info "Uploading sync logs to $SyncLogsUrl"
      Invoke-WebRequest -Credential $Credential -Method PUT -UseBasicParsing `
          -Uri "$SyncLogsUrl" `
          -InFile "$env:DATA_DIR\syncs.zip"
      if (-not $?) {
        Write-Info "Failed to publish sync logs"
      }
    }
  } elseif ($env:PUBLISH_TOKEN) {
    $LogsUrl = "$env:PUBLISH_URL/io/moderne/ingest-log/$Index/$Timestamp/ingest-log-cli-$Timestamp-$Index.zip"
    Write-Info "Uploading logs to $LogsUrl"
    Invoke-WebRequest -Headers @{"Authorization"="Bearer $env:PUBLISH_TOKEN"} -Method PUT -UseBasicParsing `
        -Uri "$LogsUrl" `
        -InFile "$env:DATA_DIR\log.zip"
    if (-not $?) {
      Write-Info "Failed to publish logs"
    }

    # Upload sync logs (if they exist)
    if (Test-Path "$env:DATA_DIR\syncs.zip") {
      $SyncLogsUrl = "$env:PUBLISH_URL/io/moderne/ingest-sync-log/$Index/$Timestamp/ingest-sync-log-cli-$Timestamp-$Index.zip"
      Write-Info "Uploading sync logs to $SyncLogsUrl"
      Invoke-WebRequest -Headers @{"Authorization"="Bearer $env:PUBLISH_TOKEN"} -Method PUT -UseBasicParsing `
          -Uri "$SyncLogsUrl" `
          -InFile "$env:DATA_DIR\syncs.zip"
      if (-not $?) {
        Write-Info "Failed to publish sync logs"
      }
    }
  } else {
    Write-Info "No log publishing credentials provided"
  }
}

Ingest-Repos
