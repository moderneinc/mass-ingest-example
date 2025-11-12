# Event-Driven Incremental repos.csv Update System

This directory contains scripts for incrementally updating a centralized effective repos.csv file based on events published during mass ingestion.

## Quick Start - Integration with Mass Ingest

### Complete Example Workflow

If you're starting from `1-quickstart`, here's the complete workflow:

> **Note for Podman users**: If you have `docker` aliased to `podman`, add `--pull=never` to all `docker run` commands to use your locally built image instead of trying to pull from Docker Hub.

> **Resource allocation**: To give the container more resources, add:
> - `--memory=8g` - Set memory limit (e.g., 8GB)
> - `--cpus=4` - Set CPU limit (e.g., 4 CPUs)
> - `--memory-swap=16g` - Set swap limit (must be larger than memory)
> - Example: `docker run --rm --pull=never --memory=8g --cpus=4 ...`

```bash
# 1. Build the Docker image (includes event scripts)
cd 1-quickstart
docker build -t mass-ingest:quickstart ..

# 2a. Run mass ingest WITH event publishing to S3
# Note: For Podman users, add --pull=never to use local image
docker run --rm \
  --pull=never \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -e PUBLISH_URL=https://artifactory.example.com/artifactory/moderne-ingest/ \
  -e PUBLISH_USER=admin \
  -e PUBLISH_PASSWORD=password \
  -e EVENT_LOCATION=s3://my-bucket/mass-ingest/events/ \
  -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
  -e AWS_REGION=us-east-1 \
  mass-ingest:quickstart

# 2b. OR for LOCAL TESTING with filesystem (requires volume mount!)
# With resource limits for better performance:
docker run --rm \
  --pull=never \
  --memory=16g \
  --cpus=4 \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -e PUBLISH_URL=https://artifactory.example.com/artifactory/moderne-ingest/ \
  -e PUBLISH_USER=admin \
  -e PUBLISH_PASSWORD=password \
  -e EVENT_LOCATION=/var/moderne/events \
  mass-ingest:quickstart
# Events will be in: $(pwd)/data/events/pending/

# 3a. Process the events (S3 example) - run AFTER mass ingest completes
docker run --rm \
  --pull=never \
  -e EVENT_LOCATION=s3://my-bucket/mass-ingest/events/ \
  -e EFFECTIVE_REPOS_LOCATION=s3://my-bucket/config/effective-repos.csv \
  -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
  -e AWS_REGION=us-east-1 \
  mass-ingest:quickstart \
  ./effective-repos-csv/consume-events.sh

# 3b. OR for LOCAL TESTING with filesystem
docker run --rm \
  --pull=never \
  -v $(pwd)/data:/var/moderne \
  -e EVENT_LOCATION=/var/moderne/events \
  -e EFFECTIVE_REPOS_LOCATION=/var/moderne/effective-repos.csv \
  mass-ingest:quickstart \
  ./effective-repos-csv/consume-events.sh
# Will read events from: $(pwd)/data/events/pending/
# Will update: $(pwd)/data/effective-repos.csv

# 3c. OR with Git repository for effective-repos.csv
docker run --rm \
  --pull=never \
  -v $(pwd)/data:/var/moderne \
  -e EVENT_LOCATION=/var/moderne/events \
  -e EFFECTIVE_REPOS_LOCATION="git@github.com:org/config-repo.git:path/to/effective-repos.csv" \
  -e GIT_CREDENTIALS="https://username:token@github.com" \
  mass-ingest:quickstart \
  ./effective-repos-csv/consume-events.sh
  
# https://github.com/kmccarp/repos-csv-test.git
time docker run --rm \
  --net=host \
  --pull=never \
  -v $(pwd)/data:/var/moderne \
  -e EVENT_LOCATION=/var/moderne/events \
  -e PUBLISH_URL=http://localhost:8082/artifactory/moderne-lst/ \
  -e PUBLISH_USER=admin \
  -e PUBLISH_PASSWORD=Kevin2007 \
  -e EFFECTIVE_REPOS_LOCATION="https://github.com/kmccarp/repos-csv-test/repos-lock.csv" \
  -e GIT_CREDENTIALS="https://kmccarp:$GITHUB_TOKEN@github.com" \
  mass-ingest:quickstart
# Will read events from: $(pwd)/data/events/pending/
# Will update: git@github.com:org/config-repo.git:path/to/effective-repos.csv
# Note: For Git repos, use SSH format (git@...) and configure GIT_CREDENTIALS or SSH keys

# 4. Your effective-repos.csv is now updated with all published repositories!
```

