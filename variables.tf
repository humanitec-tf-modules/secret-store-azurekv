# Secret store

variable "secret_store_id" {
  description = "ID of the secret store. It is the name of the Kubernetes `SecretStore` resource and the `store` value used in secret references. If you also register the secret store with the Platform Orchestrator, use the same ID there. If not set, the module generates an ID in the pattern `azurekv-<random>`, with `<random>` being a random string of four lowercase letters, e.g. `azurekv-kxqp`. Use the `secret_store_id` output to read it."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.secret_store_id == null || (can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.secret_store_id)) && length(coalesce(var.secret_store_id, "-")) <= 63)
    error_message = "secret_store_id must consist of lowercase alphanumeric characters or '-', start and end with an alphanumeric character, and be at most 63 characters long"
  }
}
variable "secret_store_cluster_wide" {
  description = "Whether the secret store is cluster-wide, i.e. usable by all Deployments onto the cluster. A cluster-wide store is created in the `operator_namespace`. If `false`, the store is Environment-local and created in `secret_store_namespace`, so it can only be used by Deployments into that namespace."
  type        = bool
  nullable    = false
  default     = true
}
variable "secret_store_namespace" {
  description = "Name of the Kubernetes namespace of the Environment for an Environment-local secret store. Required if `secret_store_cluster_wide` is `false`, must not be set otherwise. The namespace must exist."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.secret_store_cluster_wide ? var.secret_store_namespace == null : var.secret_store_namespace != null
    error_message = "secret_store_namespace must be set if secret_store_cluster_wide is false, and must not be set otherwise"
  }
}
variable "secret_store_default" {
  description = "Whether the secret store is the default secret store of the Operator. Only a cluster-wide secret store can be the default store, so set it to `false` for an Environment-local store. The Operator gets read/write access to the default store, and read-only access to any other store."
  type        = bool
  nullable    = false
  default     = true

  validation {
    condition     = !var.secret_store_default || var.secret_store_cluster_wide
    error_message = "secret_store_default can only be true if secret_store_cluster_wide is true. An Environment-local secret store cannot be the default store, so set secret_store_default to false"
  }
}

# Key Vault

variable "key_vault_id" {
  description = "Resource ID of the Azure Key Vault, e.g. `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault`. It must be located in the subscription of the `azurerm` provider that is passed in to the module. The module reads the URL and tenant ID of the secret store from the Key Vault."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex(local.key_vault_id_pattern, var.key_vault_id))
    error_message = "key_vault_id must be a Key Vault resource ID like /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault"
  }
}
variable "key_vault_rbac_authorization_enabled" {
  description = "Whether the Key Vault uses the Azure RBAC permission model (recommended). If `true`, the module grants the Operator access via an Azure role assignment, using the built-in role `Key Vault Secrets Officer` for the default store, and `Key Vault Secrets User` otherwise. If `false`, the Key Vault uses the legacy access policy permission model, and the module grants the Operator access via an access policy. It must match the permission model of the Key Vault, which the module verifies."
  type        = bool
  nullable    = false
  default     = true
}
variable "key_vault_access_create" {
  description = "Whether to grant the Operator identity access to the Key Vault, via a role assignment or an access policy depending on `key_vault_rbac_authorization_enabled`. Set it to `false` if the identity already has access, e.g. if several secret stores share one identity: Azure allows only one role assignment per identity, role, and Key Vault, and only one access policy per identity and Key Vault. Grant the access yourself in that case, using the `key_vault_role_definition_name` or `key_vault_secret_permissions` output."
  type        = bool
  nullable    = false
  default     = true
}

# Operator

variable "operator_namespace" {
  description = "Name of the Kubernetes namespace of the Humanitec Operator."
  type        = string
  nullable    = false
  default     = "humanitec-operator-system"
}
variable "operator_serviceaccount" {
  description = "Name of the Kubernetes service account of the Humanitec Operator. Used as the subject of the federated identity credential if `auth_method` is `workload_identity`."
  type        = string
  nullable    = false
  default     = "humanitec-operator-controller-manager"
}
variable "auth_method" {
  description = "How the Operator authenticates against Azure Key Vault. `workload_identity` (recommended): the Operator uses a user-assigned managed identity via Microsoft Entra Workload ID. `service_principal`: the Operator uses static credentials of a service principal, stored in a Kubernetes Secret."
  type        = string
  nullable    = false
  default     = "workload_identity"

  validation {
    condition     = contains(["workload_identity", "service_principal"], var.auth_method)
    error_message = "auth_method must be one of: workload_identity, service_principal"
  }
}

# Managed identity (auth_method = "workload_identity")

