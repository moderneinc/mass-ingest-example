# Review request: Security improvements and documentation consistency

## Overview

This commit moves git credential configuration from build-time to runtime and improves documentation consistency across all three deployment stages (quickstart, observability, scalability).

## Changes made

### 1. Security: Move git credentials to runtime mounting

**Problem**: Git credentials were configured to be COPY'd into the Docker image at build-time, which would bake secrets into image layers.

**Solution**:
- Updated `Dockerfile` to configure git credential helper at build-time to expect credentials at `/root/.git-credentials`
- Credentials are now mounted at runtime via volume mounts (`-v $(pwd)/.git-credentials:/root/.git-credentials:ro`)
- Added `.git-credentials` and `.ssh/` to `.gitignore` to prevent accidental commits
- Updated all READMEs to document the new runtime mounting approach

**Files changed**:
- `Dockerfile` (lines 152-172): Removed COPY instructions, added runtime mounting documentation
- `.gitignore`: Added `.env`, `.git-credentials`, `.ssh/` patterns
- `1-quickstart/README.md`: Updated "Repository authentication" section
- `2-observability/README.md`: Updated "Repository authentication" section, clarified credentials are already configured
- `2-observability/docker-compose.yml`: Added commented volume mounts for `.git-credentials` and `.ssh`

### 2. Documentation consistency improvements

**Problem**: Shared components were documented differently across the three READMEs, making it harder for users to understand.

**Changes**:

#### Image naming consistency
- Changed all references from `mass-ingest:basic` to `mass-ingest:quickstart` in `1-quickstart/README.md` to match directory name

#### Section naming improvements
- Changed "## Next steps" to "## Alternative deployment options" in `1-quickstart/README.md` and `2-observability/README.md`
- Changed "## Next steps" to "## Optional enhancements" in `3-scalability/README.md`
- This better conveys that these are alternatives, not required next steps

#### Standardized "Best for" sections
- Updated `2-observability/README.md` and `3-scalability/README.md` to use bullet lists matching `1-quickstart/README.md` format
- Improved clarity on when each deployment approach is appropriate

#### repos.csv format documentation
- Added consistent repos.csv format documentation to all three READMEs
- Each now includes:
  - CSV example with all required columns
  - Bulleted list of required columns with descriptions
  - Previously only `1-quickstart/README.md` had this information

## Review checklist

Please verify:

### Security
- [ ] Git credentials are never baked into Docker images
- [ ] All credential files are in `.gitignore`
- [ ] Runtime mounting is properly documented in all READMEs
- [ ] Volume mounts use `:ro` (read-only) flag for security

### Documentation accuracy
- [ ] All READMEs consistently explain repos.csv format
- [ ] Repository authentication instructions are accurate for each deployment stage
- [ ] "Alternative deployment options" properly conveys these are alternatives, not required steps
- [ ] Image tags are consistent (quickstart vs basic)

### Completeness
- [ ] Are there other shared components that should be documented consistently? (environment variables, troubleshooting, etc.)
- [ ] Should we add a shared "Common configuration" section that all READMEs reference?
- [ ] Any other security concerns with the current approach?

### Testing
- [ ] Build the Docker image and verify git credential mounting works
- [ ] Test with both .git-credentials and .ssh mounting
- [ ] Verify the approach works for all three deployment stages

## Questions for reviewer

1. Should we create a shared `CONFIGURATION.md` that all three READMEs reference for common topics?
2. Are there other security improvements we should make while we're at it?
3. Should the root README.md also be updated to explain the three deployment stages more clearly?
