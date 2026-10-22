# Déployer Red Hat build of Keycloak en GitOps (prod + dev)

Ce guide décrit, étape par étape, comment construire un dépôt GitOps qui déploie
Red Hat build of Keycloak (RHBK) 26.6 sur OpenShift avec OpenShift GitOps (ArgoCD),
pour deux environnements : **prod** et **dev**.

Il couvre **uniquement la partie applicative**. Les namespaces, l'opérateur RHBK,
External Secrets Operator (ESO) et Vault sont gérés par les administrateurs dans un
second dépôt GitOps, [`rhbk-platform`](https://github.com/msakho/rhbk-platform), décrit dans son README et dans
l'annexe A (section 17).

| Dépôt | Contenu | Droits ArgoCD |
|---|---|---|
| `rhbk-platform` (administrateurs) | namespaces, opérateurs RHBK et ESO, configuration ESO, `ClusterSecretStore`, Vault | ressources cluster autorisées |
| `rhbk-gitops` (ce guide) | image Keycloak, CR Keycloak, routes, ExternalSecrets | **aucune** ressource cluster |

**Comment lire ce guide.** Les sections 2 à 13 sont des **étapes**, à faire dans l'ordre.
Chacune donne son objectif, les actions, une vérification et le résultat attendu. À la fin
de l'étape 13, le **socle** tourne : Keycloak en prod et en dev, sans observabilité.
L'observabilité s'ajoute ensuite, partie par partie, avec
[`docs/observabilite.md`](observabilite.md). Les sections 14 à 16 servent à l'exploitation,
les annexes A à D détaillent la plateforme, la base, le certificat et l'observabilité.

En suivant les étapes 1 à 13 puis les 4 parties d'`observabilite.md` dans un dépôt vide, on
obtient exactement le dépôt `https://github.com/msakho/rhbk-gitops`.

---

## Sommaire

1. [Principes](#1-principes)
2. [Étape : prérequis et valeurs à adapter](#2-étape--prérequis-et-valeurs-à-adapter)
3. [Étape : créer le dépôt et l'arborescence](#3-étape--créer-le-dépôt-et-larborescence)
4. [Étape : certificat de chaque environnement](#4-étape--certificat-de-chaque-environnement)
5. [Étape : valeurs dans Vault](#5-étape--valeurs-dans-vault)
6. [Étape : base PostgreSQL](#6-étape--base-postgresql)
7. [Étape : construire l'image Keycloak](#7-étape--construire-limage-keycloak)
8. [Étape : la base Kustomize (`base/keycloak`)](#8-étape--la-base-kustomize-basekeycloak)
9. [Étape : les overlays prod et dev](#9-étape--les-overlays-prod-et-dev)
10. [Étape : les ExternalSecrets (secrets depuis Vault)](#10-étape--les-externalsecrets-secrets-depuis-vault)
11. [Étape : la configuration ArgoCD](#11-étape--la-configuration-argocd)
12. [Étape : valider, pousser et lancer ArgoCD](#12-étape--valider-pousser-et-lancer-argocd)
13. [Étape : synchroniser et tester](#13-étape--synchroniser-et-tester)
14. [Rejouer l'exercice sur le même cluster](#14-rejouer-lexercice-sur-le-même-cluster)
15. [Exploitation courante](#15-exploitation-courante)
16. [Dépannage](#16-dépannage)
17. [Annexe A : plateforme (dépôt rhbk-platform) et Vault](#17-annexe-a--plateforme-dépôt-rhbk-platform-et-vault)
18. [Annexe B : créer la base PostgreSQL d'un environnement](#18-annexe-b--créer-la-base-postgresql-dun-environnement)
19. [Annexe C : générer le certificat d'un environnement](#19-annexe-c--générer-le-certificat-dun-environnement)
20. [Annexe D : observabilité (vue d'ensemble)](#20-annexe-d--observabilité-vue-densemble)

### Les étapes en un coup d'œil

| Étape | Où | Résultat |
|---|---|---|
| 2. Prérequis | cluster, poste de travail | plateforme prête, outils installés, valeurs choisies |
| 3. Dépôt | GitHub, poste | dépôt local avec son arborescence et son `.gitignore` |
| 4. Certificat | poste (acme.sh, annexe C) | un certificat par environnement dans `cert/` |
| 5. Vault | pod Vault (annexe A.7) | `secret/rhbk/<env>/db`, `bootstrap-admin`, `tls` |
| 6. PostgreSQL | namespace de l'environnement (annexe B) | Service `postgres-db` prêt |
| 7. Image | poste (podman) | image optimisée sur quay.io, **digest** noté |
| 8 à 11. Fichiers du dépôt | poste | base, overlays, ExternalSecrets, ArgoCD : dépôt complet en local |
| 12. Valider, pousser, ArgoCD | poste, GitHub, cluster | Applications `rhbk-root`, `rhbk-dev`, `rhbk-prod` créées |
| 13. Synchroniser et tester | ArgoCD, navigateur | Keycloak dev et prod en ligne, console isolée |

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
  (`KEYCLOAK_NAME`, `HOSTNAME_PLACEHOLDER`…) qui ne sont jamais déployées telles quelles.
- `overlays/prod/` et `overlays/dev/` fixent ce qui change par environnement :
  namespace, nom de l'instance, hostnames, nombre de pods, ressources CPU/mémoire.

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
| `PodDisruptionBudget keycloak` | Garde au moins un pod pendant les drainages de nœuds (section 8.6). |

L'observabilité ajoute ensuite une `PrometheusRule` (alertes) et des options au CR
(`observabilite.md`).

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
| 1 | CR Keycloak, PodDisruptionBudget | Keycloak démarre avec `rhbk-internal-tls`. |
| 2 | Routes | La validation de `externalCertificate` exige le RoleBinding ; ArgoCD attend que Keycloak soit **Healthy** avant cette wave. |

### 1.6 Image optimisée : options de build et options d'exécution

Keycloak tourne avec une **image construite par nos soins** (étape 7), dite *optimisée* :
`kc.sh build` y fige à l'avance les **options de build** (base de données, sondes,
métriques, fonctionnalités…), et l'opérateur la démarre en `--optimized`, sans étape de
build au démarrage. Conséquences :

- une option **de build** se règle dans le Containerfile (`ENV KC_…`), et tout changement
  impose un nouveau build et un nouveau **digest** dans le CR ;
- une option **d'exécution** se règle dans le CR (`additionalOptions`) ;
- si le CR demande une option de build différente de l'image, **Keycloak refuse de
  démarrer** (section 15.1).

---

## 2. Étape : prérequis et valeurs à adapter

**Objectif** : vérifier que la plateforme est prête, installer les outils, choisir les
valeurs propres à ton cluster.

### 2.1 Ce que fournit la plateforme (`rhbk-platform`)

Ces éléments **ne sont pas gérés par ce dépôt** : ils sont déployés par le dépôt
`rhbk-platform` (README de `rhbk-platform`, étapes 1 à 6, et annexe A). Vérifie-les :

| # | Prérequis | Vérification |
|---|---|---|
| 1 | OpenShift 4.16+ (pour `externalCertificate` sur les Routes) — testé en 4.20 | `oc version` |
| 2 | OpenShift GitOps installé, instance `openshift-gitops` | `oc get argocd -n openshift-gitops` |
| 3 | Namespaces `rhbk` et `rhbk-dev` | `oc get ns rhbk rhbk-dev` |
| 4 | Opérateur RHBK installé **dans chaque namespace** (canal `stable-v26.6`). Il ne supporte que OwnNamespace/SingleNamespace. | `oc get csv -n rhbk-dev \| grep rhbk` → `Succeeded` |
| 5 | External Secrets Operator démarré et `ClusterSecretStore vault-store` valide ; Vault initialisé et descellé (annexe A.4 à A.6) | `oc get clustersecretstore vault-store` → `Valid`, `READY True` |
| 6 | ArgoCD a les droits sur les namespaces cibles | `oc auth can-i create keycloaks.k8s.keycloak.org -n rhbk-dev --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller` → `yes` |
| 7 | Stockage en bloc pour la base PostgreSQL | `oc get storageclass ocs-storagecluster-ceph-rbd` |

> **Si le prérequis 6 répond `no`**, vérifie que le namespace porte le label
> `argocd.argoproj.io/managed-by=openshift-gitops` : il est posé par `rhbk-platform`
> (`operators/rhbk/base/namespace.yaml`).

### 2.2 Outils et accès sur le poste de travail

| Outil ou accès | Pour | Vérification |
|---|---|---|
| `oc` (même version que le cluster), connecté au cluster | toutes les étapes | `oc version`, `oc whoami` |
| `git` et accès en écriture à un dépôt GitHub (CLI `gh` conseillée) | étapes 3 et 8 à 12 | `git --version`, `gh auth status` |
| `podman` | étape 7 | `podman --version` |
| Compte Red Hat (lecture de `registry.redhat.io`) | étape 7 | `podman login registry.redhat.io` |
| Compte quay.io et dépôt d'images (ici `quay.io/msakho0/mskeycloak`, **public**) | étape 7 | `podman login quay.io` |
| `openssl`, `python3`, acme.sh et une clé AWS Route 53 | étapes 4 et 5 | annexe C.1 |

Si le dépôt quay.io est **privé**, le cluster doit recevoir un pull secret pour cette image
(`spec.imagePullSecrets` du CR) : ce guide suppose un dépôt public.

### 2.3 Valeurs à adapter

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
| Image | `quay.io/msakho0/mskeycloak:26.6` + digest de l'étape 7 | `base/keycloak/keycloak.yaml` |
| ClusterSecretStore | `vault-store` | `overlays/*/external-secrets/*.yaml` |
| Chemins Vault | `rhbk/prod/...`, `rhbk/dev/...` | `overlays/*/external-secrets/*.yaml` |

Une fois tous les fichiers créés, un `sed` suffit pour changer le domaine :

```bash
grep -rl 'apps.cluster-nnljw.nnljw.sandbox742.opentlc.com' overlays | xargs sed -i '' 's#apps.cluster-nnljw.nnljw.sandbox742.opentlc.com#<NOUVEAU_DOMAINE>#g'
```

(Sur Linux, remplacer `sed -i ''` par `sed -i`.)

**Résultat** : les vérifications des tableaux 2.1 et 2.2 passent, et tu connais tes valeurs.

---

## 3. Étape : créer le dépôt et l'arborescence

**Objectif** : un dépôt git local avec son arborescence, protégé contre l'ajout de secrets.

### 3.1 Créer le dépôt sur GitHub

Crée un dépôt vide (sans README ni .gitignore) sur GitHub, par exemple
`rhbk-gitops-v2`. S'il est **public**, ArgoCD le lit sans identifiants. S'il est
**privé**, il faudra le déclarer dans ArgoCD (étape 12.3).

### 3.2 Créer l'arborescence locale

```bash
mkdir -p ~/rhbk-gitops-v2 && cd ~/rhbk-gitops-v2
```

```bash
mkdir -p bootstrap argocd/applications base/keycloak overlays/prod/external-secrets overlays/dev/external-secrets custom-rhbk docs tools/postgresql
```

Arborescence cible du socle :

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
  Containerfile              étape 7
tools/
  postgresql/                hors ArgoCD : base d'un environnement (annexe B)
docs/
  deploiement-gitops.md
```

L'observabilité ajoutera `base/keycloak/prometheusrule.yaml` (partie 1).

### 3.3 `.gitignore`

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

**Résultat** : arborescence vide créée, `.gitignore` en place.

---

## 4. Étape : certificat de chaque environnement

**Objectif** : un certificat Let's Encrypt par environnement, couvrant ses deux hostnames
(public et admin). Le routeur le présentera aux navigateurs.

**Actions** : suivre l'**annexe C** (C.1 à C.5) avec `ENV=dev`, puis avec `ENV=prod`. Les
fichiers sont écrits dans `cert/`, dossier ignoré par git (`.gitignore`, étape 3.3). Dans les
commandes de l'annexe, remplace `/usr/local/dev/rhbk-gitops` par le dossier de ton dépôt.

**Vérifier** : les deux hostnames de l'environnement et la date d'expiration :

```bash
openssl x509 -in cert/dev-rhbk.fullchain.pem -noout -text | grep -E 'DNS:|Not After'
```

**Résultat** : `cert/<env>-rhbk.fullchain.pem` et `cert/<env>-rhbk.key.pem` pour dev et prod.

---

## 5. Étape : valeurs dans Vault

**Objectif** : ranger dans Vault, pour chaque environnement, les trois valeurs que Keycloak
lira par ESO (étape 10). Aucune n'est écrite dans git.

| Chemin Vault | Clés | Contenu |
|---|---|---|
| `secret/rhbk/<env>/db` | `username`, `password` | identifiants de la base ; pour une base neuve, à choisir librement : l'étape 6 crée la base **avec** ces valeurs |
| `secret/rhbk/<env>/bootstrap-admin` | `username`, `password` | admin temporaire du premier démarrage de Keycloak |
| `secret/rhbk/<env>/tls` | `tls.crt` (fullchain), `tls.key` | certificat de l'étape 4 |

**Actions** : suivre l'**annexe A.7** avec `ENV=dev`, puis avec `ENV=prod`. Les valeurs
sont saisies sans affichage. Les variables `CERT` et `KEY` pointent vers les fichiers de
l'étape 4, dans le `cert/` de ton dépôt.

**Vérifier** : la commande de fin de l'annexe A.7 liste `bootstrap-admin`, `db` et `tls`.

**Résultat** : trois entrées par environnement dans Vault.

---

## 6. Étape : base PostgreSQL

**Objectif** : une base PostgreSQL par environnement, joignable par Keycloak sous le nom
**`postgres-db:5432`**, base **`rhbk`**. Elle n'est pas gérée par ArgoCD : ses manifestes
sont dans `tools/postgresql/` et s'appliquent à la main.

**Actions** :

1. Créer dans `tools/postgresql/` les 4 fichiers de l'**annexe B.2** (ils font partie du
   dépôt, mais ArgoCD ne les lit pas).
2. Depuis le dossier du dépôt, appliquer l'**annexe B.3** avec `ENV=dev`, puis avec
   `ENV=prod`. Le mot de passe de la base est lu dans Vault (étape 5) : rien à saisir.

**Vérifier** (annexe B.4) :

```bash
oc get svc postgres-db -n rhbk-dev && oc rollout status deploy/postgres-db -n rhbk-dev
```

**Résultat** : Deployment `postgres-db` prêt dans `rhbk` et `rhbk-dev`.

---

## 7. Étape : construire l'image Keycloak

**Objectif** : une image Keycloak optimisée (section 1.6), publiée sur quay.io, et son
**digest**, qui fige la version déployée dans le CR (étape 8.4).

### 7.1 Le Containerfile

Dans le dépôt local (étape 3), crée le fichier `custom-rhbk/Containerfile`. Il construit
l'image en deux temps : l'étage `builder` lance `kc.sh build` avec les options de build,
puis l'image finale ne copie que le résultat. Les commandes des étapes 7.3 à 7.5 se lancent
depuis le dossier du dépôt.

| Option de build | Pourquoi |
|---|---|
| `KC_DB=postgres` | pilote de base de données figé dans l'image |
| `KC_HEALTH_ENABLED=true` | sondes `/health` utilisées par l'opérateur : **obligatoire** |
| `KC_METRICS_ENABLED=true` | point `/metrics` (port 9000), prêt pour la partie 1 de l'observabilité |

Les options repérées `[Observability part N]` s'ajoutent avec `observabilite.md` (parties 2
et 4). Les lignes commentées montrent où ajouter un thème ou un provider (JAR).

`custom-rhbk/Containerfile`
```dockerfile
FROM registry.redhat.io/rhbk/keycloak-rhel9:26.6 AS builder

# Build-time options: they are baked into the optimized image and must match the
# Keycloak CR (base/keycloak/keycloak.yaml), since the operator starts a custom image with --optimized.
# An optimized image refuses to start if the CR asks for a different value of a build-time option.
# Grouped by observability part (docs/observabilite.md): keep only the lines of the parts you deploy.
ENV KC_DB=postgres
# [Observability part 1 - metrics and alerts] health probes and /metrics endpoint (port 9000).
# Keep both lines in every image, even without observability: the operator probes use /health.
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true

WORKDIR /opt/keycloak

# Enable custom theme.
# COPY ./themes/my-theme/ /opt/keycloak/themes/my-theme

# Add the provider JAR file to the providers directory
# ADD --chown=keycloak:keycloak --chmod=644 <MY_PROVIDER_JAR_URL> /opt/keycloak/providers/myprovider.jar

RUN /opt/keycloak/bin/kc.sh build


FROM registry.redhat.io/rhbk/keycloak-rhel9:26.6
COPY --from=builder /opt/keycloak/ /opt/keycloak/

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
```

### 7.2 Se connecter aux registres

L'image de base vient de `registry.redhat.io` (compte Red Hat) ; l'image construite part
sur quay.io :

```bash
podman login registry.redhat.io
```

```bash
podman login quay.io
```

### 7.3 Construire et pousser

`--platform linux/amd64` : les nœuds du cluster sont en x86_64, alors qu'un Mac récent est
en ARM. Le tag `26.6` de l'image de base pointe toujours sur la **dernière 26.6.x** publiée
par Red Hat.

```bash
podman build --platform linux/amd64 -t quay.io/msakho0/mskeycloak:26.6 -f custom-rhbk/Containerfile custom-rhbk
```

```bash
podman push quay.io/msakho0/mskeycloak:26.6
```

### 7.4 Récupérer le digest

```bash
oc image info quay.io/msakho0/mskeycloak:26.6 | grep Digest
```

Note la valeur `sha256:…` : elle va dans `image:` du CR (étape 8.4). Le tag `26.6` est
réécrit à chaque build ; le **digest** désigne une image précise, qui ne change jamais. Avec
lui, ArgoCD déploie exactement l'image testée, et un nouveau build ne change rien tant que
le digest du CR n'est pas mis à jour.

### 7.5 Vérifier

Les options figées dans l'image (marquées `Persisted`) :

```bash
podman run --rm --platform linux/amd64 quay.io/msakho0/mskeycloak:26.6 show-config | grep Persisted
```

Résultat attendu pour le socle : `kc.db = postgres`, `kc.health-enabled = true`,
`kc.metrics-enabled = true`, `kc.optimized = true`. La version de Keycloak contenue dans
l'image :

```bash
podman run --rm --platform linux/amd64 --entrypoint cat quay.io/msakho0/mskeycloak:26.6 /opt/keycloak/version.txt
```

**Résultat** : image publiée sur quay.io, digest noté.

Pour reconstruire l'image plus tard (nouvelle version 26.6.x, nouvelle option de build) :
section 15.1.

---

## 8. Étape : la base Kustomize (`base/keycloak`)

**Objectif** : les manifestes communs aux deux environnements, avec des valeurs factices
que les overlays remplacent (étape 9).

### 8.1 `base/keycloak/kustomization.yaml`

`base/keycloak/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - internal-svc.yaml
  - router-secret-reader-rbac.yaml
  - keycloak.yaml
  - routes.yaml
  - poddisruptionbudget.yaml
```

### 8.2 `base/keycloak/internal-svc.yaml`

Service interne. L'annotation `service.beta.openshift.io/serving-cert-secret-name`
demande au service-ca d'OpenShift de générer un certificat pour
`rhbk-internal.<namespace>.svc` dans le secret `rhbk-internal-tls`.

On ne peut pas réutiliser le Service `rhbk-<env>-service` créé par l'opérateur :
l'opérateur le gère et retirerait l'annotation.

`base/keycloak/internal-svc.yaml`
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

### 8.3 `base/keycloak/router-secret-reader-rbac.yaml`

Le routeur (ServiceAccount `router` du namespace `openshift-ingress`) doit pouvoir
lire `rhbk-tls-secret` pour utiliser `externalCertificate`. Sans ce droit, l'API
refuse la création des routes (`Forbidden: router serviceaccount does not have
permission to get this secret`).

`base/keycloak/router-secret-reader-rbac.yaml`
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

### 8.4 `base/keycloak/keycloak.yaml`

Le CR Keycloak. Points clés :

- `SkipDryRunOnMissingResource=true` : si l'opérateur (donc la CRD) manque, ArgoCD
  donne une erreur claire au lieu d'échouer au dry-run de toute l'Application.
- `image` : l'image de l'étape 7, **avec son digest** (remplace `<DIGEST>` par la valeur
  notée à l'étape 7.4, `sha256:…`).
- `startOptimized: true` : l'image est déjà construite (`kc.sh build`), Keycloak
  démarre en `--optimized`. Les options de build de l'image doivent correspondre au CR
  (section 1.6).
- `bootstrapAdmin` : admin temporaire, utilisé seulement au premier démarrage (base vide).
- `hostname.strict: true` : les URL ne sont pas déduites des en-têtes des requêtes.
- `db.host: postgres-db` : nom court, résolu dans le namespace de l'instance ;
  le même CR fonctionne dans les deux environnements.
- `http.tlsSecret: rhbk-internal-tls` : le certificat interne de la section 8.2.
- `ingress.enabled: false` : l'exposition est faite par `routes.yaml`.
- `scheduling` : anti-affinité, pour placer les pods de prod sur des nœuds différents.
- Les options d'observabilité (`features`, `tracing`, `additionalOptions`) s'ajoutent avec
  `observabilite.md`, aux places indiquées par chaque partie.

`base/keycloak/keycloak.yaml`
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
  # Custom optimized image (custom-rhbk/Containerfile), pinned by digest: build-time options
  # are baked in the image. Observability options are tagged [Observability part N] below
  # (docs/observabilite.md).
  image: quay.io/msakho0/mskeycloak:26.6@<DIGEST>
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

### 8.5 `base/keycloak/routes.yaml`

Trois routes en reencrypt. Les deux routes publiques partagent le même hostname,
avec un `path` différent. La route admin n'a pas de `path` : elle prend tout.

`base/keycloak/routes.yaml`
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

### 8.6 `base/keycloak/poddisruptionbudget.yaml`

Un PodDisruptionBudget (PDB) limite le nombre de pods arrêtés en même temps lors d'une
**interruption volontaire**, c'est-à-dire surtout un **drainage de nœud** (mise à jour
d'OpenShift, maintenance). Avant d'évincer un pod, le drainage consulte le PDB et attend
si l'éviction ferait passer sous le seuil. Le PDB ne protège ni contre une panne (nœud
perdu, crash) ni contre un rollout de l'opérateur Keycloak.

L'opérateur Keycloak ne crée pas de PodDisruptionBudget : on l'ajoute dans la base, donc
**prod et dev en ont un**. Le même `maxUnavailable: 1` se comporte différemment selon le
nombre de replicas :

| | Prod (2 replicas) | Dev (1 replica) |
|---|---|---|
| Drainage d'un nœud | un pod évincé à la fois, le second seulement quand le premier est de nouveau prêt ailleurs : **pas de coupure** | le pod unique peut être évincé : le drainage n'est **jamais bloqué**, courte coupure acceptée en dev |

À l'inverse, `maxUnavailable: 0` (ou `minAvailable: 1` avec un seul replica) interdit
toute éviction et **bloque les drainages** (cas rencontré avec le chart Vault, alerte
`PodDisruptionBudgetAtLimit`). Avec `maxUnavailable: 1`, un seul fichier convient aux deux
environnements : l'overlay ne remplace que le nom d'instance dans le sélecteur
(`replacements`, section 9.1). Le PDB complète l'anti-affinité du CR (section 8.4), qui
place les pods de prod sur des nœuds différents : un drainage n'en touche qu'un.

`base/keycloak/poddisruptionbudget.yaml`
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

**Résultat** : 6 fichiers dans `base/keycloak/`.

---

## 9. Étape : les overlays prod et dev

**Objectif** : ce qui change par environnement (namespace, nom d'instance, hostnames,
nombre de pods, ressources). Chaque overlay contient 4 fichiers ; prod et dev ne diffèrent
que par les valeurs.

### 9.1 `overlays/prod/kustomization.yaml`

- `resources` : la base Keycloak et les ExternalSecrets de l'environnement
  (étape 10).
- `namespace` : appliqué à toutes les ressources (sauf le `subjects[].namespace`
  `openshift-ingress` du RoleBinding, que Kustomize ne touche pas).
- `labels` : ajoutés sur toutes les ressources, sans toucher aux sélecteurs.
- `patches` : l'ordre compte. `patch-routes.yaml` met le hostname public sur
  **toutes** les routes, puis `patch-route-admin.yaml` corrige celui de `rhbk-admin`.
- `replacements` : recopie le nom de l'instance Keycloak (fixé par
  `patch-keycloak.yaml`) dans les sélecteurs du Service et du PodDisruptionBudget, et
  dans l'anti-affinité. Le nom n'est ainsi écrit qu'à un seul endroit.

`overlays/prod/kustomization.yaml`
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

### 9.2 `overlays/prod/patch-keycloak.yaml`

Patch JSON 6902 (liste d'opérations) appliqué au CR Keycloak. La prod tourne avec
**2 instances** (haute disponibilité, section 15.8) ; dev avec une seule.

`overlays/prod/patch-keycloak.yaml`
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
```

### 9.3 `overlays/prod/patch-routes.yaml`

`overlays/prod/patch-routes.yaml`
```yaml
# Applied to every Route; the admin host is fixed right after by patch-route-admin.yaml.
- op: replace
  path: /spec/host
  value: prod-rhbk.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
```

### 9.4 `overlays/prod/patch-route-admin.yaml`

Patch « strategic merge » : Kustomize retrouve la route par son nom.

`overlays/prod/patch-route-admin.yaml`
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: rhbk-admin
spec:
  host: prod-rhbk-admin.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
```

### 9.5 `overlays/dev/*`

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
# Client IP: read the X-Forwarded-* headers set by the OpenShift router (reencrypt routes).
# Safe only with the router replacing these headers (patch-routes.yaml), see guide 15.11.
- op: add
  path: /spec/proxy
  value:
    headers: xforwarded
```

`overlays/dev/patch-routes.yaml`
```yaml
# Applied to every Route; the admin host is fixed right after by patch-route-admin.yaml.
- op: replace
  path: /spec/host
  value: dev-rhbk.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
# The router replaces X-Forwarded-For (default: appends to the client value, which a client could
# forge). Required with proxy headers enabled in the Keycloak CR (patch-keycloak.yaml).
- op: add
  path: /metadata/annotations/haproxy.router.openshift.io~1set-forwarded-headers
  value: replace
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

**Résultat** : `overlays/prod/` et `overlays/dev/` avec 4 fichiers chacun (les
ExternalSecrets suivent à l'étape 10).

---

## 10. Étape : les ExternalSecrets (secrets depuis Vault)

**Objectif** : faire créer par ESO, depuis Vault (étape 5), les trois Secrets dont Keycloak
a besoin. Ils ne sont **jamais écrits dans git** : le dépôt contient seulement des
`ExternalSecret`, qui indiquent à ESO quel chemin lire dans Vault et quel Secret
Kubernetes créer.

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

**Résultat** : 4 fichiers dans `overlays/<env>/external-secrets/` pour chaque environnement.

---

## 11. Étape : la configuration ArgoCD

**Objectif** : le projet ArgoCD, les deux Applications (une par environnement) et l'app of
apps qui les crée.

### 11.1 `argocd/appproject.yaml`

Le projet `rhbk` limite ce que ses Applications peuvent faire : un seul dépôt
source, deux namespaces cibles, et **aucune ressource de niveau cluster** : les
namespaces et les opérateurs appartiennent à `rhbk-platform`.

`argocd/appproject.yaml`
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

### 11.2 `argocd/applications/rhbk-prod.yaml`

Prod est en **synchro manuelle** : pas de bloc `automated`. ArgoCD détecte les
écarts (`OutOfSync`) mais n'applique rien sans un clic sur **Sync**.

Pas de `CreateNamespace` ni de `managedNamespaceMetadata` : le namespace est créé et
étiqueté par `rhbk-platform`. Si les deux dépôts géraient les métadonnées du
namespace, les Applications de la plateforme resteraient `OutOfSync`.

`argocd/applications/rhbk-prod.yaml`
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

### 11.3 `argocd/applications/rhbk-dev.yaml`

Dev est en **synchro automatique** : chaque commit est appliqué, les ressources
retirées du dépôt sont supprimées (`prune`) et les modifications manuelles sur le
cluster sont annulées (`selfHeal`).

`argocd/applications/rhbk-dev.yaml`
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

### 11.4 `argocd/kustomization.yaml`

`argocd/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - appproject.yaml
  - applications/rhbk-prod.yaml
  - applications/rhbk-dev.yaml
```

### 11.5 `bootstrap/root-app.yaml`

L'app of apps. Elle appartient au projet `default`, car le projet `rhbk` n'existe
pas encore quand on l'applique.

`bootstrap/root-app.yaml`
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

### 11.6 Changer l'URL du dépôt

Si tu utilises un autre dépôt, remplace l'URL dans les 4 fichiers :

```bash
grep -rl 'github.com/msakho/rhbk-gitops.git' bootstrap argocd | xargs sed -i '' 's#https://github.com/msakho/rhbk-gitops.git#https://github.com/<compte>/<depot>.git#g'
```

**Résultat** : le dépôt local est complet.

---

## 12. Étape : valider, pousser et lancer ArgoCD

**Objectif** : vérifier le dépôt, le publier sur GitHub, puis donner la main à ArgoCD.

### 12.1 Valider en local

**Rendu Kustomize** (aucun accès au cluster nécessaire) :

```bash
oc kustomize overlays/prod > /dev/null && oc kustomize overlays/dev > /dev/null && oc kustomize argocd > /dev/null && echo "BUILD OK"
```

**Aucune valeur factice ne doit rester** dans le rendu (ni le `<DIGEST>` de l'étape 8.4) :

```bash
oc kustomize overlays/dev | grep -nE 'PLACEHOLDER|KEYCLOAK_NAME|<DIGEST>' || echo "OK : aucune valeur factice"
```

**Valeurs clés du rendu** :

```bash
oc kustomize overlays/dev | grep -nE '^  namespace:|host:|hostname:|admin: https|instance:|image:'
```

Vérifie le namespace, les 3 hostnames de routes, les 2 hostnames du CR, le nom
de l'instance dans les sélecteurs et l'image avec son digest.

**Dry-run côté serveur** (connecté au cluster) :

```bash
oc apply --dry-run=server -k overlays/dev
```

Les ressources doivent apparaître en `created (server dry run)` ou
`configured (server dry run)`. Il échoue sur les `ExternalSecret` si ESO n'est pas
installé (CRD absente, prérequis 5), ou si le namespace n'existe pas (prérequis 3).

Sur un environnement déjà déployé par ArgoCD, l'avertissement
`missing the kubectl.kubernetes.io/last-applied-configuration annotation` est
normal : ArgoCD applique en server-side apply et ne pose pas cette annotation.

### 12.2 Commit et push

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

### 12.3 Dépôt privé

ArgoCD doit pouvoir lire le dépôt. Dans la console ArgoCD : **Settings →
Repositories → Connect repo**, méthode HTTPS, avec un token en lecture seule.

### 12.4 Lancer ArgoCD (bootstrap)

Revérifie une dernière fois les prérequis de l'étape 2 pour les deux namespaces, puis
applique l'app of apps :

```bash
oc apply -f bootstrap/root-app.yaml
```

Vérifie la création des Applications (environ 30 secondes) :

```bash
oc get applications -n openshift-gitops -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

**Résultat attendu** :

| Application | SYNC | HEALTH |
|---|---|---|
| `rhbk-root` | Synced | Healthy |
| `rhbk-dev` | OutOfSync puis Synced | Progressing puis Healthy |
| `rhbk-prod` | OutOfSync | Missing ou Healthy |

---

## 13. Étape : synchroniser et tester

**Objectif** : Keycloak en ligne en dev puis en prod, console d'administration isolée.

### 13.1 Dev (automatique)

Rien à faire. Suis l'avancement :

```bash
oc get application rhbk-dev -n openshift-gitops -w
```

Compte 1 à 2 minutes. L'ordre des waves est visible dans la console ArgoCD : le
Service et le RBAC, puis Keycloak, qui doit devenir **Healthy**, puis les routes.

### 13.2 Prod (manuel)

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

### 13.3 État

```bash
oc get applications -n openshift-gitops -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

```bash
oc get keycloak,pods,route -n rhbk-dev
```

```bash
oc get externalsecret -n rhbk-dev
```

Les trois ExternalSecrets doivent être en `SecretSynced` / `READY True`. En prod, deux
pods `rhbk-prod-0` et `rhbk-prod-1`, sur des nœuds différents :

```bash
oc get pods -n rhbk -l app=keycloak -o wide
```

Version de Keycloak qui tourne :

```bash
oc exec -n rhbk-dev rhbk-dev-0 -- cat /opt/keycloak/version.txt
```

### 13.4 Isolation et accès

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

### 13.5 Connexion

1. Ouvre `https://dev-rhbk-admin.<domaine>/admin/`.
2. Connecte-toi avec l'admin temporaire :
   ```bash
   oc extract secret/initial-admin-secret -n rhbk-dev --to=-
   ```
3. Crée un administrateur permanent dans le realm `master`, puis supprime
   l'utilisateur temporaire.

### 13.6 Et ensuite

Le socle est en place. Pour l'observabilité (métriques et alertes, tableaux de bord, logs,
traces), suivre [`docs/observabilite.md`](observabilite.md), partie par partie. Pour
l'exploitation au quotidien : section 15.

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
4. Applique le `bootstrap/root-app.yaml` du **nouveau** dépôt (étape 12.4).
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

Première construction de l'image et explications : étape 7.

1. Modifier `custom-rhbk/Containerfile` si besoin (sans modification, un nouveau build prend
   la dernière version 26.6.x de l'image Red Hat), puis builder et pousser :
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

En synchro manuelle, lancer **Sync** depuis la console ArgoCD (section 13.2).

#### 15.3.7 Tester

Le script de la section 13.4 avec `qualif` :

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
partie 2 de `observabilite.md` (`user-event-metrics`, histogrammes HTTP).

| Origine | Alertes | Défini dans |
|---|---|---|
| Keycloak et PostgreSQL, par environnement | `observabilite.md`, étape 1.3 | `rhbk-gitops`, `base/keycloak/prometheusrule.yaml` |
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
   (section 8.6) et l'alerte `KeycloakDegraded`, qui signale un pod en échec que le
   service masque.

**Option à évaluer** : `spec.update.strategy: Auto`. L'opérateur lance un Job qui vérifie
si l'ancienne et la nouvelle image peuvent cohabiter : si oui (simple changement
d'options de build, correctif mineur), il fait un rolling update même quand l'image
change ; sinon, un recreate. À tester en dev avant de l'appliquer en prod.

### 15.9 Logs centralisés

Les logs de Keycloak (et de PostgreSQL, Vault, ESO, ArgoCD…) sont collectés par
OpenShift Logging et stockés 7 jours dans Loki (`rhbk-platform`, Application `logging`).
Keycloak écrit ses logs en **JSON** (`log-console-output: json`, `observabilite.md`, étape 3.4).

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

**Échantillonnage** : 100 % des requêtes en dev, **10 % en prod**, pour limiter le volume.

| Où | Valeur |
|---|---|
| CR Keycloak, `spec.tracing.samplerRatio` (`base/keycloak/keycloak.yaml`) | `1` : 100 %, valeur de dev |
| patch prod (`overlays/prod/patch-keycloak.yaml`) | `0.1` : 10 % |

```bash
oc get keycloak -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,RATIO:.spec.tracing.samplerRatio'
```

*Comment se fait la sélection.* C'est **Keycloak** qui décide, au début de chaque requête ; le
Collector et Tempo ne reçoivent que les traces retenues. L'échantillonneur est celui
d'OpenTelemetry par défaut, `traceidratio` (option `tracing-sampler-type`, non modifiée) :
l'identifiant de trace, généré au hasard, est comparé à un seuil (10 % de la plage pour `0.1`).
Conséquences :

- en pratique un **tirage au sort uniforme** : environ 1 requête sur 10 sur la durée, sans
  biais d'URL, d'utilisateur, de realm ou de pod (sur peu de requêtes, la proportion varie) ;
- une trace est gardée **en entier ou pas du tout** (tous ses spans suivent la décision) ;
- les deux pods de prod décident de la même façon (la décision ne dépend que de l'identifiant) ;
- une requête lente ou en erreur n'a **pas plus de chances** d'être gardée : pour observer une
  requête précise, la reproduire plusieurs fois, ou tester en dev (100 %) ;
- la décision d'une application cliente tracée qui transmet son contexte (`traceparent`) est
  **ignorée** : Keycloak garde le même identifiant de trace mais refait son propre tirage.

`samplerRatio` est une option **d'exécution** : la changer donne un rolling update (sans
coupure en prod). Elle ne dépend pas du stockage de Tempo ; avec un volume de taille fixe
(TempoMonolithic sur PV), elle limite aussi le volume écrit.

*Autres méthodes, non mises en place* :

| Méthode | Principe | Mise en œuvre |
|---|---|---|
| `parentbased_traceidratio` | suit la décision de l'appelant quand il transmet un contexte ; tirage à `samplerRatio` sinon | `tracing-sampler-type` est une option **de build** : `ENV KC_TRACING_SAMPLER_TYPE=parentbased_traceidratio` dans le Containerfile, rebuild, nouveau digest (recreate en prod) |
| Échantillonnage *a posteriori* (« tail sampling ») | le Collector attend la fin de chaque trace pour décider : garder **toutes les traces en erreur ou lentes** et une fraction des autres | Keycloak envoie tout (`samplerRatio: 1`), filtrage dans le Collector (processeur `tail_sampling`) ; plus de mémoire pour le Collector, à tester avant usage |

**Activer le traçage, dans l'ordre** (section 15.8) :

1. commit d'options seul : `spec.tracing.endpoint` et `samplerRatio` (ignorés tant que
   l'image n'a pas le traçage : simple avertissement « UNAVAILABLE ») ;
2. commit d'image seul : rebuild avec `KC_TRACING_ENABLED=true`, nouveau digest, et
   `spec.tracing.enabled: true` (option de build qui doit correspondre à l'image) ; recreate.

Exemple observé : une demande de jeton pour un utilisateur inexistant dure environ 460 ms,
dont l'essentiel dans `TokenEndpoint.processGrantRequest` alors que les requêtes SQL
prennent moins de 1 ms : Keycloak calcule volontairement un hachage de mot de passe factice
pour qu'on ne puisse pas deviner, à la durée de réponse, si un compte existe.

### 15.11 Adresse IP des clients (en-têtes de proxy)

Avec des routes **reencrypt** (ou edge), le routeur OpenShift déchiffre la requête et ajoute les
en-têtes `X-Forwarded-For`, `X-Forwarded-Host`, `X-Forwarded-Proto`, `X-Forwarded-Port` et
`Forwarded`. Keycloak ne les lit que si on le lui demande (`proxy-headers`). Sans cela, il voit
l'**IP du pod routeur** comme adresse du client (événements, sessions affichées dans la console,
logs). Les URL restent correctes dans les deux cas : `hostname` est une URL complète avec
`strict: true`. En **passthrough**, le routeur ne voit que du chiffré : il ne peut ajouter aucun
en-tête, et l'IP du client est perdue.

Deux réglages, **appliqués en dev** (prod : à reporter dans `overlays/prod`, ou à passer dans la base) :

| Réglage | Où | Pourquoi |
|---|---|---|
| `spec.proxy.headers: xforwarded` | CR Keycloak (`overlays/dev/patch-keycloak.yaml`) | Keycloak prend l'IP du client dans `X-Forwarded-For` (option d'exécution : rolling update) |
| annotation `haproxy.router.openshift.io/set-forwarded-headers: replace` | chaque Route (`overlays/dev/patch-routes.yaml`) | le routeur **remplace** `X-Forwarded-For` au lieu de compléter la valeur envoyée par le client, qu'un client pourrait falsifier |

Le second réglage est indispensable avec le premier : par défaut, le routeur ajoute l'IP réelle à la
suite d'un éventuel `X-Forwarded-For` envoyé par le client, et Keycloak lit la première valeur. Un
client pourrait alors se faire passer pour n'importe quelle adresse.

Option supplémentaire, non appliquée : `proxy-trusted-addresses` (adresses des proxys de confiance,
par exemple le réseau des pods). Keycloak ignore alors les en-têtes venant d'ailleurs ; utile parce
que la NetworkPolicy de l'opérateur ouvre le port 8443 à tout le cluster.

**Vérifier** : une demande de jeton pour un client inexistant (aucun identifiant) produit un
événement `CLIENT_LOGIN_ERROR`, journalisé avec l'IP retenue par Keycloak :

```bash
curl -s -o /dev/null -H "X-Forwarded-For: 1.2.3.4" -d "grant_type=client_credentials&client_id=ip-test" https://dev-rhbk.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com/realms/master/protocol/openid-connect/token
```

```bash
oc logs -n rhbk-dev rhbk-dev-0 --since=1m | grep -o 'clientId=\\"ip-test\\"[^}]*ipAddress=\\"[^\\]*'
```

Résultat observé : avant les réglages, `ipAddress` était l'IP d'un pod routeur (`10.131.0.16`) ;
après, c'est l'**IP publique du client**, y compris avec le faux `X-Forwarded-For: 1.2.3.4`, qui est
ignoré. Mêmes résultats sur le hostname admin. Les traces (`client.address`) montraient déjà la
bonne IP : l'instrumentation OpenTelemetry lit elle-même `X-Forwarded-For`.

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
| Les ExternalSecrets restent `OutOfSync` dans ArgoCD alors qu'ils sont `SecretSynced` | Les valeurs par défaut ajoutées par le webhook d'ESO ne sont pas dans git | Les déclarer explicitement (section 10) ; comparer avec `oc get externalsecret <nom> -n <ns> -o yaml`. |
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
| 6 | Puis, dans ce dépôt : bootstrap applicatif (étape 12.4) |

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

1. Copier leurs valeurs dans Vault, sous les chemins de la section 10.
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

---

## 20. Annexe D : observabilité (vue d'ensemble)

Cette annexe rassemble toute l'observabilité de RHBK : ce qui est en place, où le voir,
où c'est défini, comment le mettre en place et les pièges rencontrés. Le détail est dans
les sections référencées et dans le README de `rhbk-platform`.

> **Mise en place partie par partie** (métriques et alertes, tableaux de bord, logs,
> traces), avec le contenu complet de chaque fichier et la possibilité de ne déployer que
> certaines parties : **`docs/observabilite.md`**.

### D.1 Architecture

```
                                   ┌──────────────── console OpenShift ────────────────┐
                                   │ Observe → Alerting / Metrics / Dashboards (Perses)│
                                   │ Observe → Logs           Observe → Traces          │
                                   └──────────▲──────────────▲──────────────▲───────────┘
 Keycloak rhbk-prod / rhbk-dev                │              │              │
 ├─ métriques (port 9000) ──▶ Prometheus (projets utilisateur) ──▶ Thanos Querier ──▶ Grafana
 │                            └─▶ Thanos Ruler (alertes) ──▶ Alertmanager ──▶ rhbk-team (webhook / SMTP)
 ├─ logs JSON (stdout) ─────▶ collecteur Vector (chaque nœud) ──▶ LokiStack ──▶ bucket NooBaa loki-rhbk
 └─ traces OTLP (4317) ─────▶ OpenTelemetry Collector ──▶ TempoStack (passerelle) ──▶ bucket NooBaa tempo-rhbk
 PostgreSQL, Vault, ESO, ArgoCD : état des pods (kube-state-metrics), métriques ESO et ArgoCD, logs
```

### D.2 Quoi, où le voir, où c'est défini

| Besoin | Où le voir | Défini dans | Section |
|---|---|---|---|
| État d'ensemble (prod / dev, base, Vault, ESO, ArgoCD, trafic, connexions) | Observe → Dashboards (Perses), projet `rhbk-observability` | `rhbk-platform` : `observability-console/` | README plateforme |
| Tableaux officiels Keycloak (*troubleshooting*, *capacity planning*) | `https://grafana.apps.<domaine>` (compte OpenShift) | `rhbk-platform` : `grafana/` | 15.6 |
| Alertes Keycloak / PostgreSQL | Observe → Alerting | `rhbk-gitops` : `base/keycloak/prometheusrule.yaml` | `observabilite.md` 1.3, 15.6 |
| Alertes ESO, Vault, ArgoCD | Observe → Alerting | `rhbk-platform` : `monitoring/` | 15.6 |
| Notifications | logs du webhook `alert-webhook-test` (puis e-mail) | `rhbk-platform` : `monitoring/alertmanager-main.yaml` | 15.7 |
| Requêtes sur les métriques | Observe → Metrics | — | 15.6 |
| Logs (Keycloak en JSON, PostgreSQL, Vault, ESO, ArgoCD) | Observe → Logs | `rhbk-platform` : `logging/` (y compris le plugin de console) ; option Keycloak dans `base/keycloak/keycloak.yaml` | 15.9 |
| Traces (requête HTTP → traitement → SQL) | Observe → Traces, instance `rhbk-tracing / tempo`, tenant `rhbk` | `rhbk-platform` : `tracing/` (y compris le plugin de console) ; `spec.tracing` dans le CR | 15.10 |
| Haute disponibilité de Keycloak (prod) | Observe → Dashboards, alerte `KeycloakDegraded` | `overlays/prod/patch-keycloak.yaml`, `base/keycloak/poddisruptionbudget.yaml` | 8.6, 15.8 |

| Conservation | Durée | Stockage |
|---|---|---|
| Métriques (projets utilisateur) | 7 jours | 2 PVC de 5 Gi (`ocs-storagecluster-ceph-rbd`) |
| Logs | 7 jours | bucket NooBaa `loki-rhbk` |
| Traces | 72 heures | bucket NooBaa `tempo-rhbk` |

### D.3 Mise en place, dans l'ordre

**Plateforme** (`rhbk-platform`, détail dans son README, « Ordre de déploiement ») :

| Étape | Application(s) | Apporte |
|---|---|---|
| 1 | `platform-monitoring` | surveillance des projets utilisateur (désactivée par défaut), rétention et PVC, collecte ESO, alertes ESO / Vault / ArgoCD, configuration d'Alertmanager et webhook de test |
| 2 | `grafana-operator`, puis `grafana` | Grafana derrière le proxy OAuth, source Thanos Querier, tableaux officiels Keycloak |
| 3 | `coo-operator`, puis `observability-console` | Cluster Observability Operator, vue d'ensemble Perses dans la console |
| 4 | `loki-operator`, `logging-operator`, puis `logging` | LokiStack, collecteur (applications + `openshift-gitops`), plugin Logs de la console |
| 5 | `tempo-operator`, `otel-operator`, puis `tracing` (ou `tracing-pv`, option B sans stockage objet) | TempoStack (ou TempoMonolithic sur PVC), OpenTelemetry Collector, plugin Traces de la console |

**Application** (`rhbk-gitops`) : chaque partie d'`observabilite.md` ajoute ses changements
Keycloak au socle (étapes 1.3, 2.2, 3.4 et 4.4), selon les règles de la section 15.8 :

| Changement | Parties | Type | Effet en prod |
|---|---|---|---|
| `PrometheusRule` (base) | 1 | ressource | aucun |
| options d'exécution du CR : `metrics-enabled`, `http-metrics-histograms-enabled`, `log-console-output: json`, `spec.tracing.endpoint` et `samplerRatio` | 1, 2, 3, 4 | commit d'options | rolling update, sans coupure (2 replicas) |
| image avec les options de build (`KC_FEATURES=user-event-metrics`, `KC_EVENT_METRICS_USER_ENABLED`, `KC_TRACING_ENABLED`), nouveau digest, `features` et `tracing.enabled` dans le CR | 2, 4 | commit d'image | recreate, coupure d'environ 1 minute |

### D.4 Options Keycloak de l'observabilité

| Option | Type | Où | Rôle |
|---|---|---|---|
| `metrics-enabled` | build **et** exécution | Containerfile + CR | expose `/metrics` (port 9000) |
| `health-enabled` | build | Containerfile | sondes `/health` |
| `user-event-metrics` (fonctionnalité) | build | Containerfile (`KC_FEATURES`) + CR (`features`) | métriques de connexions par realm |
| `event-metrics-user-enabled` | **build** | Containerfile | active ces métriques (`keycloak_user_events_total`) |
| `http-metrics-histograms-enabled` | exécution | CR | percentiles de temps de réponse |
| `log-console-output: json` | exécution | CR | logs JSON exploitables dans Loki |
| `tracing-enabled` | **build** | Containerfile + CR (`tracing.enabled`, même valeur) | traces OpenTelemetry |
| `tracing-endpoint`, `tracing-sampler-ratio` | exécution | CR (`spec.tracing`) | adresse du Collector, part des requêtes tracées (dev 100 %, prod 10 %) |

Vérifier le type d'une option avant de l'ajouter au CR (section 15.1) :
`oc exec -n rhbk-dev rhbk-dev-0 -- /opt/keycloak/bin/kc.sh start --optimized --help-all | grep <option>`
(absente = option de build).

### D.5 Vérifier que tout fonctionne

```bash
oc get pods -n openshift-user-workload-monitoring
```

```bash
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- curl -s --data-urlencode 'query=up' http://localhost:9090/api/v1/query
```

Les cibles `rhbk-prod-service`, `rhbk-dev-service` et `external-secrets-metrics` doivent valoir 1.

```bash
oc exec -n openshift-monitoring alertmanager-main-0 -c alertmanager -- amtool config routes show --alertmanager.url=http://localhost:9093
```

```bash
oc get lokistack logging-loki -n openshift-logging && oc get clusterlogforwarder collector -n openshift-logging
```

```bash
oc get tempostack tempo -n rhbk-tracing && oc get opentelemetrycollector otel -n rhbk-tracing
```

```bash
oc get uiplugin
```

Les plugins `monitoring`, `logging` et `distributed-tracing` doivent être `Available`.

Puis dans la console : une alerte de test (section 15.7.1), la requête de logs
`{kubernetes_namespace_name="rhbk-dev"} | json | level=~"warn|error"` (section 15.9) et la
requête de traces `{resource.service.name="rhbk-dev"}` (section 15.10).

### D.6 Pièges rencontrés et solutions

| Piège | Symptôme | Solution |
|---|---|---|
| Surveillance des projets utilisateur **désactivée par défaut** | ServiceMonitors présents mais aucune métrique collectée | `enableUserWorkload: true` (`platform-monitoring`) |
| Namespace avec le label `openshift.io/cluster-monitoring=true` (souvent posé en pensant **activer** la surveillance) | `/metrics` répond (port-forward), ServiceMonitor présent, mais aucune cible dans Prometheus et rien dans Observe → Metrics, sans aucune erreur | retirer le label **à sa source** (manifeste du namespace dans git) : il réserve le namespace au Prometheus de la plateforme, et le Prometheus des projets utilisateur l'ignore |
| Prometheus des projets utilisateur sans volume | métriques perdues à chaque redémarrage | `user-workload-monitoring-config` : PVC et rétention 7 jours |
| Option de build placée dans le CR | Keycloak en CrashLoopBackOff (`build time options have values that differ`) | la mettre dans le Containerfile, rebuild (section 15.1) |
| Pod de StatefulSet bloqué sur une ancienne révision | le pod reste en échec après correction du CR | `oc delete pod <pod>` (section 15.8) |
| ESO isolé par des NetworkPolicies *deny-all* | `vault-store` invalide (`context deadline exceeded`) | sortie vers Vault dans `ExternalSecretsConfig` (annexe A.2) |
| ESO espace ses tentatives après un Vault scellé | ExternalSecrets en erreur après descellement ; alerte `ExternalSecretNotSynced` | relecture forcée (section 15.5) |
| Valeurs par défaut ajoutées par les webhooks (ESO, Grafana, Tempo) | Application `OutOfSync` permanente | les déclarer dans git (forme normalisée : `72h0m0s`, `protocol: TCP`, version Grafana…) |
| PDB `maxUnavailable: 0` avec un seul replica (chart Vault) | alerte `PodDisruptionBudgetAtLimit`, drainages bloqués | PDB désactivé pour Vault ; `maxUnavailable: 1` pour Keycloak |
| Grafana : référence `DS_PROMETHEUS` écrite dans l'uid | variable `namespace` vide, panneaux vides | source de données avec l'uid fixe `Prometheus` (immuable : supprimer puis recréer) |
| Grafana brièvement en échec au démarrage | synchro interrompue avant les tableaux | `retry` dans l'Application |
| Deux paquets `loki-operator` | version communautaire installée par erreur | catalogue `redhat-operators` |
| LokiStack `1x.demo` | avertissement « ingester replicas (1) » | normal (pas de haute disponibilité) ; `1x.pico` en production |
| Logs : JSON dans du JSON | champs Keycloak inaccessibles | `| json | line_format "{{.message}}" | json` ; le niveau est déjà extrait (section 15.9) |
| Schéma des Routes absent au redémarrage | Applications ArgoCD en `Unknown` (`parseableType`) | attendre, puis redémarrer le contrôleur ArgoCD si plus de 15 minutes (section 15.5) |
| Alertes système dans nos namespaces | une alerte OpenShift (ex. PDB de Vault) arrive à `rhbk-team` | voulu : la route couvre tout le namespace |

### D.7 Renvois

- 1.6 et 15.1 : options de build et d'exécution ; 7 : construction de l'image ; 8.4 : CR Keycloak
  (socle) ; 8.6 : PodDisruptionBudget ; `observabilite.md` 1.3 : alertes Keycloak
- 15.1 : options de build et d'exécution ; 15.5 : après un redémarrage ; 15.6 : alertes et
  tableaux de bord ; 15.7 : notifications et SMTP ; 15.8 : rolling update et recreate ;
  15.9 : logs ; 15.10 : traces ; 16 : dépannage
- README de `rhbk-platform` : sections « Surveillance », « Grafana », « Vue d'ensemble dans
  la console (Perses) », « Logs centralisés », « Traces », « Ordre de déploiement »
- **`docs/observabilite.md`** : mise en place partie par partie (1 à 4)
