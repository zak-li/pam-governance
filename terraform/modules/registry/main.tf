# Azure Container Registry holding the Angular app image, pulled by the AKS
# kubelet via an AcrPull role.
resource "azurerm_container_registry" "acr" {
  name                = "acrpam${var.name_suffix}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Basic"
  admin_enabled       = false
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  scope                            = azurerm_container_registry.acr.id
  role_definition_name             = "AcrPull"
  principal_id                     = var.aks_kubelet_object_id
  skip_service_principal_aad_check = true
}
