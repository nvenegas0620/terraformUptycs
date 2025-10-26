terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.11"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.48"
    }
  }
}

############################################
# Providers
############################################
provider "azurerm" {
  features {}
  subscription_id = "2944c97d-8d49-4931-a638-3535dde1dfd2"
}

provider "azuread" {}

############################################
# Variables
############################################
variable "location"             { default = "eastus" }
variable "resource_group"       { default = "rg-secure-vms" }
variable "vnet_cidr"            { default = "10.50.0.0/16" }
variable "subnet_cidr"          { default = "10.50.1.0/24" }
variable "firewall_subnet_cidr" { default = "10.50.3.0/26" }
variable "appgw_subnet_cidr"    { default = "10.50.4.0/27" }

variable "vm_admin_username" { default = "azureuser" }

variable "ssh_public_key" {
  description = "Full content of your SSH public key"
  type        = string
}

variable "enable_identity" {
  type    = bool
  default = false
}

variable "enable_aro" {
  type    = bool
  default = false
}

variable "aro_pull_secret_path" {
  type    = string
  default = ""
}

variable "aro_version" {
  type    = string
  default = "4.14.29"
}

############################################
# Resource Group
############################################
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group
  location = var.location
  tags     = { owner = "noel", env = "dev" }
}

############################################
# Delay helper so Azure finishes propagating RG
############################################
resource "null_resource" "wait_for_rg" {
  provisioner "local-exec" {
    # PowerShell sleep ~10 seconds to let ARM replicate RG metadata
    command = "powershell -Command Start-Sleep -Seconds 10"
  }

  depends_on = [
    azurerm_resource_group.rg
  ]
}

############################################
# DDoS Protection Plan
############################################
resource "azurerm_network_ddos_protection_plan" "ddos" {
  name                = "ddos-plan"
  location            = var.location
  resource_group_name = var.resource_group

  depends_on = [
    null_resource.wait_for_rg
  ]
}

############################################
# VNet + Subnets
############################################
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-core"
  location            = var.location
  resource_group_name = var.resource_group
  address_space       = [var.vnet_cidr]

  ddos_protection_plan {
    id     = azurerm_network_ddos_protection_plan.ddos.id
    enable = true
  }

  depends_on = [
    null_resource.wait_for_rg
  ]
}

resource "azurerm_subnet" "subnet_app" {
  name                 = "snet-app"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_cidr]

  depends_on = [
    null_resource.wait_for_rg,
    azurerm_virtual_network.vnet
  ]
}

resource "azurerm_subnet" "firewall_subnet" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.firewall_subnet_cidr]

  depends_on = [
    null_resource.wait_for_rg,
    azurerm_virtual_network.vnet
  ]
}

resource "azurerm_subnet" "appgw_subnet" {
  name                 = "snet-appgw"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.appgw_subnet_cidr]

  depends_on = [
    null_resource.wait_for_rg,
    azurerm_virtual_network.vnet
  ]
}

############################################
# Azure Firewall + egress rules
############################################
resource "azurerm_public_ip" "fw_pip" {
  name                = "pip-fw"
  location            = var.location
  resource_group_name = var.resource_group
  allocation_method   = "Static"
  sku                 = "Standard"

  depends_on = [
    null_resource.wait_for_rg
  ]
}

resource "azurerm_firewall" "fw" {
  name                = "azurefw"
  location            = var.location
  resource_group_name = var.resource_group

  sku_name = "AZFW_VNet"
  sku_tier = "Standard"

  ip_configuration {
    name                 = "fw-ipcfg"
    subnet_id            = azurerm_subnet.firewall_subnet.id
    public_ip_address_id = azurerm_public_ip.fw_pip.id
  }

  threat_intel_mode = "Alert"

  depends_on = [
    null_resource.wait_for_rg,
    azurerm_subnet.firewall_subnet,
    azurerm_public_ip.fw_pip
  ]
}

resource "azurerm_firewall_network_rule_collection" "allow_outbound" {
  name                = "Allow-Outbound-Web"
  azure_firewall_name = azurerm_firewall.fw.name
  resource_group_name = var.resource_group
  priority            = 100
  action              = "Allow"

  rule {
    name                  = "Allow-HTTP-HTTPS"
    protocols             = ["TCP"]
    source_addresses      = ["10.50.0.0/16"]
    destination_addresses = ["0.0.0.0/0"]
    destination_ports     = ["80", "443"]
  }

  depends_on = [
    azurerm_firewall.fw
  ]
}