### What Happens Behind the Scenes

1. **Mass ingest runs normally**, processing repos.csv in 10-repo batches
2. **After each batch**, the CLI creates `.moderne/repos-lock.csv` with what was published
3. **If EVENT_LOCATION is set**, that file gets copied to your event storage
4. **Consumer reads all events**, merges them, and updates effective-repos.csv in one operation
5. **Events are archived** so they won't be processed again

### Important: Volume Mounts for Local Testing

When using filesystem storage with Docker, you **MUST** mount volumes:
- **Without volume mount**: Events are written inside container and lost when container stops ❌
- **With volume mount**: Events persist on your host filesystem ✅

```bash
# WRONG - events lost when container stops
docker run --rm -e EVENT_LOCATION=/var/moderne/events ...

# CORRECT - events persist in ./data/events on host
docker run --rm -e EVENT_LOCATION=/var/moderne/events -v $(pwd)/data:/var/moderne ...
```

### Step 1: Configure Mass Ingest to Publish Events

When running mass ingest (e.g., from `1-quickstart`), add the `EVENT_LOCATION` environment variable:

```bash
# Local filesystem (REQUIRES volume mount to persist events!)
docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -e PUBLISH_URL=https://artifactory.example.com/artifactory/moderne-ingest/ \
  -e PUBLISH_USER=admin \
  -e PUBLISH_PASSWORD=password \
  -e EVENT_LOCATION=/var/moderne/events \
  mass-ingest:quickstart
# Events will be in: $(pwd)/data/events/pending/

# AWS with S3
docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -e PUBLISH_URL=https://artifactory.example.com/artifactory/moderne-ingest/ \
  -e PUBLISH_USER=admin \
  -e PUBLISH_PASSWORD=password \
  -e EVENT_LOCATION=s3://my-bucket/mass-ingest/events/ \
  -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID \
  -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY \
  -e AWS_REGION=us-east-1 \
  mass-ingest:quickstart

# With Artifactory for both LSTs and events
docker run --rm \
  -p 8080:8080 \
  -v $(pwd)/data:/var/moderne \
  -e PUBLISH_URL=https://artifactory.example.com/artifactory/moderne-ingest/ \
  -e PUBLISH_USER=admin \
  -e PUBLISH_PASSWORD=password \
  -e EVENT_LOCATION=https://artifactory.example.com/artifactory/generic/mass-ingest/events/ \
  mass-ingest:quickstart
```

That's it! Mass ingest will now automatically publish `repos-lock.csv` files as events after each 10-repository batch.

**Note**: The scripts are already included in the Docker image if you build from this repository. For existing images, you may need to rebuild with `docker build -t moderne-mass-ingest:latest .`

### Step 2: Process Events to Update Effective repos.csv

Run the batch consumer periodically (e.g., hourly) to update your effective repos.csv:

```bash
# Local development
EVENT_LOCATION=/path/to/events \
EFFECTIVE_REPOS_LOCATION=/path/to/effective-repos.csv \
./effective-repos-csv/consume-events.sh

# AWS with S3
EVENT_LOCATION=s3://my-bucket/mass-ingest/events/ \
EFFECTIVE_REPOS_LOCATION=s3://my-bucket/config/effective-repos.csv \
AWS_PROFILE=myprofile \
./effective-repos-csv/consume-events.sh

# With Artifactory
EVENT_LOCATION=https://artifactory.example.com/artifactory/generic/mass-ingest/events/ \
EFFECTIVE_REPOS_LOCATION=https://artifactory.example.com/artifactory/generic/config/effective-repos.csv \
PUBLISH_USER=admin \
PUBLISH_PASSWORD=password \
./effective-repos-csv/consume-events.sh

# With Git repository
EVENT_LOCATION=/path/to/events \
EFFECTIVE_REPOS_LOCATION="git@github.com:org/config.git:path/to/effective-repos.csv" \
GIT_CREDENTIALS="https://username:token@github.com" \
./effective-repos-csv/consume-events.sh
```

### Step 3: Schedule the Consumer (Optional)

#### Using Cron
```bash
# Add to crontab (runs every hour)
0 * * * * cd /path/to/mass-ingest-example && \
  EVENT_LOCATION=s3://my-bucket/events/ \
  EFFECTIVE_REPOS_LOCATION=s3://my-bucket/config/effective-repos.csv \
  ./effective-repos-csv/consume-events.sh >> /var/log/mass-ingest-consumer.log 2>&1
```

#### Using AWS Lambda
Deploy `consume-events.sh` as a Lambda function triggered by EventBridge on a schedule.

#### Using Kubernetes CronJob
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: mass-ingest-consumer
spec:
  schedule: "0 * * * *"  # Every hour
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: consumer
            image: moderne-mass-ingest:latest
            command: ["./effective-repos-csv/consume-events.sh"]
            env:
            - name: EVENT_LOCATION
              value: "s3://my-bucket/events/"
            - name: EFFECTIVE_REPOS_LOCATION
              value: "s3://my-bucket/config/effective-repos.csv"
```

## Common Deployment Patterns

### Pattern 1: Single AWS Batch Job
```bash
# Mass ingest job publishes events to S3
# Same job runs consumer at the end
aws batch submit-job --job-name mass-ingest \
  --job-definition mass-ingest-def \
  --container-overrides '{
    "environment": [
      {"name": "EVENT_LOCATION", "value": "s3://bucket/events/"},
      {"name": "EFFECTIVE_REPOS_LOCATION", "value": "s3://bucket/effective-repos.csv"}
    ],
    "command": ["sh", "-c", "./publish.sh repos.csv && ./effective-repos-csv/consume-events.sh"]
  }'
```

### Pattern 2: Separate Ingest and Consumer
```bash
# Multiple mass ingest workers publish events
# Separate Lambda/cron job processes events hourly
# This allows multiple workers to run in parallel without conflicts
```

### Pattern 3: Continuous Processing
```bash
# Mass ingest runs continuously
# Consumer runs every 30 minutes via cron
# Effective repos.csv always up-to-date within 30 minutes
```

## How It Works

1. **During Mass Ingest**: After processing each 10-repo batch, the `mod publish` command creates a `.moderne/repos-lock.csv` file. If `EVENT_LOCATION` is set, this file is automatically published as an event.

2. **Event Storage**: Events accumulate in the `pending/` directory of your chosen storage (S3, Artifactory, Git, or filesystem).

3. **Batch Processing**: The consumer script:
   - Downloads all pending events
   - Merges them into effective repos.csv (matching on origin+path+branch)
   - Uploads the updated file
   - Archives processed events to `processed/YYYY-MM-DD/`

## Configuration

The system is controlled by environment variables:

### Event Publishing (used by mass ingest)

```bash
# Where to publish repos-lock.csv events
EVENT_LOCATION="s3://bucket/events/"                    # S3
EVENT_LOCATION="https://artifactory.com/generic/events/" # Artifactory
EVENT_LOCATION="git@github.com:org/repo.git:events/"    # Git
EVENT_LOCATION="/shared/events/"                        # Local filesystem
```

### Batch Processing (used by consumer)

```bash
# Where events are stored (same as EVENT_LOCATION)
EVENT_LOCATION="s3://bucket/events/"

