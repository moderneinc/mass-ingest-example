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

function Ingest-Repos() {
  Initialize-InstanceMetadata
  Configure-Credentials
  Prepare-Environment
  Start-Monitoring

  if ($Organization) {
    $CloneDir = "$env:DATA_DIR\$Organization"
    Write-Host "Organization: $Organization"
    New-Item -Type Directory "$CloneDir" -Force
    mod git sync csv "$CloneDir" "$SourceCsv" --organization "$Organization" --with-sources
    mod git pull "$CloneDir"
    mod build "$CloneDir" --no-download
    mod publish "$CloneDir"
    mod log builds add "$CloneDir" "$env:DATA_DIR\log.zip" --last-build
    Send-Logs "org-$Organization"
  } else {
    Select-Repos "$SourceCsv"
    
    # create a partition name based on the current partition and the current date YYYY-MM-DD-HH-MM
    $PartitionName = (Get-Date -Format "yyyy-MM-dd-HH-mm")

    if (-not (Invoke-BuildAndUploadRepos "$PartitionName" "$env:DATA_DIR\selected-repos.csv")) {
      Write-Info "Error building and uploading repositories"
    } else {
      Write-Info "Successfully built and uploaded repositories"
    }

    $indexRange = if ($StartIndex -and $EndIndex) { "$StartIndex-$EndIndex" } else { "all" }
    Send-Logs $indexRange
  }
  Stop-Monitoring
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

  # Configure Moderne tenant if token provided
  if ($env:MODERNE_TOKEN -and $env:MODERNE_TENANT) {
    Write-Info "Configuring Moderne tenant: $env:MODERNE_TENANT"
    mod config moderne edit --token="$env:MODERNE_TOKEN" "$env:MODERNE_TENANT"
  }

  # Configure artifact repository
  # S3 configuration (S3 bucket URL should start with s3://)
  if ($env:PUBLISH_URL -and $env:PUBLISH_URL.StartsWith("s3://")) {
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

function Invoke-BuildAndUploadRepos {
  param(
    [string]$PartitionName,

    [string]$PartitionFile
  )

  $CloneDir = "$env:DATA_DIR\$PartitionName"

  Write-Info "Building and uploading repositories into $CloneDir from $PartitionFile"

  $env:NO_COLOR=$true

  #mod git sync csv "$CloneDir" "$PartitionFile" --with-sources
  mod git sync csv "$CloneDir" "file:///$env:DATA_DIR/selected-repos.csv" --with-sources | Write-Host

  $Process = Start-Process -FilePath "mod" -ArgumentList "build $CloneDir --no-download" -PassThru -NoNewWindow
  $Process | Wait-Process -Timeout 2700 -ErrorAction SilentlyContinue -ErrorVariable Timeout
  if ($Timeout) {
    Stop-Process -Id $Process.Id -Force
    Write-Host "`n* Build timed out after 45 minutes`n`n"
    $BuildSuccess = $false
  } else {
    $BuildSuccess = $true
  }

  mod publish "$CloneDir" | Write-Host
  mod log builds add "$CloneDir" "$env:DATA_DIR\log.zip" --last-build | Write-Host
  return $BuildSuccess
}

function Send-Logs() {
  param(
    [string]$Index
  )

  $Timestamp = Get-Date -Format "yyyyMMddHHmm"

  # TODO: Implement S3 log upload using AWS CLI
  # Example: aws s3 cp $env:DATA_DIR\log.zip $env:PUBLISH_URL/.logs/$Index/$Timestamp/ingest-log-cli-$Timestamp-$Index.zip
  if ($env:PUBLISH_URL -and $env:PUBLISH_URL.StartsWith("s3://")) {
    Write-Info "S3 log upload not yet implemented - logs are in $env:DATA_DIR\log.zip"
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
  } elseif ($env:PUBLISH_TOKEN) {
    $LogsUrl = "$env:PUBLISH_URL/io/moderne/ingest-log/$Index/$Timestamp/ingest-log-cli-$Timestamp-$Index.zip"
    Write-Info "Uploading logs to $LogsUrl"
    Invoke-WebRequest -Headers @{"Authorization"="Bearer $env:PUBLISH_TOKEN"} -Method PUT -UseBasicParsing `
        -Uri "$LogsUrl" `
        -InFile "$env:DATA_DIR\log.zip"
    if (-not $?) {
      Write-Info "Failed to publish logs"
    }
  } else {
    Write-Info "No log publishing credentials provided"
  }
}

Ingest-Repos
