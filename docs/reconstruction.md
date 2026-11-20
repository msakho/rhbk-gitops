# Recréer l'ensemble sur un nouveau cluster

Procédure courte pour redéployer **tout ce qui tourne** (plateforme, Keycloak prod et dev,
observabilité) sur un nouveau cluster, sans refaire le guide pas à pas. Tout ce qui est
déclaratif est déjà dans les deux dépôts ; il reste à changer le domaine, à rejouer les quelques
étapes manuelles (Vault, PostgreSQL) et à restaurer les données.

Le détail et les explications de chaque étape restent dans le guide
([`deploiement-gitops.md`](deploiement-gitops.md)) et dans [`observabilite.md`](observabilite.md).

## Ce qui est où

| Élément | Où | Sur le nouveau cluster |
|---|---|---|
| Opérateurs, Vault, ESO, monitoring, Grafana, Perses, logs, traces | dépôt `rhbk-platform` | synchroniser les Applications (étape 4) |
| Keycloak prod et dev (CR, routes, certificat, alertes, ExternalSecrets) | dépôt `rhbk-gitops` | bootstrap ArgoCD (étape 8) |
| Image Keycloak optimisée | `quay.io/msakho0/mskeycloak`, digest dans `base/keycloak/keycloak.yaml` | **rien à refaire** : même image, même digest |
| Certificats des routes | cert-manager (`overlays/<env>/certificate.yaml`) | réémis automatiquement pour les nouveaux noms |
| Valeurs de Vault (`secret/rhbk/<env>/db`, `bootstrap-admin`) | **sauvegarde locale** `vault-kv.json` | restaurer (étape 5) |
| Données Keycloak (realms, utilisateurs, clients) | **sauvegarde locale** `keycloak-<env>.dump` | restaurer (étape 6) |
| Clé de descellement et token root de Vault | `vault-init.json` | **nouveaux** : Vault est réinitialisé (étape 5) |
| Historique des métriques, logs et traces | stockage du cluster | perdu (non sauvegardé) |

## Sauvegarde (avant la suppression du cluster)

Dossier local, hors des dépôts, lisible par toi seul (`chmod 700`, fichiers en `600`) :
`/usr/local/dev/rhbk-backup-2026-11-20/`.

| Fichier | Contenu | Commande utilisée |
|---|---|---|
| `keycloak-prod.dump`, `keycloak-dev.dump` | base Keycloak complète (`pg_dump -Fc`, PostgreSQL 15), RHBK 26.6.7 | ci-dessous |
| `vault-kv.json` | les 4 entrées de Vault (`rhbk/{prod,dev}/{db,bootstrap-admin}`), en clair | ci-dessous |

Ces fichiers contiennent des secrets (mots de passe, empreintes des mots de passe Keycloak,
secrets des clients) : ne jamais les mettre dans git ; les garder ou les copier dans un endroit
sûr.

Pour refaire une sauvegarde (cluster encore en route, depuis le dossier de `rhbk-platform`) :

```bash
B=/usr/local/dev/rhbk-backup-$(date +%F); mkdir -p $B && chmod 700 $B
```

```bash
for env in prod dev; do ns=$([ $env = prod ] && echo rhbk || echo rhbk-dev); oc exec -n $ns deploy/postgres-db -- bash -c 'pg_dump -Fc -d "$POSTGRESQL_DATABASE"' > $B/keycloak-$env.dump && chmod 600 $B/keycloak-$env.dump; done
```

```bash
(umask 077; { echo "export VAULT_TOKEN='$(python3 -c 'import json;print(json.load(open("vault-init.json"))["root_token"])')'"; cat <<'EOF'
printf '{'; first=1
for p in rhbk/prod/db rhbk/prod/bootstrap-admin rhbk/dev/db rhbk/dev/bootstrap-admin; do
  [ $first = 1 ] || printf ','; first=0
  printf '"%s":' "$p"; vault kv get -mount=secret -format=json -field=data "$p"
done; printf '}'
EOF
} | oc exec -i -n vault vault-0 -c vault -- sh -s > $B/vault-kv.json)
```

Vérifier sans rien afficher de secret (clés seulement, et nombre de tables des dumps) :

```bash
python3 -c 'import json,sys;print({k:sorted(v) for k,v in json.load(open(sys.argv[1])).items()})' $B/vault-kv.json
```

```bash
oc exec -i -n rhbk deploy/postgres-db -- bash -c 'cat > /tmp/t.dump; pg_restore -l /tmp/t.dump | grep -c "TABLE DATA"; rm -f /tmp/t.dump' < $B/keycloak-prod.dump
```

Attendu : 4 entrées avec `password` et `username` ; 90 tables. La restauration a été testée
sur une base temporaire (realm `master` et utilisateurs retrouvés).

## 1. Prérequis du nouveau cluster

Fournis par le sandbox (à vérifier, pas à installer) :

