data "azurerm_client_config" "current" {}

# Random suffix for the fallback ID of the secret store
resource "random_string" "secret_store_id_suffix" {
  count   = var.secret_store_id == null ? 1 : 0
  length  = 4
  upper   = false
  numeric = false
  special = false
}

# Random suffix for the fallback names of the identity objects
resource "random_string" "identity_name_suffix" {
  count   = local.identity_name_suffix_required ? 1 : 0
  length  = 4
  upper   = false
  numeric = false
  special = false
}

locals {
  use_workload_identity    = var.auth_method == "workload_identity"
  use_service_principal    = var.auth_method == "service_principal"
  create_managed_identity  = local.use_workload_identity && var.managed_identity_create
  create_service_principal = local.use_service_principal && var.service_principal_create

  # ID of the secret store: the ID passed in, or the generated ID
  secret_store_id = var.secret_store_id != null ? var.secret_store_id : "azurekv-${random_string.secret_store_id_suffix[0].result}"

  # A cluster-wide secret store lives in the Operator namespace, an Environment-local store in the Environment namespace
  secret_store_namespace = var.secret_store_cluster_wide ? var.operator_namespace : var.secret_store_namespace

  # Subscription, resource group, and name of the Key Vault, parsed from its ID
  key_vault_id_parts = regex(local.key_vault_id_pattern, var.key_vault_id)

  # The Operator needs write access to the default store only, e.g. for storing resource cookies.
  # Azure RBAC: built-in role. Access policy: secret permissions.
  key_vault_role_definition_name = var.secret_store_default ? "Key Vault Secrets Officer" : "Key Vault Secrets User"
  key_vault_secret_permissions   = var.secret_store_default ? ["Get", "Set", "Delete", "Recover"] : ["Get"]

  # Managed identity and service principal names only contain characters of the secret store ID and "-",
  # which Azure allows, and stay below the maximum length of 120 characters, so no truncation is needed.
  identity_name_suffix_required = (
    (local.create_managed_identity && var.managed_identity_name == null) ||
    (local.create_service_principal && var.service_principal_name == null)
  )
  identity_generated_name = local.identity_name_suffix_required ? "humanitec-operator-${local.secret_store_id}-${random_string.identity_name_suffix[0].result}" : null

  # Subscription, resource group, and name of an existing managed identity, parsed from its ID
  existing_managed_identity_id_parts = var.managed_identity_id != null ? regex(local.managed_identity_id_pattern, var.managed_identity_id) : null

  # Attributes read back from the managed identity or service principal, so that references depend on them existing.
  # At most one of each pair exists, so one() yields null if the respective auth method is not used.
  managed_identity_id           = one(concat(azurerm_user_assigned_identity.operator[*].id, data.azurerm_user_assigned_identity.operator[*].id))
  managed_identity_name         = one(concat(azurerm_user_assigned_identity.operator[*].name, data.azurerm_user_assigned_identity.operator[*].name))
  managed_identity_client_id    = one(concat(azurerm_user_assigned_identity.operator[*].client_id, data.azurerm_user_assigned_identity.operator[*].client_id))
  managed_identity_principal_id = one(concat(azurerm_user_assigned_identity.operator[*].principal_id, data.azurerm_user_assigned_identity.operator[*].principal_id))
  service_principal_name        = one(concat(azuread_service_principal.operator[*].display_name, data.azuread_service_principal.operator[*].display_name))
  service_principal_client_id   = one(concat(azuread_service_principal.operator[*].client_id, data.azuread_service_principal.operator[*].client_id))
  service_principal_object_id   = one(concat(azuread_service_principal.operator[*].object_id, data.azuread_service_principal.operator[*].object_id))

  # Client ID and object (principal) ID of the Entra ID identity the Operator uses,
  # either the managed identity or the service principal
  operator_client_id    = local.use_workload_identity ? local.managed_identity_client_id : local.service_principal_client_id
  operator_principal_id = local.use_workload_identity ? local.managed_identity_principal_id : local.service_principal_object_id

  # Federated identity credential settings allowing the Operator service account to use the managed identity
  federated_identity_credential = local.use_workload_identity ? {
    issuer   = var.aks_oidc_issuer_url
    subject  = "system:serviceaccount:${var.operator_namespace}:${var.operator_serviceaccount}"
    audience = tolist(["api://AzureADTokenExchange"])
  } : null

  # Credentials of the service principal, either from the client secret created by the module or passed in.
  # The client secret is ephemeral if passed in, and is only ever written to write-only attributes.
  service_principal_client_secret = local.create_service_principal ? one(azuread_application_password.operator[*].value) : var.service_principal_client_secret

  # Owners of the application and service principal created by the module. Default to the identity of the azuread provider.
  # Without owners, the provider only makes that identity an owner while creating the application, and removes it again,
  # leaving an application it may no longer be allowed to manage, e.g. with the Application.ReadWrite.OwnedBy permission.
  service_principal_owners = var.service_principal_owners != null ? var.service_principal_owners : toset(data.azuread_client_config.current[*].object_id)
  service_principal_credentials_secret_name = (
    local.use_service_principal
    ? coalesce(var.service_principal_credentials_secret_name, "${local.secret_store_id}-credentials")
    : null
  )

  # SecretStore resource, see https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-azure-key-vault/
  secret_store_metadata = merge(
    {
      name      = local.secret_store_id
      namespace = local.secret_store_namespace
    },
    var.secret_store_default ? { labels = { "app.humanitec.io/default-store" = "true" } } : {},
  )
  # Authentication of the secret store, depending on the auth method.
  # With a service principal, the store references the client ID and secret in the credentials Secret.
  # With Workload Identity, the Operator uses the managed identity of its service account, which requires an empty auth.
  # Select the value by key instead of using a conditional: a conditional would convert both values into a map,
  # and kubernetes_manifest cannot convert an empty map into the auth object of the SecretStore CRD.
  secret_store_auth = {
    service_principal = {
      clientIDSecretRef = {
        name = local.service_principal_credentials_secret_name
        key  = "ClientID"
      }
      clientSecretSecretRef = {
        name = local.service_principal_credentials_secret_name
        key  = "ClientSecret"
      }
    }
    workload_identity = {}
  }[var.auth_method]

  # Patterns for Azure resource IDs, also used by the key_vault_id and managed_identity_id validations.
  # Azure resource IDs are case-insensitive.
  key_vault_id_pattern        = "(?i)^/subscriptions/(?P<subscription_id>[^/]+)/resourceGroups/(?P<resource_group_name>[^/]+)/providers/Microsoft\\.KeyVault/vaults/(?P<name>[^/]+)$"
  managed_identity_id_pattern = "(?i)^/subscriptions/(?P<subscription_id>[^/]+)/resourceGroups/(?P<resource_group_name>[^/]+)/providers/Microsoft\\.ManagedIdentity/userAssignedIdentities/(?P<name>[^/]+)$"
}

