# Mass Ingest

This example demonstrates how to use the `mod` CLI to ingest a large number of repositories into a Moderne platform.

A longer version of this documentation is available at:
https://docs.moderne.io/administrator-documentation/moderne-platform/how-to-guides/integrating-private-code

## Creating `repos.csv`

The input for the ingestion process is a CSV file of repositories to ingest, one per line.

If you're using GitHub the `gh` CLI is a convenient way to generate this list of repositories.
```bash
echo "cloneUrl,branch" > repos.csv
gh repo list openrewrite --source --no-archived --limit 1000 --json sshUrl,defaultBranchRef --template "{{range .}}{{.sshUrl}},{{.defaultBranchRef.name}}{{\"\n\"}}{{end}}" >> repos.csv
```

Additional columns can be provided as necessary, but the `cloneUrl` and `branch` columns are required.
For a complete list of columns [look at the `mod git clone csv` documentation](https://docs.moderne.io/user-documentation/moderne-cli/cli-reference#mod-git-clone-csv).

## Building the Docker image

The `Dockerfile` in this directory is a good starting point for building a Docker image that can be used to run the mass ingest.
It takes a number of arguments by default, but you might need to customize the image to fit your organization's needs.

```bash
docker build -t moderne-mass-ingest:latest \
    --build-arg MODERNE_TENANT=<> \
    --build-arg MODERNE_TOKEN=<> \
    --build-arg PUBLISH_URL=<> \
    --build-arg PUBLISH_USER=<> \
    --build-arg PUBLISH_PASSWORD=<> \
    .
```

See [the complete list of configuration options](https://docs.moderne.io/user-documentation/moderne-cli/cli-reference),
including how to set up build tools, proxies, trust stores or skip SSL verification a needed.