```bash
oc get csv -A 2>/dev/null | awk '$2 ~ /^(openshift-gitops-operator|odf-operator|cert-manager-operator)\./ {print $2, $NF}' | sort -u
```

```bash
oc get storageclass
```

```bash
oc get clusterissuer
```

```bash
oc auth can-i '*' '*' --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

Attendu : GitOps, ODF et cert-manager en `Succeeded` ; une classe RBD (ici
`ocs-storagecluster-ceph-rbd`) et la classe NooBaa `openshift-storage.noobaa.io` ; un
`ClusterIssuer` Let's Encrypt `READY True` ; `yes` (ArgoCD crée des ressources de niveau
cluster).

Noter le **domaine des routes** du nouveau cluster :

```bash
oc get ingresses.config cluster -o jsonpath='{.spec.domain}{"\n"}'
```

## 2. Changer le domaine dans les deux dépôts

Depuis `rhbk-gitops`. Le script remplace l'ancien domaine partout (hostnames Keycloak,
certificats, routes Vault et Grafana, documentation) dans les deux dépôts. Si la classe de
stockage RBD ou le nom du `ClusterIssuer` changent aussi, les passer en 2e et 3e argument :

```bash
cd /usr/local/dev/rhbk-gitops && git pull -q && git -C ../rhbk-platform pull -q
```

```bash
./tools/change-cluster.sh <domaine des routes> [classe de stockage RBD] [ClusterIssuer]
```

Exemple : `./tools/change-cluster.sh apps.cluster-abcde.abcde.sandbox123.opentlc.com`.

Relire, puis commiter et pousser les deux dépôts :

```bash
git diff --stat && git -C ../rhbk-platform diff --stat
```

```bash
git commit -qam "Move to the new cluster domain" && git push -q && git -C ../rhbk-platform commit -qam "Move to the new cluster domain" && git -C ../rhbk-platform push -q
```

## 3. Bootstrap de la plateforme

Depuis `rhbk-platform` :

```bash
cd /usr/local/dev/rhbk-platform && oc apply -f bootstrap/root-app.yaml
```

Fonction de synchronisation, réutilisée ensuite (bash et zsh). Elle lance la synchronisation de
chaque Application puis attend `Synced/Healthy` :

```bash
sync_app() { for a in "$@"; do oc patch application $a -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}' >/dev/null; done; for a in "$@"; do until [ "$(oc get application $a -n openshift-gitops -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)" = "Synced/Healthy" ]; do sleep 10; done; echo "$a Synced/Healthy"; done; }
```

## 4. Opérateurs RHBK et ESO, puis Vault

```bash
sync_app eso-operator rhbk-operator-prod rhbk-operator-dev
```

Vault reste non prêt tant qu'il n'est pas initialisé : ne pas attendre `Healthy`, seulement le
pod `Running` :

```bash
oc patch application vault -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}' && until oc get pod vault-0 -n vault 2>/dev/null | grep -q Running; do sleep 10; done; oc get pod vault-0 -n vault
```

Le pod affiche `1/2` : le conteneur `auto-unseal` attend le Secret `vault-unseal-key` (étape 5).

## 5. Vault : initialiser, desceller, configurer, restaurer les valeurs

Toujours depuis `rhbk-platform`. L'ancien `vault-init.json` ne sert plus (il appartient à
l'ancien cluster) : le ranger avec la sauvegarde avant d'en créer un nouveau.

```bash
B=/usr/local/dev/rhbk-backup-2026-11-20
```

```bash
[ -f vault-init.json ] && mv vault-init.json $B/vault-init-ancien-cluster.json
```

Initialiser (guide, annexe A.4) :

```bash
(umask 077; oc exec -n vault vault-0 -c vault -- vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-init.json)
```

**Sauvegarder le nouveau `vault-init.json`** (gestionnaire de mots de passe).

Créer le Secret du descellement automatique ; le conteneur `auto-unseal` descelle Vault dans la
minute (pod `2/2`) :

```bash
python3 -c 'import json;print(json.load(open("vault-init.json"))["unseal_keys_b64"][0],end="")' | oc create secret generic vault-unseal-key -n vault --from-file=key=/dev/stdin
```

```bash
until oc exec -n vault vault-0 -c vault -- vault status >/dev/null 2>&1; do sleep 5; done; oc exec -n vault vault-0 -c vault -- vault status | grep Sealed
```

Configurer Vault pour ESO (guide, annexe A.5 ; mêmes commandes) :

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
} | oc exec -i -n vault vault-0 -c vault -- sh -s
```

