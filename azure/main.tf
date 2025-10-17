terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "4.47.0"
    }
  }
}

provider "azurerm" {
  features {}
  resource_provider_registrations = "none"
  subscription_id                 = var.azure_subscription_id
}

variable "azure_subscription_id" {
  type        = string
  description = "AzureのSubscription ID"
}

variable "default_location" {
  type        = string
  description = "デフォルトのロケーション"
}

variable "trocco_shr_image_url" {
  type        = string
  description = "TROCCO Self-Hosted-RunnerのコンテナイメージURL"
}

variable "trocco_registration_token_container_instances" {
  type        = string
  description = "Container Instances用のTROCCO Self-Hosted-RunnerのRegistration Token"
  sensitive   = true
}

variable "trocco_registration_token_container_apps" {
  type        = string
  description = "Container Apps用のTROCCO Self-Hosted-RunnerのRegistration Token"
  sensitive   = true
}


/*
- 共通の設定
*/

# リソースグループ
resource "azurerm_resource_group" "shr_test" {
  name     = "shr-test"
  location = var.default_location
}

# 仮想ネットワーク
resource "azurerm_virtual_network" "shr_test" {
  name                = "shr-test"
  location            = azurerm_resource_group.shr_test.location
  resource_group_name = azurerm_resource_group.shr_test.name
  address_space       = ["10.0.0.0/16"]
}

# ネットワークセキュリティグループ
resource "azurerm_network_security_group" "shr_test" {
  name                = "shr-test"
  location            = azurerm_resource_group.shr_test.location
  resource_group_name = azurerm_resource_group.shr_test.name

  security_rule {
    name                       = "deny-all-outbound"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-https-outbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Log Analytics ワークスペース
resource "azurerm_log_analytics_workspace" "shr_test" {
  name                = "shr-test"
  location            = azurerm_resource_group.shr_test.location
  resource_group_name = azurerm_resource_group.shr_test.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}


/*
- Container Instanceの設定
*/

# Container Instances用サブネット
resource "azurerm_subnet" "container_instances" {
  name                 = "container-instance-public"
  resource_group_name  = azurerm_resource_group.shr_test.name
  virtual_network_name = azurerm_virtual_network.shr_test.name
  address_prefixes     = ["10.0.0.0/24"]

  delegation { # サブネットをContainer Instancesで専用利用するための設定
    name = "container-instance-delegation"
    service_delegation {
      name = "Microsoft.ContainerInstance/containerGroups"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action"
      ]
    }
  }
}

# Container Instances用サブネットネットワークセキュリティグループの関連付け
resource "azurerm_subnet_network_security_group_association" "container_instance" {
  subnet_id                 = azurerm_subnet.container_instances.id
  network_security_group_id = azurerm_network_security_group.shr_test.id
}

# Container Instances
# ip_address_type = "None"でports未指定でもデプロイ可能だが、サブネットを指定できないのでアウトバウンドネットワークの制御ができないと思われる
resource "azurerm_container_group" "shr_test" {
  name                = "shr-test"
  location            = azurerm_resource_group.shr_test.location
  resource_group_name = azurerm_resource_group.shr_test.name
  os_type             = "Linux"
  restart_policy      = "Always"
  ip_address_type     = "Private" # サブネットを指定しようとするとNoneは指定できない
  subnet_ids          = [azurerm_subnet.container_instances.id]

  container {
    name   = "shr-test"
    image  = "${var.trocco_shr_image_url}:latest"
    cpu    = "2"
    memory = "2"
    ports {           # ip_address_type = "None"ではない場合は、ポートの指定が必須; performing ContainerGroupsCreateOrUpdate: unexpected status 400 (400 Bad Request) with error: MissingIpAddressPorts: The ports in the 'ipAddress' of container group 'shr-test' cannot be empty.
      port     = 8080 # 任意のポート
      protocol = "TCP"
    }
    environment_variables = {
      TROCCO_PREVIEW_SEND = "true"
    }
    secure_environment_variables = {
      TROCCO_REGISTRATION_TOKEN = var.trocco_registration_token_container_instances
    }
  }
  diagnostics {
    log_analytics {
      workspace_id  = azurerm_log_analytics_workspace.shr_test.workspace_id
      workspace_key = azurerm_log_analytics_workspace.shr_test.primary_shared_key
    }
  }

  depends_on = [
    azurerm_subnet_network_security_group_association.container_instance
  ]
}


/*
- Container Appsの設定
*/

# Container Apps用サブネット
resource "azurerm_subnet" "container_apps" {
  name                 = "container-apps-public"
  resource_group_name  = azurerm_resource_group.shr_test.name
  virtual_network_name = azurerm_virtual_network.shr_test.name
  address_prefixes     = ["10.0.2.0/23"] # Container Appsでは/23が必要
}

# Container Apps用サブネットとネットワークセキュリティグループの関連付け
resource "azurerm_subnet_network_security_group_association" "container_apps" {
  subnet_id                 = azurerm_subnet.container_apps.id
  network_security_group_id = azurerm_network_security_group.shr_test.id
}

# Container Apps 用のリソースプロバイダー登録
resource "azurerm_resource_provider_registration" "container_apps" {
  name = "Microsoft.App"
}

# Applyが失敗することがあるので、不整合が発生したときにはImportする
# import {
#   id = "/subscriptions/${var.azure_subscription_id}/providers/Microsoft.App"
#   to = azurerm_resource_provider_registration.container_apps
# }

# Container Apps Environment
resource "azurerm_container_app_environment" "shr_test" {
  name                           = "shr-test"
  location                       = azurerm_resource_group.shr_test.location
  resource_group_name            = azurerm_resource_group.shr_test.name
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.shr_test.id
  infrastructure_subnet_id       = azurerm_subnet.container_apps.id
  internal_load_balancer_enabled = true

  depends_on = [
    azurerm_subnet_network_security_group_association.container_apps,
    azurerm_resource_provider_registration.container_apps
  ]
}

# Container Apps
resource "azurerm_container_app" "shr_test" {
  name                         = "shr-test"
  container_app_environment_id = azurerm_container_app_environment.shr_test.id
  resource_group_name          = azurerm_resource_group.shr_test.name
  revision_mode                = "Single"

  template {
    min_replicas = 1
    max_replicas = 1
    container {
      name   = "shr-test"
      image  = "${var.trocco_shr_image_url}:latest"
      memory = "2Gi" # CPUの2倍の値のみ設定可能; reff: https://learn.microsoft.com/ja-jp/azure/container-apps/containers#allocations
      cpu    = 1
      env {
        name  = "TROCCO_PREVIEW_SEND"
        value = "true"
      }
      env {
        name        = "TROCCO_REGISTRATION_TOKEN"
        secret_name = "trocco-registration-token"
      }
    }
  }
  secret {
    name  = "trocco-registration-token"
    value = var.trocco_registration_token_container_apps
  }
}
