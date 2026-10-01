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
    external-secrets/          ExternalSecrets (désactivés, voir plus bas)
custom-rhbk/Containerfile      Image Keycloak optimisée (quay.io/msakho0/mskeycloak)
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

## Hors GitOps (à créer à la main dans chaque namespace)

L'opérateur et la base PostgreSQL ne sont pas gérés par ce dépôt. Avant la première synchronisation d'un environnement :

0. **Opérateur RHBK** (administrateurs) : installé dans le namespace, canal `stable-v26.6`.
   L'opérateur ne supporte que les modes OwnNamespace / SingleNamespace : une installation par namespace.
1. **Base PostgreSQL** : Service `postgres-db` (port 5432), base `rhbk`.
2. **Secrets** (tant que les ExternalSecrets ne sont pas activés) :

```bash
NS=rhbk-dev
oc create secret tls rhbk-tls-secret --cert ./cert/rhbk.fullchain.pem --key ./cert/rhbk.key.pem -n $NS
oc create secret generic rhbk-db-secret --from-literal=database-username=<user> --from-literal=database-password=<password> -n $NS
oc create secret generic initial-admin-secret --from-literal=username=<admin> --from-literal=password=<password> -n $NS
```

Le certificat Let's Encrypt couvre les 4 hostnames (prod, prod-admin, dev, dev-admin).

## Activer les ExternalSecrets

1. Installer External Secrets Operator et créer le `ClusterSecretStore`.
2. Dans `overlays/<env>/external-secrets/*.yaml`, remplacer `CHANGE_ME-secret-store` et adapter les chemins `rhbk/<env>/...`.
3. Décommenter `- external-secrets` dans `overlays/<env>/kustomization.yaml`.
4. Supprimer les secrets créés à la main (ESO les recrée, `creationPolicy: Owner`).

## Mise en route

1. Dépôt : `https://github.com/msakho/rhbk-gitops.git` (branche `main`), référencé dans `bootstrap/root-app.yaml`,
   `argocd/appproject.yaml` et `argocd/applications/*.yaml`.
2. Pousser le dépôt.
3. Si le dépôt devient privé, le déclarer dans ArgoCD (Settings > Repositories).
4. Préparer la migration de la prod (section suivante) ; pour dev, faire installer l'opérateur dans `rhbk-dev`
   et créer la base et les secrets.
5. Appliquer l'app of apps :

```bash
oc apply -f bootstrap/root-app.yaml
```

### Migration de la prod existante (une seule fois)

L'instance prod a été créée à la main avec d'autres noms. Avant la première synchro de `rhbk-prod` :

```bash
# Anciennes ressources de test, remplacées par rhbk-internal / rhbk-admin / rhbk-public-*
oc delete route rhbk-prod-admin rhbk-prod-public-realms rhbk-prod-public-resources -n rhbk
oc delete service rhbk-prod-internal -n rhbk
oc delete secret rhbk-prod-internal-tls -n rhbk
```

Puis lancer la synchro de `rhbk-prod` dans ArgoCD. Keycloak redémarre avec le nouveau certificat interne
(interruption d'environ 1 minute). Le CR `rhbk-prod` est repris tel quel ; l'installation de l'opérateur n'est pas touchée.

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
