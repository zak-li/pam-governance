provider "azurerm" {
  # Resource providers (Microsoft.KeyVault, Microsoft.ManagedIdentity,
  # Microsoft.ContainerService) are auto-registered on first use.
  features {}
}

# The auth0 provider reads AUTH0_DOMAIN, AUTH0_CLIENT_ID and AUTH0_CLIENT_SECRET
# from the environment (a Machine-to-Machine app authorized on the Management API).
provider "auth0" {}
