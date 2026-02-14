# Dockerfile generator - design and implementation notes

## Overview

Interactive bash questionnaire that generates customized Dockerfiles for mass-ingest environments based on user's repository landscape and requirements.

**Location**: `scripts/generate-dockerfile.sh`

**Status**: POC complete, ready for testing and iteration

## Design philosophy

### Template-based generation

Instead of sed/awk manipulation of existing Dockerfiles, we use a modular template approach:

**Pros:**
- Clean separation of concerns
- Easy to add/modify features
- No fragile regex patterns
- Templates are testable independently
- Can generate both custom and example Dockerfiles from same source

**Cons:**
- Example Dockerfile must be maintained separately (or generated)
- Templates must stay in sync with best practices

### User experience focus

The questionnaire provides:
- **Context for every question** - explains why the choice matters
- **Welcoming flow** - colored output, clear sections, progress indicators
- **Smart defaults** - all JDKs enabled by default (safe but large)
- **Validation** - checks file paths, validates choices
- **Summary before generation** - shows what will be included

## Architecture

### Directory structure

```
scripts/
├── generate-dockerfile.sh              # Interactive questionnaire
└── dockerfile-templates/
    ├── 00-base.Dockerfile              # JDKs, dependencies, mod CLI
    ├── 10-gradle.Dockerfile            # Gradle 8.14
    ├── 11-maven.Dockerfile             # Maven 3.9.11 + wrapper
    ├── 20-android.Dockerfile           # Android SDK (API 25-33)
    ├── 21-bazel.Dockerfile             # Bazel
    ├── 22-node.Dockerfile              # Node.js 20.x
    ├── 23-python.Dockerfile            # Python 3.11
    ├── 24-dotnet.Dockerfile            # .NET 6.0 & 8.0
    ├── 30-certs.Dockerfile             # Self-signed cert config
    ├── 31-git-ssl.Dockerfile           # Git SSL disable
    ├── 32-maven-settings.Dockerfile    # Custom Maven settings
    └── 99-runner.Dockerfile            # Final runner stage, CMD
```

### Template naming convention

- `00-XX`: Base infrastructure (always included)
- `10-XX`: Build tools (optional)
- `20-XX`: Language runtimes (optional)
- `30-XX`: Security/configuration (optional, some with placeholders)
- `99-XX`: Final stage (always included)

Numbers ensure correct concatenation order for multi-stage Docker builds.

### Generation flow

1. **Always included**: 00-base.Dockerfile + 99-runner.Dockerfile
2. **Conditional inclusion**: Based on user answers
3. **Placeholder replacement**: For certs and Maven settings (if paths provided)
4. **Simple concatenation**: `cat template1 template2 ... > output`

## Script flow

### 1. Welcome screen
- Clear terminal
- Show header with colors
- Explain what to expect
- Estimated time

### 2. JDK version selection
- **Default**: All JDKs (8, 11, 17, 21, 25)
- **Context**: Need all versions for compatibility, ~2GB disk space
- **Option**: Can disable specific versions (UI implemented, Dockerfile generation not yet implemented)
- **Validation**: At least one JDK must be selected

### 3. Build tools
- **Multiple choice**: None / Maven / Gradle / Both
- **Context**: Explains wrappers vs global installation
- **Details**: Maven 3.9.11, Gradle 8.14

### 4. Language runtimes
- **One-by-one yes/no**: Android, Bazel, Node, Python, .NET
- **Context**: Explains when each is needed
- **Note**: Future enhancement could use checkboxes

### 5. Security configuration

#### Self-signed certificates
- **Optional path input**: Can provide cert file path or skip
- **If path provided**: Validates file exists, generates with actual filename
- **If skipped**: Includes commented instructions
- **What it does**: Imports cert to all JDK keystores + wget config

#### Git SSL verification
- **Warning**: Security implications highlighted
- **Default**: Enabled (recommended)
- **Option**: Disable for dev/test environments

### 6. Maven configuration
- **Optional path input**: Can provide settings.xml path or skip
- **If path provided**: Validates file exists, generates COPY directive
- **If skipped**: Includes commented instructions

### 7. Summary
- Shows all selected components
- Color-coded: green (included), cyan (manual setup needed), yellow (warnings)
- Final confirmation before generation

