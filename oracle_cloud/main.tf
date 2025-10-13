terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "7.21.0"
    }
  }
}

provider "oci" {
  user_ocid        = var.auth_config.user
  fingerprint      = var.auth_config.fingerprint
  tenancy_ocid     = var.auth_config.tenancy
  region           = var.auth_config.region
  private_key_path = "./.credential/private_key.pem"
}

variable "auth_config" {
  type        = object({ user = string, fingerprint = string, tenancy = string, region = string })
  description = "Terraform実行時のOCI認証情報"
}

variable "trocco_shr_image_url" {
  type        = string
  description = "TROCCO Self-Hosted-RunnerのコンテナイメージURL"
}

variable "trocco_registration_token" {
  type        = string
  description = "TROCCO Self-Hosted-RunnerのRegistration Token"
  sensitive   = true
}

# コンパートメント
resource "oci_identity_compartment" "shr_test" {
  name           = "shr_test"
  description    = "compartment for TROCCO Self-Hosted-Runner"
  compartment_id = var.auth_config.tenancy
}

# VCN
resource "oci_core_vcn" "shr_test" {
  compartment_id = oci_identity_compartment.shr_test.id
  cidr_blocks    = ["10.0.0.0/16"]
  display_name   = "shr_test"
  dns_label      = "shrtest"
}

# インターネットゲートウェイ
resource "oci_core_internet_gateway" "shr_test" {
  compartment_id = oci_identity_compartment.shr_test.id
  vcn_id         = oci_core_vcn.shr_test.id
  display_name   = "shr_test"
  enabled        = true
}

# インターネットゲートウェイへのルート
resource "oci_core_route_table" "shr_test" {
  compartment_id = oci_identity_compartment.shr_test.id
  vcn_id         = oci_core_vcn.shr_test.id
  display_name   = "shr_test"

  route_rules {
    destination       = "0.0.0.0/0"
    network_entity_id = oci_core_internet_gateway.shr_test.id
  }
}

# セキュリティリスト
resource "oci_core_security_list" "shr_test" {
  compartment_id = oci_identity_compartment.shr_test.id
  vcn_id         = oci_core_vcn.shr_test.id
  display_name   = "shr_test"

  egress_security_rules {
    protocol = "6" # TCP
    tcp_options {
      min = 443
      max = 443
    }
    destination = "0.0.0.0/0"
  }
}

# サブネット
resource "oci_core_subnet" "shr_test" {
  compartment_id    = oci_identity_compartment.shr_test.id
  vcn_id            = oci_core_vcn.shr_test.id
  cidr_block        = "10.0.1.0/24"
  display_name      = "shr_test_public"
  dns_label         = "public"
  route_table_id    = oci_core_route_table.shr_test.id
  security_list_ids = [oci_core_security_list.shr_test.id]
}

# 可用性ドメインの参照
data "oci_identity_availability_domains" "domains" {
  compartment_id = var.auth_config.tenancy
}

# Container Instances
# サービスログでの連携対象に入っていない; ref: https://docs.oracle.com/en-us/iaas/Content/Logging/Reference/service_log_reference.htm
# コンテナを操作するAPIはある; ref: https://docs.oracle.com/en-us/iaas/api/#/en/container-instances/20210415/
resource "oci_container_instances_container_instance" "shr_test" {
  compartment_id      = oci_identity_compartment.shr_test.id
  display_name        = "shr_test"
  availability_domain = data.oci_identity_availability_domains.domains.availability_domains[0].name
  shape               = "CI.Standard.E4.Flex"
  shape_config {
    memory_in_gbs = 2
    ocpus         = 1 # これではvCPU数2; ref: https://docs.oracle.com/ja-jp/iaas/Content/Compute/References/computeshapes.htm
  }
  vnics {
    subnet_id = oci_core_subnet.shr_test.id
  }
  containers {
    display_name = "shr_test"
    image_url    = "${var.trocco_shr_image_url}:latest" # スキームは含めない
    environment_variables = {
      TROCCO_PREVIEW_SEND       = "true"
      TROCCO_REGISTRATION_TOKEN = var.trocco_registration_token
    }
    resource_config {
      memory_limit_in_gbs = 2
      vcpus_limit         = 2
    }
  }
}