# Where the effective repos.csv lives
EFFECTIVE_REPOS_LOCATION="s3://bucket/config/effective-repos.csv"
EFFECTIVE_REPOS_LOCATION="https://artifactory.com/generic/effective-repos.csv"
EFFECTIVE_REPOS_LOCATION="git@github.com:org/config.git:effective-repos.csv"
EFFECTIVE_REPOS_LOCATION="/path/to/effective-repos.csv"
```

### Authentication

The system reuses existing authentication:

- **S3**: AWS CLI credentials (via `aws configure` or IAM roles)
- **Artifactory**: `PUBLISH_USER`/`PUBLISH_PASSWORD` or `PUBLISH_TOKEN`
- **Git**: SSH keys or `GIT_CREDENTIALS`

## Usage

### Publishing Events (Automatic)

When `EVENT_LOCATION` is set, the modified `publish.sh` automatically publishes events after each batch:

```bash
EVENT_LOCATION="s3://my-bucket/events/" ./publish.sh repos.csv
```

Events are published with unique names: `repos-lock-{hostname}-{timestamp}-{pid}.csv`

### Consuming Events (Manual or Scheduled)

Run the batch consumer to process all pending events:

```bash
EVENT_LOCATION="s3://my-bucket/events/" \
EFFECTIVE_REPOS_LOCATION="s3://my-bucket/config/effective-repos.csv" \
./effective-repos-csv/consume-events.sh
```

This will:
1. List all pending events
2. Download them to a temporary directory
3. Download the current effective repos.csv
4. Merge all updates (matching on origin + path + branch)
5. Upload the updated effective repos.csv
6. Archive processed events to `processed/YYYY-MM-DD/`

## Scripts

### Core Scripts

- **publish-event.sh**: Main event publisher that routes to appropriate backend
- **consume-events.sh**: Batch consumer that orchestrates the update process
- **merge-repos-csv.sh**: Core CSV merging logic

### Event Publishers

- **event-publisher-s3.sh**: Publishes to S3
- **event-publisher-artifactory.sh**: Publishes to Artifactory
- **event-publisher-git.sh**: Publishes to Git repository
- **event-publisher-file.sh**: Publishes to local filesystem

### Event Consumers

- **event-consumer-s3.sh**: Lists, downloads, and archives from S3
- **event-consumer-artifactory.sh**: Lists, downloads, and archives from Artifactory
- **event-consumer-git.sh**: Lists, downloads, and archives from Git
- **event-consumer-file.sh**: Lists, downloads, and archives from filesystem

### Storage Adapters

- **s3-adapter.sh**: Downloads/uploads effective repos.csv from/to S3
- **artifactory-adapter.sh**: Downloads/uploads from/to Artifactory
- **git-adapter.sh**: Downloads/uploads from/to Git repository
- **file-adapter.sh**: Downloads/uploads from/to filesystem

## Event Storage Structure

Events are organized in pending/processed directories:

```
events/
├── pending/           # New events waiting to be processed
│   ├── repos-lock-worker1-1699123456-1234.csv
│   └── repos-lock-worker2-1699123457-5678.csv
└── processed/         # Archived after processing
    └── 2024-11-05/
        └── repos-lock-*.csv
```

## CSV Merge Logic

The merge process:
- Matches repositories by `origin` + `path` + `branch`
- Updates `changeset` and `publishUri` columns
- Only updates if both fields are non-null (skips failed builds)
- Preserves all other columns from effective repos.csv
- Most recent event wins in case of conflicts

## Testing

### Complete Local File System Test

This test demonstrates the full workflow with local files, including updates and new entries.

#### 1. Setup Test Environment

```bash
# Create test directories
TEST_DIR=~/.moderne/mass-ingest-events
mkdir -p $TEST_DIR/events $TEST_DIR/config

