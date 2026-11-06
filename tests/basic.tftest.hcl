# Mock all providers so the tests run without access to Azure, Microsoft Entra ID or a Kubernetes cluster
mock_provider "kubernetes" {}
mock_provider "random" {
  # The mocked result does not honor the length attribute
  mock_resource "random_string" {
    defaults = {
      result = "abcd"
    }
  }
}
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      subscription_id = "00000000-0000-0000-0000-000000000000"
      tenant_id       = "11111111-1111-1111-1111-111111111111"
    }
  }
  mock_data "azurerm_key_vault" {
    defaults = {
      id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault"
      vault_uri                  = "https://my-key-vault.vault.azure.net/"
      tenant_id                  = "11111111-1111-1111-1111-111111111111"
      location                   = "westeurope"
      rbac_authorization_enabled = true
    }
  }
  mock_resource "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/created-identity"
      client_id    = "22222222-2222-2222-2222-222222222222"
      principal_id = "33333333-3333-3333-3333-333333333333"
    }
  }
  mock_data "azurerm_user_assigned_identity" {
    defaults = {
      id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/existing-identity"
      client_id    = "44444444-4444-4444-4444-444444444444"
      principal_id = "55555555-5555-5555-5555-555555555555"
    }
  }
  mock_resource "azurerm_federated_identity_credential" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/created-identity/federatedIdentityCredentials/created-credential"
    }
  }
  mock_resource "azurerm_role_assignment" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault/providers/Microsoft.Authorization/roleAssignments/66666666-6666-6666-6666-666666666666"
    }
  }
  mock_resource "azurerm_key_vault_access_policy" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault/objectId/33333333-3333-3333-3333-333333333333"
    }
  }
}
mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = {
      tenant_id = "11111111-1111-1111-1111-111111111111"
      object_id = "12121212-1212-1212-1212-121212121212"
    }
  }
  mock_resource "azuread_application" {
    defaults = {
      id        = "/applications/77777777-7777-7777-7777-777777777777"
      client_id = "88888888-8888-8888-8888-888888888888"
    }
  }
  mock_resource "azuread_service_principal" {
    defaults = {
      object_id    = "99999999-9999-9999-9999-999999999999"
      display_name = "created-service-principal"
    }
  }
  mock_resource "azuread_application_password" {
    defaults = {
      key_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      value  = "created-client-secret"
    }
  }
  mock_data "azuread_service_principal" {
    defaults = {
      object_id    = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      display_name = "existing-service-principal"
    }
  }
}

# The minimum set of variables
variables {
  secret_store_id     = "my-azurekv"
  key_vault_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault"
  aks_oidc_issuer_url = "https://westeurope.oic.prod-aks.azure.com/11111111-1111-1111-1111-111111111111/cccccccc-cccc-cccc-cccc-cccccccccccc/"
  # Terraform tests require ephemeral variables to be set explicitly in apply runs
  service_principal_client_secret = ""
}

# Default case

