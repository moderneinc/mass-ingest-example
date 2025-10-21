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

  Write-Host "[$script:InstanceId][$StartIndex-$EndIndex] $Message"
}

function Write-Fatal() {
  param(
    [string]$Message
  )

  Write-Error "[$script:InstanceId][$StartIndex-$EndIndex] $Message"
  exit 1
}

function Ingest-Repos() {
  Initialize-Setup
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

    Send-Logs "$StartIndex-$EndIndex"
  }
  Stop-Monitoring
}

function Initialize-Setup() {
  try {
    $Token = Invoke-RestMethod -Method Put -TimeoutSec 2 -Uri "http://169.254.169.254/latest/api/token" -Headers @{"X-aws-ec2-metadata-token-ttl-seconds"="21600"}
    $script:InstanceId = Invoke-RestMethod -TimeoutSec 2 -Uri "http://169.254.169.254/latest/meta-data/instance-id" -Headers @{"X-aws-ec2-metadata-token"=$Token}
  } catch {
    $script:InstanceId = "localhost"
  }
}

# Clean any existing files
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

  # if PUBLISH_USER and PUBLISH_PASSWORD are set, publish logs
  if ($env:PUBLISH_USER -and $env:PUBLISH_PASSWORD) {
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
