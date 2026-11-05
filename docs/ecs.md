# Running on Amazon ECS

[`ecs/mass-ingest.yaml`](../ecs/mass-ingest.yaml) is a CloudFormation template that runs mass ingest on [AWS Fargate](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html), so there are no instances to manage. ECS has no equivalent of a Kubernetes indexed Job, so a [Step Functions](https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html) state machine plays that part. It starts one task for each shard from 1 to `shards`, and each task runs:

```
mod publish /var/moderne/ws --sync-csv --shard i/shards
```

`concurrency` caps how many of those tasks run at the same time. When one finishes, the state machine starts the next shard, until every shard has run.

## Deploying the stack

Push the image to a registry the tasks can pull from, such as Amazon ECR, and put `repos.csv` at the root of your S3 bucket.

The template reads your secrets from Secrets Manager. If you're a SaaS customer, store an access token. If you're a DX customer, store your license key instead. Nothing in a DX run contacts Moderne.

```bash
# Moderne SaaS
aws secretsmanager create-secret --name mass-ingest/moderne-token --secret-string <token>

# Moderne DX
aws secretsmanager create-secret --name mass-ingest/license-key --secret-string <license key>
```

If any of your repositories are private, store your `.git-credentials` file too. ECS can't mount a secret as a file, so the task writes it to `/home/moderne/.git-credentials` when it starts:

```bash
aws secretsmanager create-secret --name mass-ingest/git-credentials \
  --secret-string file://.git-credentials
```

Each of these commands prints the secret's ARN, which is what you pass to the template. They're all optional. If you're just trying mass ingest out on public repositories, you can leave them out.

```bash
aws cloudformation deploy --stack-name mass-ingest --template-file ecs/mass-ingest.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    Image=<account>.dkr.ecr.<region>.amazonaws.com/mass-ingest \
    VpcId=<vpc> Subnets=<subnet>,<subnet> \
    StoreBucket=your-bucket \
    TenantHost=https://<tenant>.moderne.io TenantTokenSecretArn=<arn> \
    GitCredentialsSecretArn=<arn>
```

If the account has never used ECS, the first deploy can fail with `Unable to assume the service linked role`, because ECS is still creating that role. Delete the rolled-back stack with `aws cloudformation delete-stack --stack-name mass-ingest` and deploy again.

A DX customer replaces the two tenant parameters with `LicenseKeySecretArn=<arn>`. The subnets need a route to your SCM, your artifact store and the image registry, plus wherever the image downloads the Moderne CLI from when it starts. For a public subnet, which has no NAT gateway to go through, add `AssignPublicIp=ENABLED`.

To change a setting later, such as pinning the CLI with `MODERNE_WRAPPER_VERSION`, add it to the container's `Environment` in the template and deploy again.

## Checking the configuration

Run `mod doctor` as a one-off task. The subnets are the ones you gave the template, and the security group is in the stack's outputs:

```bash
aws ecs run-task --cluster mass-ingest --task-definition mass-ingest \
  --capacity-provider-strategy capacityProvider=FARGATE \
  --network-configuration 'awsvpcConfiguration={subnets=[<subnet>],securityGroups=[<security group>],assignPublicIp=DISABLED}' \
  --overrides '{"containerOverrides":[{"name":"mass-ingest","command":["mod","doctor","/var/moderne/ws","--sync-csv"]}]}'

aws logs tail /ecs/mass-ingest --follow
```

## Starting a run

Start the state machine, whose ARN is in the stack's outputs:

```bash
aws stepfunctions start-execution --state-machine-arn <arn> \
  --name ingest-$(date -u +%Y%m%d-%H%M) \
  --input '{"shards": 32, "concurrency": 8}'
```

If you only want to ingest a single organization from `repos.csv`, add `--organization` and its name to the `Command` in the state machine and deploy again.

To keep your LSTs current, turn on the stack's EventBridge schedule with `ScheduleState=ENABLED`. By default it starts a run at 01:00 UTC every day, using the `Shards` and `Concurrency` parameters. `Schedule` changes the time.

## When things fail

