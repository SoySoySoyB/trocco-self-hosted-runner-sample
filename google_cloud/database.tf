locals {
  google_cloud = {
    mysql = {
      port = 3306
    }
  }
}

# DB接続のためのパスワード
resource "random_password" "db_user" {
  length      = 16
  min_lower   = 2
  min_upper   = 2
  min_numeric = 2
  min_special = 2
}

# 必要なAPIを有効化
resource "google_project_service" "database" {
  for_each = toset([
    "sqladmin.googleapis.com", # Cloud SQL Admin API
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = true
}

# MySQLにアクセスするためのIPアドレス
# ref: https://cloud.google.com/sql/docs/mysql/configure-private-services-access?hl=ja
resource "google_compute_global_address" "mysql" {
  name          = "shr-test-mysql"
  address_type  = "INTERNAL"
  purpose       = "VPC_PEERING"
  prefix_length = 16
  network       = google_compute_network.vpc.id
  depends_on = [
    google_compute_subnetwork.subnet,
    google_project_service.database
  ]
}

# VPCとCloud SQLを接続するためのVPCピアリング
# ピアリングするVPC間でIPレンジの重複が許容されないことに注意
resource "google_service_networking_connection" "mysql" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.mysql.name]
  deletion_policy         = "ABANDON"
}

# MySQLインスタンス
resource "google_sql_database_instance" "mysql" {
  name             = "shr-test-mysql"
  database_version = "MYSQL_8_0"
  region           = var.default_location
  settings {
    tier = "db-f1-micro"
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
      ssl_mode        = "ENCRYPTED_ONLY"
    }
  }
  deletion_protection = false
  depends_on = [
    google_service_networking_connection.mysql
  ]
}

# MySQLのデータベース
resource "google_sql_database" "shr_test" {
  name     = "shr_test"
  instance = google_sql_database_instance.mysql.name
}

# MySQLのユーザー
resource "google_sql_user" "shr_test" {
  name     = "shr_test"
  instance = google_sql_database_instance.mysql.name
  host     = "%"
  password = random_password.db_user.result
}

# Cloud RunからCloud SQLにアクセスするためのファイアウォール
resource "google_compute_firewall" "cloud_run_to_cloud_sql" {
  name    = "shr-test-cloud-run-to-cloud-sql"
  network = google_compute_network.vpc.name
  allow {
    protocol = "tcp"
    ports    = ["3306"]
  }
  direction               = "EGRESS"
  target_service_accounts = [google_service_account.trocco_self_hosted_runner.email]
  destination_ranges      = ["${google_compute_global_address.mysql.address}/${google_compute_global_address.mysql.prefix_length}"]
  priority                = 1000
  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# DBに接続するための情報をファイルに出力
resource "local_sensitive_file" "db_connection_config" {
  filename = "${path.root}/.credential/db_connection_config.txt"
  content  = <<-EOT
    hostname  = ${google_sql_database_instance.mysql.private_ip_address}
    port      = ${local.google_cloud.mysql.port}
    user_name = ${google_sql_user.shr_test.name}
    password  = ${google_sql_user.shr_test.password}
  EOT
}
