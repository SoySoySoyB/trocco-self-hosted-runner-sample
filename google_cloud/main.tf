terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.3.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "7.5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.5.3"
    }
  }
}

provider "google" {
  project               = var.project_id
  billing_project       = var.project_id
  user_project_override = true
  region                = var.default_location
  default_labels = {
    tested_by = var.tested_by
  }
}

provider "google-beta" {
  project               = var.project_id
  billing_project       = var.project_id
  user_project_override = true
  region                = var.default_location
  default_labels = {
    test_by = var.tested_by
  }
}

variable "default_location" {
  type        = string
  description = "デフォルトのロケーション"
}

variable "project_id" {
  type        = string
  description = "Google CloudのProject ID"
}

variable "tested_by" {
  type        = string
  description = "検証担当者"
}

variable "trocco_registration_token" {
  type        = string
  description = "TROCCO Self-Hosted-RunnerのRegistration Token"
  sensitive   = true
}

variable "trocco_shr_image_path" {
  type        = string
  description = "TROCCO Self-Hosted-RunnerのコンテナイメージPath"
}

# 必要なAPIを有効化
# Service Usage APIを事前に有効化しておく必要がある; https://console.developers.google.com/apis/api/serviceusage.googleapis.com/overview
resource "google_project_service" "main" {
  for_each = toset([
    "compute.googleapis.com",           # Compute Engine API
    "servicenetworking.googleapis.com", # Service Networking API
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = true
}

# VPC
resource "google_compute_network" "vpc" {
  name                            = "shr-test"
  auto_create_subnetworks         = false
  delete_default_routes_on_create = true
  depends_on = [
    google_project_service.main
  ]
}

# サブネット
# ref: https://cloud.google.com/vpc/docs/configure-private-service-connect-apis?hl=ja
resource "google_compute_subnetwork" "subnet" {
  name                     = "shr-test"
  region                   = var.default_location
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.0.0.0/16"
  private_ip_google_access = true # これを設定するとGoogle CloudのプライベートネットワークでBigQueryにアクセスできる; 厳密にはBigQuery以外へのアクセスも可能になるので注意
}

# Internet Gatewayのためののルート
resource "google_compute_route" "internet" {
  name             = "shr-test-internet"
  network          = google_compute_network.vpc.id
  dest_range       = "0.0.0.0/0"
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

# インターネットへのアクセスをNAT経由にルーティング
resource "google_compute_router" "router" {
  name    = "shr-test"
  network = google_compute_network.vpc.id
  region  = var.default_location
}

# インターネットへのアクセスのためのNAT
resource "google_compute_router_nat" "nat" {
  name                               = "shr-test"
  router                             = google_compute_router.router.name
  region                             = var.default_location
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  log_config {
    enable = true
    filter = "ALL"
  }
}

# デフォルトですべてのアウトバウンドトラフィックを拒否するファイアウォール
resource "google_compute_firewall" "deny_all_egress" {
  name    = "shr-test-deny-all-egress"
  network = google_compute_network.vpc.name
  deny {
    protocol = "all"
  }
  direction          = "EGRESS"
  destination_ranges = ["0.0.0.0/0"]
  priority           = 65534 # デフォルトルールより高優先度
  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Cloud Runからインターネットにアクセスするためのファイアウォール
resource "google_compute_firewall" "cloud_run_egress" {
  name    = "shr-test-cloud-run-egress"
  network = google_compute_network.vpc.name
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }
  direction               = "EGRESS"
  target_service_accounts = [google_service_account.trocco_self_hosted_runner.email]
  destination_ranges      = ["0.0.0.0/0"]
  priority                = 1000
  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Cloud Runが利用するサービスアカウント
resource "google_service_account" "trocco_self_hosted_runner" {
  project      = var.project_id
  account_id   = "shr-test"
  display_name = "TROCCO Self-Hosted Runner"
}

# Self-Hosted RunnerのRegistration TokenをSecret Managerに格納するためのシークレット
resource "google_secret_manager_secret" "trocco_registration_token" {
  project   = var.project_id
  secret_id = "trocco_registration_token"
  replication {
    auto {}
  }
}

# Self-Hosted RunnerのRegistration TokenをSecret Managerに登録
resource "google_secret_manager_secret_version" "trocco_registration_token" {
  secret      = google_secret_manager_secret.trocco_registration_token.id
  secret_data = var.trocco_registration_token
}

# Cloud RunがSecret Managerのシークレットを参照できるようにする権限を付与
resource "google_secret_manager_secret_iam_member" "trocco_registration_token" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.trocco_registration_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.trocco_self_hosted_runner.member
}

# TROCCOのSelf-Hosted Runner用のDockerイメージを格納するリポジトリ
resource "google_artifact_registry_repository" "trocco_self_hosted_runner" {
  repository_id = "shr-test"
  description   = "TROCCOのSelf-Hosted Runner用のDockerイメージを格納するリポジトリ"
  project       = var.project_id
  location      = var.default_location
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"
  remote_repository_config {
    common_repository {
      uri = "https://public.ecr.aws"
    }
  }
}

# Cloud RunがArtifact Registryのイメージをpullできるようにする権限を付与
resource "google_project_iam_member" "trocco__artifact_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = google_service_account.trocco_self_hosted_runner.member
}

# Artifact Registryから最新のDockerイメージを取得
# digestベースでの指定になるため、こちらからの参照に切り替えると最新バージョンが公開後のApplyでイメージが更新できると思われる（未検証）
# data "google_artifact_registry_docker_image" "trocco_self_hosted_runner" {
#   project       = var.project_id
#   location      = var.default_location
#   repository_id = google_artifact_registry_repository.trocco_self_hosted_runner.repository_id
#   image_name    = "${var.trocco_shr_image_path}"
# }


/*
- Cloud Run Worker Poolsの設定
- 定常起動しておくにはこの種別が最適だが、2025/10/13現在でGAのステータスではない
*/

# TROCCOのSelf-Hosted RunnerをCloud Run Worker Poolsにデプロイ
resource "google_cloud_run_v2_worker_pool" "trocco_self_hosted_runner" {
  name     = "shr-test-worker-pool"
  project  = var.project_id
  location = var.default_location
  scaling {
    manual_instance_count = 0
  }
  template {
    containers {
      # この設定で自動的にImageはPullされるので、手動の操作は不要
      image = "${google_artifact_registry_repository.trocco_self_hosted_runner.location}-docker.pkg.dev/${google_artifact_registry_repository.trocco_self_hosted_runner.project}/${google_artifact_registry_repository.trocco_self_hosted_runner.name}/${var.trocco_shr_image_path}:latest"
      # image = data.google_artifact_registry_docker_image.trocco_self_hosted_runner.self_link
      name = "trocco-self-hosted-runner"
      resources {
        limits = {
          "memory" = "2Gi"
          "cpu"    = "2000m"
        }
      }
      env {
        name  = "TROCCO_PREVIEW_SEND"
        value = "true"
      }
      env {
        name = "TROCCO_REGISTRATION_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.trocco_registration_token.secret_id
            version = "latest"
          }
        }
      }
    }
    vpc_access {
      egress = "ALL_TRAFFIC"
      # ref: https://cloud.google.com/run/docs/configuring/vpc-direct-vpc?hl=ja
      network_interfaces {
        network    = google_compute_network.vpc.name
        subnetwork = google_compute_subnetwork.subnet.name
        tags       = ["trocco-self-hosted-runner-egress"]
      }
    }
    service_account = google_service_account.trocco_self_hosted_runner.email
  }
  # GA Statusではない
  # ref: https://cloud.google.com/run/docs/deploy-worker-pools?hl=ja
  # ref: https://cloud.google.com/run/docs/troubleshooting#launch-stage-validation
  launch_stage = "BETA"
  timeouts {
    create = "30m"
  }
  deletion_protection = false
  lifecycle {
    create_before_destroy = false
  }
  depends_on = [
    google_secret_manager_secret_iam_member.trocco_registration_token
  ]
}