variable "managed_identity_create" {
  description = "Whether to create the user-assigned managed identity used by the Operator. Only used if `auth_method` is `workload_identity`. If `false`, `managed_identity_id` must be the ID of an existing user-assigned managed identity. The Operator uses only one managed identity for all secret stores using Workload Identity, so set it to `false` if the Operator already uses a managed identity, e.g. one created by another instance of the module."
  type        = bool
  nullable    = false
  default     = true
}
variable "managed_identity_name" {
  description = "Name of the user-assigned managed identity to create for the Operator. Only used if `auth_method` is `workload_identity` and `managed_identity_create` is `true`. If not set, the module generates a name from the secret store ID and a random four-letter suffix."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.managed_identity_name == null || (var.auth_method == "workload_identity" && var.managed_identity_create)
    error_message = "managed_identity_name must only be set if auth_method is workload_identity and managed_identity_create is true. Use managed_identity_id to pass in an existing managed identity"
  }
}
variable "managed_identity_resource_group_name" {
  description = "Name of the resource group in which to create the user-assigned managed identity for the Operator. The resource group must exist. If not set, the resource group of the Key Vault is used. Only used if `auth_method` is `workload_identity` and `managed_identity_create` is `true`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.managed_identity_resource_group_name == null || (var.auth_method == "workload_identity" && var.managed_identity_create)
    error_message = "managed_identity_resource_group_name must only be set if auth_method is workload_identity and managed_identity_create is true"
  }
}
variable "managed_identity_location" {
  description = "Azure region in which to create the user-assigned managed identity for the Operator, e.g. `westeurope`. If not set, the region of the Key Vault is used. Only used if `auth_method` is `workload_identity` and `managed_identity_create` is `true`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.managed_identity_location == null || (var.auth_method == "workload_identity" && var.managed_identity_create)
    error_message = "managed_identity_location must only be set if auth_method is workload_identity and managed_identity_create is true"
  }
}
variable "managed_identity_tags" {
  description = "Tags to assign to the user-assigned managed identity created by the module. Only used if `auth_method` is `workload_identity` and `managed_identity_create` is `true`."
  type        = map(string)
  nullable    = true
  default     = null

  validation {
    condition     = var.managed_identity_tags == null || (var.auth_method == "workload_identity" && var.managed_identity_create)
    error_message = "managed_identity_tags must only be set if auth_method is workload_identity and managed_identity_create is true"
  }
}
variable "managed_identity_id" {
  description = "Resource ID of an existing user-assigned managed identity to be used by the Operator, e.g. `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/my-identity`. It must be located in the subscription of the `azurerm` provider that is passed in to the module. Required if `auth_method` is `workload_identity` and `managed_identity_create` is `false`, must not be set otherwise."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = (var.auth_method == "workload_identity" && !var.managed_identity_create) == (var.managed_identity_id != null)
    error_message = "managed_identity_id must be set if auth_method is workload_identity and managed_identity_create is false, and must not be set otherwise"
  }

  validation {
    condition     = var.managed_identity_id == null || can(regex(local.managed_identity_id_pattern, var.managed_identity_id))
    error_message = "managed_identity_id must be a user-assigned managed identity resource ID like /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/my-identity"
  }
}
variable "federated_identity_credential_create" {
  description = "Whether to create the federated identity credential on the managed identity, allowing the Operator service account to use it via Workload Identity. Only used if `auth_method` is `workload_identity`. Set to `false` if you manage the federated identity credential yourself, e.g. because an existing managed identity already has one for the Operator service account. Use the `federated_identity_credential` output to configure it."
  type        = bool
  nullable    = false
  default     = true
}
variable "federated_identity_credential_name" {
  description = "Name of the federated identity credential to create on the managed identity. Only used if `auth_method` is `workload_identity` and `federated_identity_credential_create` is `true`. If not set, the name is `humanitec-operator-<secret store ID>`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.federated_identity_credential_name == null || (var.auth_method == "workload_identity" && var.federated_identity_credential_create)
    error_message = "federated_identity_credential_name must only be set if auth_method is workload_identity and federated_identity_credential_create is true"
  }
}
variable "aks_oidc_issuer_url" {
  description = "URL of the OIDC issuer of the AKS cluster hosting the Operator, e.g. the `oidc_issuer_url` attribute of an `azurerm_kubernetes_cluster`. The cluster must have the OIDC issuer and Workload Identity enabled. Required if `auth_method` is `workload_identity` and `federated_identity_credential_create` is `true`. Optional otherwise: if set, it is included in the `federated_identity_credential` output. Must not be set if `auth_method` is `service_principal`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = !(var.auth_method == "workload_identity" && var.federated_identity_credential_create) || var.aks_oidc_issuer_url != null
    error_message = "aks_oidc_issuer_url must be set if auth_method is workload_identity and federated_identity_credential_create is true"
  }

  validation {
    condition     = var.auth_method != "service_principal" || var.aks_oidc_issuer_url == null
    error_message = "aks_oidc_issuer_url must not be set if auth_method is service_principal"
  }

  validation {
    condition     = var.aks_oidc_issuer_url == null || startswith(coalesce(var.aks_oidc_issuer_url, "-"), "https://")
    error_message = "aks_oidc_issuer_url must be an https:// URL"
  }
}

# Service principal (auth_method = "service_principal")

