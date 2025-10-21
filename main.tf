terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.11"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "2944c97d-8d49-4931-a638-3535dde1dfd2"
}

# --------------------------
# Basic parameters
# --------------------------
variable "location"          { default = "eastus" }
variable "resource_group"    { default = "rg-secure-vms" }
variable "vnet_cidr"         { default = "10.50.0.0/16" }
variable "subnet_cidr"       { default = "10.50.1.0/24" }
variable "vm_admin_username" { default = "azureuser" }
variable "ssh_public_key"    { description = "Full content of your SSH public key (~/.ssh/id_rsa.pub)" }

# --------------------------
# Resource Group
# --------------------------
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group
  location = var.location
}

# --------------------------
# Networking: VNet/Subnet + NAT Gateway for Internet egress
# --------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-core"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet_app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.subnet_cidr]
}

# Public IP (Standard) for NAT Gateway
resource "azurerm_public_ip" "nat_pip" {
  name                = "pip-nat-egress"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

# NAT Gateway to provide outbound Internet access
resource "azurerm_nat_gateway" "nat" {
  name                = "ngw-egress"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "Standard"
}

resource "azurerm_nat_gateway_public_ip_association" "nat_assoc_pip" {
  nat_gateway_id       = azurerm_nat_gateway.nat.id
  public_ip_address_id = azurerm_public_ip.nat_pip.id
}

resource "azurerm_subnet_nat_gateway_association" "snet_nat_assoc" {
  subnet_id      = azurerm_subnet.subnet_app.id
  nat_gateway_id = azurerm_nat_gateway.nat.id
}

# Optional: Basic NSG (Network Security Group)
# Azure allows outbound traffic by default, but we define explicit rules for clarity.
resource "azurerm_network_security_group" "nsg_app" {
  name                = "nsg-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  # Deny all inbound traffic
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

  # Allow all outbound traffic
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
}

resource "azurerm_subnet_network_security_group_association" "snet_nsg" {
  subnet_id                 = azurerm_subnet.subnet_app.id
  network_security_group_id = azurerm_network_security_group.nsg_app.id
}

# --------------------------
# NICs (no public IPs)
# --------------------------
resource "azurerm_network_interface" "nic_vm1" {
  name                = "nic-vm1"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.subnet_app.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "nic_vm2" {
  name                = "nic-vm2"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.subnet_app.id
    private_ip_address_allocation = "Dynamic"
  }
}

# --------------------------
# Availability Set (recommended for multiple VMs)
# --------------------------
resource "azurerm_availability_set" "aset" {
  name                         = "aset-app"
  location                     = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  platform_fault_domain_count   = 2
  platform_update_domain_count  = 5
  managed = true
}

# --------------------------
# Two Linux Virtual Machines (Ubuntu LTS)
# --------------------------
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
  name                = "vm1-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = local.vm_size
  admin_username      = var.vm_admin_username
  network_interface_ids = [azurerm_network_interface.nic_vm1.id]
  availability_set_id = azurerm_availability_set.aset.id

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
}

resource "azurerm_linux_virtual_machine" "vm2" {
  name                = "vm2-app"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  size                = local.vm_size
  admin_username      = var.vm_admin_username
  network_interface_ids = [azurerm_network_interface.nic_vm2.id]
  availability_set_id = azurerm_availability_set.aset.id

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
}

# --------------------------
# Outputs
# --------------------------
output "subnet_id" {
  value = azurerm_subnet.subnet_app.id
}

output "nat_gateway_public_ip" {
  value = azurerm_public_ip.nat_pip.ip_address
}

output "vm_private_ips" {
  value = [
    azurerm_network_interface.nic_vm1.ip_configuration[0].private_ip_address,
    azurerm_network_interface.nic_vm2.ip_configuration[0].private_ip_address
  ]
}