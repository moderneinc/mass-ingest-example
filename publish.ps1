$ErrorActionPreference="Continue" # continue on errors to match bash behavior

function Write-Info() {
  param(
    [string]$Message
  )

  Write-Host $Message
}

function Write-Fatal() {
  param(
    [string]$Message
  )

  Write-Error $Message
  exit 1
}

function Ingest-Repos() {
  if (-not $env:DATA_DIR) { Write-Fatal "DATA_DIR must be set" }
  if (-not (mod publish --help 2>$null | Select-String -Quiet -SimpleMatch '--sync-csv')) {
    Write-Fatal "This Moderne CLI has no 'mod publish --sync-csv'; install a release that ships it"
  }

  # turn off color output in the CLI
  $env:NO_COLOR=$true

  Configure-Credentials
  Configure-DotNetBuild
  New-Item -Type Directory "$env:DATA_DIR" -Force | Out-Null

  if ($env:DIAGNOSE -eq "true") {
    mod doctor "$env:DATA_DIR" --sync-csv
    exit $LASTEXITCODE
  }
  if ($env:DIAGNOSE_ON_START -eq "true") {
    mod doctor "$env:DATA_DIR" --sync-csv
  }

  Start-Monitoring
  Start-CodeArtifactRefresher
  $ret = Publish-Repos
  if (-not (Finalize-CodeArtifactVersions)) { Write-Info "Some CodeArtifact versions could not be finalized" }
  Stop-CodeArtifactRefresher
  Stop-Monitoring
  exit $ret
}

# Works through the store's repos.csv one repository at a time: clone, build, publish, record
# in the store's repos-lock.csv, delete. Rows whose lock entry already matches are skipped.
# Ctrl+C reaches the CLI as well as this script, so its shutdown hook flushes the lock.
function Publish-Repos() {
  $PublishArgs = @("publish", $env:DATA_DIR, "--sync-csv")
  if ($env:ORGANIZATION) { $PublishArgs += @("--organization", $env:ORGANIZATION) }
  if ($env:PARALLEL) { $PublishArgs += @("--parallel", $env:PARALLEL) }
  Write-Info "Running: mod $($PublishArgs -join ' ')"
  & mod @PublishArgs
  return $LASTEXITCODE
}