run "defaults" {
  # The random suffix of the generated names is only known after apply
  command = apply

  # Key Vault
  assert {
    condition = (
      data.azurerm_key_vault.secret_store.name == "my-key-vault" &&
      data.azurerm_key_vault.secret_store.resource_group_name == "my-rg"
    )
    error_message = "Key Vault should be read by the name and resource group in key_vault_id"
  }

  # Secret store ID
  assert {
    condition     = length(random_string.secret_store_id_suffix) == 0
    error_message = "No random suffix should be generated if secret_store_id is set"
  }

  # Managed identity
  assert {
    condition     = length(azurerm_user_assigned_identity.operator) == 1 && length(data.azurerm_user_assigned_identity.operator) == 0
    error_message = "Managed identity should be created by default"
  }
  assert {
    condition     = azurerm_user_assigned_identity.operator[0].name == "humanitec-operator-my-azurekv-abcd"
    error_message = "Managed identity name should be generated as humanitec-operator-<secret_store_id>-<suffix>, got ${azurerm_user_assigned_identity.operator[0].name}"
  }
  assert {
    condition = (
      azurerm_user_assigned_identity.operator[0].resource_group_name == "my-rg" &&
      azurerm_user_assigned_identity.operator[0].location == "westeurope"
    )
    error_message = "Managed identity should be created in the resource group and region of the Key Vault by default"
  }
  assert {
    condition     = azurerm_user_assigned_identity.operator[0].tags == null
    error_message = "Managed identity should have no tags by default"
  }

  # Federated identity credential
  assert {
    condition = (
      azurerm_federated_identity_credential.operator[0].name == "humanitec-operator-my-azurekv" &&
      azurerm_federated_identity_credential.operator[0].user_assigned_identity_id == azurerm_user_assigned_identity.operator[0].id
    )
    error_message = "Federated identity credential should be named humanitec-operator-<secret_store_id> and be created on the new managed identity"
  }
  assert {
    condition = (
      azurerm_federated_identity_credential.operator[0].issuer == var.aks_oidc_issuer_url &&
      azurerm_federated_identity_credential.operator[0].subject == "system:serviceaccount:humanitec-operator-system:humanitec-operator-controller-manager" &&
      azurerm_federated_identity_credential.operator[0].audience == tolist(["api://AzureADTokenExchange"])
    )
    error_message = "Federated identity credential should trust the Operator service account via the OIDC issuer of the AKS cluster"
  }

  # Role assignment
  assert {
    condition = (
      azurerm_role_assignment.operator[0].scope == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault" &&
      azurerm_role_assignment.operator[0].role_definition_name == "Key Vault Secrets Officer"
    )
    error_message = "Role assignment should grant read/write access to the Key Vault for the default store"
  }
  assert {
    condition = (
      azurerm_role_assignment.operator[0].principal_id == "33333333-3333-3333-3333-333333333333" &&
      azurerm_role_assignment.operator[0].principal_type == "ServicePrincipal"
    )
    error_message = "Role assignment should be for the new managed identity"
  }
  assert {
    condition     = length(azurerm_key_vault_access_policy.operator) == 0
    error_message = "No access policy should be created with Azure RBAC"
  }

  # No service principal
  assert {
    condition = (
      length(data.azuread_client_config.current) == 0 &&
      length(azuread_application.operator) == 0 &&
      length(azuread_service_principal.operator) == 0 &&
      length(azuread_application_password.operator) == 0 &&
      length(data.azuread_service_principal.operator) == 0 &&
      length(terraform_data.service_principal_credentials_version) == 0 &&
      length(kubernetes_secret_v1.operator_credentials) == 0
    )
    error_message = "No service principal, client secret or credentials Secret should be used with Workload Identity"
  }

  # Secret store
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.apiVersion == "humanitec.io/v1alpha1" &&
      kubernetes_manifest.secret_store.manifest.kind == "SecretStore"
    )
    error_message = "Secret store should be a humanitec.io/v1alpha1 SecretStore"
  }
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.metadata.name == "my-azurekv" &&
      kubernetes_manifest.secret_store.manifest.metadata.namespace == "humanitec-operator-system"
    )
    error_message = "Secret store should be named secret_store_id and be cluster-wide in the Operator namespace by default"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.labels["app.humanitec.io/default-store"] == "true" && length(kubernetes_manifest.secret_store.manifest.metadata.labels) == 1
    error_message = "Secret store should be labelled as the default store by default"
  }
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.spec.azurekv.url == "https://my-key-vault.vault.azure.net/" &&
      kubernetes_manifest.secret_store.manifest.spec.azurekv.tenantID == "11111111-1111-1111-1111-111111111111"
    )
    error_message = "Secret store should use the URI and tenant ID of the Key Vault"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.spec.azurekv.auth == {}
    error_message = "Secret store should have an empty auth object with Workload Identity. A map cannot be converted to the SecretStore CRD schema by kubernetes_manifest"
  }
  assert {
    condition     = terraform_data.secret_store_auth_method.output == "workload_identity"
    error_message = "Auth method should be tracked, so that changing it replaces the secret store"
  }

  # Outputs
  assert {
    condition = (
      output.secret_store_id == "my-azurekv" &&
      output.secret_store_namespace == "humanitec-operator-system" &&
      output.key_vault_uri == "https://my-key-vault.vault.azure.net/" &&
      output.key_vault_tenant_id == "11111111-1111-1111-1111-111111111111"
    )
    error_message = "Secret store ID, namespace, Key Vault URI and tenant outputs should use the defaults"
  }
  assert {
    condition = (
      output.key_vault_role_assignment_id == azurerm_role_assignment.operator[0].id &&
      output.key_vault_access_policy_id == null
    )
    error_message = "Role assignment ID output should be set, and access policy ID output should be null with Azure RBAC"
  }
  assert {
    condition = (
      output.key_vault_role_definition_name == "Key Vault Secrets Officer" &&
      output.key_vault_secret_permissions == null
    )
    error_message = "Role definition name output should be the read/write role for the default store, and secret permissions output should be null with Azure RBAC"
  }
  assert {
    condition = (
      output.managed_identity_id == azurerm_user_assigned_identity.operator[0].id &&
      output.managed_identity_name == "humanitec-operator-my-azurekv-abcd" &&
      output.managed_identity_client_id == "22222222-2222-2222-2222-222222222222" &&
      output.managed_identity_principal_id == "33333333-3333-3333-3333-333333333333" &&
      output.operator_client_id == "22222222-2222-2222-2222-222222222222" &&
      output.operator_principal_id == "33333333-3333-3333-3333-333333333333"
    )
    error_message = "Managed identity and Operator identity outputs should be those of the new managed identity"
  }
  assert {
    condition     = output.federated_identity_credential_id == azurerm_federated_identity_credential.operator[0].id
    error_message = "Federated identity credential ID output should be the ID of the created credential"
  }
  assert {
    condition = (
      output.federated_identity_credential.issuer == var.aks_oidc_issuer_url &&
      output.federated_identity_credential.subject == "system:serviceaccount:humanitec-operator-system:humanitec-operator-controller-manager" &&
      output.federated_identity_credential.audience == tolist(["api://AzureADTokenExchange"])
    )
    error_message = "Federated identity credential output should contain the issuer, subject and audience"
  }
  assert {
    condition     = output.operator_serviceaccount_annotations == tomap({ "azure.workload.identity/client-id" = "22222222-2222-2222-2222-222222222222" })
    error_message = "Operator service account annotations output should contain the client ID of the managed identity"
  }
  assert {
    condition     = output.operator_pod_labels == tomap({ "azure.workload.identity/use" = "true" })
    error_message = "Operator Pod labels output should enable Workload Identity"
  }
  assert {
    condition = (
      output.service_principal_name == null &&
      output.service_principal_client_id == null &&
      output.service_principal_object_id == null &&
      output.service_principal_credentials_secret_name == null
    )
    error_message = "Service principal outputs should be null with Workload Identity"
  }
}

# Variations of the secret store

