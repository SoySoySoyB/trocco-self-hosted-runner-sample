# 必要なAPIを有効化
resource "google_project_service" "api_gateway__cloud_run_functions" {
  for_each = toset([
    "apigateway.googleapis.com", # API Gateway API
    "apikeys.googleapis.com",    # API Keys API
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = true
}

# Cloud Run FunctionsからCloud Run Jobsを起動するためのサービスアカウント
resource "google_service_account" "trocco_self_hosted_runner__container_manager" {
  project      = var.project_id
  account_id   = "shr-test-manager"
  display_name = "shr-test-manager"
  description  = "Service Account for Cloud Run Functions to manage Cloud Run Jobs"
  depends_on = [
    google_project_service.api_gateway__cloud_run_functions
  ]
}

# Cloud Run FunctionsからCloud Run Jobsを起動するための権限を付与
resource "google_project_iam_member" "self_hosted_runner__container_manager" {
  for_each = toset([
    "roles/run.developer", # ジョブ構成をオーバーライドしたCloud Run Jobの実行に必要; ref: https://cloud.google.com/run/docs/execute/jobs
  ])
  project = var.project_id
  role    = each.value
  member  = google_service_account.trocco_self_hosted_runner__container_manager.member
}

# Cloud Functionのソースコードをzip化
data "archive_file" "function_source_archive" {
  type        = "zip"
  source_dir  = "${path.root}/src"
  output_path = "${path.root}/dist/function_source.zip"
}

# GCSバケット名の一意性を担保するためのUUID
resource "random_uuid" "bucket_suffix" {
}

# Cloud Functionのソースコードを格納するためのCloud Storageバケット
resource "google_storage_bucket" "function_source" {
  name          = "shr-test-function-source-${random_uuid.bucket_suffix.result}"
  project       = var.project_id
  location      = var.default_location
  force_destroy = true
}

# Cloud FunctionのソースコードをCloud Storageにアップロード
resource "google_storage_bucket_object" "function_source" {
  name   = "shr-test/function_source.zip"
  bucket = google_storage_bucket.function_source.name
  source = data.archive_file.function_source_archive.output_path
}

# Cloud Run Worker Poolのインスタンス数を調整するCloud Function
resource "google_cloudfunctions2_function" "trocco_self_hosted_runner__container_manager" {
  name        = "shr-test-manager"
  description = "Cloud Function to Manage Cloud Run Jobs"
  project     = var.project_id
  location    = var.default_location
  build_config {
    runtime     = "python311"
    entry_point = "cloud_run_jobs_manager_handler"
    source {
      storage_source {
        bucket = google_storage_bucket.function_source.name
        object = google_storage_bucket_object.function_source.name
      }
    }
  }
  service_config {
    available_memory               = "128Mi"
    min_instance_count             = 0
    timeout_seconds                = 60
    service_account_email          = google_service_account.trocco_self_hosted_runner__container_manager.email
    ingress_settings               = "ALLOW_ALL" # API Gatewayからのアクセスを許可するため
    all_traffic_on_latest_revision = true
    environment_variables = {
      CLOUD_RUN_JOB_ID = google_cloud_run_v2_job.trocco_self_hosted_runner.id
    }
  }
  lifecycle {
    replace_triggered_by = [
      google_storage_bucket_object.function_source
    ]
  }
}

# API GatewayがCloud Functionを呼び出すためのサービスアカウント
resource "google_service_account" "trocco_self_hosted_runner__container_manager_api" {
  account_id   = "shr-test-manager-api"
  display_name = "shr-test-manager-api"
  description  = "Service Account for API Gateway to invoke Cloud Run Jobs Container Manager Function"
}

# Cloud Functionを呼び出すための権限を付与
resource "google_cloudfunctions2_function_iam_member" "invoker" {
  project        = var.project_id
  location       = google_cloudfunctions2_function.trocco_self_hosted_runner__container_manager.location
  cloud_function = google_cloudfunctions2_function.trocco_self_hosted_runner__container_manager.name
  role           = "roles/cloudfunctions.invoker"
  member         = google_service_account.trocco_self_hosted_runner__container_manager_api.member
}

# API GatewayがCloud Run Functionsを呼び出すための権限を付与
resource "google_project_iam_member" "trocco_self_hosted_runner__container_manager_api" {
  for_each = toset([
    "roles/run.invoker", # Cloud Run Functionsの呼び出しに必要
  ])
  project = var.project_id
  role    = each.value
  member  = google_service_account.trocco_self_hosted_runner__container_manager_api.member
}

# API GatewayのAPI
resource "google_api_gateway_api" "trocco_self_hosted_runner__container_manager_api" {
  provider     = google-beta
  project      = var.project_id
  api_id       = "shr-test-manager-api"
  display_name = "shr-test-manager-api"
  depends_on = [
    google_cloudfunctions2_function.trocco_self_hosted_runner__container_manager
  ]
}

# API GatewayのGateway
resource "google_api_gateway_gateway" "trocco_self_hosted_runner__container_manager_api" {
  provider     = google-beta
  project      = var.project_id
  gateway_id   = google_api_gateway_api.trocco_self_hosted_runner__container_manager_api.api_id
  display_name = google_api_gateway_api.trocco_self_hosted_runner__container_manager_api.display_name
  api_config   = google_api_gateway_api_config.trocco_self_hosted_runner__container_manager_api.id
  lifecycle {
    replace_triggered_by = [
      google_api_gateway_api_config.trocco_self_hosted_runner__container_manager_api
    ]
  }
}

# API GatewayのAPI Config
# ref: https://cloud.google.com/api-gateway/docs/passing-data?hl=ja
resource "google_api_gateway_api_config" "trocco_self_hosted_runner__container_manager_api" {
  provider      = google-beta
  project       = var.project_id
  api_config_id = "shr-test-manager-config"
  display_name  = "shr-test-manager-config"
  api           = google_api_gateway_api.trocco_self_hosted_runner__container_manager_api.api_id
  openapi_documents {
    document {
      path = "openapi.yaml"
      contents = base64encode((<<-EOT
        swagger: "2.0"
        info:
          title: "Cloud Run Jobs Container Manager API"
          version: "1.0.0"
        schemes:
          - "https"
        produces:
          - "application/json"

        security:
          - api_key: []
        securityDefinitions:
          api_key:
            type: "apiKey"
            name: "x-api-key"
            in: "header"

        x-google-backend:
          address: "${google_cloudfunctions2_function.trocco_self_hosted_runner__container_manager.service_config[0].uri}"
          jwt_audience: "${google_cloudfunctions2_function.trocco_self_hosted_runner__container_manager.service_config[0].uri}"
          protocol: "h2"
          path_translation: APPEND_PATH_TO_ADDRESS

        paths:
          /run: # ref: https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs/run
            post:
              summary: "Run Cloud Run Job"
              operationId: "RunCloudRunJob"
              parameters:
                - in: body
                  name: body
                  schema:
                    type: object
                    properties:
                      trocco_pipeline_definition_id:
                        type: integer
                        description: "TROCCO Pipeline Definition ID"
                      task_count:
                        type: integer
                        description: "Number of tasks to run"
                        default: 1
                      task_execution_mode:
                        type: string
                        enum:
                          - single_job
                          - multi_job
                        default: single_job
                        description: "Task Execution Mode"
              responses:
                200:
                  description: "Success"
                400:
                  description: "Bad Request"
                401:
                  description: "Unauthorized"
                500:
                  description: "Internal Server Error"
          /executions/list: # ref: https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs.executions/list
            get:
              summary: "List Available Cloud Run Job Executions"
              operationId: "listCloudRunJobExecutions"
              parameters:
                - in: query
                  name: page_size
                  type: integer
                  description: "Page size"
                - in: query
                  name: page_token
                  type: string
                  description: "Page token"
                - in: query
                  name: show_deleted
                  type: boolean
                  description: "Whether to show deleted executions"
                  default: false
              responses:
                200:
                  description: "Success"
                400:
                  description: "Bad Request"
                401:
                  description: "Unauthorized"
                500:
                  description: "Internal Server Error"
          /executions/{execution_id}/tasks/list: # ref: https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs.executions.tasks/list
            get:
              summary: "List Available Cloud Run Job Execution Tasks"
              operationId: "listCloudRunJobExecutionTasks"
              parameters:
                - in: path
                  name: execution_id
                  required: true
                  type: string
                  description: "Cloud Run Job Execution ID"
                - in: query
                  name: page_size
                  type: integer
                  description: "Page size"
                - in: query
                  name: page_token
                  type: string
                  description: "Page token"
                - in: query
                  name: show_deleted
                  type: boolean
                  description: "Whether to show deleted executions"
                  default: false
              responses:
                200:
                  description: "Success"
                400:
                  description: "Bad Request"
                401:
                  description: "Unauthorized"
                500:
                  description: "Internal Server Error"
        EOT
      ))
    }
  }
  gateway_config {
    backend_config {
      google_service_account = google_service_account.trocco_self_hosted_runner__container_manager.email
    }
  }
  lifecycle {
    create_before_destroy = false
  }
}

# API Gatewayのサービスを有効化
# 有効化には多少の時間がかかるので、applyは失敗することがある
resource "google_project_service" "api_gateway" {
  project            = var.project_id
  service            = google_api_gateway_api.trocco_self_hosted_runner__container_manager_api.managed_service
  disable_on_destroy = true
}

# 手元で検証するためにIP制限をかけていないAPIキー
resource "google_apikeys_key" "api_key" {
  name         = "shr-test-api-key-${formatdate("YYYYMMDD-hhmmss", timeadd(timestamp(), "9h"))}"
  display_name = "shr-test-api-key-${formatdate("YYYYMMDD-hhmmss", timeadd(timestamp(), "9h"))}"
  project      = var.project_id
  restrictions {
    api_targets {
      service = google_api_gateway_api.trocco_self_hosted_runner__container_manager_api.managed_service
    }
  }
  lifecycle {
    ignore_changes = [
      name,
      display_name,
    ]
    replace_triggered_by = [
      google_project_service.api_gateway
    ]
  }
}

# Curlで検証するためのコマンドをファイルに出力
resource "local_sensitive_file" "curl_api" {
  filename = "${path.root}/.credential/curl_api.txt"
  content  = <<-EOT
    * APIキーの有効化に多少の時間がかかるので、コマンドがエラーになることがある（エラーメッセージは安定していない）
    curl -X POST "https://${google_api_gateway_gateway.trocco_self_hosted_runner__container_manager_api.default_hostname}/run" -H "x-api-key: ${google_apikeys_key.api_key.key_string}" -H "Content-Type: application/json" -d "{\"task_count\": \"1\", \"trocco_pipeline_definition_id\": \"1\"}"

    curl -X GET "https://${google_api_gateway_gateway.trocco_self_hosted_runner__container_manager_api.default_hostname}/executions/list" -H "x-api-key: ${google_apikeys_key.api_key.key_string}" -H "Content-Type: application/json"

    curl -X GET "https://${google_api_gateway_gateway.trocco_self_hosted_runner__container_manager_api.default_hostname}/executions/{execution_id}/tasks/list" -H "x-api-key: ${google_apikeys_key.api_key.key_string}" -H "Content-Type: application/json"
  EOT
}

# 実運用に使うことを想定した、IPベースでTROCCOからのアクセスのみに限定したAPIキー
resource "google_apikeys_key" "api_key_restricted" {
  name         = "shr-test-api-key-restricted-${formatdate("YYYYMMDD-hhmmss", timeadd(timestamp(), "9h"))}"
  display_name = "shr-test-api-key-restricted-${formatdate("YYYYMMDD-hhmmss", timeadd(timestamp(), "9h"))}"
  project      = var.project_id
  restrictions {
    api_targets {
      service = google_api_gateway_api.trocco_self_hosted_runner__container_manager_api.managed_service
    }
    server_key_restrictions {
      allowed_ips = [ # ref: https://documents.trocco.io/docs/global-ip-list
        "18.182.232.211",
        "13.231.52.164",
        "3.113.216.138",
        "57.181.137.181",
        "54.250.45.100",
      ]
    }
  }
  lifecycle {
    ignore_changes = [
      name,
      display_name,
    ]
    replace_triggered_by = [
      google_project_service.api_gateway
    ]
  }
}

# TROCCOのHTTPタスクでのリクエストをファイルに出力
resource "local_sensitive_file" "trocco_request_config" {
  filename = "${path.root}/.credential/trocco_request_config.txt"
  content  = <<-EOT
    # HTTPリクエストタスク

    url: https://${google_api_gateway_gateway.trocco_self_hosted_runner__container_manager_api.default_hostname}/run
    method: POST
    key: x-api-key
    value: ${google_apikeys_key.api_key_restricted.key_string}
    bodyパラメータ:
      trocco_pipeline_definition_id: integer, optional
      task_count: integer, optional, default=1
      task_execution_mode: string, optional, default=single_job
        - single_job
        - multi_job

    # カスタムコネクタ

    ## List Available Cloud Run Job Executions

    url: https://${google_api_gateway_gateway.trocco_self_hosted_runner__container_manager_api.default_hostname}/executions/list
    method: GET
    key: x-api-key
    value: ${google_apikeys_key.api_key_restricted.key_string}
    queryパラメータ:
      page_size: integer, optional
      page_token: string, optional
      show_deleted: boolean, optional

    ## List Available Cloud Run Job Execution Tasks

    url: https://${google_api_gateway_gateway.trocco_self_hosted_runner__container_manager_api.default_hostname}/executions/{execution_id}/tasks/list
    method: GET
    key: x-api-key
    value: ${google_apikeys_key.api_key_restricted.key_string}
    pathパラメータ:
      execution_id: string, required
    queryパラメータ:
      page_size: integer, optional
      page_token: string, optional
      show_deleted: boolean, optional
  EOT
}