/*
- Cloud Run Worker Servicesの設定
- Worker Poolsの利用を許容できない場合はこちらだが、ヘルスチェックのためのポート開放が必須になる
*/

# TROCCOのSelf-Hosted RunnerをCloud Run Serviceにデプロイ
resource "google_cloud_run_v2_service" "trocco_self_hosted_runner" {
  name     = "shr-test-service"
  project  = var.project_id
  location = var.default_location
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"
  template {
    containers {
      # この設定で自動的にImageはPullされるので、手動の操作は不要
      image = "${google_artifact_registry_repository.trocco_self_hosted_runner.location}-docker.pkg.dev/${google_artifact_registry_repository.trocco_self_hosted_runner.project}/${google_artifact_registry_repository.trocco_self_hosted_runner.name}/${var.trocco_shr_image_path}:latest"
      name  = "trocco-self-hosted-runner"
      resources {
        limits = {
          "memory" = "2Gi"
          "cpu"    = "2000m"
        }
        # Runnerにはインバウンドリクエストはないため、インスタンスベースの課金モデルが必須
        cpu_idle          = false
        startup_cpu_boost = false
      }
      env {
        name  = "TROCCO_PREVIEW_SEND"
        value = "true"
      }
      # startup probeの設定が必須なので、そのヘルスチェックのためのポートの指定
      env {
        name  = "HEALTH_CHECK_PORT"
        value = "8080"
      }
      env {
        name = "TROCCO_REGISTRATION_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.trocco_registration_token.secret_id
            version = "latest"
          }
        }
      }
    }
    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }
    vpc_access {
      egress = "ALL_TRAFFIC"
      # ref: https://cloud.google.com/run/docs/configuring/vpc-direct-vpc?hl=ja
      network_interfaces {
        network    = google_compute_network.vpc.name
        subnetwork = google_compute_subnetwork.subnet.name
        tags       = ["trocco-self-hosted-runner-egress"]
      }
    }
    service_account = google_service_account.trocco_self_hosted_runner.email
  }
  traffic {
    percent = 100
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
  }
  timeouts {
    create = "30m"
  }
  deletion_protection = false
  lifecycle {
    create_before_destroy = false
  }
  depends_on = [
    google_secret_manager_secret_iam_member.trocco_registration_token
  ]
}