run "generated_secret_store_id" {
  command = apply

  variables {
    secret_store_id = null
  }

  assert {
    condition     = length(random_string.secret_store_id_suffix) == 1 && random_string.secret_store_id_suffix[0].length == 4
    error_message = "A random suffix of four characters should be generated for the secret store ID"
  }
  assert {
    condition = (
      random_string.secret_store_id_suffix[0].upper == false &&
      random_string.secret_store_id_suffix[0].numeric == false &&
      random_string.secret_store_id_suffix[0].special == false
    )
    error_message = "The random suffix of the secret store ID should consist of lowercase letters only"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.name == "azurekv-abcd"
    error_message = "Secret store ID should be generated as azurekv-<random>, got ${kubernetes_manifest.secret_store.manifest.metadata.name}"
  }
  assert {
    condition     = output.secret_store_id == "azurekv-abcd"
    error_message = "Secret store ID output should be the generated ID"
  }
  assert {
    condition = (
      azurerm_user_assigned_identity.operator[0].name == "humanitec-operator-azurekv-abcd-abcd" &&
      azurerm_federated_identity_credential.operator[0].name == "humanitec-operator-azurekv-abcd"
    )
    error_message = "Generated identity names should be based on the generated secret store ID"
  }
}

run "generated_secret_store_id_with_service_principal" {
  command = apply

  variables {
    secret_store_id     = null
    auth_method         = "service_principal"
    aks_oidc_issuer_url = null
  }

  assert {
    condition     = azuread_application.operator[0].display_name == "humanitec-operator-azurekv-abcd-abcd"
    error_message = "Service principal name should be based on the generated secret store ID"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].metadata[0].name == "azurekv-abcd-credentials"
    error_message = "Credentials Secret name should be based on the generated secret store ID"
  }
}

run "non_default_store" {
  command = apply

  variables {
    secret_store_default = false
  }

  assert {
    condition     = !can(kubernetes_manifest.secret_store.manifest.metadata.labels)
    error_message = "Non-default secret store should not be labelled as the default store"
  }
  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.namespace == "humanitec-operator-system"
    error_message = "Non-default secret store should still be cluster-wide by default"
  }
  assert {
    condition     = azurerm_role_assignment.operator[0].role_definition_name == "Key Vault Secrets User"
    error_message = "Role assignment should only grant read access for a non-default store"
  }
  assert {
    condition     = output.key_vault_role_definition_name == "Key Vault Secrets User"
    error_message = "Role definition name output should be the read-only role for a non-default store"
  }
}

run "environment_local_store" {
  command = apply

  variables {
    secret_store_default      = false
    secret_store_cluster_wide = false
    secret_store_namespace    = "my-app-development"
  }

  assert {
    condition     = kubernetes_manifest.secret_store.manifest.metadata.namespace == "my-app-development"
    error_message = "Environment-local secret store should be created in secret_store_namespace"
  }
  assert {
    condition     = !can(kubernetes_manifest.secret_store.manifest.metadata.labels)
    error_message = "Environment-local secret store should not be labelled as the default store"
  }
  assert {
    condition     = output.secret_store_namespace == "my-app-development"
    error_message = "Secret store namespace output should be secret_store_namespace"
  }
  assert {
    condition     = azurerm_federated_identity_credential.operator[0].subject == "system:serviceaccount:humanitec-operator-system:humanitec-operator-controller-manager"
    error_message = "Federated identity credential should still be for the Operator service account for an Environment-local store"
  }
}

# Variations of the Key Vault permission model

run "access_policy" {
  command = apply

  override_data {
    target = data.azurerm_key_vault.secret_store
    values = {
      id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault"
      vault_uri                  = "https://my-key-vault.vault.azure.net/"
      tenant_id                  = "11111111-1111-1111-1111-111111111111"
      location                   = "westeurope"
      rbac_authorization_enabled = false
    }
  }

  variables {
    key_vault_rbac_authorization_enabled = false
  }

  assert {
    condition     = length(azurerm_role_assignment.operator) == 0
    error_message = "No role assignment should be created with an access policy"
  }
  assert {
    condition = (
      azurerm_key_vault_access_policy.operator[0].key_vault_id == "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault" &&
      azurerm_key_vault_access_policy.operator[0].tenant_id == "11111111-1111-1111-1111-111111111111" &&
      azurerm_key_vault_access_policy.operator[0].object_id == "33333333-3333-3333-3333-333333333333"
    )
    error_message = "Access policy should be set on the Key Vault for the new managed identity"
  }
  assert {
    condition     = toset(azurerm_key_vault_access_policy.operator[0].secret_permissions) == toset(["Get", "Set", "Delete", "Recover"])
    error_message = "Access policy should grant read/write access for the default store"
  }
  assert {
    condition = (
      azurerm_key_vault_access_policy.operator[0].key_permissions == null &&
      azurerm_key_vault_access_policy.operator[0].certificate_permissions == null &&
      azurerm_key_vault_access_policy.operator[0].storage_permissions == null
    )
    error_message = "Access policy should only grant secret permissions"
  }
  assert {
    condition = (
      output.key_vault_role_assignment_id == null &&
      output.key_vault_access_policy_id == azurerm_key_vault_access_policy.operator[0].id
    )
    error_message = "Access policy ID output should be set, and role assignment ID output should be null with an access policy"
  }
  assert {
    condition = (
      output.key_vault_secret_permissions == tolist(["Get", "Set", "Delete", "Recover"]) &&
      output.key_vault_role_definition_name == null
    )
    error_message = "Secret permissions output should be the read/write permissions for the default store, and role definition name output should be null with an access policy"
  }
}

