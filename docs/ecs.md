# Running on Amazon ECS

[`ecs/mass-ingest.yaml`](../ecs/mass-ingest.yaml) is a CloudFormation template that sets up everything a nightly mass ingest needs on Amazon ECS. You deploy it once with the parameters below, and it creates:

- **A task definition and an ECS cluster.** Each task runs the Moderne CLI on one shard of `repos.csv`. Tasks run on [AWS Fargate](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html), so there are no instances to manage, and nothing runs between ingests.
- **A [Step Functions](https://docs.aws.amazon.com/step-functions/latest/dg/welcome.html) state machine.** Each run of it, called an execution, starts one task per shard, keeps at most `concurrency` of them going at once, retries shards that fail, and ends as `Succeeded` or `Failed`.
- **An [EventBridge Scheduler](https://docs.aws.amazon.com/scheduler/latest/UserGuide/what-is-scheduler.html) schedule** that starts an execution every night, once you turn it on.
- **IAM roles, a security group and a CloudWatch log group** for the tasks.

```
EventBridge Scheduler ──> Step Functions execution ──> task for shard 1 ──┐
      (nightly)           (shards, concurrency)    ──> task for shard 2 ──┼──> S3 bucket
                                                   ──> task for shard N ──┘
```

Each task runs:

```
mod publish /var/moderne/ws --sync-csv --shard i/shards
```

If you need to keep groups apart, such as lines of business that each have their own bucket and service account, deploy one stack for each under a different stack name. A stack is one ingest, with one bucket, one `repos.csv` and one set of git credentials.

## Before you deploy

1. Push the image to a registry the tasks can pull from, such as Amazon ECR.
2. Put `repos.csv` at the root of your S3 bucket.
3. Pick subnets with a route to your SCM, the bucket, the image registry, and wherever the image downloads the Moderne CLI from when it starts.
4. Store your `.git-credentials` file in Secrets Manager. It has one `https://<user>:<token>@<host>` line for each host your repositories are on. ECS can't mount a secret as a file, so the task writes it to `/home/moderne/.git-credentials` when it starts.

   ```bash
   aws secretsmanager create-secret --name mass-ingest/git-credentials \
     --secret-string file://.git-credentials
   ```

5. If you're a SaaS customer, store an access token too. If you're a DX customer, skip this step, since nothing in a DX run contacts Moderne.

   ```bash
   aws secretsmanager create-secret --name mass-ingest/moderne-token --secret-string <token>
   ```

Keep the ARN each `create-secret` prints. You pass it to the template.

## Deploying the stack

```bash
aws cloudformation deploy --stack-name mass-ingest --template-file ecs/mass-ingest.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    Image=<account>.dkr.ecr.<region>.amazonaws.com/mass-ingest \
    VpcId=<vpc> Subnets=<subnet>,<subnet> \
    StoreBucket=your-bucket \
    GitCredentialsSecretArn=<arn> \
    TenantHost=https://<tenant>.moderne.io TenantTokenSecretArn=<arn>
```

If you're a DX customer, leave out the last line. These are all the parameters:

| Parameter                 | Default             | What it does                                                                         |
|---------------------------|---------------------|--------------------------------------------------------------------------------------|
| `Image`                   | required            | The image from step 1.                                                               |
| `VpcId`                   | required            | The VPC your subnets are in.                                                         |
| `Subnets`                 | required            | The subnets from step 3, separated by commas.                                        |
| `StoreBucket`             | required            | The bucket that holds `repos.csv` and receives the LSTs. Tasks can reach no other.   |
| `GitCredentialsSecretArn` | required            | The ARN of the git credentials secret from step 4.                                   |
| `TenantHost`              | none                | SaaS only. Your tenant's URL.                                                        |
| `TenantTokenSecretArn`    | none                | SaaS only. The ARN of the token secret from step 5.                                  |
| `AssignPublicIp`          | `DISABLED`          | Set `ENABLED` for public subnets, which have no NAT gateway to go through.           |
| `CapacityProvider`        | `FARGATE_SPOT`      | `FARGATE_SPOT` costs less but can reclaim a task. `FARGATE` never interrupts one.    |
| `ScheduleState`           | `DISABLED`          | Set `ENABLED` to turn on the nightly run.                                            |
| `Schedule`                | `cron(0 1 * * ? *)` | When the nightly run starts, in UTC.                                                 |
| `Shards`                  | `32`                | How many shards the nightly run splits `repos.csv` into.                             |
| `Concurrency`             | `8`                 | How many tasks the nightly run keeps going at once, up to 40.                        |

To change a parameter later, deploy again with the new value.

If your first deploy fails with `Unable to assume the service linked role`, delete the rolled-back stack with `aws cloudformation delete-stack --stack-name mass-ingest` and deploy again. This happens on accounts that have never used ECS, because ECS is still creating that role.

## Checking the configuration

Before the first run, run `mod doctor` as a one-off task. Use one of the subnets you gave the template, and the security group from the stack's outputs:

```bash
aws ecs run-task --cluster mass-ingest --task-definition mass-ingest \
  --capacity-provider-strategy capacityProvider=FARGATE \
  --network-configuration 'awsvpcConfiguration={subnets=[<subnet>],securityGroups=[<security group>],assignPublicIp=DISABLED}' \
  --overrides '{"containerOverrides":[{"name":"mass-ingest","command":["mod","doctor","/var/moderne/ws","--sync-csv"]}]}'

aws logs tail /ecs/mass-ingest --follow
```

## Running an ingest

To start a run by hand, start an execution of the state machine, whose ARN is in the stack's outputs. A run you start this way uses its own `shards` and `concurrency` instead of the stack's parameters:

```bash
aws stepfunctions start-execution --state-machine-arn <arn> \
  --name ingest-$(date -u +%Y%m%d-%H%M) \
  --input '{"shards": 32, "concurrency": 8}'
```

To run every night, deploy again with `ScheduleState=ENABLED`. The schedule starts an execution at the `Schedule` time, using the `Shards` and `Concurrency` parameters.

Set `concurrency` to the number of tasks you want running at once. Since each task builds one repository at a time, it's also how many builds run in parallel, which is the main thing that drives what a run costs. It can't go above 40, the most a [Step Functions Inline Map](https://docs.aws.amazon.com/step-functions/latest/dg/state-map-inline.html) runs at once, and your account's [Fargate vCPU quota](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-quotas.html#service-quotas-fargate) has to cover 4 vCPUs per task.

Set `shards` to about four times `concurrency`. It's how many pieces `repos.csv` is split into, and so how many tasks a run starts in total. You can change both numbers between runs, because the lock tracks each repository rather than the shard it ran in.

Plan for a full rebuild after every CLI release, since a lock row is only skipped when the same CLI version produced it. To choose when that happens, [pin the CLI version](image.md#the-cli-version).

## Watching a run

```bash
aws stepfunctions describe-execution --execution-arn <arn> --query '{status: status, cause: cause}'
aws ecs list-tasks --cluster mass-ingest
aws logs tail /ecs/mass-ingest --follow
aws ecs execute-command --cluster mass-ingest --task <task> --container mass-ingest --interactive --command bash
```

To find out why a build failed, read the `trace.csv` files the CLI writes for every command. The task logs only show each repository's progress and the first error of a build that failed. They stay in CloudWatch Logs for 30 days, in a stream named after each task. If you're a SaaS customer, each task sends its traces to your tenant before it stops, where Moderne can read them. If you're a DX customer, read the traces during the run, under `/var/moderne/ws/.moderne/build/`. They stay on the task's disk and are gone with the task.

To get to those traces, or to look at a build that hangs, open a shell in a running task with the `execute-command` line. Install the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) on your machine first. The shell runs as root.

To see what past runs did, look at `repos-lock.csv`. [Running on Kubernetes](kubernetes.md#watching-a-run) explains what it records.

## When things fail

Most failures in a mass ingest are individual repositories that don't build. These don't fail the run. The CLI leaves that repository's row of `repos-lock.csv` as it was and moves on, so a repository that has never built has an empty row.

When a task itself fails, the state machine retries its shard up to three more times, for four attempts in total. The retry skips what the earlier attempt already recorded (following the [rule in the README](../README.md#skipping-unchanged-repositories)), so it mostly repeats the build that was in progress. A task reclaimed by Fargate Spot uses up one of those attempts, because the state machine can't tell it apart from any other failure. A stopping task gets two minutes after `SIGTERM` for the CLI to write the lock.

When ECS can't start a task at all, as when Spot capacity is short, the state machine tries again every five minutes, up to six times. These don't use up the attempts above.

A shard that runs out of attempts doesn't stop the others. The run ends as `Failed` once they're done, and its cause lists the failed shards. Everything the other shards built is already recorded in `repos-lock.csv`, so the next run only has to redo the repositories the failed shard didn't get to.

If a run times out, check that none of its tasks are left with `aws ecs list-tasks`, since Step Functions stops them on a best-effort basis. A run still going after 18 hours is stopped, which puts a bound on the cost of builds that hang.

## Changing the template

To change anything that isn't a parameter, edit the template and deploy again.

### The command

If you only want to ingest a single organization from `repos.csv`, add `--organization` and its name to the `Command` in the state machine's `Publish` state. For the `Payments` organization in the [README's example](../README.md#1-list-your-repositories):

```yaml
Command:
  - mod
  - publish
  - /var/moderne/ws
  - --sync-csv
  - --organization
  - Payments
  - --shard
  - "{% $states.input.shard & '/' & $states.input.shards %}"
```

### Environment variables

To add a setting, such as `MODERNE_WRAPPER_VERSION` to pin the CLI, add it to the container's `Environment` in the task definition.

### Other artifact stores

To publish somewhere other than S3, edit the container definition using the variables in [Artifact stores](stores.md). Put plain values in `Environment` and credentials in `Secrets`, and give the execution role `secretsmanager:GetSecretValue` on those secrets. For Artifactory:

```yaml
Environment:
  - Name: MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_URL
    Value: https://artifactory.example.com/artifactory/moderne-lsts
Secrets:
  - Name: MOD_LSTS_ARTIFACTS_ARTIFACTORY_0_JFROGAPITOKEN
    ValueFrom: <secret arn>
```

### Task size

Each task gets 4 vCPUs, 12 GiB of memory and 200 GiB of ephemeral storage. Keep the container's memory limit in place. The CLI holds each build below it, so a build that runs out of memory fails that one repository instead of the task. Ignore the `mod doctor` warning that memory is below 16 GiB. It's expected.

[Fargate's storage limit](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fargate-task-storage.html) is 200 GiB, and the image takes its share of that, leaving about 175 GiB. If your largest repository doesn't fit in that, run it on [Kubernetes](kubernetes.md) or [one machine](docker.md) instead. If nothing you build comes close, lower `SizeInGiB`, since storage above the first 20 GiB is billed.
