# rhbk-gitops

Déploiement GitOps (OpenShift GitOps / ArgoCD) de Red Hat build of Keycloak 26.6, environnements **prod** et **dev**.

> Guide pas à pas pour reconstruire ce dépôt et le déployer : [docs/deploiement-gitops.md](docs/deploiement-gitops.md)

## Arborescence

```
bootstrap/root-app.yaml        App of apps, appliquée une seule fois à la main
argocd/                        Géré par rhbk-root : AppProject + Applications
  appproject.yaml              Projet "rhbk" (namespaces rhbk et rhbk-dev)
  applications/rhbk-prod.yaml  overlays/prod -> namespace rhbk      (sync manuelle)
  applications/rhbk-dev.yaml   overlays/dev  -> namespace rhbk-dev  (sync auto, prune, selfHeal)
base/
  keycloak/                    CR Keycloak, Service interne, RBAC routeur, Routes
overlays/
  prod/ dev/                   Namespace, nom d'instance, hostnames, ressources
    external-secrets/          ExternalSecrets : secrets lus dans Vault via ESO
custom-rhbk/Containerfile      Image Keycloak optimisée (quay.io/msakho0/mskeycloak)
tools/postgresql/              Hors ArgoCD : base PostgreSQL d'un environnement (guide, annexe B)
```

| | prod | dev |
|---|---|---|
| Namespace | `rhbk` | `rhbk-dev` |
| Instance Keycloak | `rhbk-prod` | `rhbk-dev` |
| Hostname public | `prod-rhbk.apps.cluster-nnljw…` | `dev-rhbk.apps.cluster-nnljw…` |
| Hostname admin | `prod-rhbk-admin.apps.cluster-nnljw…` | `dev-rhbk-admin.apps.cluster-nnljw…` |
| Ressources (req / limit) | 2 CPU, 1250M / 2 CPU, 2250M | 500m, 1G / 1 CPU, 1500M |
| Sync ArgoCD | manuelle | automatique |

### Ordre de synchronisation (sync-waves)

| Wave | Ressources |
|---|---|
| 0 | Service `rhbk-internal` (certificat service-ca), Role/RoleBinding du routeur |
| 1 | CR Keycloak |
| 2 | Routes |

## Exposition et isolation de la console admin

Les routes sont en **reencrypt** : le routeur présente le certificat Let's Encrypt (`rhbk-tls-secret`, via
`spec.tls.externalCertificate`) et rechiffre vers Keycloak, qui sert un certificat généré par le service-ca
(`rhbk-internal-tls`). Le routeur lit le chemin HTTP :

- hostname public : seuls `/realms` et `/resources` sont routés, tout le reste (`/admin`, `/`, …) renvoie 503 ;
- hostname admin : tous les chemins.

L'Ingress de l'opérateur est désactivé (`ingress.enabled: false`).

## Prérequis (plateforme)

Les namespaces, l'opérateur RHBK (un par namespace, canal `stable-v26.6`), External Secrets Operator, Vault et le
`ClusterSecretStore vault-store` sont gérés par les administrateurs dans le dépôt GitOps
[`rhbk-platform`](https://github.com/msakho/rhbk-platform). Ce dépôt-ci n'a **aucun droit au niveau cluster**.

Restent à faire à la main, par environnement :

1. **Certificat** couvrant les hostnames de l'environnement (guide, annexe C).
2. **Valeurs dans Vault** sous `secret/rhbk/<env>/` : `db`, `bootstrap-admin`, `tls` (guide, annexe A.7).
3. **Base PostgreSQL** `postgres-db` : manifestes `tools/postgresql/`, identifiants lus dans Vault (guide, annexe B).

## Secrets

Aucun secret n'est dans git. Les `ExternalSecret` de `overlays/<env>/external-secrets/` font créer par ESO,
depuis Vault, les Secrets `rhbk-db-secret`, `initial-admin-secret` et `rhbk-tls-secret`.

Après un redémarrage du cluster, Vault est scellé : le desceller, depuis le dossier local du dépôt
`rhbk-platform` (la clé est dans `vault-init.json`, ignoré par git) :

```bash
cd /usr/local/dev/rhbk-platform && oc exec -n vault vault-0 -- vault operator unseal "$(python3 -c 'import json;print(json.load(open("vault-init.json"))["unseal_keys_b64"][0])')"
```

## Mise en route

1. Dépôt : `https://github.com/msakho/rhbk-gitops.git` (branche `main`), référencé dans `bootstrap/root-app.yaml`,
   `argocd/appproject.yaml` et `argocd/applications/*.yaml`.
2. Pousser le dépôt.
3. Si le dépôt devient privé, le déclarer dans ArgoCD (Settings > Repositories).
4. Vérifier les prérequis (plateforme) pour chaque environnement.
5. Appliquer l'app of apps :

```bash
oc apply -f bootstrap/root-app.yaml
```

## Nouvelle image Keycloak

```bash
podman build --platform linux/amd64 -t quay.io/msakho0/mskeycloak:26.6 -f custom-rhbk/Containerfile custom-rhbk
podman push quay.io/msakho0/mskeycloak:26.6
oc image info quay.io/msakho0/mskeycloak:26.6 | grep Digest
```

Mettre à jour le digest dans `base/keycloak/keycloak.yaml` et commiter. Les options de build du
Containerfile (`KC_DB`, `KC_HEALTH_ENABLED`, `KC_METRICS_ENABLED`, features…) doivent rester cohérentes avec le CR.

## Vérifier le rendu en local

```bash
oc kustomize overlays/prod
oc kustomize overlays/dev
```
