resource "aws_security_group" "security_group" {
  name        = var.name
  description = var.name
  vpc_id      = var.vpc_id

  ingress = [
    {
      description      = "Allow scraping of Prometheus metrics"
      from_port        = 8080
      to_port          = 8080
      protocol         = "tcp"
      cidr_blocks      = ["10.0.0.0/16"]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = true
    },
  ]
  egress = [
    {
      description      = "Allow all outbound"
      from_port        = 0
      to_port          = 0
      protocol         = "-1"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = []
      prefix_list_ids  = []
      security_groups  = []
      self             = false
    }
  ]

  tags = var.default_tags
}

resource "aws_cloudwatch_log_group" "batch_job_log_group" {
  name = "/aws/batch/job"
  retention_in_days = 7

  tags = var.default_tags
}

resource "aws_iam_role" "ecs_instance_role" {
  name        = "ecsInstanceRole"
  path        = "/"
  description = "Allows ECS to create and manage AWS resources on your behalf."

  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "sts:AssumeRole",
        "Principal": {
          "Service": "ec2.amazonaws.com"
        },
      }
    ]
  })

  tags = var.default_tags
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecsInstanceProfile"
  role = aws_iam_role.ecs_instance_role.name

  tags = var.default_tags
}

resource "aws_iam_role_policy_attachment" "ecs_service_ec2_role" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}


resource "aws_iam_service_linked_role" "batch" {
    aws_service_name = "batch.amazonaws.com"
}

resource "aws_launch_template" "launch_template" {
  name = var.name
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      delete_on_termination = true
      encrypted = true
      volume_type = "gp3"
      volume_size = 64
    }
  }
  metadata_options {
    http_tokens = "required"
    http_put_response_hop_limit = 2
    instance_metadata_tags = "disabled"
  }
  update_default_version = true
}

resource "aws_batch_compute_environment" "compute_environment" {
  name         = var.name
  type         = "MANAGED"
  service_role = aws_iam_service_linked_role.batch.arn

  compute_resources {
    type = "EC2"
    instance_type = [
      var.instance_type,
    ]

    min_vcpus = 0
    max_vcpus = 256

    security_group_ids = [
      aws_security_group.security_group.id,
    ]

    subnets = var.subnet_ids

    instance_role = aws_iam_instance_profile.ecs_instance_profile.arn
    launch_template {
      launch_template_id = aws_launch_template.launch_template.id
    }

    tags = merge(var.default_tags, {
      Name = var.name
    })
  }

  tags = var.default_tags
}

resource "aws_batch_job_queue" "job_queue" {
  name     = "${var.name}-job-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.compute_environment.arn
  }

  tags = var.default_tags
}

# Mass Ingest - Processor
resource "aws_iam_role" "processor_task_role" {
  name = "${var.name}-processor-task-role"
  path = "/"

  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "sts:AssumeRole",
        "Principal": {
          "Service": "ecs-tasks.amazonaws.com"
        },
      }
    ]
  })

  tags = var.default_tags
}

resource "aws_iam_role_policy_attachment" "processor_ecs_task_execution_policy" {
  role       = aws_iam_role.processor_task_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "processor_secrets_access" {
  name = "secrets-access"
  role = aws_iam_role.processor_task_role.name

  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "ssm:GetParameter",
        "Resource": "arn:aws:ssm:*:*:parameter/mass-ingest/*"
      },
      {
        "Effect": "Allow",
        "Action": "secretsmanager:GetSecretValue",
        "Resource": "arn:aws:secretsmanager:*:*:secret:mass-ingest/*"
      }
    ]
  })
}

# S3 access policy for processor task role (for S3-based artifact storage).
# `mod publish --sync-csv` reads repos.csv and repos-lock.csv from the bucket as well as writing to it.
resource "aws_iam_role_policy" "processor_s3_access" {
  count = var.moderne_s3_bucket_name != "" ? 1 : 0
  name  = "s3-access"
  role  = aws_iam_role.processor_task_role.name

  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "s3:GetObject",
          "s3:PutObject"
        ],
        "Resource": [
          "arn:aws:s3:::${var.moderne_s3_bucket_name}/*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": "s3:ListBucket",
        "Resource": "arn:aws:s3:::${var.moderne_s3_bucket_name}"
      }
    ]
  })
}