# Key Vault

data "azurerm_key_vault" "secret_store" {
  name                = local.key_vault_id_parts.name
  resource_group_name = local.key_vault_id_parts.resource_group_name

  lifecycle {
    precondition {
      condition     = lower(local.key_vault_id_parts.subscription_id) == lower(data.azurerm_client_config.current.subscription_id)
      error_message = "key_vault_id must be located in the subscription of the azurerm provider (${data.azurerm_client_config.current.subscription_id})."
    }
    postcondition {
      condition     = self.rbac_authorization_enabled == var.key_vault_rbac_authorization_enabled
      error_message = "key_vault_rbac_authorization_enabled must match the permission model of the Key Vault: set it to ${self.rbac_authorization_enabled} for this Key Vault."
    }
  }
}

# Managed identity for the Operator service account (auth_method = "workload_identity")

resource "azurerm_user_assigned_identity" "operator" {
  count               = local.create_managed_identity ? 1 : 0
  name                = coalesce(var.managed_identity_name, local.identity_generated_name)
  resource_group_name = coalesce(var.managed_identity_resource_group_name, local.key_vault_id_parts.resource_group_name)
  location            = coalesce(var.managed_identity_location, data.azurerm_key_vault.secret_store.location)
  tags                = var.managed_identity_tags
}