/*
- Cloud Run Worker Jobsの設定
- イベントドリブンの方式を取る場合はこちら
- 2025/10/13現在で近日リリース予定の転送ジョブの実行後に自動停止する機能が必要になる
*/

# TROCCOのSelf-Hosted RunnerをCloud Run Jobsにデプロイ
resource "google_cloud_run_v2_job" "trocco_self_hosted_runner" {
  name     = "shr-test-job"
  project  = var.project_id
  location = var.default_location
  template {
    template {
      containers {
        # この設定で自動的にImageはPullされるので、手動の操作は不要
        image = "${google_artifact_registry_repository.trocco_self_hosted_runner.location}-docker.pkg.dev/${google_artifact_registry_repository.trocco_self_hosted_runner.project}/${google_artifact_registry_repository.trocco_self_hosted_runner.name}/${var.trocco_shr_image_path}:latest"
        name  = "trocco-self-hosted-runner"
        resources {
          limits = {
            "memory" = "2Gi"
            "cpu"    = "2000m"
          }
        }
        env {
          name  = "TROCCO_PREVIEW_SEND"
          value = "true"
        }
        env { # JOB実行後にコンテナを自動停止するための設定
          name  = "TROCCO_ONESHOT"
          value = "true"
        }
        env {
          name = "TROCCO_REGISTRATION_TOKEN"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.trocco_registration_token.secret_id
              version = "latest"
            }
          }
        }
      }
      max_retries = 0
      timeout     = "600s"
      vpc_access {
        egress = "ALL_TRAFFIC"
        # ref: https://cloud.google.com/run/docs/configuring/vpc-direct-vpc?hl=ja
        network_interfaces {
          network    = google_compute_network.vpc.name
          subnetwork = google_compute_subnetwork.subnet.name
          tags       = ["trocco-self-hosted-runner-egress"]
        }
      }
      service_account = google_service_account.trocco_self_hosted_runner.email
    }
  }
  timeouts {
    create = "30m"
  }
  deletion_protection = false
  lifecycle {
    create_before_destroy = false
  }
  depends_on = [
    google_secret_manager_secret_iam_member.trocco_registration_token
  ]
}