resource "aws_batch_job_definition" "processor_job_definition" {
  name = "${var.name}-processor-job-definition"
  type = "container"
  container_properties = jsonencode({
    image = "${var.image_registry}:${var.image_tag}",
    command = ["./publish.sh"],
    resourceRequirements = [
      {
        type = "VCPU",
        value = "4",
      },
      {
        type = "MEMORY",
        value = "15360",
      },
    ],
    executionRoleArn = aws_iam_role.processor_task_role.arn,
    environment = concat(
      [
        {
          name = "MODERNE_TENANT",
          value = var.moderne_tenant,
        },
        {
          name = "PUBLISH_URL",
          value = var.moderne_publish_url,
        },
      ],
      var.moderne_s3_endpoint != "" ? [
        {
          name = "S3_ENDPOINT",
          value = var.moderne_s3_endpoint,
        },
      ] : [],
      var.moderne_s3_region != "" ? [
        {
          name = "S3_REGION",
          value = var.moderne_s3_region,
        },
      ] : [],
      var.parallel > 0 ? [
        {
          name = "PARALLEL",
          value = tostring(var.parallel),
        },
      ] : [],
    ),
    secrets = concat(
      var.moderne_token != "" ? [
        {
          name = "MODERNE_TOKEN",
          valueFrom = var.moderne_token,
        },
      ] : [],

      var.moderne_git_credentials != "" ? [
        {
          name = "GIT_CREDENTIALS",
          valueFrom = var.moderne_git_credentials,
        },
      ]: [],

      var.moderne_ssh_credentials != "" ? [
        {
          name = "GIT_SSH_CREDENTIALS",
          valueFrom = var.moderne_ssh_credentials,
        },
      ] : [],

      var.moderne_publish_token != "" ? [
        {
          name = "PUBLISH_TOKEN",
          valueFrom = var.moderne_publish_token,
        },
      ] : var.moderne_publish_user != "" ? [
        {
          name = "PUBLISH_USER",
          valueFrom = var.moderne_publish_user,
        },
        {
          name = "PUBLISH_PASSWORD",
          valueFrom = var.moderne_publish_password,
        },
      ] : [],
    )
  })
  timeout {
    attempt_duration_seconds = var.job_timeout_seconds
  }

  tags = var.default_tags
}

# Scheduler
resource "aws_iam_role" "scheduler_role" {
  name = "${var.name}-scheduler-role"
  path = "/"

  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Action": "sts:AssumeRole",
        "Principal": {
          "Service": "scheduler.amazonaws.com"
        },
        "Effect": "Allow"
      }
    ]
  })

  tags = var.default_tags
}

resource "aws_iam_role_policy" "scheduler_batch_access" {
  name = "batch-access"
  role = aws_iam_role.scheduler_role.name

  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "batch:SubmitJob",
        "Resource": [
          aws_batch_job_queue.job_queue.arn,
          aws_batch_job_definition.processor_job_definition.arn,
        ]
      },
    ]
  })
}

# Schedules: one job per organization, or a single job over the whole repos.csv.
# (An array job would need at least two children, hence a schedule each.)
locals {
  schedules = length(var.organizations) > 0 ? {
    for org in var.organizations : replace(org, "/[^A-Za-z0-9_-]/", "-") => org
  } : { all = "" }
}

resource "aws_scheduler_schedule" "trigger" {
  for_each = local.schedules

  name = "${var.name}-${each.key}"
  schedule_expression = var.schedule_expression
  flexible_time_window {
    mode = "OFF"
  }
  target {
    arn = "arn:aws:scheduler:::aws-sdk:batch:submitJob"
    role_arn = aws_iam_role.scheduler_role.arn

    input = jsonencode({
      "JobDefinition": aws_batch_job_definition.processor_job_definition.arn,
      "JobName": "${var.name}-${each.key}",
      "JobQueue": aws_batch_job_queue.job_queue.arn,
      "ContainerOverrides": {
        "Environment": each.value == "" ? [] : [
          {
            "Name": "ORGANIZATION",
            "Value": each.value,
          },
        ]
      },
    })
  }
}