Restaurer les valeurs depuis la sauvegarde (rien n'est affiché) :

```bash
python3 -c "$(cat <<'EOF'
import json, sys
tok = json.load(open("vault-init.json"))["root_token"]
items = json.load(open(sys.argv[1]))
print("set -e"); print(f"export VAULT_TOKEN={json.dumps(tok)}"); print("umask 077")
for path, data in items.items():
    print("cat > /tmp/v.json <<'JSONEOF'"); print(json.dumps(data)); print("JSONEOF")
    print(f"vault kv put -mount=secret {path} @/tmp/v.json >/dev/null && echo 'written {path}'")
print("rm -f /tmp/v.json")
EOF
)" "$B/vault-kv.json" | oc exec -i -n vault vault-0 -c vault -- sh -s
```

Attendu : 4 lignes `written rhbk/...`. Puis la configuration ESO :

```bash
sync_app eso-config && oc get clustersecretstore vault-store
```

Attendu : `Valid`, `True`.

## 6. PostgreSQL : créer les bases et restaurer les données

Depuis `rhbk-gitops`, **avant** le bootstrap Keycloak (sinon Keycloak crée un schéma vide).
Crée la base de chaque environnement (guide, annexe B), attend qu'elle soit prête, puis
restaure le dump :

```bash
cd /usr/local/dev/rhbk-gitops
```

```bash
for env in prod dev; do ns=$([ $env = prod ] && echo rhbk || echo rhbk-dev); for f in tools/postgresql/*.yaml; do sed "s/__ENV__/$env/g" "$f"; echo '---'; done | oc apply -n $ns -f -; done
```

```bash
for ns in rhbk rhbk-dev; do until oc get secret postgres-db -n $ns >/dev/null 2>&1; do sleep 5; done; oc rollout status deploy/postgres-db -n $ns --timeout=300s; done
```

```bash
for env in prod dev; do ns=$([ $env = prod ] && echo rhbk || echo rhbk-dev); echo "== $env"; oc exec -i -n $ns deploy/postgres-db -- bash -c 'cat > /tmp/r.dump && pg_restore --no-owner --no-privileges --role="$POSTGRESQL_USER" -d "$POSTGRESQL_DATABASE" /tmp/r.dump; rc=$?; rm -f /tmp/r.dump; psql -tA -d "$POSTGRESQL_DATABASE" -c "select string_agg(name, chr(44)) from realm"; exit $rc' < $B/keycloak-$env.dump; done
```

Attendu : pour chaque environnement, la liste des realms (`master`…) et aucune erreur.

`--no-owner --role` : les objets restaurés appartiennent à l'utilisateur de la base lu dans
Vault (le même qu'avant, puisque les valeurs sont restaurées).

## 7. Observabilité (plateforme)

Opérateurs d'abord, puis leurs instances. Chaque ligne attend la précédente :

```bash
sync_app platform-monitoring coo-operator grafana-operator loki-operator logging-operator tempo-operator otel-operator
```

```bash
sync_app grafana observability-console logging tracing
```

## 8. Keycloak (dépôt `rhbk-gitops`)

```bash
oc apply -f bootstrap/root-app.yaml
```

dev se synchronise seul. La prod est en synchronisation manuelle :

```bash
sync_app rhbk-prod
```

`rhbk-prod` et `rhbk-dev` attendent que leur certificat soit émis par cert-manager (une à deux
minutes) avant de créer les routes.

## 9. Vérifier

```bash
oc get applications -n openshift-gitops -o 'custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

```bash
oc get certificate -A -o 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.conditions[0].status,EXPIRE:.status.notAfter'
```

```bash
D=$(oc get ingresses.config cluster -o jsonpath='{.spec.domain}'); for u in https://prod-rhbk.$D/realms/master/.well-known/openid-configuration https://prod-rhbk.$D/admin/ https://prod-rhbk-admin.$D/admin/master/console/ https://dev-rhbk.$D/realms/master/.well-known/openid-configuration https://dev-rhbk-admin.$D/admin/master/console/; do echo "$(curl -s -o /dev/null -w '%{http_code}' $u) $u"; done
```

Attendu : toutes les Applications `Synced/Healthy` ; les certificats `True` ; `200`, `503`
(console bloquée sur le nom public, voulu), `200`, `200`, `200`.

Puis :

- **Connexion** à la console d'administration (`https://prod-rhbk-admin.<domaine>/admin/`) avec
  le **compte admin de l'ancien cluster** : les comptes viennent de la base restaurée ;
  `bootstrap-admin` ne sert que sur une base vide.
- **Clients avec des URL de l'ancien domaine** : les realms restaurés gardent leurs URL de
  redirection. La console d'administration utilise des URL relatives et fonctionne ; les clients
  applicatifs éventuels sont à corriger (realm → Clients → *Valid redirect URIs*).
- Scénario complet des routes : guide, section 13.4. Observabilité : `observabilite.md`, sections
  « Vérifier » de chaque partie.

## Si la sauvegarde manque

Sans les dumps : sauter la restauration de l'étape 6 ; Keycloak démarre sur une base vide et
crée l'admin temporaire de `bootstrap-admin`. Sans `vault-kv.json` : ranger de nouvelles valeurs
avec le guide, annexe A.7 (une base neuve est créée **avec** ces valeurs).