Most failures in a mass ingest are individual repositories that don't build. These don't fail the run. The CLI records the failure in that repository's row of `repos-lock.csv` and moves on. Once it has worked through its shard, it exits successfully.

When a task itself fails, the state machine retries its shard up to three more times, for four attempts in total. The retry skips what the earlier attempt already recorded (following the [rule in the README](../README.md#skipping-unchanged-repositories)), so it mostly repeats the build that was in progress. A task reclaimed by Fargate Spot uses up one of those attempts, because the state machine can't tell it apart from any other failure. A stopping task gets two minutes after `SIGTERM` for the CLI to write the lock.

When ECS can't start a task at all, as when Spot capacity is short, the state machine tries again every five minutes, up to six times. These don't use up the attempts above.

A shard that runs out of attempts doesn't stop the others. The run ends as `Failed` once they're done, and its cause lists the failed shards. Everything the other shards built is already recorded in `repos-lock.csv`, so the next run only has to redo the repositories the failed shard didn't get to.

A run still going after 18 hours is stopped, which puts a bound on the cost of builds that hang. Step Functions stops the run's tasks on a best-effort basis, so if a run times out, check that none are left with `aws ecs list-tasks`.

## Watching a run

```bash
aws stepfunctions describe-execution --execution-arn <arn> --query '{status: status, cause: cause}'
aws ecs list-tasks --cluster mass-ingest
aws logs tail /ecs/mass-ingest --follow
aws ecs execute-command --cluster mass-ingest --task <task> --container mass-ingest --interactive --command bash
```

The task logs are where you'll find out why a build failed. They stay in CloudWatch Logs for 30 days, in a stream named after each task. The `execute-command` line opens a shell in a running task, which is the quickest way in if a build hangs. It needs the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) on your machine, and the shell runs as root.

If you want to know what a past run did, look at the `repos-lock.csv` file instead. [Running on Kubernetes](kubernetes.md#watching-a-run) explains what it records.

## Sizing

Set `concurrency` to the number of tasks you want running at once. Since each task builds one repository at a time, it's also how many builds run in parallel. That's the main thing that drives what a run costs. A run can't go above 40, the most a [Step Functions Inline Map](https://docs.aws.amazon.com/step-functions/latest/dg/state-map-inline.html) runs at once. Your account's [Fargate vCPU quota](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-quotas.html#service-quotas-fargate) also has to cover 4 vCPUs per task.

Set `shards` to the number of pieces you want the repository list split into. A good rule of thumb is about four shards per concurrent task. You can change both numbers between runs, because the lock tracks each repository rather than the shard it ran in.

Each task gets 4 vCPUs, 12 GiB of memory and 200 GiB of ephemeral storage. Keep the container's memory limit in place. The CLI holds each build below it, so a build that runs out of memory fails that one repository instead of the task. The one side effect is that `mod doctor` warns that memory is below 16 GiB. That warning is expected.

[Fargate's storage limit](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fargate-task-storage.html) is 200 GiB, and the image takes its share of that, leaving about 175 GiB. If your largest repository doesn't fit in that, run it on [Kubernetes](kubernetes.md) or [one machine](docker.md) instead. If nothing you build comes close, lower `SizeInGiB` in the template, since storage above the first 20 GiB is billed.

Tasks run on Fargate Spot by default, which is a good fit, because a reclaimed task only costs the progress its shard hadn't yet recorded. Set `CapacityProvider=FARGATE` if you'd rather not have interruptions.

Plan for a full rebuild after every CLI release, since a lock row is only skipped when the same CLI version produced it. [Pinning the CLI version](image.md#the-cli-version) lets you choose when that happens.

## Other artifact stores

The template publishes to S3, and the task role it creates can reach only the bucket you name. To publish elsewhere, edit the container definition in the template using the variables in [Artifact stores](stores.md). Plain values go in `Environment` and credentials go in `Secrets`, where the execution role also needs `secretsmanager:GetSecretValue` on them. For Artifactory:

```yaml
Environment:
  - Name: MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_URL
    Value: https://artifactory.example.com/artifactory/moderne-lsts
Secrets:
  - Name: MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_JFROGAPITOKEN
    ValueFrom: <secret arn>
```