############################################
# Route table to force egress via Firewall
############################################
resource "azurerm_route_table" "rt_app" {
  name                = "rt-snet-app-egress-fw"
  location            = var.location
  resource_group_name = var.resource_group

  depends_on = [
    null_resource.wait_for_rg
  ]
}

resource "azurerm_route" "default_to_fw" {
  name                   = "default-to-fw"
  resource_group_name    = var.resource_group
  route_table_name       = azurerm_route_table.rt_app.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = azurerm_firewall.fw.ip_configuration[0].private_ip_address

  depends_on = [
    azurerm_firewall.fw,
    azurerm_route_table.rt_app
  ]
}

# NOT managing the association here anymore because it caused "already exists" issues
# If you want Terraform to own it later, we'll import first, then add back.

############################################
# NSG for workload subnet (deny inbound / allow outbound)
############################################
resource "azurerm_network_security_group" "nsg_app" {
  name                = "nsg-app"
  location            = var.location
  resource_group_name = var.resource_group

  security_rule {
    name                       = "deny-all-inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-all-outbound"
    priority                   = 200
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  depends_on = [
    null_resource.wait_for_rg
  ]
}

resource "azurerm_subnet_network_security_group_association" "snet_nsg" {
  subnet_id                 = azurerm_subnet.subnet_app.id
  network_security_group_id = azurerm_network_security_group.nsg_app.id

  depends_on = [
    azurerm_subnet.subnet_app,
    azurerm_network_security_group.nsg_app
  ]
}

############################################
# Application Gateway (WAF_v2)
############################################
resource "azurerm_public_ip" "appgw_pip" {
  name                = "pip-appgw"
  location            = var.location
  resource_group_name = var.resource_group
  allocation_method   = "Static"
  sku                 = "Standard"

  depends_on = [
    null_resource.wait_for_rg
  ]
}

resource "azurerm_application_gateway" "appgw" {
  name                = "appgw-waf"
  resource_group_name = var.resource_group
  location            = var.location

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "appgw-ipcfg"
    subnet_id = azurerm_subnet.appgw_subnet.id
  }

  frontend_ip_configuration {
    name                 = "publicFrontend"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  backend_address_pool {
    name         = "backendPool"
    ip_addresses = [
      azurerm_network_interface.nic_vm1.ip_configuration[0].private_ip_address
    ]
  }

  backend_http_settings {
    name                  = "bhs-http"
    port                  = 80
    protocol              = "Http"
    cookie_based_affinity = "Disabled"
    request_timeout       = 30
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "publicFrontend"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "rule1"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "backendPool"
    backend_http_settings_name = "bhs-http"
    priority                   = 100
  }

  waf_configuration {
    enabled          = true
    firewall_mode    = "Detection"
    rule_set_type    = "OWASP"
    rule_set_version = "3.2"
  }

  depends_on = [
    null_resource.wait_for_rg,
    azurerm_network_interface.nic_vm1,
    azurerm_subnet.appgw_subnet,
    azurerm_public_ip.appgw_pip
  ]
}

############################################
# NICs + VMs
############################################
resource "azurerm_network_interface" "nic_vm1" {
  name                = "nic-vm1"
  location            = var.location
  resource_group_name = var.resource_group

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.subnet_app.id
    private_ip_address_allocation = "Dynamic"
  }

  depends_on = [
    null_resource.wait_for_rg,
    azurerm_subnet.subnet_app
  ]
}

resource "azurerm_network_interface" "nic_vm2" {
  name                = "nic-vm2"
  location            = var.location
  resource_group_name = var.resource_group

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.subnet_app.id
    private_ip_address_allocation = "Dynamic"
  }

  depends_on = [
    null_resource.wait_for_rg,
    azurerm_subnet.subnet_app
  ]
}

resource "azurerm_availability_set" "aset" {
  name                = "aset-app"
  location            = var.location
  resource_group_name = var.resource_group
  managed             = true

  depends_on = [
    null_resource.wait_for_rg
  ]
}