run "access_policy_non_default_store" {
  command = apply

  override_data {
    target = data.azurerm_key_vault.secret_store
    values = {
      id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault"
      vault_uri                  = "https://my-key-vault.vault.azure.net/"
      tenant_id                  = "11111111-1111-1111-1111-111111111111"
      location                   = "westeurope"
      rbac_authorization_enabled = false
    }
  }

  variables {
    key_vault_rbac_authorization_enabled = false
    secret_store_default                 = false
  }

  assert {
    condition     = azurerm_key_vault_access_policy.operator[0].secret_permissions == tolist(["Get"])
    error_message = "Access policy should only grant read access for a non-default store"
  }
  assert {
    condition     = output.key_vault_secret_permissions == tolist(["Get"])
    error_message = "Secret permissions output should be the read-only permissions for a non-default store"
  }
}

# Several Environment-local secret stores sharing one existing managed identity.
# The access to the Key Vault and the federated identity credential are managed outside of the module.

run "shared_identity_without_key_vault_access" {
  command = apply

  variables {
    secret_store_default                 = false
    secret_store_cluster_wide            = false
    secret_store_namespace               = "my-app-development"
    managed_identity_create              = false
    managed_identity_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/existing-identity"
    federated_identity_credential_create = false
    key_vault_access_create              = false
  }

  assert {
    condition = (
      length(azurerm_user_assigned_identity.operator) == 0 &&
      length(azurerm_federated_identity_credential.operator) == 0 &&
      length(azurerm_role_assignment.operator) == 0 &&
      length(azurerm_key_vault_access_policy.operator) == 0
    )
    error_message = "Neither a managed identity, a federated identity credential, a role assignment, nor an access policy should be created"
  }
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.metadata.namespace == "my-app-development" &&
      output.operator_principal_id == "55555555-5555-5555-5555-555555555555"
    )
    error_message = "Secret store should still be created for the existing managed identity"
  }
  assert {
    condition = (
      output.key_vault_role_assignment_id == null &&
      output.key_vault_access_policy_id == null
    )
    error_message = "Role assignment and access policy ID outputs should be null if key_vault_access_create is false"
  }
  assert {
    condition = (
      output.key_vault_role_definition_name == "Key Vault Secrets User" &&
      output.key_vault_secret_permissions == null
    )
    error_message = "Role definition name output should still name the role to assign if key_vault_access_create is false"
  }
}
run "shared_identity_without_key_vault_access_policy" {
  command = apply

  override_data {
    target = data.azurerm_key_vault.secret_store
    values = {
      id                         = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault"
      vault_uri                  = "https://my-key-vault.vault.azure.net/"
      tenant_id                  = "11111111-1111-1111-1111-111111111111"
      location                   = "westeurope"
      rbac_authorization_enabled = false
    }
  }

  variables {
    key_vault_rbac_authorization_enabled = false
    secret_store_default                 = false
    secret_store_cluster_wide            = false
    secret_store_namespace               = "my-app-development"
    managed_identity_create              = false
    managed_identity_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/existing-identity"
    federated_identity_credential_create = false
    key_vault_access_create              = false
  }

  assert {
    condition     = length(azurerm_role_assignment.operator) == 0 && length(azurerm_key_vault_access_policy.operator) == 0
    error_message = "Neither a role assignment nor an access policy should be created if key_vault_access_create is false"
  }
  assert {
    condition = (
      output.key_vault_secret_permissions == tolist(["Get"]) &&
      output.key_vault_role_definition_name == null
    )
    error_message = "Secret permissions output should still list the permissions to grant if key_vault_access_create is false"
  }
}
run "service_principal_without_key_vault_access" {
  command = apply

  variables {
    auth_method             = "service_principal"
    aks_oidc_issuer_url     = null
    key_vault_access_create = false
  }

  assert {
    condition     = length(azurerm_role_assignment.operator) == 0 && length(azurerm_key_vault_access_policy.operator) == 0
    error_message = "Neither a role assignment nor an access policy should be created for a service principal if key_vault_access_create is false"
  }
  assert {
    condition     = length(azuread_service_principal.operator) == 1 && length(kubernetes_secret_v1.operator_credentials) == 1
    error_message = "Service principal and credentials Secret should still be created if key_vault_access_create is false"
  }
}

# Complete cases

run "complete_create_managed_identity" {
  command = apply

  variables {
    secret_store_id                      = "complete-azurekv"
    secret_store_default                 = true
    operator_namespace                   = "my-operator"
    operator_serviceaccount              = "my-operator-sa"
    auth_method                          = "workload_identity"
    managed_identity_create              = true
    managed_identity_name                = "my-identity"
    managed_identity_resource_group_name = "identity-rg"
    managed_identity_location            = "northeurope"
    managed_identity_tags                = { env = "test" }
    federated_identity_credential_create = true
    federated_identity_credential_name   = "my-credential"
  }

  # Managed identity
  assert {
    condition     = length(random_string.identity_name_suffix) == 0
    error_message = "No random suffix should be generated if all identity names are set"
  }
  assert {
    condition = (
      azurerm_user_assigned_identity.operator[0].name == "my-identity" &&
      azurerm_user_assigned_identity.operator[0].resource_group_name == "identity-rg" &&
      azurerm_user_assigned_identity.operator[0].location == "northeurope" &&
      azurerm_user_assigned_identity.operator[0].tags == tomap({ env = "test" })
    )
    error_message = "Managed identity should use managed_identity_name, managed_identity_resource_group_name, managed_identity_location and managed_identity_tags"
  }

  # Federated identity credential
  assert {
    condition = (
      azurerm_federated_identity_credential.operator[0].name == "my-credential" &&
      azurerm_federated_identity_credential.operator[0].subject == "system:serviceaccount:my-operator:my-operator-sa"
    )
    error_message = "Federated identity credential should use federated_identity_credential_name and the custom Operator namespace and service account"
  }

  # Secret store
  assert {
    condition = (
      kubernetes_manifest.secret_store.manifest.metadata.name == "complete-azurekv" &&
      kubernetes_manifest.secret_store.manifest.metadata.namespace == "my-operator"
    )
    error_message = "Secret store should use secret_store_id and operator_namespace"
  }

  # Outputs
  assert {
    condition     = output.managed_identity_name == "my-identity"
    error_message = "Managed identity name output should be the custom name"
  }
  assert {
    condition     = output.federated_identity_credential.subject == "system:serviceaccount:my-operator:my-operator-sa"
    error_message = "Federated identity credential output should use the custom Operator namespace and service account"
  }
  assert {
    condition     = output.secret_store_namespace == "my-operator"
    error_message = "Cluster-wide secret store should be in the custom Operator namespace"
  }
}