### 8. Generation
- Concatenates selected templates
- Replaces placeholders (`{{CERT_FILE}}`, `{{SETTINGS_FILE}}`)
- Outputs to `Dockerfile.generated`

### 9. Next steps
- Shows generated filename
- Lists required actions (copy cert/settings files if provided)
- Build command with proper flags
- Links to documentation

## Technical decisions

### Color rendering

**Issue**: ANSI escape codes weren't rendering, showing as literal `\033[1m` text.

**Cause**: Used `cat << EOF` heredocs which don't interpret escape sequences.

**Solution**: Replaced all heredocs with `echo -e` statements for proper color rendering.

### Choice function return values

**Critical bug**: Script failed when selecting options 2, 3, or 4.

**Root cause**: With `set -e`, bash exits on non-zero return values. The `ask_choice` function returned 0-3 to indicate selection:
- Option 1 → return 0 (success)
- Option 2 → return 1 (ERROR, script exits!)
- Option 3 → return 2 (ERROR, script exits!)
- Option 4 → return 3 (ERROR, script exits!)

**Solution**:
- Function always returns 0 (success)
- Stores actual choice (0-3) in global variable `$CHOICE_RESULT`
- Case statement uses `$CHOICE_RESULT` instead of `$?`

```bash
ask_choice() {
    # ... prompt and validate input ...
    CHOICE_RESULT=$((choice-1))  # Store in global
    return 0                      # Always success
}

# Usage:
ask_choice "Which option?" "Option 1" "Option 2" "Option 3"
case $CHOICE_RESULT in
    0) DO_THING_1;;
    1) DO_THING_2;;
    2) DO_THING_3;;
esac
```

### Placeholder replacement

Used simple `sed` for dynamic content:
```bash
sed "s|{{CERT_FILE}}|mycert.crt|g" template.Dockerfile
```

Simple and works well for POC. Could be enhanced with more sophisticated templating if needed.

## What's implemented

✅ Interactive questionnaire with colored output and wizard-style screen clearing
✅ Contextual explanations for all questions
✅ JDK version selection with full filtering in generated Dockerfile
✅ Build tool selection (4 options)
✅ Language runtime selection (5 runtimes)
✅ Self-signed certificate support with file validation and retry loops
✅ Git SSL disable option
✅ Maven settings support with file validation (.xml extension required)
✅ Configuration summary
✅ Dockerfile generation via template concatenation
✅ Dynamic JDK filtering (only selected JDKs included in output)
✅ Dynamic certificate configuration (only for selected JDKs)
✅ Next steps with clear instructions

## Recent improvements (2025-10-28)

✅ **Screen clearing between questions** - Wizard-like experience with `clear` after each section
✅ **Input validation with retry loops** - Validates file extensions and paths, allows user to retry on mistakes
✅ **Selective JDK filtering** - Fully implemented! Generated Dockerfiles now only include selected JDKs
✅ **Dynamic base generation** - `generate_base_section()` function creates JDK stages on-demand
✅ **Dynamic certificate configuration** - `generate_certs_section()` handles JDK 8 special case (jre path)

## What's NOT yet implemented

❌ **Checkbox-style multi-select**
- Currently one-by-one yes/no for language runtimes
- Checkboxes would be better UX but harder in bash
- Consider using `dialog`, `whiptail`, or similar for enhanced UI

❌ **Example Dockerfile generator**
- Could create `scripts/generate-example-dockerfile.sh`
- Would concatenate ALL templates with appropriate commenting
- Would keep example in sync with templates
- Not critical for POC

❌ **Non-interactive mode**
- No config file or environment variable support
- Must answer questions interactively every time
- Could add for CI/CD scenarios

## Future enhancements

### Template improvements
- Add more JDK versions as released
- Update tool versions (Maven, Gradle, Node, etc.)
- Add more language runtimes (Go, Ruby, etc.)
- Add more build systems (Buck, Pants, etc.)

### Script improvements
- Better error messages with recovery suggestions
- Resume capability (save state, continue later)
- Non-interactive mode (env vars or config file)
- Validation of artifact repository connectivity
- Detection of local system (suggest appropriate defaults)

### JDK filtering implementation details

Instead of splitting templates into multiple files, we implemented dynamic generation:

1. **`get_highest_jdk()`** - Determines which JDK to use as the base image
2. **`generate_base_section()`** - Dynamically creates:
   - Only the FROM stages for selected JDKs
   - COPY statements for only selected JDKs
   - Base image derived from highest selected JDK
3. **`generate_certs_section()`** - Dynamically creates:
   - Keytool imports for only selected JDKs
   - Handles JDK 8 special case (different cacerts path)

This approach is cleaner than template splitting and easier to maintain.

### Advanced certificate handling
- Auto-detect system certificates
- Validate certificate format before including
- Support certificate chains
- Support multiple certificates

### Advanced Maven settings
- Template with placeholders for common patterns
- Wizard for configuring mirrors, repositories, profiles
- Encryption support for settings-security.xml

## Testing notes

### Manual testing
The script can be tested with piped input:
```bash
cat > /tmp/test-input.txt << 'EOF'
y         # Keep all JDKs
4         # Both Maven and Gradle
n         # No Android
n         # No Bazel
y         # Yes Node.js
n         # No Python
n         # No .NET
n         # No certs
n         # Don't disable Git SSL
n         # No Maven settings
y         # Confirm generation
EOF

bash scripts/generate-dockerfile.sh < /tmp/test-input.txt
```

### Validation
After generation, verify content:
```bash
# Check for expected sections
grep -q "Gradle support" Dockerfile.generated && echo "✓ Gradle found"
grep -q "Install Maven" Dockerfile.generated && echo "✓ Maven found"
grep -q "Node.js support" Dockerfile.generated && echo "✓ Node found"

# Test build (may take a while)
docker build -f Dockerfile.generated -t test:latest .
```

## Known limitations

1. **No undo/back** - Can't go back to previous questions (by design for simplicity)
2. **No config file support** - Must answer questions every time
3. **No validation of tool versions** - Doesn't check if URLs are valid
4. **Assumes Linux/macOS** - May have issues on Windows (paths, colors)
5. **Template updates** - No automatic update mechanism for templates
6. **No Dockerfile linting** - Could add hadolint or similar, but requires external tool

## Maintenance

### Updating tool versions
To update Maven, Gradle, Node, etc.:
1. Edit the relevant template file in `dockerfile-templates/`
2. Update version numbers and download URLs
3. Test the generated Dockerfile builds successfully
4. Update context text in script if version changes affect compatibility

### Adding new features
To add a new language runtime or tool:
1. Create new template file (e.g., `25-golang.Dockerfile`)
2. Add boolean flag to script (e.g., `ENABLE_GOLANG=false`)
3. Add question in appropriate section
4. Add conditional in `generate_dockerfile()` function
5. Add to summary display

### Template file naming
Keep the numeric prefix system:
- 00-09: Base infrastructure
- 10-19: Build tools
- 20-29: Language runtimes
- 30-39: Security/configuration
- 90-99: Final stages

## References

- [Original mass-ingest-example Dockerfile](/Users/peter/moderne/git/mass-ingest-example/Dockerfile)
- [Moderne CLI docs](https://docs.moderne.io/user-documentation/moderne-cli)
- [Mass ingest wrapper design](../mass-ingest-wrapper/DESIGN.md)

## Questions for next session

1. ~~Should we implement JDK filtering in Dockerfile generation?~~ ✅ Done (2025-10-28)
2. Should we create a non-interactive mode?
3. Should we add `dialog`/`whiptail` for better UX?
4. ~~Should we validate Dockerfile syntax after generation?~~ ✅ Decided against (no external dependencies)
5. Should we auto-update tool versions from upstream?
6. Should we support custom template directories?
7. Should we add telemetry to understand common configurations?
8. Should we support JDK versions beyond the current 5 (8, 11, 17, 21, 25)?

## Change log

**2025-10-28** - Major enhancements
- Implemented JDK filtering in Dockerfile generation (was #1 missing feature)
- Added wizard-style screen clearing between questions
- Added input validation with retry loops for file paths
- Added file extension validation (.xml for Maven settings, certificate formats)
- Created `generate_base_section()` for dynamic JDK stage generation
- Created `generate_certs_section()` for dynamic certificate configuration
- Updated documentation with implementation details

**2025-10-27** - Initial POC implementation
- Created template-based architecture
- Implemented interactive questionnaire
- Fixed color rendering issues
- Fixed critical `set -e` bug with choice function
- Documented design decisions and known issues
