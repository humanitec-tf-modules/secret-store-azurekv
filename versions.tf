terraform {
  # 1.11.0 introduced write-only attributes in Terraform and OpenTofu, and ephemeral variables in OpenTofu.
  required_version = ">= 1.11.0"

  required_providers {
    # 4.65.0 introduced the user_assigned_identity_id attribute of the azurerm_federated_identity_credential resource.
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.65.0, < 5.0.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3"
    }
  }
}