run "complete_existing_managed_identity" {
  command = apply

  variables {
    managed_identity_create = false
    managed_identity_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/existing-identity"
  }

  # Managed identity
  assert {
    condition     = length(azurerm_user_assigned_identity.operator) == 0
    error_message = "Managed identity should not be created if managed_identity_create is false"
  }
  assert {
    condition = (
      data.azurerm_user_assigned_identity.operator[0].name == "existing-identity" &&
      data.azurerm_user_assigned_identity.operator[0].resource_group_name == "identity-rg"
    )
    error_message = "Existing managed identity should be read by the name and resource group in managed_identity_id"
  }
  assert {
    condition     = length(random_string.identity_name_suffix) == 0
    error_message = "No random suffix should be generated for an existing managed identity"
  }

  # Federated identity credential
  assert {
    condition     = azurerm_federated_identity_credential.operator[0].user_assigned_identity_id == var.managed_identity_id
    error_message = "Federated identity credential should be created on the existing managed identity"
  }

  # Role assignment
  assert {
    condition     = azurerm_role_assignment.operator[0].principal_id == "55555555-5555-5555-5555-555555555555"
    error_message = "Role assignment should be for the existing managed identity"
  }

  # Outputs
  assert {
    condition = (
      output.managed_identity_id == var.managed_identity_id &&
      output.managed_identity_name == "existing-identity" &&
      output.managed_identity_client_id == "44444444-4444-4444-4444-444444444444" &&
      output.managed_identity_principal_id == "55555555-5555-5555-5555-555555555555" &&
      output.operator_client_id == "44444444-4444-4444-4444-444444444444" &&
      output.operator_principal_id == "55555555-5555-5555-5555-555555555555"
    )
    error_message = "Managed identity and Operator identity outputs should be those of the existing managed identity"
  }
  assert {
    condition     = output.operator_serviceaccount_annotations == tomap({ "azure.workload.identity/client-id" = "44444444-4444-4444-4444-444444444444" })
    error_message = "Operator service account annotations output should contain the client ID of the existing managed identity"
  }
}

run "complete_create_service_principal" {
  command = apply

  variables {
    auth_method                               = "service_principal"
    aks_oidc_issuer_url                       = null
    service_principal_create                  = true
    service_principal_name                    = "my-service-principal"
    service_principal_owners                  = ["cccccccc-cccc-cccc-cccc-cccccccccccc"]
    service_principal_client_secret_end_date  = "2027-01-01T00:00:00Z"
    service_principal_credentials_secret_name = "my-credentials"
  }

  # Service principal
  assert {
    condition = (
      azuread_application.operator[0].display_name == "my-service-principal" &&
      azuread_application.operator[0].owners == toset(["cccccccc-cccc-cccc-cccc-cccccccccccc"])
    )
    error_message = "Application should use service_principal_name and service_principal_owners"
  }
  assert {
    condition = (
      azuread_service_principal.operator[0].client_id == "88888888-8888-8888-8888-888888888888" &&
      azuread_service_principal.operator[0].owners == toset(["cccccccc-cccc-cccc-cccc-cccccccccccc"])
    )
    error_message = "Service principal should be created for the application with service_principal_owners"
  }
  assert {
    condition = (
      azuread_application_password.operator[0].application_id == "/applications/77777777-7777-7777-7777-777777777777" &&
      azuread_application_password.operator[0].end_date == "2027-01-01T00:00:00Z"
    )
    error_message = "Client secret should be created for the application with service_principal_client_secret_end_date"
  }

  # Role assignment
  assert {
    condition     = azurerm_role_assignment.operator[0].principal_id == "99999999-9999-9999-9999-999999999999"
    error_message = "Role assignment should be for the new service principal"
  }

  # No managed identity
  assert {
    condition = (
      length(azurerm_user_assigned_identity.operator) == 0 &&
      length(data.azurerm_user_assigned_identity.operator) == 0 &&
      length(azurerm_federated_identity_credential.operator) == 0
    )
    error_message = "No managed identity or federated identity credential should be used with a service principal"
  }

  # Credentials Secret
  assert {
    condition = (
      kubernetes_secret_v1.operator_credentials[0].metadata[0].name == "my-credentials" &&
      kubernetes_secret_v1.operator_credentials[0].metadata[0].namespace == "humanitec-operator-system"
    )
    error_message = "Credentials Secret should be named service_principal_credentials_secret_name and be in the namespace of the secret store"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo_revision == 1
    error_message = "Credentials Secret should set data_wo_revision so that the provider writes data_wo and does not read the created client secret back into the state"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo == null
    error_message = "Credentials Secret should not store the created client secret in the state via data_wo"
  }
  assert {
    condition = terraform_data.service_principal_credentials_version[0].output == {
      client_id             = "88888888-8888-8888-8888-888888888888"
      client_secret_version = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    }
    error_message = "Client ID and key ID of the created client secret should be tracked to replace the credentials Secret on change"
  }

  # Secret store
  assert {
    condition = kubernetes_manifest.secret_store.manifest.spec.azurekv.auth == {
      clientIDSecretRef     = { name = "my-credentials", key = "ClientID" }
      clientSecretSecretRef = { name = "my-credentials", key = "ClientSecret" }
    }
    error_message = "Secret store should reference the client ID and secret in the credentials Secret, as an object"
  }

  # Outputs
  assert {
    condition = (
      output.service_principal_name == "created-service-principal" &&
      output.service_principal_client_id == "88888888-8888-8888-8888-888888888888" &&
      output.service_principal_object_id == "99999999-9999-9999-9999-999999999999" &&
      output.operator_client_id == "88888888-8888-8888-8888-888888888888" &&
      output.operator_principal_id == "99999999-9999-9999-9999-999999999999"
    )
    error_message = "Service principal and Operator identity outputs should be those of the new service principal"
  }
  assert {
    condition     = output.service_principal_credentials_secret_name == "my-credentials"
    error_message = "Credentials Secret name output should be service_principal_credentials_secret_name"
  }
  assert {
    condition = (
      output.managed_identity_id == null &&
      output.managed_identity_name == null &&
      output.managed_identity_client_id == null &&
      output.managed_identity_principal_id == null &&
      output.federated_identity_credential_id == null &&
      output.federated_identity_credential == null &&
      length(output.operator_serviceaccount_annotations) == 0 &&
      length(output.operator_pod_labels) == 0
    )
    error_message = "Managed identity and Workload Identity outputs should be null or empty with a service principal"
  }
}

