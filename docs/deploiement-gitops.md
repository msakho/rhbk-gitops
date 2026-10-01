# Déployer Red Hat build of Keycloak en GitOps (prod + dev)

Ce guide décrit, étape par étape, comment construire un dépôt GitOps qui déploie
Red Hat build of Keycloak (RHBK) 26.6 sur OpenShift avec OpenShift GitOps (ArgoCD),
pour deux environnements : **prod** et **dev**.

Il couvre **uniquement la partie GitOps**. L'installation de l'opérateur, de la base
PostgreSQL et la création des secrets sont des prérequis (section 2), réalisés par
les administrateurs ou à la main, et ne sont pas détaillés ici.

En suivant ce guide dans un dépôt vide, on obtient exactement le dépôt
`https://github.com/msakho/rhbk-gitops`.

---

## Sommaire

1. [Principes](#1-principes)
2. [Prérequis](#2-prérequis)
3. [Valeurs à adapter](#3-valeurs-à-adapter)
4. [Créer le dépôt et l'arborescence](#4-créer-le-dépôt-et-larborescence)
5. [La base Kustomize (`base/keycloak`)](#5-la-base-kustomize-basekeycloak)
6. [Les overlays prod et dev](#6-les-overlays-prod-et-dev)
7. [Les ExternalSecrets (désactivés)](#7-les-externalsecrets-désactivés)
8. [La configuration ArgoCD](#8-la-configuration-argocd)
9. [Valider en local](#9-valider-en-local)
10. [Pousser le dépôt](#10-pousser-le-dépôt)
11. [Bootstrap ArgoCD](#11-bootstrap-argocd)
12. [Synchroniser dev puis prod](#12-synchroniser-dev-puis-prod)
13. [Tester le déploiement](#13-tester-le-déploiement)
14. [Rejouer l'exercice sur le même cluster](#14-rejouer-lexercice-sur-le-même-cluster)
15. [Exploitation courante](#15-exploitation-courante)
16. [Dépannage](#16-dépannage)

---

## 1. Principes

### 1.1 App of apps

```
bootstrap/root-app.yaml  ── appliqué une seule fois à la main
        │
        ▼
   Application rhbk-root  ── lit argocd/ dans le dépôt
        │
        ├── AppProject rhbk
        ├── Application rhbk-prod ── lit overlays/prod ──▶ namespace rhbk      (sync manuelle)
        └── Application rhbk-dev  ── lit overlays/dev  ──▶ namespace rhbk-dev  (sync automatique)
```

Une seule commande manuelle (`oc apply -f bootstrap/root-app.yaml`). Ensuite, tout
changement passe par un commit : ajouter un environnement, modifier une Application,
changer une image…

### 1.2 Kustomize : base + overlays

- `base/keycloak/` contient les manifestes **communs**, avec des valeurs factices
  (`KEYCLOAK_NAME`, `HOST_PLACEHOLDER`…) qui ne sont jamais déployées telles quelles.
- `overlays/prod/` et `overlays/dev/` fixent ce qui change par environnement :
  namespace, nom de l'instance, hostnames, ressources CPU/mémoire.

Kustomize assemble base + overlay au moment où ArgoCD lit le dépôt.

### 1.3 Ressources déployées par environnement

| Ressource | Rôle |
|---|---|
| `Service rhbk-internal` | Service interne vers les pods Keycloak. Son annotation fait générer par OpenShift (service-ca) le certificat `rhbk-internal-tls`. |
| `Role` / `RoleBinding router-read-rhbk-tls` | Autorise le routeur OpenShift à lire le certificat public `rhbk-tls-secret`. |
| `Keycloak rhbk-<env>` | L'instance Keycloak (CR de l'opérateur). |
| `Route rhbk-public-realms` | Hostname public, chemin `/realms` uniquement. |
| `Route rhbk-public-resources` | Hostname public, chemin `/resources` uniquement. |
| `Route rhbk-admin` | Hostname admin, tous les chemins (console). |

### 1.4 Isolation de la console admin

```
navigateur ──TLS Let's Encrypt──▶ routeur ──TLS service-ca──▶ Keycloak
                                    │
                                    └─ déchiffre, lit le chemin HTTP,
                                       choisit la Route qui correspond
```

Les routes sont en **reencrypt** : le routeur termine le TLS, lit le chemin, puis
rechiffre vers Keycloak. Sur le hostname public, seules `/realms` et `/resources` ont
une route : `/admin`, `/`, `/metrics`… reçoivent une **503 du routeur** et
n'atteignent jamais Keycloak.

Deux certificats sont en jeu :

| Certificat | Présenté par | Source |
|---|---|---|
| Public (Let's Encrypt) | le routeur, au navigateur | secret `rhbk-tls-secret`, lu via `spec.tls.externalCertificate` |
| Interne | Keycloak, au routeur | secret `rhbk-internal-tls`, généré automatiquement par le service-ca |

L'Ingress créé par défaut par l'opérateur est désactivé (`ingress.enabled: false`) :
il ferait une route passthrough qui exposerait tous les chemins.

### 1.5 Ordre de synchronisation (sync-waves)

| Wave | Ressources | Pourquoi |
|---|---|---|
| 0 | Service `rhbk-internal`, Role, RoleBinding | Le certificat interne et le droit du routeur doivent exister avant Keycloak et les routes. |
| 1 | CR Keycloak | Démarre avec `rhbk-internal-tls`. |
| 2 | Routes | La validation de `externalCertificate` exige le RoleBinding ; ArgoCD attend que Keycloak soit **Healthy** avant cette wave. |

---

## 2. Prérequis

Ces éléments **ne sont pas gérés par le dépôt**. Vérifie-les avant de commencer.

| # | Prérequis | Commande de vérification |
|---|---|---|
| 1 | OpenShift 4.16+ (pour `externalCertificate` sur les Routes) — testé en 4.20 | `oc version` |
| 2 | OpenShift GitOps installé, instance `openshift-gitops` | `oc get argocd -n openshift-gitops` |
| 3 | Namespaces `rhbk` et `rhbk-dev` | `oc get ns rhbk rhbk-dev` |
| 4 | Opérateur RHBK installé **dans chaque namespace** (canal `stable-v26.6`). Il ne supporte que OwnNamespace/SingleNamespace. | `oc get csv -n rhbk-dev \| grep rhbk` → `Succeeded` |
| 5 | PostgreSQL dans chaque namespace : Service **`postgres-db`** port 5432, base **`rhbk`** | `oc get svc postgres-db -n rhbk-dev` |
| 6 | Secret `rhbk-db-secret` (clés `database-username`, `database-password`) | `oc get secret rhbk-db-secret -n rhbk-dev` |
| 7 | Secret `initial-admin-secret` (clés `username`, `password`) | `oc get secret initial-admin-secret -n rhbk-dev` |
| 8 | Secret TLS `rhbk-tls-secret` (type `kubernetes.io/tls`), certificat couvrant les 4 hostnames | `oc get secret rhbk-tls-secret -n rhbk-dev` |
| 9 | Image Keycloak optimisée publiée (voir `custom-rhbk/Containerfile`), avec `KC_DB=postgres`, `KC_HEALTH_ENABLED=true`, `KC_METRICS_ENABLED=true` | `oc image info <image>` |
| 10 | ArgoCD a les droits sur les namespaces cibles | `oc auth can-i create keycloaks.k8s.keycloak.org -n rhbk-dev --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller` → `yes` |
| 11 | Outils locaux : `oc` (même version que le cluster), `git`, accès en écriture au dépôt GitHub | `oc version`, `git --version` |

Pour vérifier le certificat (prérequis 8) :

```bash
oc get secret rhbk-tls-secret -n rhbk-dev -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep DNS:
```

Les 4 hostnames de la section 3 doivent apparaître.

> **Si le prérequis 10 répond `no`**, ajoute le label
> `argocd.argoproj.io/managed-by=openshift-gitops` sur chaque namespace (les
> Applications le posent aussi via `managedNamespaceMetadata`, mais seulement après
> une première synchro réussie).

---

## 3. Valeurs à adapter

Le guide utilise les valeurs du déploiement de référence. Pour un autre cluster ou
un autre dépôt, remplace-les partout.

| Valeur | Référence | Où |
|---|---|---|
| URL du dépôt | `https://github.com/msakho/rhbk-gitops.git` | `bootstrap/root-app.yaml`, `argocd/appproject.yaml`, `argocd/applications/*.yaml` |
| Branche | `main` | mêmes fichiers (`targetRevision`) |
| Domaine des applications | `apps.cluster-nnljw.nnljw.sandbox742.opentlc.com` | `overlays/*/patch-*.yaml` |
| Hostname public prod | `prod-rhbk.<domaine>` | `overlays/prod/patch-keycloak.yaml`, `patch-routes.yaml` |
| Hostname admin prod | `prod-rhbk-admin.<domaine>` | `overlays/prod/patch-keycloak.yaml`, `patch-route-admin.yaml` |
| Hostname public dev | `dev-rhbk.<domaine>` | `overlays/dev/patch-keycloak.yaml`, `patch-routes.yaml` |
| Hostname admin dev | `dev-rhbk-admin.<domaine>` | `overlays/dev/patch-keycloak.yaml`, `patch-route-admin.yaml` |
| Namespaces | `rhbk` (prod), `rhbk-dev` (dev) | `overlays/*/kustomization.yaml`, `argocd/` |
| Image | `quay.io/msakho0/mskeycloak:26.6@sha256:b5c7…` | `base/keycloak/keycloak.yaml` |

Une fois tous les fichiers créés, un `sed` suffit pour changer le domaine :

```bash
grep -rl 'apps.cluster-nnljw.nnljw.sandbox742.opentlc.com' overlays | xargs sed -i '' 's#apps.cluster-nnljw.nnljw.sandbox742.opentlc.com#<NOUVEAU_DOMAINE>#g'
```

(Sur Linux, remplacer `sed -i ''` par `sed -i`.)

---

## 4. Créer le dépôt et l'arborescence

### 4.1 Créer le dépôt sur GitHub

Crée un dépôt vide (sans README ni .gitignore) sur GitHub, par exemple
`rhbk-gitops-v2`. S'il est **public**, ArgoCD le lit sans identifiants. S'il est
**privé**, il faudra le déclarer dans ArgoCD (section 10.2).

### 4.2 Créer l'arborescence locale

```bash
mkdir -p ~/rhbk-gitops-v2 && cd ~/rhbk-gitops-v2
```

```bash
mkdir -p bootstrap argocd/applications base/keycloak overlays/prod/external-secrets overlays/dev/external-secrets custom-rhbk docs
```

Arborescence cible :

```
.gitignore
README.md
bootstrap/
  root-app.yaml
argocd/
  kustomization.yaml
  appproject.yaml
  applications/
    rhbk-prod.yaml
    rhbk-dev.yaml
base/
  keycloak/
    kustomization.yaml
    internal-svc.yaml
    router-secret-reader-rbac.yaml
    keycloak.yaml
    routes.yaml
overlays/
  prod/
    kustomization.yaml
    patch-keycloak.yaml
    patch-routes.yaml
    patch-route-admin.yaml
    external-secrets/
      kustomization.yaml
      rhbk-db-secret.yaml
      initial-admin-secret.yaml
      rhbk-tls-secret.yaml
  dev/
    (mêmes fichiers que prod)
custom-rhbk/
  Containerfile
docs/
  deploiement-gitops.md
```

### 4.3 `.gitignore`

**À créer en premier**, avant tout `git add`, pour qu'aucune clé ni aucun certificat
ne parte dans le dépôt.

`.gitignore`
```gitignore
# Ne jamais commiter : identifiants AWS, clés privées, certificats
cmd.txt
cert/
*.key
*.pem
*.cer
```

---

## 5. La base Kustomize (`base/keycloak`)

### 5.1 `base/keycloak/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - internal-svc.yaml
  - router-secret-reader-rbac.yaml
  - keycloak.yaml
  - routes.yaml
```

### 5.2 `base/keycloak/internal-svc.yaml`

Service interne. L'annotation `service.beta.openshift.io/serving-cert-secret-name`
demande au service-ca d'OpenShift de générer un certificat pour
`rhbk-internal.<namespace>.svc` dans le secret `rhbk-internal-tls`.

On ne peut pas réutiliser le Service `rhbk-<env>-service` créé par l'opérateur :
l'opérateur le gère et retirerait l'annotation.

```yaml
# Internal Service: the OpenShift service-ca generates a certificate for
# rhbk-internal.<namespace>.svc in the rhbk-internal-tls secret.
# Keycloak serves this certificate; the router trusts it automatically in reencrypt mode.
apiVersion: v1
kind: Service
metadata:
  name: rhbk-internal
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: rhbk-internal-tls
    argocd.argoproj.io/sync-wave: "0"
  labels:
    app: keycloak
spec:
  selector:
    app: keycloak
    app.kubernetes.io/managed-by: keycloak-operator
    app.kubernetes.io/instance: KEYCLOAK_NAME   # replaced by the overlay
  ports:
    - name: https
      port: 8443
      targetPort: 8443
      protocol: TCP
```

### 5.3 `base/keycloak/router-secret-reader-rbac.yaml`

Le routeur (ServiceAccount `router` du namespace `openshift-ingress`) doit pouvoir
lire `rhbk-tls-secret` pour utiliser `externalCertificate`. Sans ce droit, l'API
refuse la création des routes (`Forbidden: router serviceaccount does not have
permission to get this secret`).

```yaml
# Allows the router to read the Let's Encrypt certificate (spec.tls.externalCertificate).
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: router-read-rhbk-tls
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["rhbk-tls-secret"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: router-read-rhbk-tls
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: router-read-rhbk-tls
subjects:
  - kind: ServiceAccount
    name: router
    namespace: openshift-ingress
```

### 5.4 `base/keycloak/keycloak.yaml`

Le CR Keycloak. Points clés :

- `SkipDryRunOnMissingResource=true` : si l'opérateur (donc la CRD) manque, ArgoCD
  donne une erreur claire au lieu d'échouer au dry-run de toute l'Application.
- `image` figée par **digest** : ArgoCD déploie toujours exactement cette image.
- `startOptimized: true` : l'image est déjà construite (`kc.sh build`), Keycloak
  démarre en `--optimized`. Les options de build de l'image doivent correspondre au CR.
- `db.host: postgres-db` : nom court, résolu dans le namespace de l'instance ;
  le même CR fonctionne dans les deux environnements.
- `http.tlsSecret: rhbk-internal-tls` : le certificat interne de la section 5.2.
- `ingress.enabled: false` : l'exposition est faite par `routes.yaml`.

```yaml
apiVersion: k8s.keycloak.org/v2beta1
kind: Keycloak
metadata:
  name: KEYCLOAK_NAME   # replaced by the overlay
  labels:
    app: keycloak
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    # The Keycloak CRD comes from the operator (installed by the admins): skip the dry-run if it is missing.
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  instances: 1
  # Custom optimized image (custom-rhbk/Containerfile), pinned by digest.
  # Build-time options baked in the image: db=postgres, health-enabled, metrics-enabled.
  image: quay.io/msakho0/mskeycloak:26.6@sha256:b5c791e58570953cc45c5dbcbfe930f4b7c4bb81989a99a157f4147e45c13da7
  # The operator starts the image with --optimized (no build step at startup).
  startOptimized: true
  # Only used on first start (empty database) to create the temporary admin.
  bootstrapAdmin:
    user:
      secret: initial-admin-secret
  resources:
    requests:
      cpu: "1"
      memory: "1250M"
    limits:
      cpu: "2"
      memory: "2250M"
  hostname:
    hostname: HOSTNAME_PLACEHOLDER        # replaced by the overlay
    admin: ADMIN_HOSTNAME_PLACEHOLDER     # replaced by the overlay
    # Backchannel URLs are not resolved from request headers: all applications use the public URL.
    strict: true
  # The database is not managed by GitOps (postgres-db created manually in each namespace).
  db:
    vendor: postgres
    host: postgres-db
    port: 5432
    database: rhbk
    usernameSecret:
      name: rhbk-db-secret
      key: database-username
    passwordSecret:
      name: rhbk-db-secret
      key: database-password
    poolMinSize: 5
    poolInitialSize: 5
    poolMaxSize: 5
  http:
    httpsPort: 8443
    # Internal certificate generated by the service-ca (internal-svc.yaml). The public
    # Let's Encrypt certificate (rhbk-tls-secret) is presented by the router.
    tlsSecret: rhbk-internal-tls
  # The operator Ingress is disabled: exposure is handled by routes.yaml.
  ingress:
    enabled: false
  additionalOptions:
    - name: metrics-enabled
      value: "true"
  scheduling:
    affinity:
      podAntiAffinity:
        preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              topologyKey: kubernetes.io/hostname
              labelSelector:
                matchLabels:
                  app: keycloak
                  app.kubernetes.io/managed-by: keycloak-operator
                  app.kubernetes.io/instance: KEYCLOAK_NAME   # replaced by the overlay
```

### 5.5 `base/keycloak/routes.yaml`

Trois routes en reencrypt. Les deux routes publiques partagent le même hostname,
avec un `path` différent. La route admin n'a pas de `path` : elle prend tout.

```yaml
# Public hostname: only /realms and /resources are exposed (Keycloak recommendation).
# /admin, / and every other path get a 503 from the router.
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: rhbk-public-realms
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  host: HOST_PLACEHOLDER   # replaced by the overlay
  path: /realms
  to:
    kind: Service
    name: rhbk-internal
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
    externalCertificate:
      name: rhbk-tls-secret
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: rhbk-public-resources
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  host: HOST_PLACEHOLDER   # replaced by the overlay
  path: /resources
  to:
    kind: Service
    name: rhbk-internal
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
    externalCertificate:
      name: rhbk-tls-secret
---
# Admin hostname: every path (the console needs /admin, /realms/master and /resources).
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: rhbk-admin
  annotations:
    argocd.argoproj.io/sync-wave: "2"
    # haproxy.router.openshift.io/ip_whitelist: "203.0.113.0/24 198.51.100.10"
spec:
  host: ADMIN_HOST_PLACEHOLDER   # replaced by the overlay
  to:
    kind: Service
    name: rhbk-internal
  port:
    targetPort: https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
    externalCertificate:
      name: rhbk-tls-secret
```

Pour restreindre l'accès à la console à certaines adresses IP, décommente
l'annotation `ip_whitelist` (adresses ou CIDR séparés par des espaces).

---

## 6. Les overlays prod et dev

Chaque overlay contient 4 fichiers. Ils ne diffèrent entre prod et dev que par les
valeurs.

### 6.1 `overlays/prod/kustomization.yaml`

- `namespace` : appliqué à toutes les ressources (sauf le `subjects[].namespace`
  `openshift-ingress` du RoleBinding, que Kustomize ne touche pas).
- `labels` : ajoutés sur toutes les ressources, sans toucher aux sélecteurs.
- `patches` : l'ordre compte. `patch-routes.yaml` met le hostname public sur
  **toutes** les routes, puis `patch-route-admin.yaml` corrige celui de `rhbk-admin`.
- `replacements` : recopie le nom de l'instance Keycloak (fixé par
  `patch-keycloak.yaml`) dans le sélecteur du Service et dans l'anti-affinity. Le
  nom n'est ainsi écrit qu'à un seul endroit.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: rhbk

labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk
      environment: prod

resources:
  - ../../base/keycloak
  # ExternalSecrets: enable once External Secrets Operator and the ClusterSecretStore exist.
  # - external-secrets

patches:
  - path: patch-keycloak.yaml
    target:
      kind: Keycloak
  - path: patch-routes.yaml
    target:
      kind: Route
  - path: patch-route-admin.yaml

replacements:
  # Propagate the Keycloak instance name to the selectors that target its pods.
  - source:
      kind: Keycloak
      fieldPath: metadata.name
    targets:
      - select:
          kind: Service
          name: rhbk-internal
        fieldPaths:
          - spec.selector.app\.kubernetes\.io/instance
      - select:
          kind: Keycloak
        fieldPaths:
          - spec.scheduling.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution.0.podAffinityTerm.labelSelector.matchLabels.app\.kubernetes\.io/instance
```

### 6.2 `overlays/prod/patch-keycloak.yaml`

Patch JSON 6902 (liste d'opérations) appliqué au CR Keycloak.

```yaml
- op: replace
  path: /metadata/name
  value: rhbk-prod
- op: replace
  path: /spec/instances
  value: 1
- op: replace
  path: /spec/hostname/hostname
  value: https://prod-rhbk.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
- op: replace
  path: /spec/hostname/admin
  value: https://prod-rhbk-admin.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
- op: replace
  path: /spec/resources
  value:
    requests:
      cpu: "2"
      memory: "1250M"
    limits:
      cpu: "2"
      memory: "2250M"
```

### 6.3 `overlays/prod/patch-routes.yaml`

```yaml
# Applied to every Route; the admin host is fixed right after by patch-route-admin.yaml.
- op: replace
  path: /spec/host
  value: prod-rhbk.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
```

### 6.4 `overlays/prod/patch-route-admin.yaml`

Patch « strategic merge » : Kustomize retrouve la route par son nom.

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: rhbk-admin
spec:
  host: prod-rhbk-admin.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
```

### 6.5 `overlays/dev/*`

Copie les 4 fichiers de prod :

```bash
cp overlays/prod/kustomization.yaml overlays/prod/patch-*.yaml overlays/dev/
```

Puis adapte-les. Les fichiers dev complets :

`overlays/dev/kustomization.yaml` : identique à prod, sauf ces deux lignes :

```yaml
namespace: rhbk-dev
```
```yaml
      environment: dev
```

`overlays/dev/patch-keycloak.yaml`
```yaml
- op: replace
  path: /metadata/name
  value: rhbk-dev
- op: replace
  path: /spec/instances
  value: 1
- op: replace
  path: /spec/hostname/hostname
  value: https://dev-rhbk.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
- op: replace
  path: /spec/hostname/admin
  value: https://dev-rhbk-admin.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
- op: replace
  path: /spec/resources
  value:
    requests:
      cpu: "500m"
      memory: "1G"
    limits:
      cpu: "1"
      memory: "1500M"
```

`overlays/dev/patch-routes.yaml`
```yaml
# Applied to every Route; the admin host is fixed right after by patch-route-admin.yaml.
- op: replace
  path: /spec/host
  value: dev-rhbk.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
```

`overlays/dev/patch-route-admin.yaml`
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: rhbk-admin
spec:
  host: dev-rhbk-admin.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
```

---

## 7. Les ExternalSecrets (désactivés)

Ces fichiers sont dans le dépôt mais **ne sont pas déployés** : la ligne
`- external-secrets` est commentée dans `overlays/*/kustomization.yaml`. Ils
serviront quand External Secrets Operator (ESO) sera installé.

Crée-les dans `overlays/prod/external-secrets/`, puis copie-les dans
`overlays/dev/external-secrets/` en remplaçant `rhbk/prod/` par `rhbk/dev/`.

`overlays/prod/external-secrets/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - rhbk-db-secret.yaml
  - initial-admin-secret.yaml
  - rhbk-tls-secret.yaml
```

`overlays/prod/external-secrets/rhbk-db-secret.yaml`
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: rhbk-db-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: CHANGE_ME-secret-store   # à adapter (Vault, AWS SM, ...)
  target:
    name: rhbk-db-secret
    creationPolicy: Owner
  data:
    - secretKey: database-username
      remoteRef:
        key: rhbk/prod/db          # à adapter au chemin du backend
        property: username
    - secretKey: database-password
      remoteRef:
        key: rhbk/prod/db
        property: password
```

`overlays/prod/external-secrets/initial-admin-secret.yaml`
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: initial-admin-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: CHANGE_ME-secret-store
  target:
    name: initial-admin-secret
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: rhbk/prod/bootstrap-admin
        property: username
    - secretKey: password
      remoteRef:
        key: rhbk/prod/bootstrap-admin
        property: password
```

`overlays/prod/external-secrets/rhbk-tls-secret.yaml`
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: rhbk-tls-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: CHANGE_ME-secret-store
  target:
    name: rhbk-tls-secret
    creationPolicy: Owner
    template:
      type: kubernetes.io/tls
  data:
    - secretKey: tls.crt           # fullchain PEM
      remoteRef:
        key: rhbk/prod/tls
        property: tls.crt
    - secretKey: tls.key
      remoteRef:
        key: rhbk/prod/tls
        property: tls.key
```

Copie pour dev :

```bash
for f in kustomization rhbk-db-secret initial-admin-secret rhbk-tls-secret; do sed 's#rhbk/prod/#rhbk/dev/#' overlays/prod/external-secrets/$f.yaml > overlays/dev/external-secrets/$f.yaml; done
```

---

## 8. La configuration ArgoCD

### 8.1 `argocd/appproject.yaml`

Le projet `rhbk` limite ce que ses Applications peuvent faire : un seul dépôt
source, deux namespaces cibles, et comme seule ressource de niveau cluster le
`Namespace` (pour `CreateNamespace=true`).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: rhbk
  namespace: openshift-gitops
spec:
  description: Red Hat build of Keycloak (prod and dev)
  sourceRepos:
    - https://github.com/msakho/rhbk-gitops.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: rhbk
    - server: https://kubernetes.default.svc
      namespace: rhbk-dev
  clusterResourceWhitelist:
    - group: ""
      kind: Namespace
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
```

### 8.2 `argocd/applications/rhbk-prod.yaml`

Prod est en **synchro manuelle** : pas de bloc `automated`. ArgoCD détecte les
écarts (`OutOfSync`) mais n'applique rien sans un clic sur **Sync**.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhbk-prod
  namespace: openshift-gitops
spec:
  project: rhbk
  source:
    repoURL: https://github.com/msakho/rhbk-gitops.git
    targetRevision: main
    path: overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: rhbk
  syncPolicy:
    # Prod: manual sync (review the diff in ArgoCD, then Sync).
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    managedNamespaceMetadata:
      labels:
        argocd.argoproj.io/managed-by: openshift-gitops
```

### 8.3 `argocd/applications/rhbk-dev.yaml`

Dev est en **synchro automatique** : chaque commit est appliqué, les ressources
retirées du dépôt sont supprimées (`prune`) et les modifications manuelles sur le
cluster sont annulées (`selfHeal`).

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhbk-dev
  namespace: openshift-gitops
spec:
  project: rhbk
  source:
    repoURL: https://github.com/msakho/rhbk-gitops.git
    targetRevision: main
    path: overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: rhbk-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    managedNamespaceMetadata:
      labels:
        argocd.argoproj.io/managed-by: openshift-gitops
```

### 8.4 `argocd/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - appproject.yaml
  - applications/rhbk-prod.yaml
  - applications/rhbk-dev.yaml
```

### 8.5 `bootstrap/root-app.yaml`

L'app of apps. Elle appartient au projet `default`, car le projet `rhbk` n'existe
pas encore quand on l'applique.

```yaml
# App of apps: apply once by hand (oc apply -f bootstrap/root-app.yaml).
# It then manages the AppProject and the rhbk-prod / rhbk-dev Applications from argocd/.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhbk-root
  namespace: openshift-gitops
spec:
  project: default
  source:
    repoURL: https://github.com/msakho/rhbk-gitops.git
    targetRevision: main
    path: argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### 8.6 Changer l'URL du dépôt

Si tu utilises un autre dépôt, remplace l'URL dans les 4 fichiers :

```bash
grep -rl 'github.com/msakho/rhbk-gitops.git' bootstrap argocd | xargs sed -i '' 's#https://github.com/msakho/rhbk-gitops.git#https://github.com/<compte>/<depot>.git#g'
```

---

## 9. Valider en local

Avant de pousser, vérifie que tout se construit et que l'API accepte les objets.

**9.1 Rendu Kustomize** (aucun accès au cluster nécessaire) :

```bash
oc kustomize overlays/prod > /dev/null && oc kustomize overlays/dev > /dev/null && oc kustomize argocd > /dev/null && echo "BUILD OK"
```

**9.2 Aucun placeholder ne doit rester** dans le rendu :

```bash
oc kustomize overlays/dev | grep -nE 'PLACEHOLDER|KEYCLOAK_NAME' || echo "OK : aucun placeholder"
```

**9.3 Valeurs clés du rendu** :

```bash
oc kustomize overlays/dev | grep -nE '^  namespace:|host:|hostname:|admin: https|instance:'
```

Vérifie le namespace, les 3 hostnames de routes, les 2 hostnames du CR et le nom
de l'instance dans le sélecteur.

**9.4 Dry-run côté serveur** (connecté au cluster) :

```bash
oc apply --dry-run=server -k overlays/dev
```

Les ressources doivent apparaître en `created (server dry run)` ou
`configured (server dry run)`.

Sur un environnement déjà déployé par ArgoCD, l'avertissement
`missing the kubectl.kubernetes.io/last-applied-configuration annotation` est
normal : ArgoCD applique en server-side apply et ne pose pas cette annotation.

---

## 10. Pousser le dépôt

### 10.1 Commit et push

```bash
git init -b main
```

```bash
git add . && git status
```

**Contrôle de sécurité** : la liste ne doit contenir ni `cert/`, ni `cmd.txt`, ni
aucun `.key`, `.pem` ou `.cer`. Pour être sûr :

```bash
git diff --cached --name-only | xargs grep -lE 'AKIA|PRIVATE KEY|AWS_SECRET' 2>/dev/null || echo "OK : aucun secret détecté"
```

Puis :

```bash
git commit -m "Initial GitOps layout for RHBK prod and dev"
```

```bash
git remote add origin https://github.com/<compte>/<depot>.git && git push -u origin main
```

GitHub n'accepte pas le mot de passe du compte pour git. Utilise la CLI GitHub
(`brew install gh`, puis `gh auth login --hostname github.com --git-protocol https --web`)
ou un Personal Access Token avec le droit *Contents: Read and write*.

### 10.2 Dépôt privé

ArgoCD doit pouvoir lire le dépôt. Dans la console ArgoCD : **Settings →
Repositories → Connect repo**, méthode HTTPS, avec un token en lecture seule.

---

## 11. Bootstrap ArgoCD

**11.1 Vérifier une dernière fois les prérequis** de la section 2 pour les deux
namespaces.

**11.2 Appliquer l'app of apps** :

```bash
oc apply -f bootstrap/root-app.yaml
```

**11.3 Vérifier la création des Applications** (environ 30 secondes) :

```bash
oc get applications -n openshift-gitops -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

Résultat attendu :

| Application | SYNC | HEALTH |
|---|---|---|
| `rhbk-root` | Synced | Healthy |
| `rhbk-dev` | OutOfSync puis Synced | Progressing puis Healthy |
| `rhbk-prod` | OutOfSync | Missing ou Healthy |

---

## 12. Synchroniser dev puis prod

### 12.1 Dev (automatique)

Rien à faire. Suis l'avancement :

```bash
oc get application rhbk-dev -n openshift-gitops -w
```

Compte 1 à 2 minutes. L'ordre des waves est visible dans la console ArgoCD : le
Service et le RBAC, puis Keycloak, qui doit devenir **Healthy**, puis les routes.

### 12.2 Prod (manuel)

1. Dans la console ArgoCD, ouvre l'Application `rhbk-prod` et clique sur
   **App Diff** pour relire ce qui va être appliqué.
2. Clique sur **Sync**, puis **Synchronize**.

Ou en ligne de commande :

```bash
oc patch application rhbk-prod -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"<ton-nom>"},"sync":{"revision":"main"}}}'
```

```bash
oc get application rhbk-prod -n openshift-gitops -w
```

Attends `Synced` / `Healthy`.

---

## 13. Tester le déploiement

### 13.1 État

```bash
oc get applications -n openshift-gitops -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

```bash
oc get keycloak,pods,route -n rhbk-dev
```

### 13.2 Isolation et accès

Ce script teste les deux environnements :

```bash
D=apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
for e in prod dev; do P=https://$e-rhbk.$D; A=https://$e-rhbk-admin.$D; echo "== $e"
for u in "$P/admin/master/console/" "$P/metrics" "$P/realms/master/.well-known/openid-configuration" "$A/admin/master/console/"; do
  printf "  %s tls=%s  %s\n" $(curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}' "$u") "$u"; done; done
```

Résultats attendus :

| URL | Code |
|---|---|
| `https://<env>-rhbk…/admin/master/console/` | **503** (console isolée) |
| `https://<env>-rhbk…/metrics` | **503** |
| `https://<env>-rhbk…/realms/master/.well-known/openid-configuration` | **200** |
| `https://<env>-rhbk-admin…/admin/master/console/` | **200** |
| `tls=` | **0** (certificat valide) |

### 13.3 Connexion

1. Ouvre `https://dev-rhbk-admin.<domaine>/admin/`.
2. Connecte-toi avec l'admin temporaire :
   ```bash
   oc extract secret/initial-admin-secret -n rhbk-dev --to=-
   ```
3. Crée un administrateur permanent dans le realm `master`, puis supprime
   l'utilisateur temporaire.

---

## 14. Rejouer l'exercice sur le même cluster

Si le premier déploiement tourne déjà sur le cluster, un second dépôt qui déploie
les mêmes ressources dans les mêmes namespaces entrerait en conflit avec lui :
deux Applications se disputeraient les mêmes objets.

### 14.1 Option A : remplacer le premier dépôt (sans coupure)

Les Applications du premier dépôt n'ont pas de finalizer
`resources-finalizer.argocd.argoproj.io`. Les supprimer **ne supprime donc pas** les
ressources déployées : elles restent en place, simplement plus suivies.

1. Vérifie qu'aucune Application n'a de finalizer :
   ```bash
   oc get applications -n openshift-gitops -o 'custom-columns=NAME:.metadata.name,FINALIZERS:.metadata.finalizers'
   ```
   La colonne `FINALIZERS` doit être `<none>` pour `rhbk-root`, `rhbk-prod` et
   `rhbk-dev`.
2. Supprime l'app of apps, **puis** les deux Applications :
   ```bash
   oc delete application rhbk-root -n openshift-gitops
   ```
   ```bash
   oc delete application rhbk-prod rhbk-dev -n openshift-gitops
   ```
3. Vérifie que Keycloak tourne toujours :
   ```bash
   oc get keycloak -A
   ```
4. Applique le `bootstrap/root-app.yaml` du **nouveau** dépôt (section 11).
   ArgoCD reprend les ressources existantes : elles portent les mêmes noms, et la
   synchro ne fait que mettre à jour l'annotation de suivi.

ArgoCD suit ses ressources par l'annotation
`argocd.argoproj.io/tracking-id: <application>:<groupe>/<kind>:<namespace>/<nom>`.
**Garde les mêmes noms d'Applications** (`rhbk-root`, `rhbk-prod`, `rhbk-dev`) dans
le nouveau dépôt : la reprise est alors transparente. Avec d'autres noms, ArgoCD
signale les ressources comme appartenant à une autre Application tant que l'ancienne
annotation n'est pas remplacée par une synchro.

> ⚠️ Si une Application a un finalizer, sa suppression **supprime aussi** le CR
> Keycloak et les routes. Retire d'abord le finalizer :
> `oc patch application <nom> -n openshift-gitops --type json -p '[{"op":"remove","path":"/metadata/finalizers"}]'`

### 14.2 Option B : déployer à côté (namespaces distincts)

Pour garder les deux déploiements, utilise d'autres namespaces (par exemple
`rhbk2` et `rhbk2-dev`), d'autres hostnames, d'autres noms d'Applications
(`rhbk2-root`…) et un autre nom d'AppProject. Les prérequis de la section 2
(opérateur, base, secrets, certificat couvrant les nouveaux hostnames) doivent alors
être réunis dans ces nouveaux namespaces.

---

## 15. Exploitation courante

### 15.1 Déployer une nouvelle image Keycloak

1. Modifier `custom-rhbk/Containerfile`, puis builder et pousser :
   ```bash
   podman build --platform linux/amd64 -t quay.io/msakho0/mskeycloak:26.6 -f custom-rhbk/Containerfile custom-rhbk
   ```
   ```bash
   podman push quay.io/msakho0/mskeycloak:26.6
   ```
2. Récupérer le digest :
   ```bash
   oc image info quay.io/msakho0/mskeycloak:26.6 | grep Digest
   ```
3. Mettre à jour `image:` dans `base/keycloak/keycloak.yaml`, puis commit et push.
4. Dev se met à jour automatiquement. Pour prod, lancer **Sync** après avoir vérifié dev.

Toute option de build ajoutée dans le Containerfile (`KC_FEATURES`, `KC_CACHE`,
providers…) doit être cohérente avec le CR.

### 15.2 Modifier un paramètre d'un seul environnement

Modifier le fichier de l'overlay concerné (par exemple les ressources dans
`overlays/dev/patch-keycloak.yaml`), puis commit et push.

### 15.3 Ajouter un environnement (par exemple `staging`)

1. Prérequis de la section 2 dans le nouveau namespace.
2. `cp -r overlays/dev overlays/staging`, puis adapter le namespace, le nom
   d'instance et les hostnames.
3. Créer `argocd/applications/rhbk-staging.yaml`, l'ajouter dans
   `argocd/kustomization.yaml` et ajouter le namespace dans les `destinations` de
   l'AppProject.
4. Commit et push : `rhbk-root` crée la nouvelle Application.

### 15.4 Activer les ExternalSecrets

1. Faire installer External Secrets Operator et créer le `ClusterSecretStore`.
2. Remplacer `CHANGE_ME-secret-store` et les chemins `rhbk/<env>/...` dans
   `overlays/<env>/external-secrets/`.
3. Décommenter `- external-secrets` dans `overlays/<env>/kustomization.yaml`.
4. Commit et push, puis vérifier :
   ```bash
   oc get externalsecret -n rhbk-dev
   ```
   Le statut doit être `SecretSynced`.

---

## 16. Dépannage

| Symptôme | Cause | Solution |
|---|---|---|
| Application en erreur : `the server could not find the requested resource` sur `Keycloak` | Opérateur absent du namespace (pas de CRD) | Faire installer l'opérateur RHBK dans le namespace. |
| Routes refusées : `externalCertificate: Forbidden: router serviceaccount does not have permission` | Le Role ou le RoleBinding du routeur manque, ou le secret ne s'appelle pas `rhbk-tls-secret` | Vérifier `oc get role,rolebinding router-read-rhbk-tls -n <ns>` et le nom du secret. |
| Application bloquée en `Progressing`, routes `Missing` | ArgoCD attend que Keycloak soit Healthy (wave 1) avant de créer les routes (wave 2) | Regarder le pod Keycloak (ligne suivante). |
| Pod `rhbk-<env>-0` en `ContainerCreating`, événement `FailedMount … secret "…" not found` | Le pod est resté sur une ancienne révision du StatefulSet qui monte un secret supprimé. Kubernetes ne remplace pas un pod de StatefulSet qui n'est jamais devenu Ready. | `oc delete pod rhbk-<env>-0 -n <ns>` : le StatefulSet le recrée avec la bonne révision. **Prévention** : lors d'une migration, ne supprimer un ancien secret qu'**après** la synchro. |
| Pod Keycloak en `CrashLoopBackOff`, `Connection refused` vers PostgreSQL | Base arrêtée ou pas encore prête (par exemple au redémarrage du cluster) | Vérifier `oc get pods -n <ns>` ; Keycloak repart seul quand la base répond. |
| 503 sur toutes les URL, y compris `/realms` | Le Service `rhbk-internal` n'a pas d'endpoint, ou le routeur refuse le certificat de Keycloak | `oc get endpointslice -n <ns> -l kubernetes.io/service-name=rhbk-internal` ; vérifier que `tlsSecret` vaut `rhbk-internal-tls`. |
| `/admin` répond 200 sur le hostname public | Une ancienne route passthrough ou l'Ingress de l'opérateur existe encore | `oc get route,ingress -n <ns>` ; supprimer la route en trop, vérifier `ingress.enabled: false`. |
| Keycloak : `build time options differ` ou démarrage lent avec un rebuild | Options de build de l'image différentes du CR | Aligner le Containerfile et le CR, rebuilder, mettre à jour le digest. |
| `rhbk-prod` reste `OutOfSync` | Normal : synchro manuelle | Relire le diff, puis **Sync**. |