data "azurerm_user_assigned_identity" "operator" {
  count               = local.use_workload_identity && !var.managed_identity_create ? 1 : 0
  name                = local.existing_managed_identity_id_parts.name
  resource_group_name = local.existing_managed_identity_id_parts.resource_group_name

  lifecycle {
    precondition {
      condition     = lower(local.existing_managed_identity_id_parts.subscription_id) == lower(data.azurerm_client_config.current.subscription_id)
      error_message = "managed_identity_id must be located in the subscription of the azurerm provider (${data.azurerm_client_config.current.subscription_id})."
    }
  }
}

# Federated identity credential allowing the Operator service account to use the managed identity via Workload Identity
resource "azurerm_federated_identity_credential" "operator" {
  count                     = local.use_workload_identity && var.federated_identity_credential_create ? 1 : 0
  name                      = coalesce(var.federated_identity_credential_name, "humanitec-operator-${local.secret_store_id}")
  user_assigned_identity_id = local.managed_identity_id
  issuer                    = local.federated_identity_credential.issuer
  subject                   = local.federated_identity_credential.subject
  audience                  = local.federated_identity_credential.audience
}

# Service principal with a client secret (auth_method = "service_principal")

data "azuread_client_config" "current" {
  count = local.use_service_principal ? 1 : 0
}

resource "azuread_application" "operator" {
  count        = local.create_service_principal ? 1 : 0
  display_name = coalesce(var.service_principal_name, local.identity_generated_name)
  description  = "Humanitec Operator access to the Azure Key Vault secret store ${local.secret_store_id}"
  owners       = local.service_principal_owners

  lifecycle {
    precondition {
      condition     = data.azuread_client_config.current[0].tenant_id == data.azurerm_key_vault.secret_store.tenant_id
      error_message = "The azuread provider must be configured for the tenant of the Key Vault (${data.azurerm_key_vault.secret_store.tenant_id})."
    }
  }
}

resource "azuread_service_principal" "operator" {
  count       = length(azuread_application.operator)
  client_id   = azuread_application.operator[0].client_id
  description = "Humanitec Operator access to the Azure Key Vault secret store ${local.secret_store_id}"
  owners      = local.service_principal_owners
}

resource "azuread_application_password" "operator" {
  count          = length(azuread_application.operator)
  application_id = azuread_application.operator[0].id
  display_name   = "humanitec-operator-${local.secret_store_id}"
  end_date       = var.service_principal_client_secret_end_date
}

data "azuread_service_principal" "operator" {
  count     = local.use_service_principal && !var.service_principal_create ? 1 : 0
  client_id = var.service_principal_client_id

  lifecycle {
    precondition {
      condition     = data.azuread_client_config.current[0].tenant_id == data.azurerm_key_vault.secret_store.tenant_id
      error_message = "The azuread provider must be configured for the tenant of the Key Vault (${data.azurerm_key_vault.secret_store.tenant_id})."
    }
  }
}

# Version of the client secret in the Kubernetes Secret. Write-only data is not part of the state, so a change
# cannot be detected on the Secret itself. Tracking the client ID and the key ID of the client secret created by the
# module, or the version passed in, here detects any change of the credentials, e.g. a rotation, and replaces the Secret.
resource "terraform_data" "service_principal_credentials_version" {
  count = local.use_service_principal ? 1 : 0
  input = {
    client_id             = local.service_principal_client_id
    client_secret_version = local.create_service_principal ? one(azuread_application_password.operator[*].key_id) : tostring(coalesce(var.service_principal_client_secret_version, 0))
  }
}

