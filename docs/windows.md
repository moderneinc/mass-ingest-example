# Windows / PowerShell

The Docker image runs the bash `publish.sh`. `publish.ps1` is a PowerShell port of the same flow that runs **directly on a Windows host, without Docker**. The usual reason is **.NET (C#) repositories**: on Windows they build natively with just the NuGet CLI (no Mono), so one host produces both .NET Framework and .NET Core LSTs.

## Prerequisites

- Windows with PowerShell 5.1+ (or PowerShell 7+).
- The Moderne CLI (`mod`) on `PATH`, from a release that ships `mod publish --sync-csv` and `mod doctor`. See the [CLI install guide](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro).
- JDKs for the JVM repositories you build (registered with `mod config java jdk`), plus Maven and Gradle as needed.
- The AWS CLI if you publish to CodeArtifact.
- For .NET builds: .NET SDK 10.0+ and the NuGet CLI (`nuget.exe`) on `PATH`. Keep the `dotnet` build step in `moderne.yml` (enabled by default); `nuget/nuget.config` is a template for a private feed.

## Running

`publish.ps1` reads the same environment variables as the bash flow. `DATA_DIR` (the working directory) is required; the rest are those in the [README](../README.md), the [S3](s3.md) and [CodeArtifact](codeartifact.md) settings, and

- `NUGET_CONFIG_FILE`: a `nuget.config` applied to `%APPDATA%\NuGet\NuGet.Config` before the run so restores use a private feed.

```powershell
$env:DATA_DIR = "C:\moderne\data"
$env:PUBLISH_URL = "https://artifactory.example.com/artifactory/moderne-ingest/"
$env:PUBLISH_USER = "svc-moderne"
$env:PUBLISH_PASSWORD = "..."

.\publish.ps1                                  # everything in the store's repos.csv
$env:ORGANIZATION = "Claims"; .\publish.ps1    # one organization
$env:DIAGNOSE = "true"; .\publish.ps1          # mod doctor only
```

Ctrl+C reaches the CLI as well as the script, so the central `repos-lock.csv` is flushed before it exits. The CodeArtifact token refresher runs as a background PowerShell job; its output is printed when the run ends.

## Differences from the Docker flow

- No container: install and register the toolchain (JDKs, Maven/Gradle, .NET SDK, NuGet CLI) yourself rather than through the Dockerfile.
- Credential files are written under `%USERPROFILE%` (`.git-credentials`, `.ssh\private-key`), and git's `credential.helper` is pointed at the file explicitly because Windows git defaults to the credential manager.