# Configure credentials at runtime (passed via environment variables)
function Configure-Credentials() {
  Write-Info "Configuring credentials"

  # Configure Moderne tenant if token provided
  if ($env:MODERNE_TOKEN -and $env:MODERNE_TENANT) {
    Write-Info "Configuring Moderne tenant: $env:MODERNE_TENANT"
    mod config moderne edit --token="$env:MODERNE_TOKEN" "$env:MODERNE_TENANT"
  }

  # Git credentials for cloning private repositories. `\n` escapes are expanded so
  # multi-line SSH keys can be passed through a single environment variable.
  if ($env:GIT_CREDENTIALS) {
    $GitCredFile = "$env:USERPROFILE\.git-credentials"
    Set-Content -Path $GitCredFile -Value ($env:GIT_CREDENTIALS -replace '\\n', "`n") -NoNewline
    # Windows git defaults to the credential manager, which ignores .git-credentials, so
    # register the store helper explicitly and point it at the file just written.
    git config --global credential.helper "store --file=`"$($GitCredFile -replace '\\','/')`""
  }

  if ($env:GIT_SSH_CREDENTIALS) {
    $SshKey = "$env:USERPROFILE\.ssh\private-key"
    New-Item -Type Directory "$env:USERPROFILE\.ssh" -Force | Out-Null
    Set-Content -Path $SshKey -Value ($env:GIT_SSH_CREDENTIALS -replace '\\n', "`n") -NoNewline
    # OpenSSH refuses a key with loose ACLs; strip inheritance and grant only this user.
    icacls $SshKey /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
    # Point git at the key (forward slashes so git's shell keeps the path intact) and
    # accept unknown host keys so the clone does not block on a prompt.
    git config --global core.sshCommand "ssh -i `"$($SshKey -replace '\\','/')`" -o StrictHostKeyChecking=accept-new"
  }

  # Configure artifact repository
  # AWS CodeArtifact (Maven endpoint with a short-lived, rotating auth token)
  if ($env:CODEARTIFACT_DOMAIN) {
    Configure-CodeArtifact
  }
  # S3 configuration (S3 bucket URL should start with s3://)
  elseif ($env:PUBLISH_URL -and $env:PUBLISH_URL.StartsWith("s3://")) {
    Write-Info "Configuring S3 artifact repository: $env:PUBLISH_URL"

    $S3ConfigCmd = @("mod", "config", "lsts", "artifacts", "s3", "edit", $env:PUBLISH_URL)
    if ($env:S3_ENDPOINT) {
      $S3ConfigCmd += "--endpoint-url"
      $S3ConfigCmd += $env:S3_ENDPOINT
    }
    if ($env:S3_PROFILE) {
      $S3ConfigCmd += "--profile"
      $S3ConfigCmd += $env:S3_PROFILE
    }
    if ($env:S3_REGION) {
      $S3ConfigCmd += "--region"
      $S3ConfigCmd += $env:S3_REGION
    }

    Write-Info "Running: $($S3ConfigCmd -join ' ')"
    & $S3ConfigCmd[0] $S3ConfigCmd[1..($S3ConfigCmd.Length-1)]
  }
  # Maven repository configuration
  elseif ($env:PUBLISH_URL -and $env:PUBLISH_USER -and $env:PUBLISH_PASSWORD) {
    Write-Info "Configuring Maven artifact repository with username/password"
    mod config lsts artifacts maven add "$env:PUBLISH_URL" --user "$env:PUBLISH_USER" --password "$env:PUBLISH_PASSWORD"
  }
  # Artifactory configuration
  elseif ($env:PUBLISH_URL -and $env:PUBLISH_TOKEN) {
    Write-Info "Configuring Artifactory artifact repository with API token"
    mod config lsts artifacts artifactory add "$env:PUBLISH_URL" --jfrog-api-token "$env:PUBLISH_TOKEN"
  } else {
    Write-Fatal "PUBLISH_URL must be supplied via environment variable. For S3, use s3:// URL format. For Maven/Artifactory, also provide PUBLISH_USER/PUBLISH_PASSWORD or PUBLISH_TOKEN"
  }
}

# CodeArtifact's Basic-auth token expires within 12h, so it is minted at runtime and refreshed
# in the background while the CLI runs (see Start-CodeArtifactRefresher).
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

  if (-not (Refresh-CodeArtifactToken)) { Write-Fatal "Unable to configure the CodeArtifact publish target" }

  # Only registered on a CodeArtifact run: the catch-all mirror would break Maven builds in a
  # non-CodeArtifact run. A user-provided ~/.m2/settings.xml takes precedence.
  $UserMavenSettings = "$env:USERPROFILE\.m2\settings.xml"
  $RenderedMavenSettings = "$env:USERPROFILE\.m2\settings-codeartifact.xml"
  $RepoMavenSettings = "$PSScriptRoot\maven\settings-codeartifact.xml"
  $RepoGradleInit = "$PSScriptRoot\gradle\init-codeartifact.gradle"
  if (-not (Test-Path $UserMavenSettings) -and (Test-Path $RenderedMavenSettings)) {
    mod config build maven settings edit "$RenderedMavenSettings"
  }

  if (-not (Test-Path $UserMavenSettings) -and -not (Test-Path $RepoMavenSettings) -and -not (Test-Path $RepoGradleInit)) {
    Write-Info "WARNING: CodeArtifact is configured for publishing, but no build dependency configuration was found. Provide a Maven settings or Gradle init script so dependencies resolve from CodeArtifact rather than public repositories."
  }
}

# Mints a token and writes it everywhere the running CLI and the build tools read it from
# disk, because an environment variable cannot reach an already-running process.
# Returns $true on success, $false on failure.
function Refresh-CodeArtifactToken() {
  param(
    [string]$RepoRoot = $PSScriptRoot
  )

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

  # gradle/init-codeartifact.gradle reads the token file; Maven gets it rendered into its settings
  Set-Content -Path "$env:USERPROFILE\.codeartifact-token" -Value $token -NoNewline
  $Template = "$RepoRoot\maven\settings-codeartifact.xml"
  if (Test-Path $Template) {
    New-Item -Type Directory "$env:USERPROFILE\.m2" -Force | Out-Null
    (Get-Content $Template -Raw).Replace('${env.CODEARTIFACT_AUTH_TOKEN}', $token) |
      Set-Content -Path "$env:USERPROFILE\.m2\settings-codeartifact.xml" -NoNewline
  }
  $env:CODEARTIFACT_AUTH_TOKEN = $token
  return $true
}

function Start-CodeArtifactRefresher() {
  if (-not $env:CODEARTIFACT_DOMAIN) { return }

  $lifetime = if ($env:CODEARTIFACT_TOKEN_DURATION) { [int]$env:CODEARTIFACT_TOKEN_DURATION } else { 43200 }
  # 0 ties the token to the role session, whose minimum is 15 minutes
  if ($lifetime -le 0) { $lifetime = 900 }

  # A job runs in its own process, so it gets the function body and repo path explicitly
  $script:Refresher = Start-Job -ArgumentList $lifetime, ${function:Refresh-CodeArtifactToken}.ToString(), $PSScriptRoot -ScriptBlock {
    param([int]$Lifetime, [string]$RefreshBody, [string]$RepoRoot)
    function Write-Info([string]$Message) { Write-Host $Message }
    ${function:Refresh-CodeArtifactToken} = [scriptblock]::Create($RefreshBody)
    $next = [int]($Lifetime * 3 / 4)
    while ($true) {
      Start-Sleep -Seconds $next
      if (Refresh-CodeArtifactToken -RepoRoot $RepoRoot) {
        $next = [int]($Lifetime * 3 / 4)
      } else {
        Write-Info "CodeArtifact token refresh failed; retrying in 5 minutes"
        $next = 300
      }
    }
  }
}

function Stop-CodeArtifactRefresher() {
  if ($script:Refresher) {
    Receive-Job $script:Refresher | Write-Host
    Stop-Job $script:Refresher
    Remove-Job $script:Refresher
  }
}

# CodeArtifact marks versions uploaded without a maven-metadata.xml as Unfinished, and its
# Maven endpoint returns 404 for every asset of an Unfinished version.
# see https://docs.aws.amazon.com/codeartifact/latest/ug/maven-curl.html
# No-op when CodeArtifact is not in use; a failure leaves the versions hidden but recoverable
# (rerun `aws codeartifact update-package-versions-status` manually), so callers only warn.
# Returns $true when all versions were finalized (or nothing to do), $false otherwise.
function Finalize-CodeArtifactVersions() {
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

  # No local csv survives the run, so the coordinates come from the repository itself
  $packages = @(aws codeartifact list-packages @AwsArgs --query 'packages[].[namespace,package]' --output text 2>$null)
  if ($LASTEXITCODE -ne 0) {
    Write-Info "Could not list the packages in CodeArtifact repository '$repository'"
    return $false
  }

  $failed = $false
  foreach ($line in $packages) {
    $parts = $line -split "`t"
    if ($parts.Count -lt 2 -or -not $parts[1]) { continue }
    $namespace = $parts[0]
    $package = $parts[1]
    $versions = (aws codeartifact list-package-versions @AwsArgs `
      --namespace $namespace --package $package --status Unfinished `
      --query 'versions[?origin.originType==`INTERNAL`].version' --output text 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $versions -or $versions -eq "None") { continue }

    $versionList = @($versions -split '\s+' | Where-Object { $_ })
    aws codeartifact update-package-versions-status @AwsArgs `
      --namespace $namespace --package $package --versions $versionList `
      --target-status Published 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Info "Published CodeArtifact version(s) of ${namespace}:${package}"
    } else {
      Write-Info "Failed to finalize ${namespace}:${package} version(s) $($versionList -join ' '); they stay hidden from the Maven endpoint until published manually"
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

function Start-Monitoring() {
  Write-Info "Starting monitoring"
  $script:Monitor = Start-Process -FilePath "mod" -ArgumentList "monitor --port 8080" -PassThru -WindowStyle Hidden
}

function Stop-Monitoring() {
  Write-Info "Cleaning up monitoring"
  if ($script:Monitor) {
    Stop-Process -Id $script:Monitor.Id -Force -ErrorAction SilentlyContinue
  }
}

Ingest-Repos
