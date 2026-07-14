# =====================================================================
#  Azure Kubernetes Service - hosts the app behind Kong (edge) with
#  the Istio service mesh (east-west mTLS). Single node (student quota).
# =====================================================================
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-pam-governance"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "pamgov"
  sku_tier            = "Free" # free control plane

  default_node_pool {
    name                 = "system"
    node_count           = 1
    vm_size              = "Standard_B4s_v2" # 4 vCPU / 16 GB (Bsv2, allowed)
    os_disk_size_gb      = 64
    orchestrator_version = null
    upgrade_settings {
      max_surge = "10%"
    }
  }

  identity {
    type = "SystemAssigned"
  }

  # kubenet + Calico: NetworkPolicy actually enforced (default-deny)
  network_profile {
    network_plugin = "kubenet"
    network_policy = "calico"
  }

  role_based_access_control_enabled = true

  # Hardening: automatic cert rotation, patch upgrade channel
  automatic_channel_upgrade = "patch"

  lifecycle {
    ignore_changes = [
      default_node_pool[0].orchestrator_version,
      kubernetes_version,
    ]
  }
}