variable "service_principal_create" {
  description = "Whether to create the Microsoft Entra ID application, service principal, and client secret used by the Operator. Only used if `auth_method` is `service_principal`. If `true`, the client secret is stored in the OpenTofu/Terraform state as part of the `azuread_application_password` resource. If `false`, `service_principal_client_id` and `service_principal_client_secret` must be set for an existing service principal, and the client secret is not stored in the state."
  type        = bool
  nullable    = false
  default     = true
}
variable "service_principal_name" {
  description = "Display name of the Microsoft Entra ID application and service principal to create for the Operator. Only used if `auth_method` is `service_principal` and `service_principal_create` is `true`. If not set, the module generates a name from the secret store ID and a random four-letter suffix."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.service_principal_name == null || (var.auth_method == "service_principal" && var.service_principal_create)
    error_message = "service_principal_name must only be set if auth_method is service_principal and service_principal_create is true. Use service_principal_client_id to pass in an existing service principal"
  }
}
variable "service_principal_owners" {
  description = "Object IDs of the owners of the Microsoft Entra ID application and service principal created for the Operator. Only used if `auth_method` is `service_principal` and `service_principal_create` is `true`. If not set, the owner is the identity the `azuread` provider authenticates as. If you set it, include that identity if it needs ownership to manage the application, e.g. because it only has the `Application.ReadWrite.OwnedBy` permission. An empty set means no owners."
  type        = set(string)
  nullable    = true
  default     = null

  validation {
    condition     = var.service_principal_owners == null || (var.auth_method == "service_principal" && var.service_principal_create)
    error_message = "service_principal_owners must only be set if auth_method is service_principal and service_principal_create is true"
  }
}
variable "service_principal_client_secret_end_date" {
  description = "End date of the client secret created for the Operator, in RFC3339 format, e.g. `2027-01-01T00:00:00Z`. If not set, the client secret expires after two years. Only used if `auth_method` is `service_principal` and `service_principal_create` is `true`. Changing it replaces the client secret, and the module updates the Kubernetes Secret accordingly."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.service_principal_client_secret_end_date == null || (var.auth_method == "service_principal" && var.service_principal_create)
    error_message = "service_principal_client_secret_end_date must only be set if auth_method is service_principal and service_principal_create is true"
  }

  validation {
    condition     = var.service_principal_client_secret_end_date == null || can(timeadd(coalesce(var.service_principal_client_secret_end_date, "-"), "0s"))
    error_message = "service_principal_client_secret_end_date must be a timestamp in RFC3339 format, e.g. 2027-01-01T00:00:00Z"
  }
}
variable "service_principal_client_id" {
  description = "Client (application) ID of an existing service principal to be used by the Operator. It must be located in the tenant of the Key Vault. Required if `auth_method` is `service_principal` and `service_principal_create` is `false`, must not be set otherwise."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = (var.auth_method == "service_principal" && !var.service_principal_create) == (var.service_principal_client_id != null)
    error_message = "service_principal_client_id must be set if auth_method is service_principal and service_principal_create is false, and must not be set otherwise"
  }

  validation {
    condition     = var.service_principal_client_id == null || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.service_principal_client_id))
    error_message = "service_principal_client_id must be a UUID like 00000000-0000-0000-0000-000000000000"
  }
}
# Not nullable with an empty string meaning "not set": Terraform tests cannot run an apply
# with an ephemeral variable that is null.
variable "service_principal_client_secret" {
  description = "Client secret of the existing service principal passed in via `service_principal_client_id`. Required if `auth_method` is `service_principal` and `service_principal_create` is `false`, must be empty otherwise. The variable is ephemeral, so the value can come from an ephemeral source. It is not stored in the state or plan, as the module only writes it to a write-only attribute of the Kubernetes Secret. The Kubernetes Secret is only updated if `service_principal_client_id` or `service_principal_client_secret_version` changes as well."
  type        = string
  nullable    = false
  sensitive   = true
  ephemeral   = true
  default     = ""

  validation {
    condition     = (var.auth_method == "service_principal" && !var.service_principal_create) == (var.service_principal_client_secret != "")
    error_message = "service_principal_client_secret must be set if auth_method is service_principal and service_principal_create is false, and must be empty otherwise"
  }
}
variable "service_principal_client_secret_version" {
  description = "Version of the client secret passed in via `service_principal_client_secret`. The module keeps it in the state to detect changes of the write-only client secret. Increase it whenever you pass in a new client secret, e.g. when rotating it, to make the module replace the Kubernetes Secret holding the credentials. Only used if `auth_method` is `service_principal` and `service_principal_create` is `false`."
  type        = number
  nullable    = true
  default     = null

  validation {
    condition     = var.service_principal_client_secret_version == null || (var.auth_method == "service_principal" && !var.service_principal_create)
    error_message = "service_principal_client_secret_version must only be set if auth_method is service_principal and service_principal_create is false"
  }
}
variable "service_principal_credentials_secret_name" {
  description = "Name of the Kubernetes Secret holding the client ID and client secret of the service principal. It is created in the namespace of the secret store. The credentials are written to the Secret via a write-only attribute, so the Secret does not add them to the state. Only used if `auth_method` is `service_principal`. If not set, the name is `<secret store ID>-credentials`."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.service_principal_credentials_secret_name == null || var.auth_method == "service_principal"
    error_message = "service_principal_credentials_secret_name must only be set if auth_method is service_principal"
  }
}