# Kubernetes Secret holding the service principal credentials, in the namespace of the secret store referencing it.
# The credentials are written via the write-only data_wo attribute so that they are not stored in the state.
# Like the secret store, it waits for the SecretStore CRD, as the Operator namespace may not exist before that.
resource "kubernetes_secret_v1" "operator_credentials" {
  count = local.use_service_principal && local.secret_store_crd_ready ? 1 : 0
  metadata {
    name      = local.service_principal_credentials_secret_name
    namespace = local.secret_store_namespace
  }
  data_wo = {
    ClientID     = local.service_principal_client_id
    ClientSecret = local.service_principal_client_secret
  }
  # The provider only writes data_wo, and skips reading the Secret data back into the state, if the revision is
  # at least 1. It stays constant, as any change of the credentials replaces the Secret, which writes data_wo anew.
  data_wo_revision = 1

  lifecycle {
    replace_triggered_by = [terraform_data.service_principal_credentials_version[count.index]]
  }
}

# Key Vault access for the Operator identity

# Azure RBAC permission model (key_vault_access_create = true, key_vault_rbac_authorization_enabled = true)
resource "azurerm_role_assignment" "operator" {
  count                = var.key_vault_access_create && var.key_vault_rbac_authorization_enabled ? 1 : 0
  scope                = data.azurerm_key_vault.secret_store.id
  role_definition_name = local.key_vault_role_definition_name
  principal_id         = local.operator_principal_id
  principal_type       = "ServicePrincipal"
  description          = "Humanitec Operator access to the Azure Key Vault secret store ${local.secret_store_id}"
  # The principal is always a service principal, i.e. the managed identity or the service principal.
  # Skip the check of its existence, which may fail for a new principal due to Entra ID replication lag.
  skip_service_principal_aad_check = true
}

# Access policy permission model (key_vault_access_create = true, key_vault_rbac_authorization_enabled = false)
resource "azurerm_key_vault_access_policy" "operator" {
  count              = var.key_vault_access_create && !var.key_vault_rbac_authorization_enabled ? 1 : 0
  key_vault_id       = data.azurerm_key_vault.secret_store.id
  tenant_id          = data.azurerm_key_vault.secret_store.tenant_id
  object_id          = local.operator_principal_id
  secret_permissions = local.key_vault_secret_permissions
}

# Secret store registration with the Operator

# Guard against the "secretstores" CRD not yet being present on the cluster
data "kubernetes_resources" "secret_store_crd" {
  api_version    = "apiextensions.k8s.io/v1"
  kind           = "CustomResourceDefinition"
  field_selector = "metadata.name=secretstores.humanitec.io"
}

locals {
  secret_store_crd_ready = length([
    for crd in data.kubernetes_resources.secret_store_crd.objects : crd
    if try(crd.metadata.deletionTimestamp, null) == null
  ]) > 0
}

# Shown as a warning in plan/apply output, does not fail the run
check "secret_store_crd" {
  assert {
    condition     = local.secret_store_crd_ready
    error_message = "SecretStore CRD not found: the SecretStore object on the cluster was not created. Run apply again once the Operator is installed."
  }
}

# Tracks the auth method, so that changing it replaces the secret store
resource "terraform_data" "secret_store_auth_method" {
  input = var.auth_method
}

resource "kubernetes_manifest" "secret_store" {
  count = local.secret_store_crd_ready ? 1 : 0
  manifest = {
    apiVersion = "humanitec.io/v1alpha1"
    kind       = "SecretStore"
    metadata   = local.secret_store_metadata
    spec = {
      azurekv = {
        url      = data.azurerm_key_vault.secret_store.vault_uri
        tenantID = data.azurerm_key_vault.secret_store.tenant_id
        auth     = local.secret_store_auth
      }
    }
  }

  # Only register the store once the Operator identity has its permissions
  depends_on = [
    azurerm_federated_identity_credential.operator,
    azurerm_role_assignment.operator,
    azurerm_key_vault_access_policy.operator,
    kubernetes_secret_v1.operator_credentials,
  ]

  lifecycle {
    # kubernetes_manifest cannot update the auth object from the Secret references of a service principal
    # to the empty object of Workload Identity: it sends null, which the Kubernetes API server rejects.
    # Recreate the secret store whenever the auth method changes instead.
    replace_triggered_by = [terraform_data.secret_store_auth_method]
  }
}