run "complete_existing_service_principal" {
  command = apply

  variables {
    auth_method                             = "service_principal"
    aks_oidc_issuer_url                     = null
    service_principal_create                = false
    service_principal_client_id             = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    service_principal_client_secret         = "existing-client-secret"
    service_principal_client_secret_version = 2
  }

  # Service principal
  assert {
    condition = (
      length(azuread_application.operator) == 0 &&
      length(azuread_service_principal.operator) == 0 &&
      length(azuread_application_password.operator) == 0
    )
    error_message = "Neither an application, a service principal nor a client secret should be created if service_principal_create is false"
  }
  assert {
    condition     = data.azuread_service_principal.operator[0].client_id == "dddddddd-dddd-dddd-dddd-dddddddddddd"
    error_message = "Existing service principal should be read by service_principal_client_id"
  }
  assert {
    condition     = azurerm_role_assignment.operator[0].principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    error_message = "Role assignment should be for the existing service principal"
  }

  # Credentials Secret
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].metadata[0].name == "my-azurekv-credentials"
    error_message = "Credentials Secret name should be generated as <secret_store_id>-credentials"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo_revision == 1
    error_message = "Credentials Secret should set data_wo_revision so that the provider writes data_wo and does not read the client secret passed in back into the state"
  }
  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].data_wo == null
    error_message = "Credentials Secret should not store the client secret passed in in the state via data_wo"
  }
  assert {
    condition = terraform_data.service_principal_credentials_version[0].output == {
      client_id             = "dddddddd-dddd-dddd-dddd-dddddddddddd"
      client_secret_version = "2"
    }
    error_message = "Client ID and service_principal_client_secret_version should be tracked to replace the credentials Secret on change"
  }

  # Outputs
  assert {
    condition = (
      output.service_principal_name == "existing-service-principal" &&
      output.service_principal_client_id == "dddddddd-dddd-dddd-dddd-dddddddddddd" &&
      output.service_principal_object_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" &&
      output.operator_client_id == "dddddddd-dddd-dddd-dddd-dddddddddddd" &&
      output.operator_principal_id == "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    )
    error_message = "Service principal and Operator identity outputs should be those of the existing service principal"
  }
}

run "existing_service_principal_without_version" {
  command = apply

  variables {
    auth_method                     = "service_principal"
    aks_oidc_issuer_url             = null
    service_principal_create        = false
    service_principal_client_id     = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    service_principal_client_secret = "existing-client-secret"
  }

  assert {
    condition     = terraform_data.service_principal_credentials_version[0].output.client_secret_version == "0"
    error_message = "Client secret version should default to 0 if service_principal_client_secret_version is not set"
  }
}

