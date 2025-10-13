# 必要なAPIを有効化
resource "google_project_service" "cloud_scheduler__workflows" {
  for_each = toset([
    "workflows.googleapis.com",          # Cloud Workflows API
    "workflowexecutions.googleapis.com", # Cloud Workflows Executions API
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = true
}

# WorkflowsからCloud Run Worker Pools／Servicesを調整するためのサービスアカウント
resource "google_service_account" "trocco_self_hosted_runner__container_scheduler" {
  project      = var.project_id
  account_id   = "shr-test-scheduler"
  display_name = "shr-test-scheduler"
  description  = "Service Account for Workflows to manage Cloud Run Worker Pools"
  depends_on = [
    google_project_service.cloud_scheduler__workflows
  ]
}

# WorkflowsからCloud Run Worker Pools／Servicesを調整するための権限を付与
resource "google_project_iam_member" "trocco_self_hosted_runner__container_scheduler" {
  for_each = toset([
    "roles/workflows.invoker",     # Cloud SchedulerからCloud Workflowsを実行するために必要
    "roles/logging.logWriter",     # Cloud Workflowsのログ出力に必要
    "roles/run.admin",             # Cloud Run Worker Pools／Servicesの更新に必要
    "roles/iam.serviceAccountUser" # Cloud Runの更新時にサービスアカウントを利用するために必要
  ])
  project = var.project_id
  role    = each.value
  member  = google_service_account.trocco_self_hosted_runner__container_scheduler.member
}


/*
- Cloud Run Worker Poolsの場合
*/

# Cloud Run Worker Poolのインスタンス数を調整するためのWorkflow
resource "google_workflows_workflow" "trocco_self_hosted_runner__container_scheduler__worker_pool" {
  name            = "shr-test-scheduler-worker-pool"
  region          = var.default_location
  description     = "Workflow to Manage Cloud Run Worker Pool Instance Count"
  service_account = google_service_account.trocco_self_hosted_runner__container_scheduler.email
  # ref: https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.workerPools
  source_contents     = <<-EOT
    main:
      params: [args]
      steps:
        - log_start:
            call: sys.log
            args:
              severity: "INFO"
              text: "インスタンス調整開始; 対象: ${google_cloud_run_v2_worker_pool.trocco_self_hosted_runner.name}, インスタンス数: $${args.manual_instance_count}"

        - update_instance_count:
            # Beta APIのため、googleapis.run.v2ではなく、http.patchで直接APIを叩くしかない
            # ref: https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.workerPools/patch
            call: http.patch
            args:
              url: "https://run.googleapis.com/v2/${google_cloud_run_v2_worker_pool.trocco_self_hosted_runner.id}"
              auth:
                type: OAuth2
              headers:
                Content-Type: "application/json"
              query:
                updateMask: "scaling.manualInstanceCount"
              body:
                scaling:
                  manualInstanceCount: $${args.manual_instance_count}
            result: updated_result

        - log_success:
            call: sys.log
            args:
              severity: "INFO"
              text: "インスタンス調整完了; 対象: ${google_cloud_run_v2_worker_pool.trocco_self_hosted_runner.name}, インスタンス数: $${args.manual_instance_count}"

        - return_result:
            return:
              status: "success"
              worker_pool: ${google_cloud_run_v2_worker_pool.trocco_self_hosted_runner.name}
              manual_instance_count: $${args.manual_instance_count}
              updated_result: $${updated_result}
  EOT
  deletion_protection = false
}

# Cloud Run　Worker Poolsを起動するためのCloud Scheduler
resource "google_cloud_scheduler_job" "trocco_self_hosted_runner__container_scheduler__worker_pool__start" {
  name      = "shr-test-scheduler-worker-pool-start"
  schedule  = "0 9 * * *" # これは適当な時間
  time_zone = "Asia/Tokyo"
  http_target {
    uri         = "https://workflowexecutions.googleapis.com/v1/projects/${var.project_id}/locations/${var.default_location}/workflows/${google_workflows_workflow.trocco_self_hosted_runner__container_scheduler__worker_pool.name}/executions"
    http_method = "POST"
    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode(jsonencode({
      argument = jsonencode({
        manual_instance_count = 1
      })
    }))
    oauth_token {
      service_account_email = google_service_account.trocco_self_hosted_runner__container_scheduler.email
    }
  }
}

# Cloud Run　Worker Poolsを停止するためのCloud Scheduler
resource "google_cloud_scheduler_job" "trocco_self_hosted_runner__container_scheduler__worker_pool__end" {
  name      = "shr-test-scheduler-worker-pool-end"
  schedule  = "0 19 * * *" # これは適当な時間
  time_zone = "Asia/Tokyo"
  http_target {
    uri         = "https://workflowexecutions.googleapis.com/v1/projects/${var.project_id}/locations/${var.default_location}/workflows/${google_workflows_workflow.trocco_self_hosted_runner__container_scheduler__worker_pool.name}/executions"
    http_method = "POST"
    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode(jsonencode({
      argument = jsonencode({
        manual_instance_count = 0
      })
    }))
    oauth_token {
      service_account_email = google_service_account.trocco_self_hosted_runner__container_scheduler.email
    }
  }
}


/*
- Cloud Run Serviceの場合
*/

# WorkflowsからCloud Run Servicesを調整するための権限を付与
resource "google_project_iam_member" "trocco_self_hosted_runner__container_scheduler__service" {
  for_each = toset([
    "roles/artifactregistry.reader", # Cloud Runの更新時にイメージを取得するために必要
  ])
  project = var.project_id
  role    = each.value
  member  = google_service_account.trocco_self_hosted_runner__container_scheduler.member
}

# Cloud Run Serviceのインスタンス数を調整するためのWorkflow
resource "google_workflows_workflow" "trocco_self_hosted_runner__container_scheduler__service" {
  name            = "shr-test-scheduler-service"
  region          = var.default_location
  description     = "Workflow to Manage Cloud Run Service Instance Count"
  service_account = google_service_account.trocco_self_hosted_runner__container_scheduler.email
  # ref: cloud.google.com/run/docs/reference/rest/v2/projects.locations.services
  source_contents     = <<-EOT
    main:
      params: [args]
      steps:
        - log_start:
            call: sys.log
            args:
              severity: "INFO"
              text: "インスタンス調整開始; 対象: ${google_cloud_run_v2_service.trocco_self_hosted_runner.name}, 最小インスタンス数: $${args.min_instance_count}, 最大インスタンス数: $${args.max_instance_count}"

        - get_current_service:
            call: googleapis.run.v2.projects.locations.services.get
            args:
              name: ${google_cloud_run_v2_service.trocco_self_hosted_runner.id}
            result: current_service

        - update_scaling:
            assign:
              - updated_service: $${current_service}
              - updated_service.template.containers[0].resources.cpuIdle: $${args.min_instance_count == 0 and args.max_instance_count == 1} # これが課金モデルの設定
              - updated_service.template.scaling.minInstanceCount: $${args.min_instance_count}
              - updated_service.template.scaling.maxInstanceCount: $${args.max_instance_count}

        - update_service:
            call: googleapis.run.v2.projects.locations.services.patch
            args:
              name: ${google_cloud_run_v2_service.trocco_self_hosted_runner.id}
              body: $${updated_service}
            result: updated_result

        - log_success:
            call: sys.log
            args:
              severity: "INFO"
              text: '$${"スケーリング完了: " + ${google_cloud_run_v2_service.trocco_self_hosted_runner.name}'

        - return_result:
            return:
              status: "success"
              service: ${google_cloud_run_v2_service.trocco_self_hosted_runner.name}
              min_instance_count: $${args.min_instance_count}
              max_instance_count: $${args.max_instance_count}
              updated_result: $${updated_result}
  EOT
  deletion_protection = false
}

# Cloud Run　Serviceを稼働させるためのCloud Scheduler
resource "google_cloud_scheduler_job" "trocco_self_hosted_runner__container_scheduler__service__start" {
  name      = "shr-test-scheduler-service-start"
  schedule  = "0 9 * * *" # これは適当な時間
  time_zone = "Asia/Tokyo"
  http_target {
    uri         = "https://workflowexecutions.googleapis.com/v1/projects/${var.project_id}/locations/${var.default_location}/workflows/${google_workflows_workflow.trocco_self_hosted_runner__container_scheduler__service.name}/executions"
    http_method = "POST"
    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode(jsonencode({
      argument = jsonencode({
        min_instance_count = 1
        max_instance_count = 1
      })
    }))
    oauth_token {
      service_account_email = google_service_account.trocco_self_hosted_runner__container_scheduler.email
    }
  }
}

# Cloud Run　Serviceを停止するためのCloud Scheduler
# 外部からのリクエストは全く発生しないので、インスタンス数は0になると思われる
resource "google_cloud_scheduler_job" "trocco_self_hosted_runner__container_scheduler__service__end" {
  name      = "shr-test-scheduler-service-end"
  schedule  = "0 19 * * *" # これは適当な時間
  time_zone = "Asia/Tokyo"
  http_target {
    uri         = "https://workflowexecutions.googleapis.com/v1/projects/${var.project_id}/locations/${var.default_location}/workflows/${google_workflows_workflow.trocco_self_hosted_runner__container_scheduler__service.name}/executions"
    http_method = "POST"
    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode(jsonencode({
      argument = jsonencode({
        min_instance_count = 0
        max_instance_count = 1
      })
    }))
    oauth_token {
      service_account_email = google_service_account.trocco_self_hosted_runner__container_scheduler.email
    }
  }
}
