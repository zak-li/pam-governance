# =====================================================================
#  Azure Container Registry - holds the Angular app image built by
#  `az acr build`, pulled by the AKS kubelet via an AcrPull role.
# =====================================================================
resource "azurerm_container_registry" "acr" {
  name                = "acrpam${random_string.kv_suffix.result}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}