run "create_service_principal_default_owners" {
  command = apply

  variables {
    auth_method         = "service_principal"
    aks_oidc_issuer_url = null
  }

  assert {
    condition = (
      azuread_application.operator[0].owners == toset(["12121212-1212-1212-1212-121212121212"]) &&
      azuread_service_principal.operator[0].owners == toset(["12121212-1212-1212-1212-121212121212"])
    )
    error_message = "Application and service principal should be owned by the identity of the azuread provider if service_principal_owners is not set"
  }
}
run "create_service_principal_without_owners" {
  command = apply

  variables {
    auth_method              = "service_principal"
    aks_oidc_issuer_url      = null
    service_principal_owners = []
  }

  assert {
    condition = (
      length(azuread_application.operator[0].owners) == 0 &&
      length(azuread_service_principal.operator[0].owners) == 0
    )
    error_message = "Application and service principal should have no owners if service_principal_owners is an empty set"
  }
}
run "environment_local_store_with_service_principal" {
  command = apply

  variables {
    auth_method               = "service_principal"
    aks_oidc_issuer_url       = null
    secret_store_default      = false
    secret_store_cluster_wide = false
    secret_store_namespace    = "my-app-development"
  }

  assert {
    condition     = kubernetes_secret_v1.operator_credentials[0].metadata[0].namespace == "my-app-development"
    error_message = "Credentials Secret should be in the namespace of the Environment-local secret store"
  }
  assert {
    condition     = azuread_application.operator[0].display_name == "humanitec-operator-my-azurekv-abcd"
    error_message = "Service principal name should be generated as humanitec-operator-<secret_store_id>-<suffix>, got ${azuread_application.operator[0].display_name}"
  }
  assert {
    condition     = azurerm_role_assignment.operator[0].role_definition_name == "Key Vault Secrets User"
    error_message = "Role assignment should only grant read access for an Environment-local store"
  }
}

# Edge cases

run "create_managed_identity_without_federated_identity_credential" {
  command = apply

  variables {
    federated_identity_credential_create = false
    aks_oidc_issuer_url                  = null
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.operator) == 1 && length(azurerm_federated_identity_credential.operator) == 0
    error_message = "Managed identity, but no federated identity credential should be created if federated_identity_credential_create is false"
  }
  assert {
    condition     = output.federated_identity_credential_id == null
    error_message = "Federated identity credential ID output should be null if no credential is created"
  }
  assert {
    condition = (
      output.federated_identity_credential.issuer == null &&
      output.federated_identity_credential.subject == "system:serviceaccount:humanitec-operator-system:humanitec-operator-controller-manager" &&
      output.federated_identity_credential.audience == tolist(["api://AzureADTokenExchange"])
    )
    error_message = "Federated identity credential output should provide the values to configure a credential yourself, and no issuer if aks_oidc_issuer_url is not set"
  }
}

run "existing_managed_identity_without_federated_identity_credential" {
  command = apply

  # aks_oidc_issuer_url is still set from the file-level variables
  variables {
    managed_identity_create              = false
    managed_identity_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/existing-identity"
    federated_identity_credential_create = false
  }

  assert {
    condition     = length(azurerm_user_assigned_identity.operator) == 0 && length(azurerm_federated_identity_credential.operator) == 0
    error_message = "Neither a managed identity nor a federated identity credential should be created"
  }
  assert {
    condition     = output.federated_identity_credential.issuer == var.aks_oidc_issuer_url
    error_message = "Federated identity credential output should include aks_oidc_issuer_url if set"
  }
}

run "key_vault_id_is_case_insensitive" {
  command = apply

  variables {
    key_vault_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/my-rg/providers/microsoft.keyvault/vaults/my-key-vault"
  }

  assert {
    condition = (
      data.azurerm_key_vault.secret_store.name == "my-key-vault" &&
      data.azurerm_key_vault.secret_store.resource_group_name == "my-rg"
    )
    error_message = "Key Vault should be read from a resource ID in a different letter case"
  }
}

# Validation failures

run "rejects_invalid_secret_store_id" {
  command = plan

  variables {
    secret_store_id = "My_Store"
  }

  expect_failures = [var.secret_store_id]
}

run "rejects_invalid_auth_method" {
  command = plan

  variables {
    auth_method = "pod_identity"
  }

  expect_failures = [var.auth_method]
}

run "default_store_must_be_cluster_wide" {
  command = plan

  # secret_store_default is true by default
  variables {
    secret_store_cluster_wide = false
    secret_store_namespace    = "my-app-development"
  }

  expect_failures = [var.secret_store_default]
}

run "environment_local_store_requires_namespace" {
  command = plan

  variables {
    secret_store_default      = false
    secret_store_cluster_wide = false
  }

  expect_failures = [var.secret_store_namespace]
}

run "cluster_wide_store_rejects_namespace" {
  command = plan

  variables {
    secret_store_namespace = "my-app-development"
  }

  expect_failures = [var.secret_store_namespace]
}

run "rejects_invalid_key_vault_id" {
  command = plan

  variables {
    key_vault_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.Storage/storageAccounts/my-account"
  }

  expect_failures = [var.key_vault_id]
}

run "key_vault_rejects_other_subscription" {
  command = plan

  variables {
    key_vault_id = "/subscriptions/ffffffff-ffff-ffff-ffff-ffffffffffff/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault"
  }

  expect_failures = [data.azurerm_key_vault.secret_store]
}

run "rejects_mismatching_permission_model" {
  command = plan

  # The mocked Key Vault uses Azure RBAC
  variables {
    key_vault_rbac_authorization_enabled = false
  }

  expect_failures = [data.azurerm_key_vault.secret_store]
}

run "federated_identity_credential_requires_aks_oidc_issuer_url" {
  command = plan

  variables {
    aks_oidc_issuer_url = null
  }

  expect_failures = [var.aks_oidc_issuer_url]
}

run "federated_identity_credential_requires_aks_oidc_issuer_url_for_existing_identity" {
  command = plan

  variables {
    managed_identity_create = false
    managed_identity_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/existing-identity"
    aks_oidc_issuer_url     = null
  }

  expect_failures = [var.aks_oidc_issuer_url]
}

run "rejects_invalid_aks_oidc_issuer_url" {
  command = plan

  variables {
    aks_oidc_issuer_url = "westeurope.oic.prod-aks.azure.com/11111111-1111-1111-1111-111111111111/cccccccc-cccc-cccc-cccc-cccccccccccc/"
  }

  expect_failures = [var.aks_oidc_issuer_url]
}

