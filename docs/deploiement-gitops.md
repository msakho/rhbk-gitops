# Déployer Red Hat build of Keycloak en GitOps (prod + dev)

Ce guide décrit, étape par étape, comment construire un dépôt GitOps qui déploie
Red Hat build of Keycloak (RHBK) 26.6 sur OpenShift avec OpenShift GitOps (ArgoCD),
pour deux environnements : **prod** et **dev**.

Il couvre **uniquement la partie applicative**. Les namespaces, l'opérateur RHBK,
External Secrets Operator (ESO) et Vault sont gérés par les administrateurs dans un
second dépôt GitOps, [`rhbk-platform`](https://github.com/msakho/rhbk-platform), décrit dans son README et dans
l'annexe A (section 17). La base PostgreSQL (annexe B) et le certificat (annexe C)
sont créés à la main. Tout cela forme les prérequis de la section 2.

| Dépôt | Contenu | Droits ArgoCD |
|---|---|---|
| `rhbk-platform` (administrateurs) | namespaces, opérateurs RHBK et ESO, configuration ESO, `ClusterSecretStore`, Vault | ressources cluster autorisées |
| `rhbk-gitops` (ce guide) | CR Keycloak, routes, ExternalSecrets | **aucune** ressource cluster |

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
7. [Les ExternalSecrets (secrets depuis Vault)](#7-les-externalsecrets-secrets-depuis-vault)
8. [La configuration ArgoCD](#8-la-configuration-argocd)
9. [Valider en local](#9-valider-en-local)
10. [Pousser le dépôt](#10-pousser-le-dépôt)
11. [Bootstrap ArgoCD](#11-bootstrap-argocd)
12. [Synchroniser dev puis prod](#12-synchroniser-dev-puis-prod)
13. [Tester le déploiement](#13-tester-le-déploiement)
14. [Rejouer l'exercice sur le même cluster](#14-rejouer-lexercice-sur-le-même-cluster)
15. [Exploitation courante](#15-exploitation-courante)
16. [Dépannage](#16-dépannage)
17. [Annexe A : plateforme (dépôt rhbk-platform) et Vault](#17-annexe-a--plateforme-dépôt-rhbk-platform-et-vault)
18. [Annexe B : créer la base PostgreSQL d'un environnement](#18-annexe-b--créer-la-base-postgresql-dun-environnement)
19. [Annexe C : générer le certificat d'un environnement](#19-annexe-c--générer-le-certificat-dun-environnement)

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
| `ExternalSecret` ×3 | Font créer par ESO, depuis Vault, les Secrets `rhbk-db-secret`, `initial-admin-secret` et `rhbk-tls-secret`. |
| `Keycloak rhbk-<env>` | L'instance Keycloak (CR de l'opérateur). |
| `Route rhbk-public-realms` | Hostname public, chemin `/realms` uniquement. |
| `Route rhbk-public-resources` | Hostname public, chemin `/resources` uniquement. |
| `Route rhbk-admin` | Hostname admin, tous les chemins (console). |
| `PodDisruptionBudget keycloak` | Garde au moins un pod pendant les drainages de nœuds (section 5.7). |
| `PrometheusRule keycloak-alerts` | Alertes Keycloak et PostgreSQL de l'environnement (section 5.6). |

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
| 0 | Service `rhbk-internal`, Role, RoleBinding, ExternalSecrets | Le certificat interne, le droit du routeur et les secrets doivent exister avant Keycloak et les routes. |
| 1 | CR Keycloak | Démarre avec `rhbk-internal-tls`. |
| 2 | Routes | La validation de `externalCertificate` exige le RoleBinding ; ArgoCD attend que Keycloak soit **Healthy** avant cette wave. |

---

## 2. Prérequis

Ces éléments **ne sont pas gérés par le dépôt**. Vérifie-les avant de commencer.

| # | Prérequis | Commande de vérification |
|---|---|---|
| 1 | OpenShift 4.16+ (pour `externalCertificate` sur les Routes) — testé en 4.20 | `oc version` |
| 2 | OpenShift GitOps installé, instance `openshift-gitops` | `oc get argocd -n openshift-gitops` |
| 3 | Namespaces `rhbk` et `rhbk-dev` (créés par `rhbk-platform`) | `oc get ns rhbk rhbk-dev` |
| 4 | Opérateur RHBK installé **dans chaque namespace** par `rhbk-platform` (canal `stable-v26.6`). Il ne supporte que OwnNamespace/SingleNamespace. | `oc get csv -n rhbk-dev \| grep rhbk` → `Succeeded` |
| 5 | PostgreSQL dans chaque namespace : Service **`postgres-db`** port 5432, base **`rhbk`** (annexe B) | `oc get svc postgres-db -n rhbk-dev` |
| 6 | External Secrets Operator démarré et `ClusterSecretStore vault-store` valide (`rhbk-platform`, annexe A) | `oc get clustersecretstore vault-store` → `Valid`, `READY True` |
| 7 | Valeurs rangées dans Vault pour l'environnement : `secret/rhbk/<env>/db` (`username`, `password`), `secret/rhbk/<env>/bootstrap-admin` (`username`, `password`), `secret/rhbk/<env>/tls` (`tls.crt` = fullchain, `tls.key`) | `oc exec -n vault vault-0 -- vault kv list -mount=secret rhbk/dev` (avec un token, voir annexe A.5) |
| 8 | Certificat (`tls.crt`) couvrant les hostnames public et admin de l'environnement | voir ci-dessous |
| 9 | Image Keycloak optimisée publiée (voir `custom-rhbk/Containerfile`), avec `KC_DB=postgres`, `KC_HEALTH_ENABLED=true`, `KC_METRICS_ENABLED=true` | `oc image info <image>` |
| 10 | ArgoCD a les droits sur les namespaces cibles | `oc auth can-i create keycloaks.k8s.keycloak.org -n rhbk-dev --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller` → `yes` |
| 11 | Outils locaux : `oc` (même version que le cluster), `git`, accès en écriture au dépôt GitHub | `oc version`, `git --version` |
| 12 | Surveillance des projets utilisateur activée (`rhbk-platform`, Application `platform-monitoring`) | `oc get pods -n openshift-user-workload-monitoring` : `prometheus-user-workload-*` et `thanos-ruler-user-workload-*` en `Running` |

Pour vérifier le certificat (prérequis 8), sur le fichier avant de le ranger dans
Vault :

```bash
openssl x509 -in rhbk.fullchain.pem -noout -text | grep DNS:
```

Ou, une fois l'environnement déployé, sur le Secret créé par ESO :

```bash
oc get secret rhbk-tls-secret -n rhbk-dev -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text | grep DNS:
```

Les hostnames public et admin de l'environnement (section 3) doivent apparaître.

> **Si le prérequis 10 répond `no`**, vérifie que le namespace porte le label
> `argocd.argoproj.io/managed-by=openshift-gitops` : il est posé par `rhbk-platform`
> (`operators/rhbk/base/namespace.yaml`).

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
| ClusterSecretStore | `vault-store` | `overlays/*/external-secrets/*.yaml` |
| Chemins Vault | `rhbk/prod/...`, `rhbk/dev/...` | `overlays/*/external-secrets/*.yaml` |

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
mkdir -p bootstrap argocd/applications base/keycloak overlays/prod/external-secrets overlays/dev/external-secrets custom-rhbk docs tools/postgresql
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
    prometheusrule.yaml
    poddisruptionbudget.yaml
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
tools/
  postgresql/                hors ArgoCD : base d'un environnement (annexe B)
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

# Clé de descellement et token root de Vault
vault-init.json
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
  - prometheusrule.yaml
  - poddisruptionbudget.yaml
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
- `features: user-event-metrics` : déclare la fonctionnalité figée dans l'image.
- `additionalOptions` : options **d'exécution** seulement (`metrics-enabled`,
  `http-metrics-histograms-enabled` pour les percentiles de temps de réponse,
  `log-console-output: json` pour des logs exploitables dans Loki, section 15.9).
  `event-metrics-user-enabled` (métriques de connexions par realm) est une option **de
  build** : elle est dans le Containerfile, pas ici.
- `tracing` : envoi des traces OpenTelemetry au Collector de la plateforme
  (`rhbk-tracing`, section 15.10). `endpoint` et `samplerRatio` sont des options
  d'exécution ; `enabled` est une option **de build** et doit correspondre à l'image
  (`KC_TRACING_ENABLED` dans le Containerfile).
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
  # Build-time options baked in the image: db=postgres, health-enabled, metrics-enabled,
  # features=user-event-metrics, event-metrics-user-enabled, tracing-enabled.
  image: quay.io/msakho0/mskeycloak:26.6@sha256:33e17c25d6cc2c8a44fe70f7126fb3165ff9be56a56099b350135656ddd801cc
  # The operator starts the image with --optimized (no build step at startup).
  startOptimized: true
  # Must match the features baked in the image (custom-rhbk/Containerfile, KC_FEATURES).
  features:
    enabled:
      - user-event-metrics
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
  # Traces (OpenTelemetry) sent to the collector of the platform (namespace rhbk-tracing).
  # tracing.enabled is a BUILD-time option: it is set together with the image built with
  # KC_TRACING_ENABLED=true (custom-rhbk/Containerfile). samplerRatio: share of traced requests.
  tracing:
    enabled: true          # build-time: matches the image (KC_TRACING_ENABLED)
    endpoint: http://otel-collector.rhbk-tracing.svc.cluster.local:4317
    samplerRatio: 1
  additionalOptions:
    - name: metrics-enabled
      value: "true"
    # Percentiles (p95, p99) of HTTP response times, used by the dashboards.
    - name: http-metrics-histograms-enabled
      value: "true"
    # JSON console logs (runtime option): fields (level, loggerName, message...) can be filtered
    # in Loki with the "| json" LogQL parser.
    - name: log-console-output
      value: json
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

### 5.6 `base/keycloak/prometheusrule.yaml`

Alertes déployées dans chaque environnement. Elles sont évaluées par le Thanos Ruler
de la **surveillance des projets utilisateur**, activée par l'Application
`platform-monitoring` de `rhbk-platform` (prérequis 12). Une règle ne voit que les
séries de son namespace : les métriques Keycloak (collectées par le ServiceMonitor que
crée l'opérateur, port de gestion 9000) et les métriques de pods du namespace
(`kube_pod_status_ready`, `kube_pod_container_status_restarts_total`).

| Alerte | Déclenchement | Sévérité |
|---|---|---|
| `KeycloakNotReady` | aucun pod Keycloak prêt depuis 5 min | critical |
| `PostgresNotReady` | pod PostgreSQL non prêt depuis 5 min | critical |
| `KeycloakDegraded` | moins de pods prêts que de replicas demandés depuis 10 min (le service tourne sur les autres) | warning |
| `KeycloakMetricsTargetDown` | port de métriques injoignable depuis 5 min | warning |
| `KeycloakFrequentRestarts` | plus de 2 redémarrages en 1 h | warning |
| `KeycloakHighServerErrorRate` | plus de 5 % de réponses 5xx pendant 10 min (hors `/health`, `/metrics`) | warning |
| `KeycloakSlowResponses` | temps de réponse moyen supérieur à 1 s pendant 10 min | warning |
| `KeycloakDatabasePoolExhausted` | requêtes en attente d'une connexion à la base depuis 5 min | warning |
| `KeycloakHeapUsageHigh` | mémoire JVM (heap) au-delà de 90 % pendant 15 min | warning |

```yaml
# Keycloak alerts, deployed in each environment namespace. Evaluated by the user workload
# Thanos Ruler: rules only see the series of their own namespace (Keycloak metrics scraped by the
# operator ServiceMonitor, and kube-state-metrics series for pods of the namespace).
# Health endpoints and /metrics are excluded from the HTTP indicators.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: keycloak-alerts
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  groups:
    - name: keycloak
      rules:
        - alert: KeycloakNotReady
          expr: sum(kube_pod_status_ready{pod=~"rhbk-[a-z]+-[0-9]+", condition="true"}) == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "No Keycloak pod is ready in {{ $labels.namespace }}"
            description: "Check the pod (oc get pods), the database and the Keycloak CR status."
        - alert: KeycloakDegraded
          # With 2+ replicas a failed pod no longer stops the service: this alert makes it visible.
          expr: kube_statefulset_status_replicas_ready{statefulset=~"rhbk-[a-z]+"} < kube_statefulset_replicas{statefulset=~"rhbk-[a-z]+"}
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Keycloak {{ $labels.statefulset }}: {{ $value }} pod(s) ready, fewer than expected"
            description: "The service still runs on the remaining pods. Check the failed pod (oc get pods); if it stays on an old revision after a fix, delete it."
        - alert: KeycloakMetricsTargetDown
          expr: up{endpoint="management", service=~".+-service"} == 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Keycloak metrics endpoint is down ({{ $labels.pod }})"
            description: "Prometheus cannot scrape the management port (9000)."
        - alert: KeycloakFrequentRestarts
          expr: increase(kube_pod_container_status_restarts_total{container="keycloak"}[1h]) > 2
          labels:
            severity: warning
          annotations:
            summary: "Keycloak pod {{ $labels.pod }} restarted {{ $value | humanize }} times in 1h"
            description: "Often the database not being ready (after a cluster restart) or a memory limit."
        - alert: KeycloakHighServerErrorRate
          expr: |
            sum(rate(http_server_requests_seconds_count{outcome="SERVER_ERROR", uri!~"/health.*|/metrics"}[5m]))
              / sum(rate(http_server_requests_seconds_count{uri!~"/health.*|/metrics"}[5m])) > 0.05
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "More than 5% of Keycloak requests fail with a 5xx error"
            description: "Current ratio: {{ $value | humanizePercentage }}."
        - alert: KeycloakSlowResponses
          expr: |
            sum(rate(http_server_requests_seconds_sum{uri!~"/health.*|/metrics"}[5m]))
              / sum(rate(http_server_requests_seconds_count{uri!~"/health.*|/metrics"}[5m])) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Keycloak average response time is above 1s"
            description: "Current average: {{ $value | humanizeDuration }}."
        - alert: KeycloakDatabasePoolExhausted
          expr: max(agroal_awaiting_count) > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Keycloak requests are waiting for a database connection"
            description: "The connection pool (db.poolMaxSize) is saturated or the database is slow."
        - alert: KeycloakHeapUsageHigh
          expr: sum(jvm_memory_used_bytes{area="heap"}) / sum(jvm_memory_max_bytes{area="heap"} > 0) > 0.9
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "Keycloak heap usage above 90%"
            description: "Current usage: {{ $value | humanizePercentage }}. Consider raising the memory limit."
        - alert: PostgresNotReady
          expr: sum(kube_pod_status_ready{pod=~"postgres-db-.+", condition="true"}) == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "The PostgreSQL pod is not ready in {{ $labels.namespace }}"
            description: "Keycloak cannot work without its database (postgres-db)."
```

### 5.7 `base/keycloak/poddisruptionbudget.yaml`

L'opérateur Keycloak ne crée pas de PodDisruptionBudget. Avec `maxUnavailable: 1`, un
drainage de nœud (mise à jour d'OpenShift…) garde au moins un pod quand il y a 2 replicas
ou plus, et n'est **jamais bloqué** avec un seul replica. À l'inverse, `maxUnavailable: 0`
avec un seul replica interdit toute éviction et bloque les drainages (cas rencontré avec
le chart Vault).

```yaml
# The Keycloak operator creates no PodDisruptionBudget. maxUnavailable: 1 keeps at least one pod
# during node drains when there are 2+ replicas, and never blocks a drain with a single replica
# (unlike maxUnavailable: 0, which forbids any eviction).
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: keycloak
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: keycloak
      app.kubernetes.io/managed-by: keycloak-operator
      app.kubernetes.io/instance: KEYCLOAK_NAME   # replaced by the overlay
```

## 6. Les overlays prod et dev

Chaque overlay contient 4 fichiers. Ils ne diffèrent entre prod et dev que par les
valeurs.

### 6.1 `overlays/prod/kustomization.yaml`

- `resources` : la base Keycloak et les ExternalSecrets de l'environnement
  (section 7).
- `namespace` : appliqué à toutes les ressources (sauf le `subjects[].namespace`
  `openshift-ingress` du RoleBinding, que Kustomize ne touche pas).
- `labels` : ajoutés sur toutes les ressources, sans toucher aux sélecteurs.
- `patches` : l'ordre compte. `patch-routes.yaml` met le hostname public sur
  **toutes** les routes, puis `patch-route-admin.yaml` corrige celui de `rhbk-admin`.
- `replacements` : recopie le nom de l'instance Keycloak (fixé par
  `patch-keycloak.yaml`) dans les sélecteurs du Service et du PodDisruptionBudget, et
  dans l'anti-affinity. Le
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
  # ExternalSecrets from Vault (ClusterSecretStore vault-store, defined in the rhbk-platform repository).
  - external-secrets

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
          kind: PodDisruptionBudget
          name: keycloak
        fieldPaths:
          - spec.selector.matchLabels.app\.kubernetes\.io/instance
      - select:
          kind: Keycloak
        fieldPaths:
          - spec.scheduling.affinity.podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution.0.podAffinityTerm.labelSelector.matchLabels.app\.kubernetes\.io/instance
```

### 6.2 `overlays/prod/patch-keycloak.yaml`

Patch JSON 6902 (liste d'opérations) appliqué au CR Keycloak. La prod tourne avec
**2 instances** (haute disponibilité, section 15.8) ; dev avec une seule.

```yaml
- op: replace
  path: /metadata/name
  value: rhbk-prod
- op: replace
  path: /spec/instances
  value: 2
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
- op: replace
  path: /spec/tracing/samplerRatio
  value: 0.1
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

## 7. Les ExternalSecrets (secrets depuis Vault)

Les trois Secrets dont Keycloak a besoin ne sont **jamais écrits dans git**. Le dépôt
contient seulement des `ExternalSecret` : chacun indique à External Secrets Operator
(ESO) quel chemin lire dans Vault et quel Secret Kubernetes créer.

```
ExternalSecret (git) ──▶ ESO ──(ClusterSecretStore vault-store)──▶ Vault secret/rhbk/<env>/...
                          │
                          └──▶ crée et tient à jour le Secret Kubernetes, lu par Keycloak
```

| ExternalSecret | Chemin Vault | Secret créé | Clés |
|---|---|---|---|
| `rhbk-db-secret` | `secret/rhbk/<env>/db` | `rhbk-db-secret` | `database-username`, `database-password` |
| `initial-admin-secret` | `secret/rhbk/<env>/bootstrap-admin` | `initial-admin-secret` | `username`, `password` |
| `rhbk-tls-secret` | `secret/rhbk/<env>/tls` | `rhbk-tls-secret` (type `kubernetes.io/tls`) | `tls.crt`, `tls.key` |

Points importants :

- `secretStoreRef` pointe vers le `ClusterSecretStore vault-store`, créé par les
  administrateurs (annexe A).
- `creationPolicy: Owner` : ESO est propriétaire du Secret ; il le recrée s'il est
  supprimé.
- **Les champs `conversionStrategy`, `decodingStrategy`, `metadataPolicy`,
  `nullBytePolicy`, `deletionPolicy`, `engineVersion` et `mergePolicy` sont les valeurs
  par défaut d'ESO.** Le webhook d'ESO les ajoute de toute façon ; s'ils manquent dans
  git, ArgoCD voit un écart permanent et l'Application reste `OutOfSync`. Il faut donc
  les écrire explicitement.

Crée les fichiers dans `overlays/prod/external-secrets/`, puis copie-les pour dev.

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
    name: vault-store
  target:
    name: rhbk-db-secret
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: database-username
      remoteRef:
        key: rhbk/prod/db
        property: username
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
    - secretKey: database-password
      remoteRef:
        key: rhbk/prod/db
        property: password
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
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
    name: vault-store
  target:
    name: initial-admin-secret
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: username
      remoteRef:
        key: rhbk/prod/bootstrap-admin
        property: username
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
    - secretKey: password
      remoteRef:
        key: rhbk/prod/bootstrap-admin
        property: password
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
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
    name: vault-store
  target:
    name: rhbk-tls-secret
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      mergePolicy: Replace
      type: kubernetes.io/tls
  data:
    - secretKey: tls.crt           # fullchain PEM
      remoteRef:
        key: rhbk/prod/tls
        property: tls.crt
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
    - secretKey: tls.key
      remoteRef:
        key: rhbk/prod/tls
        property: tls.key
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
```

Copie pour dev, en remplaçant les chemins Vault :

```bash
for f in kustomization rhbk-db-secret initial-admin-secret rhbk-tls-secret; do sed 's#rhbk/prod/#rhbk/dev/#' overlays/prod/external-secrets/$f.yaml > overlays/dev/external-secrets/$f.yaml; done
```

## 8. La configuration ArgoCD

### 8.1 `argocd/appproject.yaml`

Le projet `rhbk` limite ce que ses Applications peuvent faire : un seul dépôt
source, deux namespaces cibles, et **aucune ressource de niveau cluster** : les
namespaces et les opérateurs appartiennent à `rhbk-platform`.

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
  # No cluster-scoped resource: namespaces and operators belong to the platform repository (rhbk-platform).
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: "*"
      kind: "*"
```

### 8.2 `argocd/applications/rhbk-prod.yaml`

Prod est en **synchro manuelle** : pas de bloc `automated`. ArgoCD détecte les
écarts (`OutOfSync`) mais n'applique rien sans un clic sur **Sync**.

Pas de `CreateNamespace` ni de `managedNamespaceMetadata` : le namespace est créé et
étiqueté par `rhbk-platform`. Si les deux dépôts géraient les métadonnées du
namespace, les Applications de la plateforme resteraient `OutOfSync`.

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
    # The namespace is created by the platform repository (rhbk-platform).
    syncOptions:
      - ServerSideApply=true
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
    # The namespace is created by the platform repository (rhbk-platform).
    syncOptions:
      - ServerSideApply=true
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

Il échoue sur les `ExternalSecret` si ESO n'est pas installé (CRD absente) : voir
le prérequis 6. Le namespace doit aussi exister (prérequis 3).

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

```bash
oc get externalsecret -n rhbk-dev
```

Les trois ExternalSecrets doivent être en `SecretSynced` / `READY True`.

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
(`rhbk2-root`…) et un autre nom d'AppProject. Les prérequis de la section 2 doivent
alors être réunis pour ces nouveaux namespaces :

- dans `rhbk-platform` : un overlay `operators/rhbk/overlays/<env>` et une Application
  par namespace (namespace + opérateur), et les namespaces ajoutés aux `destinations`
  de l'AppProject `platform` (voir son README, « Ajouter un environnement ») ;
- à la main : la base PostgreSQL ;
- dans Vault : les valeurs sous `secret/rhbk/<env>/...`, avec un certificat couvrant
  les nouveaux hostnames (annexe A.7).

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

> **Option de build ou d'exécution ?** Une image optimisée **refuse de démarrer** si le CR
> demande une option de build différente de celle figée dans l'image (message
> `build time options have values that differ from what is persisted`, pod en
> CrashLoopBackOff). Avant d'ajouter une option dans `additionalOptions`, vérifier
> qu'elle apparaît dans l'aide d'exécution de l'image :
> `oc exec -n rhbk-dev rhbk-dev-0 -- /opt/keycloak/bin/kc.sh start --optimized --help-all | grep <option>`.
> Si elle n'y est pas, c'est une option de build : la mettre dans le Containerfile
> (`KC_<OPTION>`), rebuilder, mettre à jour le digest. Attention : certaines options
> n'apparaissent dans l'aide qu'une fois leur fonctionnalité activée
> (`event-metrics-user-enabled` avec `user-event-metrics`). Après un tel échec, si le pod
> reste bloqué une fois le CR corrigé, le supprimer (section 16).

### 15.2 Modifier un paramètre d'un seul environnement

Modifier le fichier de l'overlay concerné (par exemple les ressources dans
`overlays/dev/patch-keycloak.yaml`), puis commit et push.

### 15.3 Ajouter un environnement (exemple : `qualif`)

On ajoute un environnement `qualif` en partant de l'overlay `dev`. Les commandes
ci-dessous sont à lancer à la racine du dépôt.

| | Valeur pour `qualif` |
|---|---|
| Namespace | `rhbk-qualif` |
| Instance Keycloak | `rhbk-qualif` |
| Hostname public | `qualif-rhbk.<domaine>` |
| Hostname admin | `qualif-rhbk-admin.<domaine>` |
| Chemins ExternalSecrets | `rhbk/qualif/...` |
| Application ArgoCD | `rhbk-qualif` |

#### 15.3.1 Prérequis (hors GitOps)

Les prérequis de la section 2, dans le namespace `rhbk-qualif` :

1. Namespace `rhbk-qualif` et opérateur RHBK : dans `rhbk-platform` (README,
   « Ajouter un environnement »), à synchroniser **avant** l'étape 15.3.6.
2. **Certificat** pour les hostnames de qualif (annexe C).
3. **Valeurs dans Vault** sous `secret/rhbk/qualif/` : `db`, `bootstrap-admin` et
   `tls` (voir annexe A.7). Les ExternalSecrets de l'overlay les liront après la
   commande `sed` de l'étape 15.3.2. Aucun Secret n'est à créer à la main.
4. **Base PostgreSQL** `postgres-db` (annexe B), une fois le namespace créé par
   `rhbk-platform` et les valeurs rangées dans Vault.
5. **Vérifier le certificat** : le certificat existant ne couvre que les hostnames prod et
   dev. Le `tls.crt` rangé dans `secret/rhbk/qualif/tls` doit avoir un SAN contenant
   `qualif-rhbk.<domaine>` et `qualif-rhbk-admin.<domaine>`. Vérification sur le
   fichier avant de le ranger :

   ```bash
   openssl x509 -in qualif.fullchain.pem -noout -text | grep DNS:
   ```

   Sans ce certificat, les routes répondent, mais le navigateur affiche une erreur
   de certificat.

#### 15.3.2 Créer l'overlay

Copier l'overlay de dev :

```bash
cp -r overlays/dev overlays/qualif
```

Remplacer les valeurs de dev dans tous ses fichiers (namespace et nom d'instance,
hostnames, label `environment`, chemins des ExternalSecrets) :

```bash
find overlays/qualif -name '*.yaml' -exec sed -i '' -e 's#rhbk-dev#rhbk-qualif#g' -e 's#dev-rhbk#qualif-rhbk#g' -e 's#environment: dev#environment: qualif#g' -e 's#rhbk/dev/#rhbk/qualif/#g' {} +
```

(Sur Linux, remplacer `sed -i ''` par `sed -i`.)

Ajuster si besoin les ressources CPU/mémoire et le nombre d'instances dans
`overlays/qualif/patch-keycloak.yaml`.

Résultat attendu, par exemple pour `overlays/qualif/patch-keycloak.yaml` :

```yaml
- op: replace
  path: /metadata/name
  value: rhbk-qualif
- op: replace
  path: /spec/instances
  value: 1
- op: replace
  path: /spec/hostname/hostname
  value: https://qualif-rhbk.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
- op: replace
  path: /spec/hostname/admin
  value: https://qualif-rhbk-admin.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
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

#### 15.3.3 Créer l'Application ArgoCD

À partir de celle de dev :

```bash
sed -e 's#rhbk-dev#rhbk-qualif#g' -e 's#overlays/dev#overlays/qualif#g' argocd/applications/rhbk-dev.yaml > argocd/applications/rhbk-qualif.yaml
```

Elle hérite de la synchro **automatique** de dev. Pour une synchro **manuelle**
comme en prod, supprimer le bloc `automated:` (3 lignes) de
`argocd/applications/rhbk-qualif.yaml`.

`argocd/applications/rhbk-qualif.yaml` (synchro automatique) :

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhbk-qualif
  namespace: openshift-gitops
spec:
  project: rhbk
  source:
    repoURL: https://github.com/msakho/rhbk-gitops.git
    targetRevision: main
    path: overlays/qualif
  destination:
    server: https://kubernetes.default.svc
    namespace: rhbk-qualif
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # The namespace is created by the platform repository (rhbk-platform).
    syncOptions:
      - ServerSideApply=true
```

#### 15.3.4 Déclarer l'Application et le namespace

Ajouter l'Application à la liste gérée par `rhbk-root` :

```bash
echo '  - applications/rhbk-qualif.yaml' >> argocd/kustomization.yaml
```

Autoriser le namespace dans l'AppProject (sinon ArgoCD refuse l'Application avec
`application destination ... is not permitted in project 'rhbk'`) :

```bash
sed -i '' '/      namespace: rhbk-dev/a\
    - server: https://kubernetes.default.svc\
      namespace: rhbk-qualif
' argocd/appproject.yaml
```

Résultat attendu dans `argocd/appproject.yaml` :

```yaml
  destinations:
    - server: https://kubernetes.default.svc
      namespace: rhbk
    - server: https://kubernetes.default.svc
      namespace: rhbk-dev
    - server: https://kubernetes.default.svc
      namespace: rhbk-qualif
```

#### 15.3.5 Valider en local

Aucune référence à dev ne doit rester :

```bash
grep -rn 'dev' overlays/qualif argocd/applications/rhbk-qualif.yaml || echo "OK : plus aucune référence à dev"
```

Rendu et valeurs clés :

```bash
oc kustomize overlays/qualif | grep -nE '^  namespace:|host:|hostname:|admin: https|instance:|PLACEHOLDER'
```

```bash
oc kustomize argocd | grep -nE 'name: rhbk-|path: overlays'
```

Dry-run côté serveur (le namespace doit exister) :

```bash
oc apply --dry-run=server -k overlays/qualif
```

#### 15.3.6 Déployer

```bash
git add overlays/qualif argocd && git commit -m "Add qualif environment" && git push
```

`rhbk-root` (synchro automatique) met à jour l'AppProject et crée l'Application
`rhbk-qualif`. Suivre son état :

```bash
oc get application rhbk-qualif -n openshift-gitops -w
```

En synchro manuelle, lancer **Sync** depuis la console ArgoCD (section 12.2).

#### 15.3.7 Tester

Le script de la section 13.2 avec `qualif` :

```bash
D=apps.cluster-nnljw.nnljw.sandbox742.opentlc.com; P=https://qualif-rhbk.$D; A=https://qualif-rhbk-admin.$D
for u in "$P/admin/master/console/" "$P/realms/master/.well-known/openid-configuration" "$A/admin/master/console/"; do printf "%s tls=%s  %s\n" $(curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}' "$u") "$u"; done
```

Attendu : 503, 200, 200, et `tls=0` partout. Ensuite, se connecter avec l'admin
temporaire (`oc extract secret/initial-admin-secret -n rhbk-qualif --to=-`), créer
un admin permanent et supprimer l'utilisateur temporaire.

#### 15.3.8 Supprimer l'environnement

Faire l'inverse dans le dépôt : supprimer `overlays/qualif` et
`argocd/applications/rhbk-qualif.yaml`, retirer la ligne de
`argocd/kustomization.yaml` et la destination de l'AppProject, puis commit et push.
`rhbk-root` supprime l'Application `rhbk-qualif`.

Comme l'Application n'a pas de finalizer, **les ressources déployées restent en
place** (Keycloak, routes…). Pour les supprimer aussi, ajouter avant le commit le
finalizer à l'Application et attendre sa prise en compte :

```bash
oc patch application rhbk-qualif -n openshift-gitops --type merge -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
```

La base, les secrets créés à la main et l'opérateur ne sont jamais supprimés par
ArgoCD : ils sont à retirer à la main (admins).

### 15.4 Modifier un secret (rotation)

Les valeurs sont dans Vault ; le dépôt ne change pas.

1. Écrire la nouvelle valeur dans Vault (annexe A.7), par exemple pour le mot de
   passe de la base de dev (après l'avoir changé dans PostgreSQL).
2. ESO met le Secret à jour au plus tard après `refreshInterval` (1 h). Pour forcer
   tout de suite :
   ```bash
   oc annotate externalsecret rhbk-db-secret -n rhbk-dev force-sync=$(date +%s) --overwrite
   ```
3. Keycloak ne relit ses secrets qu'au démarrage : redémarrer le pod.
   ```bash
   oc delete pod rhbk-dev-0 -n rhbk-dev
   ```
   Pour le certificat (`tls`), pas de redémarrage : le routeur relit
   `rhbk-tls-secret` automatiquement (`externalCertificate`).

### 15.5 Après un redémarrage du cluster

Tout redémarre seul (PostgreSQL, Keycloak, ArgoCD, ESO, Vault et leurs données),
**sauf une étape : Vault redémarre scellé** et doit être descellé à la main.

**Ce qui se passe tant que Vault est scellé** (comportement vérifié en supprimant le
pod `vault-0`) :

| Élément | État |
|---|---|
| Pod `vault-0` | `Running` mais non prêt ; `vault status` → `Sealed true` ; interface web en 503 |
| `ClusterSecretStore vault-store` | `InvalidProviderConfig`, `READY False` |
| ExternalSecrets | passent en `SecretSyncedError` à leur rafraîchissement suivant (au plus tard 1 h) |
| Secrets Kubernetes | **conservés** (`deletionPolicy: Retain`) |
| Keycloak | **fonctionne normalement** : il lit les Secrets déjà présents dans le cluster |
| ArgoCD | `rhbk-prod` / `rhbk-dev` en `Degraded` (reflet des ExternalSecrets), toujours `Synced` |

Tant que Vault est scellé, on ne peut ni changer un secret (section 15.4) ni
déployer un nouvel environnement (ses valeurs ne peuvent pas être lues).

**Desceller Vault** (annexe A.4), depuis le dossier local du dépôt `rhbk-platform`,
où se trouve `vault-init.json` :

```bash
cd /usr/local/dev/rhbk-platform && oc exec -n vault vault-0 -- vault operator unseal "$(python3 -c 'import json;print(json.load(open("vault-init.json"))["unseal_keys_b64"][0])')"
```

**Vérifier le retour à la normale.** Compter **5 à 10 minutes** après le descellement
avant de conclure : le store redevient valide en une vingtaine de secondes, mais les
ExternalSecrets et ArgoCD peuvent mettre plus longtemps (voir « Constaté après un vrai
redémarrage » ci-dessous).

```bash
oc get clustersecretstore vault-store
```

`STATUS Valid`, `READY True`.

Pour ne pas attendre le rafraîchissement suivant des ExternalSecrets :

```bash
for ns in rhbk rhbk-dev; do for es in rhbk-db-secret initial-admin-secret rhbk-tls-secret; do oc annotate externalsecret $es -n $ns force-sync=$(date +%s) --overwrite; done; done
```

```bash
oc get externalsecret -n rhbk-dev && oc get applications -n openshift-gitops
```

ExternalSecrets en `SecretSynced`, Applications `Synced` / `Healthy`.

**Constaté après un vrai redémarrage du cluster** (en plus du descellement) :

| Symptôme | Cause | Que faire |
|---|---|---|
| Un ExternalSecret reste en `SecretSyncedError` (`could not get secret data from provider`) alors que `vault-store` est `Valid` ; l'Application correspondante est `Degraded` | Pendant que Vault était scellé, ESO a échoué plusieurs fois sur ce secret et **espace ses nouvelles tentatives** (délai croissant) : il n'a pas encore réessayé depuis le descellement. Keycloak n'est pas affecté (le Secret existant est conservé). | Forcer la relecture avec la boucle `force-sync` ci-dessus. |
| Une ou plusieurs Applications en `Unknown`, message `ComparisonError … unable to resolve parseableType for GroupVersionKind: route.openshift.io/v1, Kind=Route` | Les serveurs d'API redémarrent avec le cluster et ne publient pas tout de suite le schéma complet des Routes. Si le contrôleur ArgoCD démarre avant, il garde ce schéma incomplet en mémoire. Aucun impact sur ce qui tourne. | Attendre quelques minutes, puis relire l'Application (`oc annotate application <nom> -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite`). **Si l'état `Unknown` persiste au-delà de 15 minutes**, redémarrer le contrôleur ArgoCD (sans impact sur les applications) : `oc delete pod -n openshift-gitops -l app.kubernetes.io/name=openshift-gitops-application-controller`. |

### 15.6 Alertes

**Où les voir** : console OpenShift, **Observe → Alerting** (filtrer sur le namespace),
ou **Observe → Metrics** pour interroger les métriques (par exemple
`agroal_active_count`, `http_server_requests_seconds_count`).

**Vue d'ensemble dans la console** : **Observe → Dashboards (Perses)**, projet
`rhbk-observability`, tableau **RHBK - vue d'ensemble** (`rhbk-platform`, Cluster
Observability Operator) : état de Keycloak, PostgreSQL, Vault, ESO et ArgoCD, trafic,
erreurs, temps de réponse et connexions, prod et dev côte à côte.

**Tableaux de bord détaillés** : Grafana (`rhbk-platform`), `https://grafana.apps.<domaine>`,
connexion avec le compte OpenShift, dossier **Keycloak** : tableaux officiels
*Keycloak troubleshooting* (disponibilité, HTTP, percentiles de temps de réponse, base,
JVM, caches, CPU) et *Keycloak capacity planning* (connexions réussies et échouées,
émissions de jetons, par realm). Choisir le namespace `rhbk` ou `rhbk-dev` en haut du
tableau. Les métriques de connexions et les percentiles reposent sur les options de la
section 5.4 et du Containerfile (`user-event-metrics`, histogrammes HTTP).

| Origine | Alertes | Défini dans |
|---|---|---|
| Keycloak et PostgreSQL, par environnement | section 5.6 | `rhbk-gitops`, `base/keycloak/prometheusrule.yaml` |
| ESO | `ExternalSecretNotSynced` (15 min), `ClusterSecretStoreNotReady` | `rhbk-platform`, `monitoring/` |
| Vault | `VaultSealedOrDown` : Vault scellé ou arrêté depuis 5 min (pod non prêt) | `rhbk-platform`, `monitoring/` |
| ArgoCD | `ArgoCDApplicationUnhealthy` (Degraded / Missing / Unknown depuis 15 min) ; `ArgoCDSyncAlert` (OutOfSync, fournie par l'opérateur GitOps) | `rhbk-platform`, `monitoring/` |

Après un redémarrage du cluster, `VaultSealedOrDown` signale qu'il faut desceller, et
`ExternalSecretNotSynced` qu'il faut forcer la relecture (section 15.5).

**Historique** : les métriques sont conservées **7 jours** sur des volumes persistants
(`rhbk-platform`, `monitoring/user-workload-monitoring-config.yaml`) et survivent aux
redémarrages du cluster.

**Notifications** : section 15.7.

**Non couvert** : l'expiration du certificat (il faudrait un sondeur *blackbox* ;
cert-manager fournira cette métrique).

### 15.7 Notifications

Les alertes des projets utilisateur sont envoyées à l'**Alertmanager de la plateforme**
(`alertmanager-main`, namespace `openshift-monitoring`). Sa configuration est gérée par
`rhbk-platform` (`monitoring/alertmanager-main.yaml`) : elle garde les destinataires et
règles d'inhibition par défaut d'OpenShift, et ajoute une route pour nos alertes.

| Alertes | Destinataire |
|---|---|
| namespaces `rhbk`, `rhbk-<env>`, `vault`, `external-secrets`, `openshift-gitops` | **`rhbk-team`** (regroupées par namespace et nom d'alerte) |
| `Watchdog` (alerte permanente de contrôle d'OpenShift) | `Watchdog` (aucun envoi) |
| autres alertes `critical` du cluster | `Critical` (aucun envoi) |
| tout le reste | `Default` (aucun envoi) |

Rythme : premier envoi 30 s après le déclenchement (`group_wait`), mises à jour toutes
les 5 min (`group_interval`), rappel toutes les 12 h tant que l'alerte est active
(`repeat_interval`), et notification « résolue » à la fin (`send_resolved`).

#### 15.7.1 Aujourd'hui : récepteur de test

`rhbk-team` envoie vers un **webhook de test** dans le cluster (namespace
`alert-webhook-test`) qui écrit chaque alerte dans ses logs :

```bash
oc logs -n alert-webhook-test deploy/alert-webhook
```

Exemple de ligne : `2026-10-18T14:24:41Z FIRING info RHBKNotificationTest ns=rhbk-dev | …`

Vérifier le routage (dans le pod Alertmanager) :

```bash
oc exec -n openshift-monitoring alertmanager-main-0 -c alertmanager -- amtool config routes show --alertmanager.url=http://localhost:9093
```

Tester toute la chaîne avec une alerte temporaire toujours vraie (arrive en 1 à 2 minutes,
puis « RESOLVED » 5 à 10 minutes après la suppression de la règle) :

```bash
cat <<'EOF' | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: zz-notification-test
  namespace: rhbk-dev
spec:
  groups:
    - name: zz-test
      rules:
        - alert: RHBKNotificationTest
          expr: vector(1)
          labels: {severity: info}
          annotations: {summary: "Test de la chaîne de notification (à ignorer)"}
EOF
```

```bash
oc delete prometheusrule zz-notification-test -n rhbk-dev
```

#### 15.7.2 Passer à l'e-mail (SMTP)

Le modèle prêt à l'emploi est dans `rhbk-platform` :
`monitoring/examples/alertmanager-main-smtp.yaml`. C'est un **ExternalSecret** qui génère
toute la configuration d'Alertmanager (même routage) à partir des paramètres SMTP rangés
dans Vault : le mot de passe SMTP n'est jamais dans git. Ce modèle a été validé (rendu par
ESO avec des valeurs factices, puis `amtool check-config`).

**Il te faut** : l'adresse du serveur SMTP et son port (`smarthost`, par exemple
`smtp.gmail.com:587`), l'expéditeur (`from`), le destinataire (`to`), l'identifiant et le
mot de passe SMTP. Avec Gmail : compte avec validation en deux étapes et **mot de passe
d'application** (pas le mot de passe du compte).

> Le cluster doit pouvoir joindre le serveur SMTP. Sur AWS, le **port 25 sortant est
> bloqué par défaut** : utiliser le port **587** (STARTTLS), comme dans l'exemple.

**1. Autoriser ESO à lire le chemin Vault de la plateforme.** La politique actuelle
(`rhbk-read`) ne couvre que `secret/rhbk/*`. Depuis le dossier de `rhbk-platform` :

```bash
cd /usr/local/dev/rhbk-platform
```

```bash
{ echo "export VAULT_TOKEN='$(python3 -c 'import json;print(json.load(open("vault-init.json"))["root_token"])')'"; cat <<'EOF'
set -e
vault policy write platform-alertmanager-read - <<'POL'
path "secret/data/platform/alertmanager/*" {
  capabilities = ["read"]
}
POL
vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=rhbk-read,platform-alertmanager-read \
  ttl=1h
EOF
} | oc exec -i -n vault vault-0 -- sh -s
```

**2. Ranger les paramètres SMTP dans Vault** (`secret/platform/alertmanager/smtp`).
Toutes les valeurs sont demandées au terminal, sans affichage :

```bash
python3 -c "$(cat <<'EOF'
import json, getpass
ask = getpass.getpass
tok = json.load(open("vault-init.json"))["root_token"]
data = {k: ask(k + ": ") for k in ("smarthost", "from", "to", "username", "password")}
print("set -e"); print(f"export VAULT_TOKEN={json.dumps(tok)}"); print("umask 077")
print("cat > /tmp/v.json <<'JSONEOF'"); print(json.dumps(data)); print("JSONEOF")
print("vault kv put -mount=secret platform/alertmanager/smtp @/tmp/v.json >/dev/null && echo 'written platform/alertmanager/smtp'")
print("rm -f /tmp/v.json")
EOF
)" | oc exec -i -n vault vault-0 -- sh -s
```

**3. Remplacer la configuration de test par le modèle SMTP**, dans `rhbk-platform` :

```bash
git rm monitoring/alertmanager-main.yaml && git mv monitoring/examples/alertmanager-main-smtp.yaml monitoring/alertmanager-main.yaml
```

Puis, dans `monitoring/kustomization.yaml`, retirer la ligne `- alert-webhook-test`
(le récepteur de test n'est plus utile). Commit et push.

**4. Synchroniser `platform-monitoring` sans « Prune »** : ESO reprend le Secret
`alertmanager-main` existant (un Prune le supprimerait avant qu'ESO ne le recrée). Puis
supprimer le récepteur de test :

```bash
oc delete namespace alert-webhook-test
```

**5. Vérifier** :

```bash
oc get externalsecret alertmanager-main -n openshift-monitoring
```

`SecretSynced`.

```bash
oc exec -n openshift-monitoring alertmanager-main-0 -c alertmanager -- amtool config routes show --alertmanager.url=http://localhost:9093
```

La route `rhbk-team` est présente. Lancer ensuite le test de la section 15.7.1 : un e-mail
« RHBKNotificationTest » doit arriver. En cas d'échec d'envoi, les logs d'Alertmanager
indiquent la cause (authentification, TLS, réseau) :

```bash
oc logs -n openshift-monitoring alertmanager-main-0 -c alertmanager | grep -i -E 'notify|smtp|email' | tail
```

**Changer un paramètre SMTP** (mot de passe, destinataire) : le modifier dans Vault
(étape 2), puis forcer la relecture ; Alertmanager recharge sa configuration seul.

```bash
oc annotate externalsecret alertmanager-main -n openshift-monitoring force-sync=$(date +%s) --overwrite
```

### 15.8 Comment l'opérateur applique un changement (et pourquoi 2 replicas)

L'opérateur Keycloak applique un changement du CR de deux façons
(`spec.update.strategy`, par défaut `RecreateOnImageChange`) :

| Changement | Méthode | Effet |
|---|---|---|
| **Sans changement d'image** (option d'exécution, ressources, nombre d'instances…) | **rolling update** du StatefulSet : un pod après l'autre, en commençant par le numéro le plus élevé, chacun devant être Ready avant le suivant | avec **2 replicas ou plus**, pas de coupure ; si le nouveau pod échoue, la mise à jour s'arrête et les autres pods continuent sur l'ancienne version |
| **Avec changement d'image** (nouveau digest) | **recreate** : tous les pods sont arrêtés puis recréés (deux versions différentes ne partagent pas leurs caches) | **coupure** d'environ **1 minute** (mesurée en prod avec 2 replicas lors du passage à l'image tracée), quel que soit le nombre de replicas ; si la nouvelle version échoue, plus aucun pod ne répond |

**Pod bloqué sur une ancienne révision** : un pod de StatefulSet qui n'a jamais été
Ready n'est jamais remplacé, même après correction du CR (le StatefulSet attend qu'il
soit Ready). Il faut le supprimer : `oc delete pod <pod> -n <namespace>`. C'est vrai avec
1 ou plusieurs replicas ; avec 2 replicas et un rolling update, le service continue
pendant ce temps sur l'autre pod.

**Règles à suivre** :

1. **Ne pas mélanger, dans un même commit, un nouveau digest d'image et des changements
   d'options.** Un changement d'options seul passe en rolling update : avec 2 replicas,
   une option fautive ne touche qu'un pod.
2. **Tester en dev d'abord** (synchro automatique) ; la prod (synchro manuelle) ne reçoit
   le changement qu'une fois validé.
3. **Avant d'ajouter une option dans le CR, vérifier qu'elle est d'exécution** (section
   15.1) : une option de build différente de l'image empêche Keycloak de démarrer.
4. **Prod à 2 replicas minimum**, avec le PodDisruptionBudget `maxUnavailable: 1`
   (section 5.7) et l'alerte `KeycloakDegraded`, qui signale un pod en échec que le
   service masque.

**Option à évaluer** : `spec.update.strategy: Auto`. L'opérateur lance un Job qui vérifie
si l'ancienne et la nouvelle image peuvent cohabiter : si oui (simple changement
d'options de build, correctif mineur), il fait un rolling update même quand l'image
change ; sinon, un recreate. À tester en dev avant de l'appliquer en prod.

### 15.9 Logs centralisés

Les logs de Keycloak (et de PostgreSQL, Vault, ESO, ArgoCD…) sont collectés par
OpenShift Logging et stockés 7 jours dans Loki (`rhbk-platform`, Application `logging`).
Keycloak écrit ses logs en **JSON** (`log-console-output: json`, section 5.4).

**Où les voir** : console OpenShift, **Observe → Logs** (choisir le namespace), ou onglet
**Aggregated Logs** d'un pod. Les requêtes s'écrivent en **LogQL**.

| Besoin | Requête |
|---|---|
| Tous les logs Keycloak de la prod | `{kubernetes_namespace_name="rhbk", kubernetes_container_name="keycloak"}` |
| Seulement les avertissements et erreurs | `{kubernetes_namespace_name="rhbk", kubernetes_container_name="keycloak"} \| json \| level=~"warn\|error"` |
| Les champs de Keycloak (`loggerName`, `message`…) | `{kubernetes_namespace_name="rhbk", kubernetes_container_name="keycloak"} \| json \| line_format "{{.message}}" \| json \| __error__=""` |
| Par composant Keycloak | ajouter `\| loggerName=~"org.keycloak.events.*"` à la requête précédente |
| Nombre de lignes par niveau (graphique) | `sum by (level) (count_over_time({kubernetes_namespace_name="rhbk", kubernetes_container_name="keycloak"} \| json [5m]))` |
| ArgoCD | `{kubernetes_namespace_name="openshift-gitops"}` (tenant *infrastructure*) |

Le collecteur enveloppe chaque ligne dans son propre JSON (namespace, pod, niveau…) : la
ligne JSON de Keycloak est dans le champ `message` de cette enveloppe, d'où la double
analyse `| json | line_format "{{.message}}" | json`. Le **niveau** est déjà extrait et
normalisé (en minuscules) par le collecteur : une seule analyse suffit pour filtrer par
niveau. `__error__=""` écarte les lignes non JSON (anciennes lignes, traces de pile
coupées).

### 15.10 Traces

Keycloak envoie ses traces (OpenTelemetry, OTLP gRPC) au Collector de la plateforme
(`otel-collector.rhbk-tracing`), qui les transmet à Tempo (`rhbk-platform`, Application
`tracing`). Une trace suit une requête de bout en bout : requête HTTP, traitement Keycloak,
requêtes SQL, avec la durée de chaque étape.

**Où les voir** : console OpenShift, **Observe → Traces**, instance `rhbk-tracing / tempo`,
tenant `rhbk`. Requêtes **TraceQL** utiles :

| Besoin | Requête |
|---|---|
| Toutes les traces de la prod | `{resource.service.name="rhbk-prod"}` |
| Requêtes HTTP de dev | `{resource.service.name="rhbk-dev" && span.http.request.method="POST"}` |
| Demandes de jeton lentes (plus de 500 ms) | `{resource.service.name="rhbk-prod" && name=~".*/token" && duration > 500ms}` |
| Requêtes en erreur | `{resource.service.name="rhbk-prod" && status = error}` |

**Échantillonnage** : 100 % des requêtes en dev, **10 % en prod** (`spec.tracing.samplerRatio`,
`overlays/prod/patch-keycloak.yaml`), pour limiter le volume.

**Activer le traçage, dans l'ordre** (section 15.8) :

1. commit d'options seul : `spec.tracing.endpoint` et `samplerRatio` (ignorés tant que
   l'image n'a pas le traçage : simple avertissement « UNAVAILABLE ») ;
2. commit d'image seul : rebuild avec `KC_TRACING_ENABLED=true`, nouveau digest, et
   `spec.tracing.enabled: true` (option de build qui doit correspondre à l'image) ; recreate.

Exemple observé : une demande de jeton pour un utilisateur inexistant dure environ 460 ms,
dont l'essentiel dans `TokenEndpoint.processGrantRequest` alors que les requêtes SQL
prennent moins de 1 ms : Keycloak calcule volontairement un hachage de mot de passe factice
pour qu'on ne puisse pas deviner, à la durée de réponse, si un compte existe.

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
| Juste après un redémarrage du cluster : Applications en `Unknown`, `unable to resolve parseableType … Kind=Route` | Schéma des Routes pas encore publié quand le contrôleur ArgoCD a démarré | Attendre quelques minutes et relire l'Application ; si ça persiste au-delà de 15 minutes, redémarrer le contrôleur ArgoCD (section 15.5). |
| Après un descellement de Vault : un ExternalSecret reste en `SecretSyncedError` alors que le store est `Valid` | ESO espace ses nouvelles tentatives après plusieurs échecs | Forcer la relecture (`force-sync`, section 15.5). |
| Les ExternalSecrets restent `OutOfSync` dans ArgoCD alors qu'ils sont `SecretSynced` | Les valeurs par défaut ajoutées par le webhook d'ESO ne sont pas dans git | Les déclarer explicitement (section 7) ; comparer avec `oc get externalsecret <nom> -n <ns> -o yaml`. |
| ExternalSecret en `SecretSyncedError`, message `ClusterSecretStore "vault-store" is not ready` | Le store n'est pas valide | `oc get clustersecretstore vault-store -o yaml` : voir les lignes suivantes. |
| Store invalide : `unable to log in with Kubernetes auth: context deadline exceeded` | Les pods ESO sont isolés par des NetworkPolicies deny-all : la sortie vers Vault n'est pas ouverte | Dans `rhbk-platform`, ajouter la règle d'egress dans `eso/externalsecretsconfig.yaml` (`spec.controllerConfig.networkPolicies`, annexe A.2), puis synchroniser `eso-config`. Jamais de NetworkPolicy à la main. |
| Store invalide : `Vault is sealed` / code 503 | Vault redémarré et scellé | Desceller (section 15.5). |
| Store invalide : `permission denied` / 403 | Rôle ou politique Vault incorrects | Vérifier le rôle `external-secrets` et la politique `rhbk-read` (annexe A.5). |
| ExternalSecret `SecretSyncedError` : `cannot find secret data for key` | Chemin ou propriété absents dans Vault | `vault kv get -mount=secret rhbk/<env>/<chemin>` ; vérifier les noms des propriétés. |

---

## 17. Annexe A : plateforme (dépôt rhbk-platform) et Vault

La plateforme est gérée par les administrateurs dans le dépôt GitOps
[`rhbk-platform`](https://github.com/msakho/rhbk-platform) (AppProject `platform`,
Applications en synchro manuelle). Son README décrit l'arborescence, l'ordre de
déploiement et l'ajout d'un environnement. Cette annexe résume ce qu'il faut en savoir
côté application, et détaille les **étapes manuelles de Vault**, qui ne sont pas
déclaratives.

```
namespace external-secrets-operator : opérateur ESO (Red Hat)        Application eso-operator
namespace external-secrets          : ESO (créé par l'opérateur)      Application eso-config
namespace vault                     : Vault 1 nœud, Raft sur PVC      Application vault (Helm)
ClusterSecretStore vault-store      : ESO -> Vault (auth Kubernetes)  Application eso-config
namespaces rhbk, rhbk-dev           : namespace + opérateur RHBK      Applications rhbk-operator-<env>
```

### A.1 Ordre de déploiement de la plateforme

| Étape | Dans `rhbk-platform` |
|---|---|
| 1 | `oc apply -f bootstrap/root-app.yaml` (crée l'AppProject et les Applications, sans rien synchroniser) |
| 2 | Sync `eso-operator` |
| 3 | Sync `vault`, puis **étapes manuelles A.4, A.5 et A.7** |
| 4 | Sync `eso-config` → `oc get clustersecretstore vault-store` : `Valid` |
| 5 | Sync `rhbk-operator-<env>` (namespace + opérateur RHBK) |
| 6 | Puis, dans ce dépôt : bootstrap applicatif (section 11) |

### A.2 Deux pièges déjà traités dans `rhbk-platform`

- **NetworkPolicies d'ESO** : l'opérateur Red Hat isole les pods ESO avec des
  NetworkPolicies *deny-all* (seuls l'API Kubernetes et le DNS sont autorisés). La
  sortie vers Vault (namespace `vault`, port 8200) est ouverte dans
  `eso/externalsecretsconfig.yaml` (`spec.controllerConfig.networkPolicies`) ;
  l'opérateur crée la NetworkPolicy `eso-user-allow-egress-to-vault`. Une
  NetworkPolicy créée à la main serait supprimée par l'opérateur.
- **Image Vault** : sur OpenShift, le nom court `hashicorp/vault` est d'abord cherché
  dans `registry.connect.redhat.com`, où ce tag n'existe pas (`ImagePullBackOff`).
  `vault/values.yaml` indique le nom complet `docker.io/hashicorp/vault`.

### A.3 Où sont les secrets de Vault

`vault-init.json` (clé de descellement et token root) est conservé **dans le dossier
local du dépôt `rhbk-platform`**, ignoré par git. Les commandes A.4 à A.7 sont à
lancer depuis ce dossier :

```bash
cd /usr/local/dev/rhbk-platform
```

### A.4 Initialiser et desceller Vault

L'initialisation génère **la clé de descellement et le token root, une seule fois**.
Ils sont écrits dans `vault-init.json`, ignoré par git (`.gitignore`), lisible par
toi seul. **Sauvegarde ce fichier** (gestionnaire de mots de passe) : sans la clé de
descellement, les données de Vault sont irrécupérables.

Pour le sandbox, une seule part de clé (`-key-shares=1`). En production, utiliser
plusieurs parts réparties entre plusieurs personnes, ou un descellement automatique
(KMS).

```bash
grep -qx 'vault-init.json' .gitignore || printf '\n# Clé de descellement et token root de Vault\nvault-init.json\n' >> .gitignore
```

```bash
(umask 077; oc exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-init.json)
```

```bash
git check-ignore -v vault-init.json
```

Desceller (à refaire après chaque redémarrage du pod ou du cluster) :

```bash
oc exec -n vault vault-0 -- vault operator unseal "$(python3 -c 'import json;print(json.load(open("vault-init.json"))["unseal_keys_b64"][0])')"
```

Vérifier : `Initialized true`, `Sealed false`.

### A.5 Configurer Vault pour ESO

Les commandes `vault` sont exécutées dans le pod. Le token root est passé par
l'entrée standard pour ne pas apparaître dans la ligne de commande :

```bash
{ echo "export VAULT_TOKEN='$(python3 -c 'import json;print(json.load(open("vault-init.json"))["root_token"])')'"; cat <<'EOF'
set -e
vault secrets enable -path=secret -version=2 kv
vault auth enable kubernetes
vault write auth/kubernetes/config kubernetes_host="https://${KUBERNETES_PORT_443_TCP_ADDR}:443"
vault policy write rhbk-read - <<'POL'
path "secret/data/rhbk/*" {
  capabilities = ["read"]
}
path "secret/metadata/rhbk/*" {
  capabilities = ["read", "list"]
}
POL
vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=rhbk-read \
  ttl=1h
EOF
} | oc exec -i -n vault vault-0 -- sh -s
```

| Élément | Rôle |
|---|---|
| Moteur KV v2 sur `secret/` | stockage des valeurs, versionnées |
| Auth `kubernetes` | ESO se connecte avec le token de son ServiceAccount : **aucun mot de passe stocké** |
| Politique `rhbk-read` | lecture seule sur `secret/rhbk/*` |
| Rôle `external-secrets` | associe le ServiceAccount `external-secrets/external-secrets` à la politique |

L'avertissement `Role external-secrets does not have an audience configured` est
sans conséquence ici.

### A.6 Vérifier le `ClusterSecretStore`

Le `ClusterSecretStore vault-store` est déployé par l'Application `eso-config` de
`rhbk-platform` (`eso/clustersecretstore.yaml`) : ESO se connecte à
`http://vault-active.vault.svc:8200` avec l'auth Kubernetes (rôle `external-secrets`).

```bash
oc get clustersecretstore vault-store
```

`STATUS Valid`, `READY True`.

### A.7 Ranger les valeurs d'un environnement dans Vault

Depuis le dossier de `rhbk-platform` (où se trouve `vault-init.json`), en indiquant
l'environnement et les fichiers du certificat de cet environnement (annexe C). Les
valeurs passent par l'entrée standard et un fichier temporaire supprimé aussitôt :

```bash
cd /usr/local/dev/rhbk-platform
```

```bash
ENV=qualif
CERT=/usr/local/dev/rhbk-gitops/cert/$ENV-rhbk.fullchain.pem
KEY=/usr/local/dev/rhbk-gitops/cert/$ENV-rhbk.key.pem
```

```bash
python3 -c "$(cat <<'EOF'
import json, sys, getpass
env, cert, key = sys.argv[1:4]
ask = getpass.getpass  # prompts on the terminal (not on stdout), input not echoed
tok = json.load(open("vault-init.json"))["root_token"]
items = {
  f"rhbk/{env}/db": {"username": ask("db username: "), "password": ask("db password: ")},
  f"rhbk/{env}/bootstrap-admin": {"username": ask("admin username: "), "password": ask("admin password: ")},
  f"rhbk/{env}/tls": {"tls.crt": open(cert).read(), "tls.key": open(key).read()},
}
print("set -e"); print(f"export VAULT_TOKEN={json.dumps(tok)}"); print("umask 077")
for path, data in items.items():
    print("cat > /tmp/v.json <<'JSONEOF'"); print(json.dumps(data)); print("JSONEOF")
    print(f"vault kv put -mount=secret {path} @/tmp/v.json >/dev/null && echo 'written {path}'")
print("rm -f /tmp/v.json")
EOF
)" "$ENV" "$CERT" "$KEY" | oc exec -i -n vault vault-0 -- sh -s
```

Les questions (`db username:`…) s'affichent dans le terminal ; rien n'est affiché à
la saisie, ni les noms d'utilisateur ni les mots de passe. Le script est passé à
`python3 -c` pour que la saisie reste sur le terminal ; seules les commandes `vault`
partent vers le pod.

- **Base** : pour un nouvel environnement, choisis librement l'utilisateur et le mot
  de passe : la base de l'annexe B est créée **avec** ces valeurs (même chemin Vault).
  Pour un environnement existant, ce sont les identifiants de sa base actuelle.
- **Admin** : utilisateur temporaire du premier démarrage de Keycloak (à remplacer
  par un admin permanent après le premier login).

Vérifier les clés (sans les valeurs) :

```bash
{ echo "export VAULT_TOKEN='$(python3 -c 'import json;print(json.load(open("vault-init.json"))["root_token"])')'"; echo "vault kv list -mount=secret rhbk/$ENV"; } | oc exec -i -n vault vault-0 -- sh -s
```

L'interface web est aussi utilisable :
`https://vault.<domaine>` (méthode *Token*), moteur `secret/`.

### A.8 Reprendre des Secrets créés à la main (migration)

Si un environnement fonctionne déjà avec des Secrets créés à la main :

1. Copier leurs valeurs dans Vault, sous les chemins de la section 7.
2. Activer les ExternalSecrets dans l'overlay (ligne `- external-secrets`), commit,
   push, synchro.

ESO **reprend les Secrets existants** du même nom : il les met à jour avec les
valeurs de Vault et en devient propriétaire. Si les valeurs sont identiques, rien ne
change pour Keycloak : **pas de suppression, pas de coupure**. Vérifier :

```bash
oc get secret rhbk-db-secret -n rhbk-dev -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}{"\n"}'
```

Résultat attendu : `ExternalSecret/rhbk-db-secret`.

---

## 18. Annexe B : créer la base PostgreSQL d'un environnement

La base n'est pas gérée par ArgoCD. Les manifestes sont dans `tools/postgresql/` et
s'appliquent à la main, une fois par environnement. Ils reprennent les réglages de la
base de prod (image Red Hat PostgreSQL 15, volume de 1 Gi), avec une différence : le
Secret de la base (`postgres-db`) est **créé par ESO depuis Vault**, au même chemin
que `rhbk-db-secret` (`secret/rhbk/<env>/db`). La base et Keycloak utilisent donc les
mêmes identifiants, sans mot de passe à saisir.

| Fichier | Contenu |
|---|---|
| `externalsecret.yaml` | Secret `postgres-db` (`database-user`, `database-password`, `database-name: rhbk`) depuis Vault |
| `pvc.yaml` | volume de 1 Gi (`ocs-storagecluster-ceph-rbd`) |
| `deployment.yaml` | PostgreSQL 15, stratégie `Recreate` |
| `service.yaml` | `postgres-db:5432`, sélecteur `app: postgresql-db` |

Pièges évités par rapport au template OpenShift `postgresql-persistent` : il crée un
DeploymentConfig (déprécié) et un Service dont le sélecteur (`name: postgres-db`) ne
correspond pas aux pods une fois remplacé par un Deployment, ce qui donne
`connection refused`.

### B.1 Prérequis

1. Le namespace existe (créé par `rhbk-platform`).
2. Les valeurs `secret/rhbk/<env>/db` sont dans Vault (annexe A.7).

### B.2 Les manifestes

`tools/postgresql/externalsecret.yaml`
```yaml
# Database credentials for the PostgreSQL pod, read from the same Vault path as the Keycloak
# ExternalSecret rhbk-db-secret (secret/rhbk/<env>/db): one source for both sides.
# __ENV__ is replaced at apply time (see docs/deploiement-gitops.md, annex B).
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: postgres-db
  labels:
    app: postgresql-db
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: vault-store
  target:
    name: postgres-db
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      mergePolicy: Replace
      data:
        database-name: rhbk
        database-user: "{{ .username }}"
        database-password: "{{ .password }}"
  dataFrom:
    - extract:
        key: rhbk/__ENV__/db
```

`tools/postgresql/pvc.yaml`
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-db
  labels:
    app: postgresql-db
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ocs-storagecluster-ceph-rbd
  resources:
    requests:
      storage: 1Gi
```

`tools/postgresql/deployment.yaml`
```yaml
# Same settings as the prod database (Red Hat PostgreSQL 15 image).
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-db
  labels:
    app: postgresql-db
spec:
  replicas: 1
  strategy:
    type: Recreate          # RWO volume: never two pods at the same time
  selector:
    matchLabels:
      app: postgresql-db
  template:
    metadata:
      labels:
        app: postgresql-db
    spec:
      containers:
        - name: postgresql
          image: registry.redhat.io/rhel8/postgresql-15
          ports:
            - containerPort: 5432
              protocol: TCP
          env:
            - name: POSTGRESQL_USER
              valueFrom:
                secretKeyRef:
                  name: postgres-db
                  key: database-user
            - name: POSTGRESQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: postgres-db
                  key: database-password
            - name: POSTGRESQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: postgres-db
                  key: database-name
          resources:
            limits:
              memory: 512Mi
          readinessProbe:
            exec:
              command: ["/usr/libexec/check-container"]
            initialDelaySeconds: 5
            timeoutSeconds: 1
          livenessProbe:
            exec:
              command: ["/usr/libexec/check-container", "--live"]
            initialDelaySeconds: 120
            timeoutSeconds: 10
          volumeMounts:
            - name: postgres-db-data
              mountPath: /var/lib/pgsql/data
      volumes:
        - name: postgres-db-data
          persistentVolumeClaim:
            claimName: postgres-db
```

`tools/postgresql/service.yaml`
```yaml
# Keycloak connects to "postgres-db:5432" (db.host in base/keycloak/keycloak.yaml).
# The selector must match the pod labels of deployment.yaml.
apiVersion: v1
kind: Service
metadata:
  name: postgres-db
  labels:
    app: postgresql-db
spec:
  selector:
    app: postgresql-db
  ports:
    - name: postgresql
      port: 5432
      targetPort: 5432
      protocol: TCP
```

### B.3 Créer la base

Depuis le dossier de `rhbk-gitops`. `__ENV__` est remplacé par le nom de
l'environnement ; le `---` sépare les documents YAML :

```bash
ENV=qualif
for f in tools/postgresql/*.yaml; do sed "s/__ENV__/$ENV/g" "$f"; echo '---'; done | oc apply -n rhbk-$ENV -f -
```

### B.4 Vérifier

```bash
oc get externalsecret postgres-db -n rhbk-$ENV
```

`SecretSynced`.

```bash
oc rollout status deploy/postgres-db -n rhbk-$ENV
```

Connexion par le Service, comme Keycloak (n'affiche aucune valeur) :

```bash
oc exec -n rhbk-$ENV deploy/postgres-db -- bash -c 'PGPASSWORD=$POSTGRESQL_PASSWORD psql -h postgres-db -U $POSTGRESQL_USER -d $POSTGRESQL_DATABASE -tAc "select 1"' >/dev/null && echo "connexion OK"
```

---

## 19. Annexe C : générer le certificat d'un environnement

Les routes présentent un certificat Let's Encrypt, obtenu avec
[acme.sh](https://github.com/acmesh-official/acme.sh) et un challenge DNS sur AWS
Route 53 (le domaine `apps.<cluster>` est dans une zone Route 53 du sandbox). On génère
**un certificat par environnement**, pour ses deux hostnames : pas besoin de
régénérer celui des autres environnements.

Les certificats Let's Encrypt durent **90 jours**. cert-manager pourra automatiser le
renouvellement plus tard ; en attendant, refaire cette annexe avant l'expiration.

### C.1 Prérequis

- acme.sh récupéré dans `cert/acme.sh` (dossier ignoré par git) :
  ```bash
  git clone https://github.com/acmesh-official/acme.sh.git /usr/local/dev/rhbk-gitops/cert/acme.sh
  ```
- Une clé AWS avec les droits Route 53 sur la zone du cluster.

### C.2 Identifiants AWS

Saisis sans affichage, gardés dans le terminal uniquement (jamais dans un fichier du
dépôt) :

```bash
read -r "AWS_ACCESS_KEY_ID?AWS access key id: " && read -rs "AWS_SECRET_ACCESS_KEY?AWS secret access key: " && echo && export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DNS_SLOWRATE=1
```

(Syntaxe zsh, le shell par défaut de macOS. En bash : `read -rp "..." AWS_ACCESS_KEY_ID`
et `read -rsp "..." AWS_SECRET_ACCESS_KEY`.)

### C.3 Demander le certificat

```bash
ENV=qualif
DOMAIN=apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
cd /usr/local/dev/rhbk-gitops/cert/acme.sh
```

```bash
./acme.sh --issue --server letsencrypt --keylength 4096 --accountemail <ton-email> --dns dns_aws -d $ENV-rhbk.$DOMAIN -d $ENV-rhbk-admin.$DOMAIN
```

La validation DNS prend une à deux minutes.

### C.4 Copier le certificat et la clé

Dans `cert/`, ignoré par git, avec les noms attendus par l'annexe A.7 :

```bash
./acme.sh --install-cert -d $ENV-rhbk.$DOMAIN --fullchain-file ../$ENV-rhbk.fullchain.pem --key-file ../$ENV-rhbk.key.pem
```

```bash
chmod 600 ../$ENV-rhbk.key.pem
```

### C.5 Vérifier

Les deux hostnames de l'environnement et la date d'expiration :

```bash
openssl x509 -in ../$ENV-rhbk.fullchain.pem -noout -text | grep -E 'DNS:|Not After'
```

Puis ranger le certificat dans Vault (annexe A.7, chemin `secret/rhbk/$ENV/tls`).

### C.6 Renouveler

Même commande qu'en C.3 avec `--renew` à la place de `--issue` (ou `--force` pour
renouveler avant la date prévue), puis C.4, puis remettre `tls` dans Vault (annexe A.7,
section `tls` seulement, ou l'interface web) : ESO met `rhbk-tls-secret` à jour et le
routeur prend le nouveau certificat sans redémarrage.

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

À lancer quand tu as fini, pour retirer la clé AWS du terminal.

