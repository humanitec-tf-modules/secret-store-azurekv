# Azure Key Vault as an Operator secret store

This repository contains an OpenTofu/Terraform module to connect an instance of [Azure Key Vault](https://learn.microsoft.com/azure/key-vault) as a secret store to the [Humanitec Operator](https://developer.humanitec.com/platform-orchestrator/docs/integration-and-extensions/humanitec-operator/overview/) running on an Azure Kubernetes Service (AKS) cluster. It implements the setup described in [Connect to Azure Key Vault](https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-azure-key-vault/).

The module creates:

- The Microsoft Entra ID identity used by the Operator. Depending on `auth_method`, this is one of:
  - `workload_identity` (default, recommended): A user-assigned managed identity used by the Operator service account via [Microsoft Entra Workload ID](https://learn.microsoft.com/azure/aks/workload-identity-overview), plus the federated identity credential trusting the Operator service account
  - `service_principal`: An application and service principal with a client secret, plus a Kubernetes Secret holding the client ID and secret
- The access of the Operator identity to the Key Vault. The Operator gets read/write access to the [default secret store](https://developer.humanitec.com/platform-orchestrator/docs/integration-and-extensions/humanitec-operator/architecture/#the-default-secret-store), and read-only access to any other store. Depending on the permission model of the Key Vault, this is one of:
  - [Azure RBAC](https://learn.microsoft.com/azure/key-vault/general/rbac-guide) (default, recommended): A role assignment of the built-in role `Key Vault Secrets Officer` for the default store, or `Key Vault Secrets User` otherwise
  - [Access policy](https://learn.microsoft.com/azure/key-vault/general/assign-access-policy) (legacy): An access policy with the secret permissions `Get`, `Set`, `Delete`, and `Recover` for the default store, or `Get` otherwise
- The `SecretStore` Kubernetes resource registering the secret store with the Operator, either cluster-wide or Environment-local

You can also bring your own managed identity or service principal instead of having the module create it, and grant it access to the Key Vault yourself.

> [!NOTE]
> The module does not register the secret store with the Platform Orchestrator. Follow the [instructions](https://developer.humanitec.com/platform-orchestrator/guides/platform-engineers/security/connect-secret-stores/connect-to-azure-key-vault/#register-the-secret-store-with-the-platform-orchestrator) to do so, using the same secret store ID.

Prerequisites:

- The Humanitec Operator is installed on the cluster before you plan the module. See [Installation order](#installation-order)
- If you use Workload Identity, the [OIDC issuer and Workload Identity](https://learn.microsoft.com/azure/aks/workload-identity-deploy-cluster) are enabled on the AKS cluster
- For an Environment-local secret store, the Environment namespace exists

The Key Vault must be located in the Azure subscription of the `azurerm` provider passed in to the module. The module also requires an `azuread` provider configured for the tenant of the Key Vault. It only manages Microsoft Entra ID objects with it if `auth_method` is `service_principal`, but you need to pass it in either way.

## Installation order

The module creates the `SecretStore` resource using a `kubernetes_manifest`, which reads the `SecretStore` custom resource definition (CRD) from the cluster during planning. The Humanitec Operator Helm chart installs this CRD. Therefore, the Operator must already be installed when you plan the module.

If you install the Operator in the same OpenTofu/Terraform configuration as the present module, e.g. via a `helm_release`, apply the Operator before you add the module, e.g. in a separate stage or using `-target`. Adding a `depends_on` on the module is not sufficient, as the CRD is required during planning already.

> [!NOTE]
> **Architectural decision**
>
> A provider such as [alekc/kubectl](https://registry.terraform.io/providers/alekc/kubectl), which does not require the CRD to exist at plan time, would allow a single apply. However, it would introduce another external community provider, require users to configure and pass in a fourth provider, and require an additional module input to order the SecretStore after the Operator installation. It would also need retry handling, as a newly installed CRD can take a moment before the API server accepts resources of its type. The module therefore accepts the two-pass limitation. It only applies when the Operator is installed in the same run as the module, e.g. on a new cluster.

With Workload Identity, the Operator service account also needs an annotation with the client ID of the managed identity, and the Operator Pod needs a label. See [Configure the Operator for Workload Identity](#configure-the-operator-for-workload-identity) for how to provide them.

> [!NOTE]
> **Architectural decision**
>
> The permission model of the Key Vault is an input (`key_vault_rbac_authorization_enabled`) instead of being read from the Key Vault. The module decides on it whether to create a role assignment or an access policy, which must be known during planning. If you create the Key Vault in the same configuration as the present module, its permission model is only known after apply. The module still reads the permission model from the Key Vault and fails if it does not match the input.

## Usage

### Common usage: Default secret store with Workload Identity

This configuration creates a cluster-wide secret store, as well as the user-assigned managed identity, its federated identity credential for the Operator service account, and the role assignment granting it access to the Key Vault. The secret store is the default store of the Operator, as `secret_store_default` is `true` by default. The managed identity is created in the resource group and region of the Key Vault.

```hcl
module "my_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }

  secret_store_id     = "my-azurekv"
  key_vault_id        = azurerm_key_vault.my_key_vault.id
  aks_oidc_issuer_url = azurerm_kubernetes_cluster.my_aks_cluster.oidc_issuer_url
}
```

Then [configure the Operator for Workload Identity](#configure-the-operator-for-workload-identity).

> [!NOTE]
> Azure role assignments can take several minutes to propagate. The Operator may fail to access the Key Vault until then.

### Configure the Operator for Workload Identity

With Workload Identity, the Operator service account must be annotated with the client ID of the managed identity, and the Operator Pod must carry the label `azure.workload.identity/use: "true"`. The module does not modify the Operator installation, so you need to set both via the Helm values of the Operator. Azure generates the client ID when it creates the managed identity, so it is only known once the identity exists.

Use the `operator_serviceaccount_annotations` and `operator_pod_labels` outputs of the module in the Helm values of the existing Operator installation:

```hcl
locals {
  humanitec_operator_helm_values = {
    controllerManager = {
      serviceAccount = {
        annotations = module.my_azurekv_secret_store.operator_serviceaccount_annotations
      }
      podLabels = module.my_azurekv_secret_store.operator_pod_labels
    }
  }
}
```

This corresponds to these Helm values:

```yaml
controllerManager:
  serviceAccount:
    annotations:
      azure.workload.identity/client-id: <client ID of the managed identity>
  podLabels:
    azure.workload.identity/use: "true"
```

Then restart the Operator to pick up the managed identity:

```shell
kubectl rollout restart deployment -n humanitec-operator-system humanitec-operator-controller-manager
```

To set the Helm values when you first install the Operator instead, create the managed identity before the Operator and [bring your own managed identity](#bring-your-own-managed-identity).

> [!IMPORTANT]
> The Operator uses exactly one managed identity: the one whose client ID is annotated on its service account. All secret stores on the cluster that use Workload Identity therefore share that managed identity, and its single federated identity credential for the Operator service account. Let at most one instance of the module create the managed identity and the federated identity credential, and pass the managed identity in to all other instances with `managed_identity_create = false` and `federated_identity_credential_create = false`. See [Non-default secret store](#non-default-secret-store) and [Several Environment-local secret stores](#several-environment-local-secret-stores).
>
> This does not apply to `auth_method = "service_principal"`, where each secret store references its own credentials.

### Non-default secret store

Set `secret_store_default` to `false` to create a cluster-wide secret store that is not the default store, e.g. if you already have a default store. The Operator gets read-only access to this store.

This configuration adds a non-default secret store for a second Key Vault next to the [default secret store](#common-usage-default-secret-store-with-workload-identity) created by another instance of the module. As the [Operator uses only one managed identity](#configure-the-operator-for-workload-identity), it reuses the managed identity and federated identity credential of the default store, and only grants the managed identity access to the second Key Vault.

```hcl
module "my_other_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }

  secret_store_id      = "my-other-azurekv"
  secret_store_default = false
  key_vault_id         = azurerm_key_vault.my_other_key_vault.id

  managed_identity_create              = false
  managed_identity_id                  = module.my_azurekv_secret_store.managed_identity_id
  federated_identity_credential_create = false
}
```

### Environment-local secret store

This configuration creates a secret store in the namespace of an Environment, so that only Deployments into that namespace can use it. An Environment-local secret store cannot be the default store, so `secret_store_default` must be set to `false`. The Operator gets read-only access to this store.

```hcl
module "my_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }

  secret_store_id           = "my-azurekv"
  secret_store_default      = false
  secret_store_cluster_wide = false
  secret_store_namespace    = "my-app-development"
  key_vault_id              = azurerm_key_vault.my_key_vault.id
  aks_oidc_issuer_url       = azurerm_kubernetes_cluster.my_aks_cluster.oidc_issuer_url
}
```

The managed identity and the federated identity credential are still created for the Operator service account in the Operator namespace, as the Operator reads the secrets on behalf of the Environment. This only works if it is the only secret store using Workload Identity on the cluster, as the [Operator uses only one managed identity](#configure-the-operator-for-workload-identity). Otherwise, pass in the managed identity of the Operator as shown in [Several Environment-local secret stores](#several-environment-local-secret-stores).

### Several Environment-local secret stores

This configuration creates one Environment-local secret store per Environment namespace. As the [Operator uses only one managed identity](#configure-the-operator-for-workload-identity), all secret stores necessarily share it, as well as its federated identity credential. Azure allows only one federated identity credential with the same issuer and subject on a managed identity, and the subject is always the Operator service account. So pass in the managed identity, and set `federated_identity_credential_create` to `false`.

Whether the Environment-local stores need to grant the managed identity access to the Key Vault depends on which Key Vault they use. If the Environment-local stores use service principals instead of Workload Identity, none of this applies, see [With service principals](#with-service-principals).

#### Same Key Vault as the default secret store

In this setup the instance of the module creating the [default secret store](#common-usage-default-secret-store-with-workload-identity) also creates the managed identity and its federated identity credential, and grants it read/write access to the Key Vault. The read-only access needed by the Environment-local stores is included in that access, so set `key_vault_access_create` to `false` for them. Granting it again would fail anyway, as Azure allows only one role assignment of the same role to the same identity on the same Key Vault, and only one access policy per identity on a Key Vault.

The access then belongs to the default store, which also owns the managed identity, so removing an Environment-local store does not revoke the access of the others. This works the same for both permission models of the Key Vault.

```hcl
locals {
  environment_namespaces = toset(["my-app-development", "my-app-staging"])
}

# Default secret store, creating the managed identity of the Operator
module "my_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }

  secret_store_id     = "my-azurekv"
  key_vault_id        = azurerm_key_vault.my_key_vault.id
  aks_oidc_issuer_url = azurerm_kubernetes_cluster.my_aks_cluster.oidc_issuer_url
}

# Environment-local secret stores, using the managed identity and the Key Vault access of the default store
module "my_environment_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }
  for_each = local.environment_namespaces

  secret_store_id           = "my-azurekv-${each.key}"
  secret_store_default      = false
  secret_store_cluster_wide = false
  secret_store_namespace    = each.key
  key_vault_id              = azurerm_key_vault.my_key_vault.id

  managed_identity_create              = false
  managed_identity_id                  = module.my_azurekv_secret_store.managed_identity_id
  federated_identity_credential_create = false
  key_vault_access_create              = false
}
```

Then [configure the Operator for Workload Identity](#configure-the-operator-for-workload-identity) using the outputs of the default store.

#### One Key Vault per Environment

If each Environment-local store uses its own Key Vault, no other secret store uses the access to it. Let each instance of the module grant the managed identity read-only access to its Key Vault, i.e. leave `key_vault_access_create` at `true`. The managed identity and its federated identity credential are still shared, though, as the [Operator uses only one managed identity](#configure-the-operator-for-workload-identity).

This example uses the managed identity created by the module instance of the [default secret store](#same-key-vault-as-the-default-secret-store). If there is no default secret store using Workload Identity, create the managed identity and its federated identity credential yourself as shown in [One Key Vault shared by the Environments](#one-key-vault-shared-by-the-environments).

```hcl
locals {
  environment_namespaces = toset(["my-app-development", "my-app-staging"])
}

# One Key Vault per Environment
resource "azurerm_key_vault" "environment" {
  for_each = local.environment_namespaces

  # ...
}

module "my_environment_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }
  for_each = local.environment_namespaces

  secret_store_id           = "my-azurekv-${each.key}"
  secret_store_default      = false
  secret_store_cluster_wide = false
  secret_store_namespace    = each.key
  key_vault_id              = azurerm_key_vault.environment[each.key].id

  # Use the managed identity of the default secret store
  managed_identity_create              = false
  managed_identity_id                  = module.my_azurekv_secret_store.managed_identity_id
  federated_identity_credential_create = false
}
```

#### One Key Vault shared by the Environments

If all Environment-local stores share one Key Vault other than that of the default store, grant the managed identity read-only access to it once outside of the module, and set `key_vault_access_create` to `false` for the Environment-local stores. Granting it in each instance of the module would fail, as Azure allows only one role assignment of the same role to the same identity on the same Key Vault, and only one access policy per identity on a Key Vault. Creating the access outside of the module also ensures that removing one secret store does not revoke the access of the others. The `key_vault_role_definition_name` output (Azure RBAC) or `key_vault_secret_permissions` output (access policy) of the module names the access to grant.

This example also creates the managed identity and its federated identity credential itself, e.g. because there is no default secret store using Workload Identity.

```hcl
locals {
  environment_namespaces = toset(["my-app-development", "my-app-staging"])
}

# If the module instance of the default secret store creates the managed identity,
# omit this resource and the federated identity credential below.
resource "azurerm_user_assigned_identity" "humanitec_operator" {
  name                = "humanitec-operator"
  resource_group_name = azurerm_resource_group.my_aks_rg.name
  location            = azurerm_resource_group.my_aks_rg.location
}

# Set controllerManager.serviceAccount.annotations."azure.workload.identity/client-id" to
# azurerm_user_assigned_identity.humanitec_operator.client_id, and
# controllerManager.podLabels."azure.workload.identity/use" to "true"
# in the Helm values of the Operator installation.

resource "azurerm_federated_identity_credential" "humanitec_operator" {
  name                      = "humanitec-operator"
  user_assigned_identity_id = azurerm_user_assigned_identity.humanitec_operator.id
  issuer                    = azurerm_kubernetes_cluster.my_aks_cluster.oidc_issuer_url
  subject                   = "system:serviceaccount:humanitec-operator-system:humanitec-operator-controller-manager"
  audience                  = ["api://AzureADTokenExchange"]
}

# With the access policy permission model, create an azurerm_key_vault_access_policy
# with the secret permission "Get" instead.
resource "azurerm_role_assignment" "humanitec_operator" {
  scope                = azurerm_key_vault.my_environment_key_vault.id
  role_definition_name = "Key Vault Secrets User"
  # Or the managed_identity_principal_id output of the default secret store
  principal_id   = azurerm_user_assigned_identity.humanitec_operator.principal_id
  principal_type = "ServicePrincipal"
}

module "my_environment_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }
  for_each = local.environment_namespaces

  secret_store_id           = "my-azurekv-${each.key}"
  secret_store_default      = false
  secret_store_cluster_wide = false
  secret_store_namespace    = each.key
  key_vault_id              = azurerm_key_vault.my_environment_key_vault.id

  managed_identity_create = false
  # Or the managed_identity_id output of the default secret store
  managed_identity_id                  = azurerm_user_assigned_identity.humanitec_operator.id
  federated_identity_credential_create = false
  key_vault_access_create              = false
}
```

#### With service principals

With `auth_method = "service_principal"`, each secret store references its own credentials, so the Environment-local stores do not share an identity. Each instance of the module creates a dedicated service principal and client secret, a Kubernetes Secret holding them in the Environment namespace, and the access of the service principal to the Key Vault. The role assignments or access policies of different service principals do not conflict, so this works for any combination of Key Vaults, and removing one secret store only revokes the access of its own service principal. All inputs about the managed identity, the federated identity credential, and the Key Vault access can keep their defaults.

The secret stores may use the same Key Vault as a default secret store using Workload Identity, as in this example, or any other Key Vault.

```hcl
locals {
  environment_namespaces = toset(["my-app-development", "my-app-staging"])
}

module "my_environment_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }
  for_each = local.environment_namespaces

  secret_store_id           = "my-azurekv-${each.key}"
  secret_store_default      = false
  secret_store_cluster_wide = false
  secret_store_namespace    = each.key
  key_vault_id              = azurerm_key_vault.my_key_vault.id

  auth_method = "service_principal"
}
```

> [!WARNING]
> The Kubernetes Secret holding the client ID and secret is located in the Environment namespace. Anyone who can read Secrets in that namespace can use the service principal, and thus read the secrets in the Key Vault of the secret store. Using a dedicated service principal per secret store limits this to one secret store. The client secret is also stored in the OpenTofu/Terraform state, see [Use a service principal with static credentials](#use-a-service-principal-with-static-credentials).

### Key Vault with the access policy permission model

If your Key Vault uses the legacy access policy permission model instead of Azure RBAC, set `key_vault_rbac_authorization_enabled` to `false`. The module then grants the Operator access via an access policy instead of a role assignment.

```hcl
module "my_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }

  secret_store_id     = "my-azurekv"
  key_vault_id        = azurerm_key_vault.my_key_vault.id
  aks_oidc_issuer_url = azurerm_kubernetes_cluster.my_aks_cluster.oidc_issuer_url

  key_vault_rbac_authorization_enabled = false
}
```

### Customize the managed identity

This configuration creates the default secret store, and customizes the name, resource group, region, and tags of the managed identity, as well as the name of the federated identity credential.

```hcl
module "my_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }

  secret_store_id     = "my-azurekv"
  key_vault_id        = azurerm_key_vault.my_key_vault.id
  aks_oidc_issuer_url = azurerm_kubernetes_cluster.my_aks_cluster.oidc_issuer_url

  managed_identity_name                = "humanitec-operator-my-azurekv"
  managed_identity_resource_group_name = azurerm_resource_group.my_aks_rg.name
  managed_identity_location            = "westeurope"
  managed_identity_tags = {
    "tag1" = "value1"
  }
  federated_identity_credential_name = "humanitec-operator"
}
```

### Bring your own managed identity

This configuration creates the default secret store, using your own user-assigned managed identity for the Operator. The module creates the federated identity credential on it, and grants it access to the Key Vault.

Creating the managed identity yourself lets you set the client ID annotation when you first install the Operator, before the module runs. Once the module has created the federated identity credential and the role assignment, the Operator can use the managed identity without any further changes.

```hcl
resource "azurerm_user_assigned_identity" "humanitec_operator" {
  name                = "humanitec-operator"
  resource_group_name = azurerm_resource_group.my_aks_rg.name
  location            = azurerm_resource_group.my_aks_rg.location
}

# Set controllerManager.serviceAccount.annotations."azure.workload.identity/client-id" to
# azurerm_user_assigned_identity.humanitec_operator.client_id, and
# controllerManager.podLabels."azure.workload.identity/use" to "true"
# in the Helm values of the Operator installation.

module "my_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }

  secret_store_id     = "my-azurekv"
  key_vault_id        = azurerm_key_vault.my_key_vault.id
  aks_oidc_issuer_url = azurerm_kubernetes_cluster.my_aks_cluster.oidc_issuer_url

  managed_identity_create = false
  managed_identity_id     = azurerm_user_assigned_identity.humanitec_operator.id
}
```

### Manage the federated identity credential yourself

This configuration creates the default secret store and the managed identity, but not the federated identity credential. Use the `managed_identity_id` and `federated_identity_credential` outputs of the present module to configure the federated identity credential yourself. `aks_oidc_issuer_url` is optional in this case.

```hcl
module "my_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }

  secret_store_id = "my-azurekv"
  key_vault_id    = azurerm_key_vault.my_key_vault.id

  federated_identity_credential_create = false
}
```

### Use a service principal with static credentials

This configuration creates the default secret store, as well as a Microsoft Entra ID application, service principal, and client secret for the Operator. It stores the client ID and secret in a Kubernetes Secret referenced by the secret store. Using a service principal requires you to maintain static credentials, so prefer Workload Identity where possible.

```hcl
module "my_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }

  secret_store_id = "my-azurekv"
  key_vault_id    = azurerm_key_vault.my_key_vault.id

  auth_method = "service_principal"

  # Optional: set owners (default: the identity of the azuread provider) and the expiry of the client secret
  service_principal_owners                 = [data.azuread_client_config.current.object_id, data.azuread_user.platform_admin.object_id]
  service_principal_client_secret_end_date = "2027-12-31T23:59:59Z"
}
```

The application and service principal are owned by the identity of the `azuread` provider unless you set `service_principal_owners`. If you set it, include that identity if it relies on ownership to manage the application, e.g. because it only has the `Application.ReadWrite.OwnedBy` permission.

The client secret expires after two years unless you set `service_principal_client_secret_end_date`. Changing the end date replaces the client secret, and the module updates the Kubernetes Secret accordingly.

> [!WARNING]
> If the module creates the service principal, the client secret is stored in the OpenTofu/Terraform state as part of the `azuread_application_password` resource. Make sure your state is stored securely, or [bring your own service principal](#bring-your-own-service-principal) to keep the secret out of the state.

### Bring your own service principal

This configuration creates the default secret store, using your own service principal and client secret for the Operator. The module grants the service principal access to the Key Vault, and stores the client ID and secret in a Kubernetes Secret referenced by the secret store. The service principal must be located in the tenant of the Key Vault.

The client secret is not stored in the state or plan: `service_principal_client_secret` is an ephemeral variable, and the module only writes the secret to the write-only `data_wo` attribute of the Kubernetes Secret. To keep the secret out of your own state as well, read it from an ephemeral source, e.g. a secret in another Azure Key Vault:

```hcl
ephemeral "azurerm_key_vault_secret" "operator_client_secret" {
  name         = "humanitec-operator-client-secret"
  key_vault_id = azurerm_key_vault.my_admin_key_vault.id
}

module "my_azurekv_secret_store" {
  source = "github.com/humanitec-tf-modules/secret-store-azurekv?ref=vX.Y.Z"
  providers = {
    azurerm    = azurerm
    azuread    = azuread
    kubernetes = kubernetes
  }

  secret_store_id = "my-azurekv"
  key_vault_id    = azurerm_key_vault.my_key_vault.id

  auth_method                             = "service_principal"
  service_principal_create                = false
  service_principal_client_id             = "00000000-0000-0000-0000-000000000000"
  service_principal_client_secret         = ephemeral.azurerm_key_vault_secret.operator_client_secret.value
  service_principal_client_secret_version = 1
}
```

The client ID must not be ephemeral, as the module keeps it in the state to detect changes of the write-only credentials. When you rotate the client secret, pass in the new secret and increase `service_principal_client_secret_version`. The new version makes the module replace the Kubernetes Secret with the new credentials. Changing only the client secret does not update the Kubernetes Secret.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11.0 |
| <a name="requirement_azuread"></a> [azuread](#requirement\_azuread) | ~> 3 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | >= 4.65.0, < 5.0.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [azuread_application.operator](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/application) | resource |
| [azuread_application_password.operator](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/application_password) | resource |
| [azuread_service_principal.operator](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/resources/service_principal) | resource |
| [azurerm_federated_identity_credential.operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential) | resource |
| [azurerm_key_vault_access_policy.operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_access_policy) | resource |
| [azurerm_role_assignment.operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment) | resource |
| [azurerm_user_assigned_identity.operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity) | resource |
| [kubernetes_manifest.secret_store](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/manifest) | resource |
| [kubernetes_secret_v1.operator_credentials](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret_v1) | resource |
| [random_string.identity_name_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [random_string.secret_store_id_suffix](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string) | resource |
| [terraform_data.service_principal_credentials_version](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [azuread_client_config.current](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/data-sources/client_config) | data source |
| [azuread_service_principal.operator](https://registry.terraform.io/providers/hashicorp/azuread/latest/docs/data-sources/service_principal) | data source |
| [azurerm_client_config.current](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/client_config) | data source |
| [azurerm_key_vault.secret_store](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/key_vault) | data source |
| [azurerm_user_assigned_identity.operator](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/user_assigned_identity) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aks_oidc_issuer_url"></a> [aks\_oidc\_issuer\_url](#input\_aks\_oidc\_issuer\_url) | URL of the OIDC issuer of the AKS cluster hosting the Operator, e.g. the `oidc_issuer_url` attribute of an `azurerm_kubernetes_cluster`. The cluster must have the OIDC issuer and Workload Identity enabled. Required if `auth_method` is `workload_identity` and `federated_identity_credential_create` is `true`. Optional otherwise: if set, it is included in the `federated_identity_credential` output. Must not be set if `auth_method` is `service_principal`. | `string` | `null` | no |
| <a name="input_auth_method"></a> [auth\_method](#input\_auth\_method) | How the Operator authenticates against Azure Key Vault. `workload_identity` (recommended): the Operator uses a user-assigned managed identity via Microsoft Entra Workload ID. `service_principal`: the Operator uses static credentials of a service principal, stored in a Kubernetes Secret. | `string` | `"workload_identity"` | no |
| <a name="input_federated_identity_credential_create"></a> [federated\_identity\_credential\_create](#input\_federated\_identity\_credential\_create) | Whether to create the federated identity credential on the managed identity, allowing the Operator service account to use it via Workload Identity. Only used if `auth_method` is `workload_identity`. Set to `false` if you manage the federated identity credential yourself, e.g. because an existing managed identity already has one for the Operator service account. Use the `federated_identity_credential` output to configure it. | `bool` | `true` | no |
| <a name="input_federated_identity_credential_name"></a> [federated\_identity\_credential\_name](#input\_federated\_identity\_credential\_name) | Name of the federated identity credential to create on the managed identity. Only used if `auth_method` is `workload_identity` and `federated_identity_credential_create` is `true`. If not set, the name is `humanitec-operator-<secret store ID>`. | `string` | `null` | no |
| <a name="input_key_vault_access_create"></a> [key\_vault\_access\_create](#input\_key\_vault\_access\_create) | Whether to grant the Operator identity access to the Key Vault, via a role assignment or an access policy depending on `key_vault_rbac_authorization_enabled`. Set it to `false` if the identity already has access, e.g. if several secret stores share one identity: Azure allows only one role assignment per identity, role, and Key Vault, and only one access policy per identity and Key Vault. Grant the access yourself in that case, using the `key_vault_role_definition_name` or `key_vault_secret_permissions` output. | `bool` | `true` | no |
| <a name="input_key_vault_id"></a> [key\_vault\_id](#input\_key\_vault\_id) | Resource ID of the Azure Key Vault, e.g. `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.KeyVault/vaults/my-key-vault`. It must be located in the subscription of the `azurerm` provider that is passed in to the module. The module reads the URL and tenant ID of the secret store from the Key Vault. | `string` | n/a | yes |
| <a name="input_key_vault_rbac_authorization_enabled"></a> [key\_vault\_rbac\_authorization\_enabled](#input\_key\_vault\_rbac\_authorization\_enabled) | Whether the Key Vault uses the Azure RBAC permission model (recommended). If `true`, the module grants the Operator access via an Azure role assignment, using the built-in role `Key Vault Secrets Officer` for the default store, and `Key Vault Secrets User` otherwise. If `false`, the Key Vault uses the legacy access policy permission model, and the module grants the Operator access via an access policy. It must match the permission model of the Key Vault, which the module verifies. | `bool` | `true` | no |
| <a name="input_managed_identity_create"></a> [managed\_identity\_create](#input\_managed\_identity\_create) | Whether to create the user-assigned managed identity used by the Operator. Only used if `auth_method` is `workload_identity`. If `false`, `managed_identity_id` must be the ID of an existing user-assigned managed identity. The Operator uses only one managed identity for all secret stores using Workload Identity, so set it to `false` if the Operator already uses a managed identity, e.g. one created by another instance of the module. | `bool` | `true` | no |
| <a name="input_managed_identity_id"></a> [managed\_identity\_id](#input\_managed\_identity\_id) | Resource ID of an existing user-assigned managed identity to be used by the Operator, e.g. `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/my-identity`. It must be located in the subscription of the `azurerm` provider that is passed in to the module. Required if `auth_method` is `workload_identity` and `managed_identity_create` is `false`, must not be set otherwise. | `string` | `null` | no |
| <a name="input_managed_identity_location"></a> [managed\_identity\_location](#input\_managed\_identity\_location) | Azure region in which to create the user-assigned managed identity for the Operator, e.g. `westeurope`. If not set, the region of the Key Vault is used. Only used if `auth_method` is `workload_identity` and `managed_identity_create` is `true`. | `string` | `null` | no |
| <a name="input_managed_identity_name"></a> [managed\_identity\_name](#input\_managed\_identity\_name) | Name of the user-assigned managed identity to create for the Operator. Only used if `auth_method` is `workload_identity` and `managed_identity_create` is `true`. If not set, the module generates a name from the secret store ID and a random four-letter suffix. | `string` | `null` | no |
| <a name="input_managed_identity_resource_group_name"></a> [managed\_identity\_resource\_group\_name](#input\_managed\_identity\_resource\_group\_name) | Name of the resource group in which to create the user-assigned managed identity for the Operator. The resource group must exist. If not set, the resource group of the Key Vault is used. Only used if `auth_method` is `workload_identity` and `managed_identity_create` is `true`. | `string` | `null` | no |
| <a name="input_managed_identity_tags"></a> [managed\_identity\_tags](#input\_managed\_identity\_tags) | Tags to assign to the user-assigned managed identity created by the module. Only used if `auth_method` is `workload_identity` and `managed_identity_create` is `true`. | `map(string)` | `null` | no |
| <a name="input_operator_namespace"></a> [operator\_namespace](#input\_operator\_namespace) | Name of the Kubernetes namespace of the Humanitec Operator. | `string` | `"humanitec-operator-system"` | no |
| <a name="input_operator_serviceaccount"></a> [operator\_serviceaccount](#input\_operator\_serviceaccount) | Name of the Kubernetes service account of the Humanitec Operator. Used as the subject of the federated identity credential if `auth_method` is `workload_identity`. | `string` | `"humanitec-operator-controller-manager"` | no |
| <a name="input_secret_store_cluster_wide"></a> [secret\_store\_cluster\_wide](#input\_secret\_store\_cluster\_wide) | Whether the secret store is cluster-wide, i.e. usable by all Deployments onto the cluster. A cluster-wide store is created in the `operator_namespace`. If `false`, the store is Environment-local and created in `secret_store_namespace`, so it can only be used by Deployments into that namespace. | `bool` | `true` | no |
| <a name="input_secret_store_default"></a> [secret\_store\_default](#input\_secret\_store\_default) | Whether the secret store is the default secret store of the Operator. Only a cluster-wide secret store can be the default store, so set it to `false` for an Environment-local store. The Operator gets read/write access to the default store, and read-only access to any other store. | `bool` | `true` | no |
| <a name="input_secret_store_id"></a> [secret\_store\_id](#input\_secret\_store\_id) | ID of the secret store. It is the name of the Kubernetes `SecretStore` resource and the `store` value used in secret references. If you also register the secret store with the Platform Orchestrator, use the same ID there. If not set, the module generates an ID in the pattern `azurekv-<random>`, with `<random>` being a random string of four lowercase letters, e.g. `azurekv-kxqp`. Use the `secret_store_id` output to read it. | `string` | `null` | no |
| <a name="input_secret_store_namespace"></a> [secret\_store\_namespace](#input\_secret\_store\_namespace) | Name of the Kubernetes namespace of the Environment for an Environment-local secret store. Required if `secret_store_cluster_wide` is `false`, must not be set otherwise. The namespace must exist. | `string` | `null` | no |
| <a name="input_service_principal_client_id"></a> [service\_principal\_client\_id](#input\_service\_principal\_client\_id) | Client (application) ID of an existing service principal to be used by the Operator. It must be located in the tenant of the Key Vault. Required if `auth_method` is `service_principal` and `service_principal_create` is `false`, must not be set otherwise. | `string` | `null` | no |
| <a name="input_service_principal_client_secret"></a> [service\_principal\_client\_secret](#input\_service\_principal\_client\_secret) | Client secret of the existing service principal passed in via `service_principal_client_id`. Required if `auth_method` is `service_principal` and `service_principal_create` is `false`, must be empty otherwise. The variable is ephemeral, so the value can come from an ephemeral source. It is not stored in the state or plan, as the module only writes it to a write-only attribute of the Kubernetes Secret. The Kubernetes Secret is only updated if `service_principal_client_id` or `service_principal_client_secret_version` changes as well. | `string` | `""` | no |
| <a name="input_service_principal_client_secret_end_date"></a> [service\_principal\_client\_secret\_end\_date](#input\_service\_principal\_client\_secret\_end\_date) | End date of the client secret created for the Operator, in RFC3339 format, e.g. `2027-01-01T00:00:00Z`. If not set, the client secret expires after two years. Only used if `auth_method` is `service_principal` and `service_principal_create` is `true`. Changing it replaces the client secret, and the module updates the Kubernetes Secret accordingly. | `string` | `null` | no |
| <a name="input_service_principal_client_secret_version"></a> [service\_principal\_client\_secret\_version](#input\_service\_principal\_client\_secret\_version) | Version of the client secret passed in via `service_principal_client_secret`. The module keeps it in the state to detect changes of the write-only client secret. Increase it whenever you pass in a new client secret, e.g. when rotating it, to make the module replace the Kubernetes Secret holding the credentials. Only used if `auth_method` is `service_principal` and `service_principal_create` is `false`. | `number` | `null` | no |
| <a name="input_service_principal_create"></a> [service\_principal\_create](#input\_service\_principal\_create) | Whether to create the Microsoft Entra ID application, service principal, and client secret used by the Operator. Only used if `auth_method` is `service_principal`. If `true`, the client secret is stored in the OpenTofu/Terraform state as part of the `azuread_application_password` resource. If `false`, `service_principal_client_id` and `service_principal_client_secret` must be set for an existing service principal, and the client secret is not stored in the state. | `bool` | `true` | no |
| <a name="input_service_principal_credentials_secret_name"></a> [service\_principal\_credentials\_secret\_name](#input\_service\_principal\_credentials\_secret\_name) | Name of the Kubernetes Secret holding the client ID and client secret of the service principal. It is created in the namespace of the secret store. The credentials are written to the Secret via a write-only attribute, so the Secret does not add them to the state. Only used if `auth_method` is `service_principal`. If not set, the name is `<secret store ID>-credentials`. | `string` | `null` | no |
| <a name="input_service_principal_name"></a> [service\_principal\_name](#input\_service\_principal\_name) | Display name of the Microsoft Entra ID application and service principal to create for the Operator. Only used if `auth_method` is `service_principal` and `service_principal_create` is `true`. If not set, the module generates a name from the secret store ID and a random four-letter suffix. | `string` | `null` | no |
| <a name="input_service_principal_owners"></a> [service\_principal\_owners](#input\_service\_principal\_owners) | Object IDs of the owners of the Microsoft Entra ID application and service principal created for the Operator. Only used if `auth_method` is `service_principal` and `service_principal_create` is `true`. If not set, the owner is the identity the `azuread` provider authenticates as. If you set it, include that identity if it needs ownership to manage the application, e.g. because it only has the `Application.ReadWrite.OwnedBy` permission. An empty set means no owners. | `set(string)` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_federated_identity_credential"></a> [federated\_identity\_credential](#output\_federated\_identity\_credential) | Issuer, subject, and audience of the federated identity credential allowing the Operator service account to use the managed identity. If `federated_identity_credential_create` is `false`, configure a federated identity credential with these values on the managed identity yourself. The issuer is `null` if `aks_oidc_issuer_url` is not set. Returns `null` if `auth_method` is not `workload_identity`. |
| <a name="output_federated_identity_credential_id"></a> [federated\_identity\_credential\_id](#output\_federated\_identity\_credential\_id) | ID of the federated identity credential created by the module. Returns `null` if `auth_method` is not `workload_identity` or `federated_identity_credential_create` is `false`. |
| <a name="output_key_vault_access_policy_id"></a> [key\_vault\_access\_policy\_id](#output\_key\_vault\_access\_policy\_id) | ID of the Key Vault access policy granting the Operator access to the Key Vault. Returns `null` if `key_vault_access_create` is `false` or `key_vault_rbac_authorization_enabled` is `true`. |
| <a name="output_key_vault_role_assignment_id"></a> [key\_vault\_role\_assignment\_id](#output\_key\_vault\_role\_assignment\_id) | ID of the Azure role assignment granting the Operator access to the Key Vault. Returns `null` if `key_vault_access_create` or `key_vault_rbac_authorization_enabled` is `false`. |
| <a name="output_key_vault_role_definition_name"></a> [key\_vault\_role\_definition\_name](#output\_key\_vault\_role\_definition\_name) | Name of the built-in Azure role the Operator identity needs on the Key Vault: `Key Vault Secrets Officer` for the default store, `Key Vault Secrets User` otherwise. If `key_vault_access_create` is `false`, assign this role to the identity yourself. Returns `null` if `key_vault_rbac_authorization_enabled` is `false`. |
| <a name="output_key_vault_secret_permissions"></a> [key\_vault\_secret\_permissions](#output\_key\_vault\_secret\_permissions) | Secret permissions the Operator identity needs in a Key Vault access policy: `Get`, `Set`, `Delete`, and `Recover` for the default store, `Get` otherwise. If `key_vault_access_create` is `false`, create an access policy with these permissions for the identity yourself. Returns `null` if `key_vault_rbac_authorization_enabled` is `true`. |
| <a name="output_key_vault_tenant_id"></a> [key\_vault\_tenant\_id](#output\_key\_vault\_tenant\_id) | ID of the Microsoft Entra ID tenant of the Azure Key Vault, used as the `tenantID` of the secret store. |
| <a name="output_key_vault_uri"></a> [key\_vault\_uri](#output\_key\_vault\_uri) | URI of the Azure Key Vault, used as the `url` of the secret store. |
| <a name="output_managed_identity_client_id"></a> [managed\_identity\_client\_id](#output\_managed\_identity\_client\_id) | Client ID of the user-assigned managed identity used by the Operator. Returns `null` if `auth_method` is `service_principal`. |
| <a name="output_managed_identity_id"></a> [managed\_identity\_id](#output\_managed\_identity\_id) | Resource ID of the user-assigned managed identity used by the Operator. Returns `null` if `auth_method` is `service_principal`. |
| <a name="output_managed_identity_name"></a> [managed\_identity\_name](#output\_managed\_identity\_name) | Name of the user-assigned managed identity used by the Operator. Returns `null` if `auth_method` is `service_principal`. |
| <a name="output_managed_identity_principal_id"></a> [managed\_identity\_principal\_id](#output\_managed\_identity\_principal\_id) | Object (principal) ID of the user-assigned managed identity used by the Operator. Returns `null` if `auth_method` is `service_principal`. |
| <a name="output_operator_client_id"></a> [operator\_client\_id](#output\_operator\_client\_id) | Client ID of the managed identity or service principal used by the Operator, depending on `auth_method`. |
| <a name="output_operator_pod_labels"></a> [operator\_pod\_labels](#output\_operator\_pod\_labels) | Labels to set on the Operator Pod so that it uses Workload Identity, e.g. via the `controllerManager.podLabels` value of the Operator Helm chart. Returns an empty map if `auth_method` is not `workload_identity`. |
| <a name="output_operator_principal_id"></a> [operator\_principal\_id](#output\_operator\_principal\_id) | Object (principal) ID of the managed identity or service principal used by the Operator, depending on `auth_method`. Use it to grant the Operator access to further Azure resources. |
| <a name="output_operator_serviceaccount_annotations"></a> [operator\_serviceaccount\_annotations](#output\_operator\_serviceaccount\_annotations) | Annotations to set on the Operator service account so that it uses the managed identity via Workload Identity, e.g. via the `controllerManager.serviceAccount.annotations` value of the Operator Helm chart. Restart the Operator after changing them. Returns an empty map if `auth_method` is not `workload_identity`. |
| <a name="output_secret_store_id"></a> [secret\_store\_id](#output\_secret\_store\_id) | ID of the secret store, i.e. the name of the Kubernetes `SecretStore` resource. This is either `secret_store_id` or the generated ID. Use it as the `store` in secret references. |
| <a name="output_secret_store_namespace"></a> [secret\_store\_namespace](#output\_secret\_store\_namespace) | Name of the Kubernetes namespace of the `SecretStore` resource. This is the Operator namespace for a cluster-wide store, or the Environment namespace for an Environment-local store. |
| <a name="output_service_principal_client_id"></a> [service\_principal\_client\_id](#output\_service\_principal\_client\_id) | Client (application) ID of the service principal used by the Operator. Returns `null` if `auth_method` is not `service_principal`. |
| <a name="output_service_principal_credentials_secret_name"></a> [service\_principal\_credentials\_secret\_name](#output\_service\_principal\_credentials\_secret\_name) | Name of the Kubernetes Secret holding the client ID and client secret of the service principal, located in the `secret_store_namespace`. Returns `null` if `auth_method` is not `service_principal`. |
| <a name="output_service_principal_name"></a> [service\_principal\_name](#output\_service\_principal\_name) | Display name of the service principal used by the Operator. Returns `null` if `auth_method` is not `service_principal`. |
| <a name="output_service_principal_object_id"></a> [service\_principal\_object\_id](#output\_service\_principal\_object\_id) | Object ID of the service principal used by the Operator. Returns `null` if `auth_method` is not `service_principal`. |
<!-- END_TF_DOCS -->