run "create_managed_identity_rejects_managed_identity_id" {
  command = plan

  variables {
    managed_identity_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/existing-identity"
  }

  expect_failures = [var.managed_identity_id]
}

run "existing_managed_identity_requires_managed_identity_id" {
  command = plan

  variables {
    managed_identity_create = false
  }

  expect_failures = [var.managed_identity_id]
}

run "existing_managed_identity_rejects_invalid_managed_identity_id" {
  command = plan

  variables {
    managed_identity_create = false
    managed_identity_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault"
  }

  expect_failures = [var.managed_identity_id]
}

run "existing_managed_identity_rejects_other_subscription" {
  command = plan

  variables {
    managed_identity_create = false
    managed_identity_id     = "/subscriptions/ffffffff-ffff-ffff-ffff-ffffffffffff/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/existing-identity"
  }

  expect_failures = [data.azurerm_user_assigned_identity.operator]
}

run "existing_managed_identity_rejects_managed_identity_settings" {
  command = plan

  variables {
    managed_identity_create              = false
    managed_identity_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/existing-identity"
    managed_identity_name                = "my-identity"
    managed_identity_resource_group_name = "identity-rg"
    managed_identity_location            = "northeurope"
    managed_identity_tags                = { env = "test" }
  }

  expect_failures = [
    var.managed_identity_name,
    var.managed_identity_resource_group_name,
    var.managed_identity_location,
    var.managed_identity_tags,
  ]
}

run "no_federated_identity_credential_rejects_name" {
  command = plan

  variables {
    federated_identity_credential_create = false
    federated_identity_credential_name   = "my-credential"
  }

  expect_failures = [var.federated_identity_credential_name]
}

run "service_principal_rejects_aks_oidc_issuer_url" {
  command = plan

  variables {
    auth_method = "service_principal"
  }

  expect_failures = [var.aks_oidc_issuer_url]
}

run "service_principal_rejects_workload_identity_settings" {
  command = plan

  variables {
    auth_method                          = "service_principal"
    aks_oidc_issuer_url                  = null
    managed_identity_name                = "my-identity"
    managed_identity_resource_group_name = "identity-rg"
    managed_identity_location            = "northeurope"
    managed_identity_tags                = { env = "test" }
    managed_identity_id                  = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/identity-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/existing-identity"
    federated_identity_credential_name   = "my-credential"
  }

  expect_failures = [
    var.managed_identity_name,
    var.managed_identity_resource_group_name,
    var.managed_identity_location,
    var.managed_identity_tags,
    var.managed_identity_id,
    var.federated_identity_credential_name,
  ]
}

run "workload_identity_rejects_service_principal_settings" {
  command = plan

  variables {
    service_principal_name                    = "my-service-principal"
    service_principal_owners                  = ["cccccccc-cccc-cccc-cccc-cccccccccccc"]
    service_principal_client_secret_end_date  = "2027-01-01T00:00:00Z"
    service_principal_credentials_secret_name = "my-credentials"
  }

  expect_failures = [
    var.service_principal_name,
    var.service_principal_owners,
    var.service_principal_client_secret_end_date,
    var.service_principal_credentials_secret_name,
  ]
}

run "create_service_principal_rejects_existing_service_principal_settings" {
  command = plan

  variables {
    auth_method                             = "service_principal"
    aks_oidc_issuer_url                     = null
    service_principal_client_id             = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    service_principal_client_secret         = "existing-client-secret"
    service_principal_client_secret_version = 2
  }

  expect_failures = [
    var.service_principal_client_id,
    var.service_principal_client_secret,
    var.service_principal_client_secret_version,
  ]
}

run "create_service_principal_rejects_invalid_client_secret_end_date" {
  command = plan

  variables {
    auth_method                              = "service_principal"
    aks_oidc_issuer_url                      = null
    service_principal_client_secret_end_date = "2027-01-01"
  }

  expect_failures = [var.service_principal_client_secret_end_date]
}

run "create_service_principal_rejects_other_tenant" {
  command = plan

  override_data {
    target = data.azuread_client_config.current
    values = {
      tenant_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    }
  }

  variables {
    auth_method         = "service_principal"
    aks_oidc_issuer_url = null
  }

  expect_failures = [azuread_application.operator]
}

run "existing_service_principal_requires_client_id_and_secret" {
  command = plan

  variables {
    auth_method              = "service_principal"
    aks_oidc_issuer_url      = null
    service_principal_create = false
  }

  expect_failures = [
    var.service_principal_client_id,
    var.service_principal_client_secret,
  ]
}

run "existing_service_principal_rejects_invalid_client_id" {
  command = plan

  variables {
    auth_method                     = "service_principal"
    aks_oidc_issuer_url             = null
    service_principal_create        = false
    service_principal_client_id     = "my-service-principal"
    service_principal_client_secret = "existing-client-secret"
  }

  expect_failures = [var.service_principal_client_id]
}

run "existing_service_principal_rejects_other_tenant" {
  command = plan

  override_data {
    target = data.azuread_client_config.current
    values = {
      tenant_id = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    }
  }

  variables {
    auth_method                     = "service_principal"
    aks_oidc_issuer_url             = null
    service_principal_create        = false
    service_principal_client_id     = "dddddddd-dddd-dddd-dddd-dddddddddddd"
    service_principal_client_secret = "existing-client-secret"
  }

  expect_failures = [data.azuread_service_principal.operator]
}