# Create initial effective repos.csv with existing data
cat > $TEST_DIR/config/effective-repos.csv << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,org/existing-repo,main,https://github.com/org/existing-repo,oldHash123,https://artifactory.com/lst/old-existing.jar
github.com,org/another-repo,main,https://github.com/org/another-repo,anotherHash456,https://artifactory.com/lst/another.jar
EOF

echo "Initial effective repos.csv:"
cat $TEST_DIR/config/effective-repos.csv
```

#### 2. Create and Publish First Event

```bash
# Create first repos-lock.csv event (updates existing + adds new)
cat > $TEST_DIR/repos-lock-1.csv << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,org/existing-repo,main,https://github.com/org/existing-repo,newHash789,https://artifactory.com/lst/new-existing.jar
github.com,org/new-repo,main,https://github.com/org/new-repo,brandNewHash,https://artifactory.com/lst/new-repo.jar
EOF

# Publish the event
./effective-repos-csv/publish-event.sh $TEST_DIR/repos-lock-1.csv $TEST_DIR/events

# Verify event was published
echo "Published events:"
ls -la $TEST_DIR/events/pending/
```

#### 3. Create and Publish Second Event

```bash
# Create second repos-lock.csv event (another update)
cat > $TEST_DIR/repos-lock-2.csv << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,org/another-repo,main,https://github.com/org/another-repo,updatedHash999,https://artifactory.com/lst/updated-another.jar
github.com,org/third-repo,main,https://github.com/org/third-repo,thirdHash111,https://artifactory.com/lst/third.jar
EOF

# Publish the second event
./effective-repos-csv/publish-event.sh $TEST_DIR/repos-lock-2.csv $TEST_DIR/events

# Show all pending events
echo "All pending events:"
ls -la $TEST_DIR/events/pending/
```

#### 4. Run Batch Consumer

```bash
# Process all pending events
EVENT_LOCATION="$TEST_DIR/events" \
EFFECTIVE_REPOS_LOCATION="$TEST_DIR/config/effective-repos.csv" \
./effective-repos-csv/consume-events.sh
```

#### 5. Verify Results

```bash
# Check updated effective repos.csv
echo "Updated effective repos.csv:"
cat $TEST_DIR/config/effective-repos.csv

# Expected results:
# - existing-repo: changeset updated from oldHash123 to newHash789
# - another-repo: changeset updated from anotherHash456 to updatedHash999
# - new-repo: added as new entry
# - third-repo: added as new entry

# Verify events were archived
echo "Archived events:"
ls -la $TEST_DIR/events/processed/$(date +%Y-%m-%d)/

# Verify pending is empty
echo "Pending directory (should be empty):"
ls -la $TEST_DIR/events/pending/
```

#### 6. Cleanup

```bash
# Remove test data
rm -rf $TEST_DIR
```

### Testing with S3

```bash
# Prerequisites: AWS CLI configured with credentials

# Set test bucket and paths
S3_BUCKET="your-test-bucket"
S3_EVENTS="s3://$S3_BUCKET/mass-ingest/events"
S3_CONFIG="s3://$S3_BUCKET/mass-ingest/config/effective-repos.csv"

# Upload initial effective repos.csv
cat > /tmp/initial-repos.csv << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,test/repo1,main,https://github.com/test/repo1,hash1,https://artifactory.com/lst/repo1.jar
EOF
aws s3 cp /tmp/initial-repos.csv $S3_CONFIG

# Create and publish test event
cat > /tmp/test-repos-lock.csv << 'EOF'
origin,path,branch,cloneUrl,changeset,publishUri
github.com,test/repo1,main,https://github.com/test/repo1,hash2-updated,https://artifactory.com/lst/repo1-new.jar
github.com,test/repo2,main,https://github.com/test/repo2,hash3-new,https://artifactory.com/lst/repo2.jar
EOF

