# AKS: hosts the app behind Kong (edge) with the Istio mesh (east-west mTLS).
# Single node to fit the student quota.
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-pam-governance"
  location            = var.location
  resource_group_name = var.resource_group_name
  dns_prefix          = "pamgov"
  sku_tier            = "Free"

  default_node_pool {
    name                 = "system"
    node_count           = 1
    vm_size              = "Standard_B4s_v2"
    os_disk_size_gb      = 64
    orchestrator_version = null
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "kubenet"
    network_policy = "calico"
  }

  role_based_access_control_enabled = true

  # Azure enables the OIDC issuer server-side and refuses to disable it; match
  # that so Terraform does not attempt a rejected update on re-apply.
  oidc_issuer_enabled = true

  lifecycle {
    ignore_changes = [
      default_node_pool[0].orchestrator_version,
      kubernetes_version,
    ]
  }
}
