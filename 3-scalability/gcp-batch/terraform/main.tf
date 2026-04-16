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

# Validate that local CSV paths have total_repos set
check "csv_config" {
  assert {
    condition     = can(regex("^https?://", var.ingest_csv_file)) || var.total_repos > 0
    error_message = "When csv_file is a local path (not a URL), total_repos must be set to the number of repositories in the CSV (excluding the header row)."
  }
}

# Enable required APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "batch.googleapis.com",
    "compute.googleapis.com",
    "workflows.googleapis.com",
    "cloudscheduler.googleapis.com",
    "secretmanager.googleapis.com",
    "logging.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# Service account for batch tasks (chunk + processor)
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

# Service account for the scheduler to invoke workflows
resource "google_service_account" "scheduler" {
  account_id   = "${var.name}-scheduler"
  display_name = "Mass Ingest Scheduler"
}

resource "google_project_iam_member" "scheduler_workflows_invoker" {
  project = var.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.scheduler.email}"
}

# Service account for workflows to submit batch jobs
resource "google_service_account" "workflow" {
  account_id   = "${var.name}-workflow"
  display_name = "Mass Ingest Workflow"
}

resource "google_project_iam_member" "workflow_batch_submitter" {
  project = var.project_id
  role    = "roles/batch.jobsEditor"
  member  = "serviceAccount:${google_service_account.workflow.email}"
}

resource "google_project_iam_member" "workflow_sa_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.workflow.email}"
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

# Workflow that creates and runs the batch job with N parallel tasks.
# When csv_file is a URL, the workflow fetches it and counts lines automatically.
# When csv_file is a local path, total_repos must be provided.
# Each task runs task.sh which computes --start/--end from BATCH_TASK_INDEX.

locals {
  # Build workflow steps conditionally based on whether we need to fetch the CSV
  fetch_steps = var.total_repos > 0 ? [] : [
    {
      fetch_csv = {
        call = "http.get"
        args = {
          url = var.ingest_csv_file
        }
        result = "csvResponse"
      }
    }
  ]

  init_assigns = concat(
    var.total_repos > 0 ? [
      { totalRepos = "$${${var.total_repos}}" },
    ] : [
      { csvLines = "$${text.split(csvResponse.body, \"\\n\")}" },
      { lastLine = "$${csvLines[len(csvLines) - 1]}" },
      { totalRepos = "$${if(lastLine == \"\", len(csvLines) - 2, len(csvLines) - 1)}" },
    ],
    [
      { taskCount = "$${int((totalRepos + ${var.ingest_chunk_size} - 1) / ${var.ingest_chunk_size})}" },
      { jobId = "$${\"${var.name}-\" + string(int(sys.now()))}" },
    ]
  )
}

resource "google_workflows_workflow" "mass_ingest" {
  name            = var.name
  region          = var.region
  service_account = google_service_account.workflow.email

  source_contents = yamlencode({
    main = {
      steps = concat(
        local.fetch_steps,
        [
        {
          init = {
            assign = local.init_assigns
          }
        },
        {
          create_batch_job = {
            call = "googleapis.batch.v1.projects.locations.jobs.create"
            args = {
              parent = "projects/${var.project_id}/locations/${var.region}"
              jobId  = "$${jobId}"
              body = {
                taskGroups = [
                  {
                    taskCount   = "$${taskCount}"
                    parallelism = "$${taskCount}"
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
                      maxRunDuration = "3600s"
                      maxRetryCount  = var.max_retry_count
                      environment = {
                        variables = merge(
                          {
                            MODERNE_TENANT = var.moderne_tenant
                            PUBLISH_URL    = var.publish_url
                            CSV_FILE       = var.ingest_csv_file
                            CHUNK_SIZE     = tostring(var.ingest_chunk_size)
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
            result = "createResult"
          }
        },
        {
          return_result = {
            return = "$${createResult}"
          }
        }
      ])
    }
  })

  depends_on = [google_project_service.apis]
}

# Cloud Scheduler — triggers the workflow on a cron schedule
resource "google_cloud_scheduler_job" "trigger" {
  name      = "${var.name}-trigger"
  region    = var.region
  schedule  = var.schedule
  time_zone = "UTC"

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${google_workflows_workflow.mass_ingest.id}/executions"
    body = base64encode(jsonencode({
      argument = jsonencode({})
    }))
    headers = {
      "Content-Type" = "application/json"
    }

    oauth_token {
      service_account_email = google_service_account.scheduler.email
    }
  }

  depends_on = [google_project_service.apis]
}