locals {
  vm_size = "Standard_B2s"
  image = {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

resource "azurerm_linux_virtual_machine" "vm1" {
  name                  = "vm1-app"
  location              = var.location
  resource_group_name   = var.resource_group
  size                  = local.vm_size
  admin_username        = var.vm_admin_username
  network_interface_ids = [azurerm_network_interface.nic_vm1.id]
  availability_set_id   = azurerm_availability_set.aset.id

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }

  os_disk {
    name                 = "osdisk-vm1"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  disable_password_authentication = true

  depends_on = [
    azurerm_network_interface.nic_vm1,
    azurerm_availability_set.aset
  ]
}

resource "azurerm_linux_virtual_machine" "vm2" {
  name                  = "vm2-app"
  location              = var.location
  resource_group_name   = var.resource_group
  size                  = local.vm_size
  admin_username        = var.vm_admin_username
  network_interface_ids = [azurerm_network_interface.nic_vm2.id]
  availability_set_id   = azurerm_availability_set.aset.id

  admin_ssh_key {
    username   = var.vm_admin_username
    public_key = var.ssh_public_key
  }

  source_image_reference {
    publisher = local.image.publisher
    offer     = local.image.offer
    sku       = local.image.sku
    version   = local.image.version
  }

  os_disk {
    name                 = "osdisk-vm2"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  disable_password_authentication = true

  depends_on = [
    azurerm_network_interface.nic_vm2,
    azurerm_availability_set.aset
  ]
}

############################################
# Subscription data (for future ARO/identity use)
############################################
data "azurerm_subscription" "primary" {}

############################################
# Conditional Entra ID + ARO
############################################
resource "azuread_application" "aro_app" {
  count            = var.enable_identity ? 1 : 0
  display_name     = "tf-aro-app"
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "aro_sp" {
  count     = var.enable_identity ? 1 : 0
  client_id = var.enable_identity ? azuread_application.aro_app[0].client_id : null
}

resource "azuread_application_password" "aro_app_secret" {
  count                 = var.enable_identity ? 1 : 0
  application_object_id = var.enable_identity ? azuread_application.aro_app[0].object_id : null
  display_name          = "tf-aro-secret"
  end_date_relative     = "8760h"
}

resource "azurerm_role_assignment" "aro_sp_contrib" {
  count                = var.enable_identity ? 1 : 0
  scope                = data.azurerm_subscription.primary.id
  role_definition_name = "Contributor"
  principal_id         = var.enable_identity ? azuread_service_principal.aro_sp[0].object_id : null
}

resource "azurerm_redhat_openshift_cluster" "aro" {
  count               = var.enable_aro ? 1 : 0
  name                = "aro-cluster"
  resource_group_name = var.resource_group
  location            = var.location

  cluster_profile {
    version     = var.aro_version
    pull_secret = file(var.aro_pull_secret_path)
    domain      = "aro.example.internal"
  }

  service_principal {
    client_id     = azuread_application.aro_app[0].client_id
    client_secret = azuread_application_password.aro_app_secret[0].value
  }

  main_profile {
    vm_size   = "Standard_D4s_v3"
    subnet_id = azurerm_subnet.subnet_app.id
  }

  worker_profile {
    vm_size       = "Standard_D4s_v3"
    subnet_id     = azurerm_subnet.subnet_app.id
    node_count    = 3
    disk_size_gb  = 128
  }

  api_server_profile {
    visibility = "Public"
  }

  ingress_profile {
    visibility = "Public"
  }

  network_profile {
    pod_cidr     = "10.128.0.0/14"
    service_cidr = "172.30.0.0/16"
  }

  tags = { env = "dev" }

  depends_on = [
    azurerm_role_assignment.aro_sp_contrib,
    null_resource.wait_for_rg
  ]
}

############################################
# Outputs
############################################
output "firewall_public_ip" {
  value = azurerm_public_ip.fw_pip.ip_address
}

output "firewall_private_ip" {
  value = azurerm_firewall.fw.ip_configuration[0].private_ip_address
}

output "appgw_public_ip" {
  value = azurerm_public_ip.appgw_pip.ip_address
}
