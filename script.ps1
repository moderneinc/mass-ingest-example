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

function Do-Work() {
    Write-Host "processing"
    mod publish "$env:DATA_DIR\"
}

Do-Work