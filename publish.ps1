[CmdletBinding()]
Param(
  [Parameter(Mandatory=$true, HelpMessage='Repository CSV file')]
  [string]$CsvFile
)

$ErrorActionPreference="Continue" # continue on errors to match bash behavior

# Clean any existing files in the data directory
if (Test-Path -Path $env:DATA_DIR) {
  Remove-Item $env:DATA_DIR\* -Recurse -Force
}

# Create the data directory and partition directory
$env:PARTITION_DIR="$env:DATA_DIR\partitions"
New-Item -Type Directory $env:PARTITION_DIR | Out-Null

$DataFile="$env:DATA_DIR\$((Get-Item $CsvFile).Name)"
Copy-Item $CsvFile $DataFile

# split csv file into 10 line chunks.
# the chunks should be named `repos-{chunk}`
# the csv file will contain two columns: url and branch
cd $env:PARTITION_DIR
Import-Csv $DataFile | Foreach-Object -Begin {
  $Index = 0
  $BatchSize = 10
} -Process {
  if ($Index % $BatchSize -eq 0) {
    $BatchNumber = [math]::Floor($Index++/$BatchSize)
    $Pipeline = { Export-Csv -Path .\repos-$BatchNumber -NoTypeInformation }.GetSteppablePipeline()
    $Pipeline.Begin($True)
  }
  $Pipeline.Process($_)
  if ($Index++ % $BatchSize -eq 0) {
    $Pipeline.End()
  }
} -End {
  $Pipeline.End()
}

# counter init to 0
$Index=0

function Invoke-BuildAndUploadRepos {
  $Count = (Get-ChildItem "repos-*").Count
  for ($Index = 0; $Index -lt $Count; $Index++) {
    $File="repos-$Index"

    # extract just the partition name from the file name
    $PartitionName=($File -split "-")[1]

    mod git clone csv .\$PartitionName $File --filter=tree:0

    mod build .\$PartitionName --no-download

    mod publish .\$PartitionName

    mod log builds add .\$PartitionName log.zip --last-build

    if (Test-Path -Path .\$PartitionName) {
      Remove-Item .\$PartitionName -Recurse -Force
    }
  }

  if ($env:PUBLISH_URL) {
    $LogVersion=Get-Date -Format "yyyyMMddHHmmss"
    if ($env:PUBLISH_USER -and $env:PUBLISH_PASSWORD) {
      $SecurePassword = ConvertTo-SecureString -String $env:PUBLISH_PASSWORD -AsPlainText -Force
      $Credential = New-Object PSCredential($env:PUBLISH_USER, $SecurePassword)
      Invoke-WebRequest -Credential $Credential -Method PUT -UseBasicParsing `
          -Uri "$env:PUBLISH_URL/$LogVersion/ingest-log-$LogVersion.zip" `
          -InFile .\log.zip
    } elseif ($env:PUBLISH_TOKEN) {
      Invoke-WebRequest -Headers @{"Authorization"="Bearer $env:PUBLISH_TOKEN"} -Method PUT -UseBasicParsing `
          -Uri "$env:PUBLISH_URL/$LogVersion/ingest-log-$LogVersion.zip" `
          -InFile .\log.zip
    } else {
      Write-Host "[$Index] No log publishing credentials for $env:PUBLISH_URL provided"
    }
  } else {
    Write-Host "[$Index] No log publishing credentials or URL provided"
  }

  # increment index
  $Index++
}

while ($True) {
  Invoke-BuildAndUploadRepos
}
