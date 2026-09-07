terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Enable required APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "batch.googleapis.com",
    "compute.googleapis.com",
    "cloudscheduler.googleapis.com",
    "secretmanager.googleapis.com",
    "logging.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# Service account for batch tasks
resource "google_service_account" "batch_task" {
  account_id   = "${var.name}-batch-task"
  display_name = "Mass Ingest Batch Task"
}

# Grant batch task SA access to secrets
resource "google_secret_manager_secret_iam_member" "moderne_token" {
  secret_id = var.moderne_token_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_secret_manager_secret_iam_member" "git_credentials" {
  count     = var.git_credentials_secret != "" ? 1 : 0
  secret_id = var.git_credentials_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_secret_manager_secret_iam_member" "ssh_credentials" {
  count     = var.ssh_credentials_secret != "" ? 1 : 0
  secret_id = var.ssh_credentials_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_secret_manager_secret_iam_member" "publish_user" {
  count     = var.publish_user_secret != "" ? 1 : 0
  secret_id = var.publish_user_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_secret_manager_secret_iam_member" "publish_password" {
  count     = var.publish_password_secret != "" ? 1 : 0
  secret_id = var.publish_password_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_secret_manager_secret_iam_member" "publish_token" {
  count     = var.publish_token_secret != "" ? 1 : 0
  secret_id = var.publish_token_secret
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.batch_task.email}"
}

# Grant batch task SA permission to pull container images from Artifact Registry
resource "google_project_iam_member" "batch_task_artifact_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.batch_task.email}"
}

# Grant batch task SA permission to report status and write logs
resource "google_project_iam_member" "batch_task_batch_agent" {
  project = var.project_id
  role    = "roles/batch.agentReporter"
  member  = "serviceAccount:${google_service_account.batch_task.email}"
}

resource "google_project_iam_member" "batch_task_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.batch_task.email}"
}

# Service account for the scheduler to create batch jobs (running as the batch task SA)
resource "google_service_account" "scheduler" {
  account_id   = "${var.name}-scheduler"
  display_name = "Mass Ingest Scheduler"
}

resource "google_project_iam_member" "scheduler_batch_submitter" {
  project = var.project_id
  role    = "roles/batch.jobsEditor"
  member  = "serviceAccount:${google_service_account.scheduler.email}"
}

resource "google_project_iam_member" "scheduler_sa_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.scheduler.email}"
}

# Firewall rule — allow Prometheus metrics scraping on port 8080
resource "google_compute_firewall" "metrics" {
  name    = "${var.name}-metrics"
  network = var.network

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges           = ["10.0.0.0/8"]
  target_service_accounts = [google_service_account.batch_task.email]
}

# One task per organization (task.sh maps BATCH_TASK_INDEX to a name from ORGANIZATIONS),
# or a single task over the whole repos.csv when none are listed.
locals {
  task_count = max(1, length(var.organizations))

  batch_job = {
    taskGroups = [
      {
        taskCount   = local.task_count
        parallelism = local.task_count
        taskSpec = {
          runnables = [
            {
              container = {
                imageUri   = "${var.image_registry}:${var.image_tag}"
                entrypoint = "/bin/bash"
                commands   = ["-c", "./task.sh"]
              }
            }
          ]
          computeResource = {
            cpuMilli  = 4000
            memoryMib = 16384
          }
          maxRunDuration = "${var.max_run_duration_seconds}s"
          maxRetryCount  = var.max_retry_count
          environment = {
            variables = merge(
              {
                MODERNE_TENANT = var.moderne_tenant
                PUBLISH_URL    = var.publish_url
                ORGANIZATIONS  = join(",", var.organizations)
              },
              var.s3_endpoint != "" ? { S3_ENDPOINT = var.s3_endpoint } : {},
              var.s3_region != "" ? { S3_REGION = var.s3_region } : {},
            )
            secretVariables = merge(
              {
                MODERNE_TOKEN = "projects/${var.project_id}/secrets/${var.moderne_token_secret}/versions/latest"
              },
              var.git_credentials_secret != "" ? {
                GIT_CREDENTIALS = "projects/${var.project_id}/secrets/${var.git_credentials_secret}/versions/latest"
              } : {},
              var.ssh_credentials_secret != "" ? {
                GIT_SSH_CREDENTIALS = "projects/${var.project_id}/secrets/${var.ssh_credentials_secret}/versions/latest"
              } : {},
              var.publish_token_secret != "" ? {
                PUBLISH_TOKEN = "projects/${var.project_id}/secrets/${var.publish_token_secret}/versions/latest"
              } : var.publish_user_secret != "" ? {
                PUBLISH_USER     = "projects/${var.project_id}/secrets/${var.publish_user_secret}/versions/latest"
                PUBLISH_PASSWORD = "projects/${var.project_id}/secrets/${var.publish_password_secret}/versions/latest"
              } : {},
            )
          }
        }
      }
    ]
    allocationPolicy = {
      instances = [
        {
          policy = {
            machineType = var.machine_type
            bootDisk = {
              sizeGb = var.boot_disk_size_gb
            }
          }
        }
      ]
      network = {
        networkInterfaces = [
          {
            network    = "projects/${var.project_id}/global/networks/${var.network}"
            subnetwork = "projects/${var.project_id}/regions/${var.region}/subnetworks/${var.subnetwork}"
          }
        ]
      }
      serviceAccount = {
        email = google_service_account.batch_task.email
      }
    }
    logsPolicy = {
      destination = "CLOUD_LOGGING"
    }
    labels = var.labels
  }
}

# Cloud Scheduler — creates the batch job directly on a cron schedule.
# Batch generates the job id when none is given.
resource "google_cloud_scheduler_job" "trigger" {
  name      = "${var.name}-trigger"
  region    = var.region
  schedule  = var.schedule
  time_zone = "UTC"

  http_target {
    http_method = "POST"
    uri         = "https://batch.googleapis.com/v1/projects/${var.project_id}/locations/${var.region}/jobs"
    body        = base64encode(jsonencode(local.batch_job))
    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }

  depends_on = [google_project_service.apis]
}