./effective-repos-csv/publish-event.sh /tmp/test-repos-lock.csv $S3_EVENTS

# Run consumer
EVENT_LOCATION="$S3_EVENTS" \
EFFECTIVE_REPOS_LOCATION="$S3_CONFIG" \
./effective-repos-csv/consume-events.sh

# Verify results
aws s3 cp $S3_CONFIG - | cat
```

### Testing with Docker

```bash
# Build image with event support
docker build -t mass-ingest-events-test .

# Run with local file system events
docker run -it --rm \
  -v ~/.moderne/mass-ingest-events:/events \
  -e EVENT_LOCATION=/events \
  -e EFFECTIVE_REPOS_LOCATION=/events/config/effective-repos.csv \
  -e PUBLISH_URL=https://artifactory.example.com \
  -e PUBLISH_USER=user \
  -e PUBLISH_PASSWORD=pass \
  mass-ingest-events-test \
  ./publish.sh /path/to/repos.csv
```

### Testing Error Scenarios

#### Missing repos-lock.csv

```bash
# Test with missing files
echo "Testing missing repos-lock.csv handling..."
./effective-repos-csv/publish-event.sh /nonexistent/file.csv /tmp/events
# Should show error message
```

#### Invalid Event Location

```bash
# Test with invalid location format
EVENT_LOCATION="invalid://location" \
./effective-repos-csv/publish-event.sh test.csv invalid://location
# Should show error about unknown format
```

#### No Pending Events

```bash
# Test consumer with no events
EVENT_LOCATION="$TEST_DIR/empty-events" \
EFFECTIVE_REPOS_LOCATION="$TEST_DIR/config/effective-repos.csv" \
./effective-repos-csv/consume-events.sh
# Should report "No pending events found"
```

### Debugging Tips

1. **Enable verbose mode**: Add `set -x` to scripts for debugging
2. **Check file contents**: Use `head -20` to inspect CSV files
3. **Verify paths**: Use `ls -la` to confirm files exist where expected
4. **Test authentication**: Run storage-specific commands directly
5. **Check logs**: Look for error messages in script output

## Scheduling

### Cron Job
```bash
# Run every 30 minutes
*/30 * * * * cd /path/to/mass-ingest && EVENT_LOCATION=... EFFECTIVE_REPOS_LOCATION=... ./effective-repos-csv/consume-events.sh
```

### AWS Lambda
Use EventBridge to trigger Lambda function that runs the consumer

### GitHub Actions
```yaml
on:
  schedule:
    - cron: '0 * * * *'  # Every hour
  workflow_dispatch:      # Manual trigger

jobs:
  update-effective-repos:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - run: |
          EVENT_LOCATION="${{ secrets.EVENT_LOCATION }}" \
          EFFECTIVE_REPOS_LOCATION="${{ secrets.EFFECTIVE_REPOS_LOCATION }}" \
          ./effective-repos-csv/consume-events.sh
```

## Troubleshooting

### No events found
- Check `EVENT_LOCATION` is correct
- Verify events are being published to `pending/` directory
- Check authentication/permissions

### Merge produces no changes
- Verify repos-lock.csv contains `changeset` and `publishUri` columns
- Check that these columns have non-null values
- Ensure origin/path/branch match between files

### Authentication errors
- S3: Run `aws sts get-caller-identity` to test credentials
- Artifactory: Verify `PUBLISH_USER`/`PUBLISH_PASSWORD` or `PUBLISH_TOKEN`
- Git: Test with `git clone` using the repository URL

## Performance

For 100,000 repositories in batches of 10:
- 10,000 event files generated (~10-20 MB total)
- Processing time: ~1-2 minutes for batch consumer
- Network transfer: Depends on storage backend

## Future Enhancements

- Event deduplication
- Incremental processing (only new events since last run)
- Webhook notifications on completion
- Metrics and monitoring integration
- Retry logic for failed events
