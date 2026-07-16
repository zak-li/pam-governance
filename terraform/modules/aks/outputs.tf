output "name" { value = azurerm_kubernetes_cluster.aks.name }
output "node_resource_group" { value = azurerm_kubernetes_cluster.aks.node_resource_group }
output "kubelet_object_id" { value = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id }
