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
  $ret = Publish-Repos
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
  # S3 configuration (S3 bucket URL should start with s3://)
  if ($env:PUBLISH_URL -and $env:PUBLISH_URL.StartsWith("s3://")) {
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
