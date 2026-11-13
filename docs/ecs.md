# Running on Amazon ECS

[`ecs/mass-ingest.yaml`](../ecs/mass-ingest.yaml) is a CloudFormation template that runs mass ingest on Amazon ECS. Every night, EventBridge Scheduler starts a Step Functions state machine, which runs one [Fargate](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html) task for each shard of `repos.csv`. The tasks publish LSTs to your S3 bucket.

## Setting it up

1. Push the image to a registry the tasks can pull from, such as Amazon ECR.
2. Put `repos.csv` at the root of your S3 bucket.
3. Store your `.git-credentials` file in Secrets Manager:

   ```bash
   aws secretsmanager create-secret --name mass-ingest/git-credentials \
     --secret-string file://.git-credentials
   ```

4. If you're a SaaS customer, store a Moderne access token too:

   ```bash
   aws secretsmanager create-secret --name mass-ingest/moderne-token --secret-string <token>
   ```

5. Deploy the template, using the secret ARNs from the last two steps. If you're a DX customer, leave out the last line.

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

If your first deploy fails with `Unable to assume the service linked role`, delete the stack and deploy again.

Deploy one stack for each bucket and `repos.csv`, with a different stack name for each.

## Running it

To run every night, deploy again with `ScheduleState=ENABLED`. The `Shards`, `Concurrency` and `Schedule` parameters control the nightly run.

To run now, start the state machine, whose ARN is in the stack's outputs:

```bash
aws stepfunctions start-execution --state-machine-arn <arn> \
  --input '{"shards": 32, "concurrency": 8}'
```

Set `concurrency` to how many builds you want running at once, up to 40. Set `shards` to about four times that.

## Finding out why a build failed

Read the build's `trace.csv`.

- If you're a SaaS customer, Moderne can read it in your tenant.
- If you're a DX customer, read it in the running task, under `/var/moderne/ws/.moderne/build/`, before the task stops. To open a shell in the task, use `aws ecs execute-command --cluster mass-ingest --task <task> --container mass-ingest --interactive --command bash`.

## Changing other settings

To change anything else, such as the task size or the artifact store ([Artifact stores](stores.md) lists the variables), edit the template and deploy again. For example, to ingest only one organization from `repos.csv`, add `--organization` and its name to the `Command` in the state machine.
