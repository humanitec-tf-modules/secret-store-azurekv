output "secret_store_id" {
  description = "ID of the secret store, i.e. the name of the Kubernetes `SecretStore` resource. This is either `secret_store_id` or the generated ID. Use it as the `store` in secret references."
  value       = local.secret_store_id
  # Consumers of the ID should wait for the SecretStore, once it can be created
  depends_on = [kubernetes_manifest.secret_store]
}
output "secret_store_namespace" {
  description = "Name of the Kubernetes namespace of the `SecretStore` resource. This is the Operator namespace for a cluster-wide store, or the Environment namespace for an Environment-local store."
  value       = local.secret_store_namespace
  depends_on  = [kubernetes_manifest.secret_store]
}
output "secret_store_ready" {
  description = "Whether the module manages the `SecretStore` resource. This is `false` if the `SecretStore` CRD was not present on the cluster during planning. In that case, apply the configuration again once the Operator is installed. See [Installation order](#installation-order)."
  value       = local.secret_store_crd_ready
}
output "key_vault_uri" {
  description = "URI of the Azure Key Vault, used as the `url` of the secret store."
  value       = data.azurerm_key_vault.secret_store.vault_uri
}
output "key_vault_tenant_id" {
  description = "ID of the Microsoft Entra ID tenant of the Azure Key Vault, used as the `tenantID` of the secret store."
  value       = data.azurerm_key_vault.secret_store.tenant_id
}
output "key_vault_role_definition_name" {
  description = "Name of the built-in Azure role the Operator identity needs on the Key Vault: `Key Vault Secrets Officer` for the default store, `Key Vault Secrets User` otherwise. If `key_vault_access_create` is `false`, assign this role to the identity yourself. Returns `null` if `key_vault_rbac_authorization_enabled` is `false`."
  value       = var.key_vault_rbac_authorization_enabled ? local.key_vault_role_definition_name : null
}
output "key_vault_secret_permissions" {
  description = "Secret permissions the Operator identity needs in a Key Vault access policy: `Get`, `Set`, `Delete`, and `Recover` for the default store, `Get` otherwise. If `key_vault_access_create` is `false`, create an access policy with these permissions for the identity yourself. Returns `null` if `key_vault_rbac_authorization_enabled` is `true`."
  value       = var.key_vault_rbac_authorization_enabled ? null : local.key_vault_secret_permissions
}
output "key_vault_role_assignment_id" {
  description = "ID of the Azure role assignment granting the Operator access to the Key Vault. Returns `null` if `key_vault_access_create` or `key_vault_rbac_authorization_enabled` is `false`."
  value       = one(azurerm_role_assignment.operator[*].id)
}
output "key_vault_access_policy_id" {
  description = "ID of the Key Vault access policy granting the Operator access to the Key Vault. Returns `null` if `key_vault_access_create` is `false` or `key_vault_rbac_authorization_enabled` is `true`."
  value       = one(azurerm_key_vault_access_policy.operator[*].id)
}
output "operator_client_id" {
  description = "Client ID of the managed identity or service principal used by the Operator, depending on `auth_method`."
  value       = local.operator_client_id
}
output "operator_principal_id" {
  description = "Object (principal) ID of the managed identity or service principal used by the Operator, depending on `auth_method`. Use it to grant the Operator access to further Azure resources."
  value       = local.operator_principal_id
}
output "managed_identity_id" {
  description = "Resource ID of the user-assigned managed identity used by the Operator. Returns `null` if `auth_method` is `service_principal`."
  value       = local.managed_identity_id
}
output "managed_identity_name" {
  description = "Name of the user-assigned managed identity used by the Operator. Returns `null` if `auth_method` is `service_principal`."
  value       = local.managed_identity_name
}
output "managed_identity_client_id" {
  description = "Client ID of the user-assigned managed identity used by the Operator. Returns `null` if `auth_method` is `service_principal`."
  value       = local.managed_identity_client_id
}
output "managed_identity_principal_id" {
  description = "Object (principal) ID of the user-assigned managed identity used by the Operator. Returns `null` if `auth_method` is `service_principal`."
  value       = local.managed_identity_principal_id
}
output "federated_identity_credential_id" {
  description = "ID of the federated identity credential created by the module. Returns `null` if `auth_method` is not `workload_identity` or `federated_identity_credential_create` is `false`."
  value       = one(azurerm_federated_identity_credential.operator[*].id)
}
output "federated_identity_credential" {
  description = "Issuer, subject, and audience of the federated identity credential allowing the Operator service account to use the managed identity. If `federated_identity_credential_create` is `false`, configure a federated identity credential with these values on the managed identity yourself. The issuer is `null` if `aks_oidc_issuer_url` is not set. Returns `null` if `auth_method` is not `workload_identity`."
  value       = local.federated_identity_credential
}
output "operator_serviceaccount_annotations" {
  description = "Annotations to set on the Operator service account so that it uses the managed identity via Workload Identity, e.g. via the `controllerManager.serviceAccount.annotations` value of the Operator Helm chart. Restart the Operator after changing them. Returns an empty map if `auth_method` is not `workload_identity`."
  value       = local.use_workload_identity ? tomap({ "azure.workload.identity/client-id" = local.managed_identity_client_id }) : tomap({})
}
output "operator_pod_labels" {
  description = "Labels to set on the Operator Pod so that it uses Workload Identity, e.g. via the `controllerManager.podLabels` value of the Operator Helm chart. Returns an empty map if `auth_method` is not `workload_identity`."
  value       = local.use_workload_identity ? tomap({ "azure.workload.identity/use" = "true" }) : tomap({})
}
output "service_principal_name" {
  description = "Display name of the service principal used by the Operator. Returns `null` if `auth_method` is not `service_principal`."
  value       = local.service_principal_name
}
output "service_principal_client_id" {
  description = "Client (application) ID of the service principal used by the Operator. Returns `null` if `auth_method` is not `service_principal`."
  value       = local.service_principal_client_id
}
output "service_principal_object_id" {
  description = "Object ID of the service principal used by the Operator. Returns `null` if `auth_method` is not `service_principal`."
  value       = local.service_principal_object_id
}
output "service_principal_credentials_secret_name" {
  description = "Name of the Kubernetes Secret holding the client ID and client secret of the service principal, located in the `secret_store_namespace`. Returns `null` if `auth_method` is not `service_principal`."
  value       = one(kubernetes_secret_v1.operator_credentials[*].metadata[0].name)
}
