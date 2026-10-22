# Observabilité de RHBK : mise en place partie par partie

Ce document décrit la mise en place de l'observabilité de Red Hat build of Keycloak en **4
parties**, chacune avec ses étapes, de la partie 1 à la partie 4. On peut s'arrêter après
n'importe quelle partie, ou ne déployer que certaines d'entre elles (voir les dépendances).
Le contenu de chaque fichier est donné en entier : il est identique aux dépôts
`rhbk-gitops` et `rhbk-platform`.

**Point de départ** : le **socle** du guide principal (`docs/deploiement-gitops.md`, étapes 1
à 13), c'est-à-dire Keycloak en prod et en dev sans observabilité. Chaque partie indique les
lignes à **ajouter** à l'image et au CR Keycloak, et à quel endroit. Socle + 4 parties =
dépôts actuels.

Vue d'ensemble, pièges rencontrés et renvois : guide principal, **annexe D**
(`docs/deploiement-gitops.md`). Utilisation au quotidien : sections 15.6 à 15.10 du guide.

## Sommaire

0. [Avant de commencer](#0-avant-de-commencer)
1. [Partie 1 : métriques et alertes](#partie-1--métriques-et-alertes)
2. [Partie 2 : tableaux de bord](#partie-2--tableaux-de-bord)
3. [Partie 3 : logs centralisés](#partie-3--logs-centralisés)
4. [Partie 4 : traces](#partie-4--traces)
5. [Exemple : ne déployer que les parties 1 et 2](#exemple--ne-déployer-que-les-parties-1-et-2)

---

## 0. Avant de commencer

### 0.1 Les 4 parties et leurs dépendances

| Partie | Apporte | Dépend de | Outils |
|---|---|---|---|
| **1. Métriques et alertes** | collecte des métriques, alertes, notifications | — | surveillance des projets utilisateur (Prometheus, Thanos Ruler), Alertmanager |
| **2. Tableaux de bord** | Grafana (tableaux officiels Keycloak), vue d'ensemble Perses dans la console | **partie 1** (les tableaux lisent ses métriques) | Grafana Operator (communautaire), Cluster Observability Operator (COO, Red Hat) |
| **3. Logs centralisés** | logs dans la console, Keycloak en JSON | — (indépendante) | OpenShift Logging, Loki, COO pour l'affichage |
| **4. Traces** | traces de bout en bout | — (indépendante) | Red Hat build of OpenTelemetry, Tempo, COO pour l'affichage |

- Le **Cluster Observability Operator** (COO) affiche dans la console les tableaux Perses (2),
  les logs (3) et les traces (4). Il est installé une fois, à la première de ces parties
  (étape 2.4.1) ; les parties 3 et 4 le réutilisent.
- Chaque partie a sa propre Application ArgoCD dans `rhbk-platform` et ses propres options
  Keycloak, repérées par `[Observability part N]` dans `custom-rhbk/Containerfile` et
  `base/keycloak/keycloak.yaml`.

### 0.2 Prérequis communs

| Prérequis | Pour | Vérification |
|---|---|---|
| Socle applicatif en place (guide principal, étapes 1 à 13) | toutes | `oc get keycloak -A` |
| Plateforme `rhbk-platform` en place : bootstrap, ESO, Vault, opérateurs RHBK (README de `rhbk-platform`, étapes 1 à 6) | toutes | `oc get applications -n openshift-gitops` |
| Stockage en bloc `ocs-storagecluster-ceph-rbd` | 1, 3, 4 | `oc get storageclass ocs-storagecluster-ceph-rbd` |
| Stockage objet ODF / NooBaa (classe `openshift-storage.noobaa.io`) | 3, 4 (option A) | `oc get noobaa -n openshift-storage` |
| `podman` et accès en écriture à `quay.io/msakho0/mskeycloak` (rebuild de l'image) | 2, 4 | `podman login quay.io` |

### 0.3 Conventions

- **Plateforme** : chaque Application est ajoutée à `rhbk-platform/argocd/kustomization.yaml`,
  et ses namespaces à l'AppProject `platform`. Après commit et push, `platform-root` crée
  l'Application, à synchroniser à la main (console ArgoCD : **Sync**, ou `oc patch`
  ci-dessous). Les opérateurs se synchronisent **avant** les Applications qui utilisent
  leurs ressources.
- **Keycloak** (`rhbk-gitops`), règles de la section 15.8 du guide :
  - une option **d'exécution** va dans le CR (`base/keycloak/keycloak.yaml`) : rolling update,
    sans coupure en prod (2 replicas) ;
  - une option **de build** va dans le Containerfile : rebuild, nouveau digest, recreate
    (coupure d'environ 1 minute en prod) ;
  - **ne jamais mélanger** dans un même commit un nouveau digest et des options d'exécution ;
  - dev se synchronise seul ; la prod est synchronisée à la main une fois dev validé.
- Rebuild de l'image et digest (à chaque option de build) :
```bash
podman build --platform linux/amd64 -t quay.io/msakho0/mskeycloak:26.6 -f custom-rhbk/Containerfile custom-rhbk
```

```bash
podman push quay.io/msakho0/mskeycloak:26.6
```

```bash
oc image info quay.io/msakho0/mskeycloak:26.6 | grep Digest
```

  Puis remplacer le digest dans `image:` de `base/keycloak/keycloak.yaml`.

---

## Partie 1 : métriques et alertes

**Résultat** : métriques Keycloak, ESO et ArgoCD collectées et conservées 7 jours ; alertes
Keycloak, PostgreSQL, ESO, Vault et ArgoCD ; notifications vers un récepteur de test
(e-mail ensuite, section 15.7.2 du guide).

### 1.1 Prérequis

Aucune autre partie. Keycloak doit exposer ses métriques : options `KC_HEALTH_ENABLED` et
`KC_METRICS_ENABLED` dans le Containerfile (repère `[Observability part 1]`, déjà présentes
dans l'image du socle : **pas de rebuild**) et `metrics-enabled` dans le CR (étape 1.3).

### 1.2 Plateforme : Application `platform-monitoring`

| Fichier | Rôle |
|---|---|
| `cluster-monitoring-config.yaml` | active la **surveillance des projets utilisateur** (désactivée par défaut : sans elle, les ServiceMonitors hors `openshift-*` sont ignorés) |
| `user-workload-monitoring-config.yaml` | rétention 7 jours, volumes persistants |
| `eso-servicemonitor.yaml`, `eso-alerts.yaml` | collecte et alertes ESO |
| `vault-alerts.yaml` | Vault scellé (détecté par le pod non prêt) |
| `argocd-alerts.yaml` | Applications ArgoCD non saines |
| `alertmanager-main.yaml` | routage des alertes RHBK vers `rhbk-team` |
| `alert-webhook-test/` | récepteur de test (écrit les alertes dans ses logs) |

`rhbk-platform/monitoring/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - cluster-monitoring-config.yaml
  - user-workload-monitoring-config.yaml
  - eso-servicemonitor.yaml
  - eso-alerts.yaml
  - vault-alerts.yaml
  - argocd-alerts.yaml
  - alertmanager-main.yaml
  - alert-webhook-test
```

`rhbk-platform/monitoring/cluster-monitoring-config.yaml`
```yaml
# Enables monitoring for user-defined projects (rhbk, rhbk-dev, external-secrets, vault...):
# without it, ServiceMonitors and PrometheusRules outside openshift-* namespaces are ignored.
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
  annotations:
    argocd.argoproj.io/sync-wave: "0"
data:
  config.yaml: |
    enableUserWorkload: true
```

`rhbk-platform/monitoring/user-workload-monitoring-config.yaml`
```yaml
# Persistent storage and retention for the user workload Prometheus (2 replicas: one PVC each).
# Without it, metrics are kept 24h in an emptyDir and lost at each cluster restart.
# ~4000 series today (Keycloak prod/dev, ESO): 7 days take a few hundred MB.
# retentionSize is a safety net below the PVC size; ceph-rbd allows volume expansion.
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
  annotations:
    argocd.argoproj.io/sync-wave: "1"
data:
  config.yaml: |
    prometheus:
      retention: 7d
      retentionSize: 4GB
      volumeClaimTemplate:
        spec:
          storageClassName: ocs-storagecluster-ceph-rbd
          resources:
            requests:
              storage: 5Gi
```

`rhbk-platform/monitoring/eso-servicemonitor.yaml`
```yaml
# Scrapes the ESO controller (externalsecret_status_condition, clustersecretstore_status_condition...).
# The ESO NetworkPolicies already allow port 8080 from openshift-user-workload-monitoring.
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: external-secrets
  namespace: external-secrets
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  selector:
    matchLabels:
      app.kubernetes.io/instance: external-secrets
      app.kubernetes.io/name: external-secrets
  endpoints:
    - port: metrics
      interval: 60s
```

`rhbk-platform/monitoring/eso-alerts.yaml`
```yaml
# Evaluated by the user workload Thanos Ruler (rules only see metrics of their own namespace:
# here the ESO metrics, which carry the ExternalSecret namespace as "exported_namespace").
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: external-secrets-alerts
  namespace: external-secrets
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  groups:
    - name: external-secrets
      rules:
        - alert: ExternalSecretNotSynced
          # Typical after a cluster restart: Vault was sealed, ESO backs off and does not retry
          # right after the unseal. Fix: force-sync (guide, section 15.5).
          expr: externalsecret_status_condition{condition="Ready", status="False"} == 1
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "ExternalSecret {{ $labels.exported_namespace }}/{{ $labels.name }} is not synced"
            description: "The Kubernetes Secret is no longer refreshed from Vault (the existing value is kept). Check vault-store, then force a resync."
        - alert: ClusterSecretStoreNotReady
          expr: clustersecretstore_status_condition{condition="Ready", status="False"} == 1
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "ClusterSecretStore {{ $labels.name }} is not ready"
            description: "ESO cannot read Vault: Vault sealed or down, network policy, or Kubernetes auth. See guide section 16."
```

`rhbk-platform/monitoring/vault-alerts.yaml`
```yaml
# Vault exposes no metrics here: a sealed Vault is detected through the pod readiness
# (the readiness probe fails while Vault is sealed). kube-state-metrics series of the "vault"
# namespace are visible to rules of this namespace (user workload Thanos Ruler).
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: vault-alerts
  namespace: vault
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  groups:
    - name: vault
      rules:
        - alert: VaultSealedOrDown
          expr: sum(kube_pod_status_ready{namespace="vault", pod=~"vault-[0-9]+", condition="true"}) == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Vault is sealed or not ready"
            description: "After a restart, Vault must be unsealed (guide, section 15.5). Until then ESO cannot refresh secrets."
```

`rhbk-platform/monitoring/argocd-alerts.yaml`
```yaml
# openshift-gitops is a platform namespace (openshift.io/cluster-monitoring=true): this rule is
# evaluated by the platform Prometheus, which scrapes ArgoCD. The GitOps operator only alerts on
# OutOfSync (ArgoCDSyncAlert); this adds health.
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: argocd-health-alerts
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  groups:
    - name: argocd-health
      rules:
        - alert: ArgoCDApplicationUnhealthy
          expr: argocd_app_info{namespace="openshift-gitops", health_status=~"Degraded|Missing|Unknown"} > 0
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "ArgoCD Application {{ $labels.name }} is {{ $labels.health_status }}"
            description: "Check the Application in the ArgoCD console (App Details / Events)."
```

`rhbk-platform/monitoring/alertmanager-main.yaml`
```yaml
# Configuration of the platform Alertmanager (it also receives the user workload alerts).
# Keeps the OpenShift defaults (Default / Watchdog / Critical receivers, inhibit rules) and adds a
# route for the RHBK alerts, placed before "Critical" so that our critical alerts are delivered too.
# Receiver "rhbk-team": test webhook for now; SMTP later (guide, section 15.7).
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-main
  namespace: openshift-monitoring
  annotations:
    argocd.argoproj.io/sync-wave: "1"
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      http_config:
        proxy_from_environment: true
    inhibit_rules:
      - equal: [namespace, alertname]
        source_matchers: ["severity = critical"]
        target_matchers: ["severity =~ warning|info"]
      - equal: [namespace, alertname]
        source_matchers: ["severity = warning"]
        target_matchers: ["severity = info"]
    route:
      receiver: Default
      group_by: [namespace]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      routes:
        - matchers: ["alertname = Watchdog"]
          receiver: Watchdog
        # RHBK: Keycloak/PostgreSQL (rhbk, rhbk-dev, rhbk-<env>), Vault, ESO, ArgoCD.
        - matchers: ['namespace =~ "rhbk(-.+)?|vault|external-secrets|openshift-gitops"']
          receiver: rhbk-team
          group_by: [namespace, alertname]
        - matchers: ["severity = critical"]
          receiver: Critical
    receivers:
      - name: Default
      - name: Watchdog
      - name: Critical
      - name: rhbk-team
        webhook_configs:
          - url: http://alert-webhook.alert-webhook-test.svc:8080/
            send_resolved: true
```

`rhbk-platform/monitoring/alert-webhook-test/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - configmap.yaml
  - deployment.yaml
  - service.yaml
```

`rhbk-platform/monitoring/alert-webhook-test/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: alert-webhook-test
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

`rhbk-platform/monitoring/alert-webhook-test/configmap.yaml`
```yaml
# Minimal Alertmanager webhook receiver: prints one line per alert in the pod logs.
# Test receiver only, to validate the alert chain until the real channel (SMTP) is configured.
apiVersion: v1
kind: ConfigMap
metadata:
  name: alert-webhook
  namespace: alert-webhook-test
data:
  receiver.py: |
    import datetime, http.server, json

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            try:
                msg = json.loads(body)
                for a in msg.get("alerts", []):
                    l = a.get("labels", {})
                    print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                          a.get("status", "").upper(), l.get("severity", "-"), l.get("alertname"),
                          "ns=" + l.get("exported_namespace", l.get("namespace", "-")),
                          "|", a.get("annotations", {}).get("summary", ""), flush=True)
            except ValueError:
                print("non-JSON payload:", body[:300], flush=True)
            self.send_response(200)
            self.end_headers()

        def do_GET(self):  # readiness
            self.send_response(200)
            self.end_headers()

        def log_message(self, *args):
            pass

    http.server.HTTPServer(("", 8080), Handler).serve_forever()
```

`rhbk-platform/monitoring/alert-webhook-test/deployment.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: alert-webhook
  namespace: alert-webhook-test
  labels:
    app: alert-webhook
spec:
  replicas: 1
  selector:
    matchLabels:
      app: alert-webhook
  template:
    metadata:
      labels:
        app: alert-webhook
    spec:
      containers:
        - name: receiver
          image: registry.access.redhat.com/ubi9/python-312
          command: ["python3", "/app/receiver.py"]
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /
              port: 8080
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          volumeMounts:
            - name: app
              mountPath: /app
      volumes:
        - name: app
          configMap:
            name: alert-webhook
```

`rhbk-platform/monitoring/alert-webhook-test/service.yaml`
```yaml
apiVersion: v1
kind: Service
metadata:
  name: alert-webhook
  namespace: alert-webhook-test
spec:
  selector:
    app: alert-webhook
  ports:
    - name: http
      port: 8080
      targetPort: 8080
```

`rhbk-platform/argocd/applications/platform-monitoring.yaml`
```yaml
# Monitoring for the platform: user workload monitoring, metrics and alerts for ESO, Vault and ArgoCD.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-monitoring
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: monitoring
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-monitoring
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
```

Déclarer les Applications dans `rhbk-platform/argocd/kustomization.yaml` (sous `resources:`) :

```yaml
  - applications/platform-monitoring.yaml
```

Autoriser les namespaces dans `rhbk-platform/argocd/appproject.yaml`, sous `spec.destinations` :

```yaml
    - server: https://kubernetes.default.svc
      namespace: openshift-monitoring
    - server: https://kubernetes.default.svc
      namespace: openshift-user-workload-monitoring
    - server: https://kubernetes.default.svc
      namespace: external-secrets
    - server: https://kubernetes.default.svc
      namespace: openshift-gitops
    - server: https://kubernetes.default.svc
      namespace: alert-webhook-test
```

et les ressources de niveau cluster, sous `spec.clusterResourceWhitelist` (si absentes) :

```yaml
    - group: ""
      kind: Namespace
```

Commit, push, puis :

```bash
oc patch application platform-monitoring -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
```

### 1.3 Keycloak : alertes et option de métriques

Option d'exécution dans `base/keycloak/keycloak.yaml`, dans le bloc `additionalOptions`,
placé **juste avant `scheduling:`**. Si le bloc n'existe pas encore (socle), ajouter aussi la
ligne `additionalOptions:` :

```yaml
  additionalOptions:
    # [Observability part 1 - metrics and alerts] /metrics endpoint.
    - name: metrics-enabled
      value: "true"
```

Alertes Keycloak et PostgreSQL : ajouter la ligne suivante à `base/keycloak/kustomization.yaml`,
après `- routes.yaml` :

```yaml
  - prometheusrule.yaml
```

puis créer le fichier :

`rhbk-gitops/base/keycloak/prometheusrule.yaml`
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

L'alerte `KeycloakDegraded` n'a d'intérêt qu'avec 2 replicas ou plus (section 15.8 du guide).

Commit et push : dev se met à jour seul (rolling update), puis synchroniser la prod (section
13.2 du guide).

### 1.4 Vérifier

> **Piège** : les namespaces de Keycloak **ne doivent pas** porter le label
> `openshift.io/cluster-monitoring=true`. Il les réserve au Prometheus de la plateforme, et le
> Prometheus des projets utilisateur ignore alors leurs ServiceMonitors, sans aucune erreur :
> `/metrics` répond, le ServiceMonitor existe, mais rien n'est collecté. Sortie vide attendue :

```bash
oc get ns rhbk rhbk-dev --show-labels | grep -o 'openshift.io/cluster-monitoring=[a-z]*'
```

Si le label est présent, le retirer à sa source (manifeste du namespace dans git), sinon ArgoCD
le remet. Ensuite :

```bash
oc get pods -n openshift-user-workload-monitoring
```

```bash
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- curl -s --data-urlencode 'query=up' http://localhost:9090/api/v1/query
```

Les cibles `rhbk-prod-service`, `rhbk-dev-service` et `external-secrets-metrics` valent 1.

Si une cible manque ou vaut 0, l'état détaillé de chaque cible et la dernière erreur :

```bash
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -c prometheus -- curl -s http://localhost:9090/api/v1/targets | python3 -c 'import json,sys;[print(t["labels"].get("namespace"),t["labels"].get("pod"),t["health"],t["lastError"]) for t in json.load(sys.stdin)["data"]["activeTargets"] if t["labels"].get("namespace","").startswith("rhbk")]'
```

```bash
oc exec -n openshift-monitoring alertmanager-main-0 -c alertmanager -- amtool config routes show --alertmanager.url=http://localhost:9093
```

Puis l'alerte de test de la section 15.7.1 du guide, et la console : **Observe → Alerting**.

### 1.5 Si on s'arrête ici

Alertes et métriques disponibles dans la console (**Observe → Alerting**, **Observe →
Metrics**). Pas de tableaux de bord, ni de métriques de connexions par realm (partie 2).

---

## Partie 2 : tableaux de bord

**Résultat** : Grafana avec les tableaux officiels Keycloak (*troubleshooting*, *capacity
planning*) et une vue d'ensemble RHBK dans la console (Perses).

### 2.1 Prérequis

**Partie 1** : les tableaux lisent les métriques qu'elle collecte.

### 2.2 Keycloak : métriques de connexions et percentiles

**Commit 1, image.** Deux options **de build** dans `custom-rhbk/Containerfile`, juste après la
ligne `ENV KC_METRICS_ENABLED=true` :

```dockerfile
# [Observability part 2 - dashboards] user event metrics (logins, login errors, token issuance...
# per realm): the feature AND event-metrics-user-enabled are build-time options. The CR declares
# the same feature (spec.features).
ENV KC_FEATURES=user-event-metrics
ENV KC_EVENT_METRICS_USER_ENABLED=true
```

Rebuild, push, nouveau digest (section 0.3). Dans `base/keycloak/keycloak.yaml`, **dans le
même commit que le digest** (la fonctionnalité doit correspondre à l'image), juste après
`startOptimized: true` :

```yaml
  # [Observability part 2 - dashboards] must match the features baked in the image
  # (custom-rhbk/Containerfile, KC_FEATURES).
  features:
    enabled:
      - user-event-metrics
```

En prod, ce commit provoque un recreate (coupure d'environ 1 minute).

**Commit 2, option d'exécution** des percentiles, dans `additionalOptions` (à la suite des
options déjà présentes, avant `scheduling:`) :

```yaml
    # [Observability part 2 - dashboards] percentiles (p95, p99) of HTTP response times.
    - name: http-metrics-histograms-enabled
      value: "true"
```


Vérifier en dev : `keycloak_user_events_total` apparaît après une première connexion, et
`http_server_requests_seconds_bucket` est présent (**Observe → Metrics**, ou en ligne de
commande ci-dessous : l'image Keycloak n'a pas `curl`, on passe par un `port-forward`).

```bash
oc port-forward -n rhbk-dev pod/rhbk-dev-0 19000:9000 &
```

```bash
curl -sk https://localhost:19000/metrics | grep -E '^keycloak_user_events_total|^http_server_requests_seconds_bucket' | head
```

```bash
kill %1
```

### 2.3 Grafana (Applications `grafana-operator` et `grafana`)

`rhbk-platform/operators/grafana/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - namespace.yaml
  - operatorgroup.yaml
  - subscription.yaml
```

`rhbk-platform/operators/grafana/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

`rhbk-platform/operators/grafana/operatorgroup.yaml`
```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: grafana-operator
  namespace: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  targetNamespaces:
    - grafana
  upgradeStrategy: Default
```

`rhbk-platform/operators/grafana/subscription.yaml`
```yaml
# Community operator (catalog community-operators): not supported by Red Hat.
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

`rhbk-platform/argocd/applications/grafana-operator.yaml`
```yaml
# Grafana Operator (community) in namespace grafana.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: grafana-operator
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: operators/grafana
  destination:
    server: https://kubernetes.default.svc
    namespace: grafana
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
```

Instance Grafana derrière le proxy OAuth d'OpenShift (connexion avec le compte OpenShift),
source de données Thanos Querier (jeton d'un ServiceAccount en lecture seule, créé par
OpenShift), tableaux officiels Keycloak téléchargés par l'opérateur.

`rhbk-platform/grafana/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - datasource-serviceaccount.yaml
  - proxy-cookie-secret.yaml
  - proxy-service-route.yaml
  - grafana.yaml
  - datasource.yaml
  - dashboards.yaml
```

`rhbk-platform/grafana/datasource-serviceaccount.yaml`
```yaml
# Read-only access to all metrics (platform + user workloads) through Thanos Querier.
# The token Secret is filled by OpenShift: nothing sensitive in git.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: grafana-thanos
  namespace: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: v1
kind: Secret
metadata:
  name: grafana-thanos-token
  namespace: grafana
  annotations:
    kubernetes.io/service-account.name: grafana-thanos
    argocd.argoproj.io/sync-wave: "0"
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-thanos-cluster-monitoring-view
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
  - kind: ServiceAccount
    name: grafana-thanos
    namespace: grafana
```

`rhbk-platform/grafana/proxy-cookie-secret.yaml`
```yaml
# Random session cookie secret for the OAuth proxy, generated once by ESO (no value in git).
# refreshInterval "0": never regenerated (a new value would log every user out).
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: grafana-proxy-cookie
  namespace: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  length: 32
  digits: 8
  symbols: 0
  noUpper: false
  allowRepeat: true
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-proxy-cookie
  namespace: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  refreshInterval: "0"
  target:
    name: grafana-proxy-cookie
    creationPolicy: Owner
    deletionPolicy: Retain
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: Password
          name: grafana-proxy-cookie
```

`rhbk-platform/grafana/proxy-service-route.yaml`
```yaml
# Service in front of the OAuth proxy (the service-ca generates its certificate) and route.
apiVersion: v1
kind: Service
metadata:
  name: grafana-proxy
  namespace: grafana
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: grafana-proxy-tls
    argocd.argoproj.io/sync-wave: "0"
spec:
  selector:
    app: grafana
  ports:
    - name: proxy-https
      port: 9091
      targetPort: 9091
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: grafana
  namespace: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  host: grafana.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com
  to:
    kind: Service
    name: grafana-proxy
  port:
    targetPort: proxy-https
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
```

`rhbk-platform/grafana/grafana.yaml`
```yaml
# Grafana instance managed by the Grafana Operator, behind the OpenShift OAuth proxy:
# users log in with their OpenShift account; only users allowed to "get services" in the
# "grafana" namespace (cluster admins) get in. No Grafana login form.
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: grafana
  labels:
    dashboards: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  # Grafana image pinned by digest (default image of grafana-operator v5.25.0). Declared here
  # because the operator writes it into the CR: without it ArgoCD reports OutOfSync.
  version: docker.io/grafana/grafana@sha256:ab5cb380e3ff3172d6c8bd2e7cfd31cce977d2881b260e1f5bc089bf0b759b43
  config:
    log:
      mode: console
    auth:
      disable_login_form: "true"
      disable_signout_menu: "true"
    auth.basic:
      enabled: "true"          # used by the operator to call the Grafana API (service port 3000)
    auth.proxy:
      enabled: "true"
      header_name: X-Forwarded-User
      header_property: username
      auto_sign_up: "true"
    users:
      auto_assign_org_role: Editor
  serviceAccount:
    metadata:
      annotations:
        serviceaccounts.openshift.io/oauth-redirectreference.primary: '{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"grafana"}}'
  deployment:
    spec:
      template:
        spec:
          containers:
            - name: grafana-proxy
              image: image-registry.openshift-image-registry.svc:5000/openshift/oauth-proxy:v4.4
              args:
                - -provider=openshift
                - -https-address=:9091
                - -http-address=
                - -email-domain=*
                - -upstream=http://localhost:3000
                - -openshift-service-account=grafana-sa
                - '-openshift-sar={"namespace":"grafana","resource":"services","verb":"get"}'
                - -tls-cert=/etc/tls/private/tls.crt
                - -tls-key=/etc/tls/private/tls.key
                - -cookie-secret-file=/etc/proxy/cookie/password
                - -pass-basic-auth=false
              ports:
                - name: proxy-https
                  containerPort: 9091
                  protocol: TCP
              resources:
                requests:
                  cpu: 10m
                  memory: 32Mi
              volumeMounts:
                - name: proxy-tls
                  mountPath: /etc/tls/private
                  readOnly: true
                - name: proxy-cookie
                  mountPath: /etc/proxy/cookie
                  readOnly: true
          volumes:
            - name: proxy-tls
              secret:
                secretName: grafana-proxy-tls
            - name: proxy-cookie
              secret:
                secretName: grafana-proxy-cookie
```

`rhbk-platform/grafana/datasource.yaml`
```yaml
# Thanos Querier: platform metrics (CPU of containers...) + user workloads (Keycloak, ESO).
# The bearer token comes from the grafana-thanos-token Secret (placeholder ${token}).
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: thanos-querier
  namespace: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "2"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  valuesFrom:
    - targetPath: secureJsonData.httpHeaderValue1
      valueFrom:
        secretKeyRef:
          name: grafana-thanos-token
          key: token
  # Fixed uid (immutable): the operator writes the datasourceName mapped in GrafanaDashboard
  # ("Prometheus") into the dashboards' datasource uid, so the datasource must have this uid.
  uid: Prometheus
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      httpHeaderName1: Authorization
      tlsSkipVerify: true
      timeInterval: 30s
    secureJsonData:
      httpHeaderValue1: "Bearer ${token}"
```

`rhbk-platform/grafana/dashboards.yaml`
```yaml
# Official Keycloak dashboards (github.com/keycloak/keycloak-grafana-dashboard), pinned to the
# 26.4.0 release; the operator downloads them. DS_PROMETHEUS is mapped to our datasource.
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaFolder
metadata:
  name: keycloak
  namespace: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "2"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  title: Keycloak
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: keycloak-troubleshooting
  namespace: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "3"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folderRef: keycloak
  url: https://raw.githubusercontent.com/keycloak/keycloak-grafana-dashboard/26.4.0/dashboards/keycloak-troubleshooting-dashboard.json
  datasources:
    - inputName: DS_PROMETHEUS
      datasourceName: Prometheus
---
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: keycloak-capacity-planning
  namespace: grafana
  annotations:
    argocd.argoproj.io/sync-wave: "3"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folderRef: keycloak
  url: https://raw.githubusercontent.com/keycloak/keycloak-grafana-dashboard/26.4.0/dashboards/keycloak-capacity-planning-dashboard.json
  datasources:
    - inputName: DS_PROMETHEUS
      datasourceName: Prometheus
```

`rhbk-platform/argocd/applications/grafana.yaml`
```yaml
# Grafana instance (OpenShift OAuth proxy), Thanos Querier datasource, official Keycloak dashboards. Needs grafana-operator.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: grafana
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: grafana
  destination:
    server: https://kubernetes.default.svc
    namespace: grafana
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
    # The Grafana CR is briefly reported as failed while the instance starts: retry instead of
    # stopping before the datasource and dashboards waves.
    retry:
      limit: 5
      backoff:
        duration: 20s
        factor: 2
        maxDuration: 3m
```

Déclarer les Applications dans `rhbk-platform/argocd/kustomization.yaml` (sous `resources:`) :

```yaml
  - applications/grafana-operator.yaml
  - applications/grafana.yaml
```

Autoriser les namespaces dans `rhbk-platform/argocd/appproject.yaml`, sous `spec.destinations` :

```yaml
    - server: https://kubernetes.default.svc
      namespace: grafana
```

et les ressources de niveau cluster, sous `spec.clusterResourceWhitelist` (si absentes) :

```yaml
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
```

Commit, push, puis (l'opérateur d'abord) :

```bash
oc patch application grafana-operator -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
oc patch application grafana -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
```

Pièges déjà traités dans ces fichiers : uid fixe `Prometheus` de la source de données
(immuable), version de Grafana figée, `protocol: TCP`, nouvelles tentatives de l'Application
(README de `rhbk-platform`, section « Grafana »).

### 2.4 Vue d'ensemble dans la console (Perses)

#### 2.4.1 Cluster Observability Operator (Application `coo-operator`)

Installé une seule fois : les parties 3 et 4 le réutilisent pour leurs plugins de console.

`rhbk-platform/operators/coo/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - namespace.yaml
  - operatorgroup.yaml
  - subscription.yaml
```

`rhbk-platform/operators/coo/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cluster-observability-operator
  labels:
    openshift.io/cluster-monitoring: "true"
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

`rhbk-platform/operators/coo/operatorgroup.yaml`
```yaml
# AllNamespaces mode (no targetNamespaces).
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-operator
  namespace: openshift-cluster-observability-operator
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  upgradeStrategy: Default
```

`rhbk-platform/operators/coo/subscription.yaml`
```yaml
# Cluster Observability Operator (Red Hat): console UI plugins (Perses dashboards).
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-cluster-observability-operator
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  channel: stable
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

`rhbk-platform/argocd/applications/coo-operator.yaml`
```yaml
# Cluster Observability Operator (Red Hat, AllNamespaces).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: coo-operator
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: operators/coo
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-cluster-observability-operator
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
```

#### 2.4.2 Plugin Perses et tableau RHBK (Application `observability-console`)

La source de données utilise le **jeton de l'utilisateur connecté à la console** : chacun ne
voit que ce qu'il a le droit de voir. Le tableau est généré en JSON (YAML valide). Aucun
namespace n'y est écrit en dur : la variable **Environnement**, en haut du tableau, liste
automatiquement les namespaces où tourne un conteneur `keycloak` (tous sélectionnés par
défaut). Un nouvel environnement y apparaît sans modifier le tableau.

`rhbk-platform/observability-console/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - uiplugin-monitoring.yaml
  - namespace.yaml
  - datasource.yaml
  - dashboard-rhbk-overview.yaml
```

`rhbk-platform/observability-console/uiplugin-monitoring.yaml`
```yaml
# Console plugin of the Cluster Observability Operator: Perses dashboards in the OpenShift console
# (Observe -> Dashboards (Perses)).
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
```

`rhbk-platform/observability-console/namespace.yaml`
```yaml
# Project holding the RHBK overview dashboard (Perses) shown in the OpenShift console.
apiVersion: v1
kind: Namespace
metadata:
  name: rhbk-observability
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

`rhbk-platform/observability-console/datasource.yaml`
```yaml
# Default datasource of the project: Thanos Querier (platform + user workload metrics).
# Same settings as the datasources created by COO: TLS with the service CA; Perses forwards the
# token of the user logged in to the console (each user only sees what they are allowed to see).
apiVersion: perses.dev/v1alpha2
kind: PersesDatasource
metadata:
  name: rhbk-thanos
  namespace: rhbk-observability
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  client:
    tls:
      enable: true
      caCert:
        type: file
        certPath: /ca/service-ca.crt
  config:
    default: true
    display:
      name: Thanos Querier (RHBK)
    plugin:
      kind: PrometheusDatasource
      spec:
        proxy:
          kind: HTTPProxy
          spec:
            url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
            secret: rhbk-thanos-secret
```

`rhbk-platform/observability-console/dashboard-rhbk-overview.yaml`
```yaml
# RHBK overview dashboard (Perses), shown in the OpenShift console: Observe -> Dashboards (Perses),
# project rhbk-observability. Keycloak environments side by side, chosen with the "Environnement"
# variable (namespaces running a keycloak container, discovered automatically); platform state.
# Generated as JSON (valid YAML) to keep queries exact.
{
  "apiVersion": "perses.dev/v1alpha2",
  "kind": "PersesDashboard",
  "metadata": {
    "name": "rhbk-overview",
    "namespace": "rhbk-observability",
    "annotations": {
      "argocd.argoproj.io/sync-wave": "2",
      "argocd.argoproj.io/sync-options": "SkipDryRunOnMissingResource=true"
    }
  },
  "spec": {
    "config": {
      "display": {
        "name": "RHBK - vue d'ensemble"
      },
      "duration": "1h",
      "refreshInterval": "30s",
      "panels": {
        "kc_ready": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "Pods Keycloak prêts",
              "description": "Nombre de pods Keycloak prêts par environnement (rhbk = prod)."
            },
            "plugin": {
              "kind": "StatChart",
              "spec": {
                "calculation": "last-number",
                "format": {
                  "unit": "decimal"
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "sum by (namespace) (kube_pod_container_status_ready{namespace=~\"$namespace\", container=\"keycloak\"})",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "pg_ready": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "Pods PostgreSQL prêts"
            },
            "plugin": {
              "kind": "StatChart",
              "spec": {
                "calculation": "last-number",
                "format": {
                  "unit": "decimal"
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "sum by (namespace) (kube_pod_status_ready{namespace=~\"$namespace\", pod=~\"postgres-db-.+\", condition=\"true\"})",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "vault_ready": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "Vault prêt (descellé)",
              "description": "0 = Vault scellé ou arrêté : le desceller (guide, section 15.5)."
            },
            "plugin": {
              "kind": "StatChart",
              "spec": {
                "calculation": "last-number",
                "format": {
                  "unit": "decimal"
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "sum(kube_pod_status_ready{namespace=\"vault\", pod=~\"vault-[0-9]+\", condition=\"true\"})",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "es_errors": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "ExternalSecrets en erreur",
              "description": "Secrets qui ne sont plus rafraîchis depuis Vault. Après un redémarrage : forcer la relecture."
            },
            "plugin": {
              "kind": "StatChart",
              "spec": {
                "calculation": "last-number",
                "format": {
                  "unit": "decimal"
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "sum(externalsecret_status_condition{condition=\"Ready\", status=\"False\"}) or vector(0)",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "argo_unhealthy": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "Applications ArgoCD non saines"
            },
            "plugin": {
              "kind": "StatChart",
              "spec": {
                "calculation": "last-number",
                "format": {
                  "unit": "decimal"
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "count(argocd_app_info{namespace=\"openshift-gitops\", health_status!=\"Healthy\"}) or vector(0)",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "alerts": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "Alertes RHBK actives",
              "description": "Détail : Observe -> Alerting."
            },
            "plugin": {
              "kind": "StatChart",
              "spec": {
                "calculation": "last-number",
                "format": {
                  "unit": "decimal"
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "count(ALERTS{alertstate=\"firing\", namespace=~\"$namespace|vault|external-secrets|openshift-gitops\"}) or vector(0)",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "kc_rps": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "Requêtes HTTP / s",
              "description": "Hors sondes de santé et /metrics."
            },
            "plugin": {
              "kind": "TimeSeriesChart",
              "spec": {
                "legend": {
                  "position": "bottom",
                  "mode": "list"
                },
                "yAxis": {
                  "format": {
                    "unit": "decimal"
                  }
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "sum by (namespace) (rate(http_server_requests_seconds_count{namespace=~\"$namespace\", uri!~\"/health.*|/metrics\"}[5m]))",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "kc_5xx": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "Taux d'erreurs 5xx"
            },
            "plugin": {
              "kind": "TimeSeriesChart",
              "spec": {
                "legend": {
                  "position": "bottom",
                  "mode": "list"
                },
                "yAxis": {
                  "format": {
                    "unit": "percent-decimal"
                  }
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "sum by (namespace) (rate(http_server_requests_seconds_count{namespace=~\"$namespace\", outcome=\"SERVER_ERROR\", uri!~\"/health.*|/metrics\"}[5m])) / sum by (namespace) (rate(http_server_requests_seconds_count{namespace=~\"$namespace\", uri!~\"/health.*|/metrics\"}[5m]))",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "kc_p95": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "Temps de réponse p95"
            },
            "plugin": {
              "kind": "TimeSeriesChart",
              "spec": {
                "legend": {
                  "position": "bottom",
                  "mode": "list"
                },
                "yAxis": {
                  "format": {
                    "unit": "seconds"
                  }
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "histogram_quantile(0.95, sum by (namespace, le) (rate(http_server_requests_seconds_bucket{namespace=~\"$namespace\", uri!~\"/health.*|/metrics\"}[5m])))",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "kc_logins": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "Connexions / s (réussies et échouées)",
              "description": "Série sans erreur = connexions réussies ; sinon le type d'erreur (invalid_user_credentials, user_not_found...)."
            },
            "plugin": {
              "kind": "TimeSeriesChart",
              "spec": {
                "legend": {
                  "position": "bottom",
                  "mode": "list"
                },
                "yAxis": {
                  "format": {
                    "unit": "decimal"
                  }
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "sum by (namespace, error) (rate(keycloak_user_events_total{namespace=~\"$namespace\", event=\"login\"}[5m]))",
                      "seriesNameFormat": "{{namespace}} {{error}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "kc_db": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "Connexions base actives / en attente",
              "description": "Pool de connexions PostgreSQL (db.poolMaxSize = 5)."
            },
            "plugin": {
              "kind": "TimeSeriesChart",
              "spec": {
                "legend": {
                  "position": "bottom",
                  "mode": "list"
                },
                "yAxis": {
                  "format": {
                    "unit": "decimal"
                  }
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "sum by (namespace) (agroal_active_count{namespace=~\"$namespace\"})",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "kc_heap": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "Mémoire JVM (heap)"
            },
            "plugin": {
              "kind": "TimeSeriesChart",
              "spec": {
                "legend": {
                  "position": "bottom",
                  "mode": "list"
                },
                "yAxis": {
                  "format": {
                    "unit": "percent-decimal"
                  }
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "sum by (namespace) (jvm_memory_used_bytes{namespace=~\"$namespace\", area=\"heap\"}) / sum by (namespace) (jvm_memory_max_bytes{namespace=~\"$namespace\", area=\"heap\"} > 0)",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        },
        "kc_cpu": {
          "kind": "Panel",
          "spec": {
            "display": {
              "name": "CPU Keycloak (cœurs)"
            },
            "plugin": {
              "kind": "TimeSeriesChart",
              "spec": {
                "legend": {
                  "position": "bottom",
                  "mode": "list"
                },
                "yAxis": {
                  "format": {
                    "unit": "decimal"
                  }
                }
              }
            },
            "queries": [
              {
                "kind": "TimeSeriesQuery",
                "spec": {
                  "plugin": {
                    "kind": "PrometheusTimeSeriesQuery",
                    "spec": {
                      "query": "sum by (namespace) (rate(container_cpu_usage_seconds_total{namespace=~\"$namespace\", container=\"keycloak\"}[5m]))",
                      "seriesNameFormat": "{{namespace}}"
                    }
                  }
                }
              }
            ]
          }
        }
      },
      "layouts": [
        {
          "kind": "Grid",
          "spec": {
            "display": {
              "title": "État",
              "collapse": {
                "open": true
              }
            },
            "items": [
              {
                "x": 0,
                "y": 0,
                "width": 4,
                "height": 4,
                "content": {
                  "$ref": "#/spec/panels/kc_ready"
                }
              },
              {
                "x": 4,
                "y": 0,
                "width": 4,
                "height": 4,
                "content": {
                  "$ref": "#/spec/panels/pg_ready"
                }
              },
              {
                "x": 8,
                "y": 0,
                "width": 4,
                "height": 4,
                "content": {
                  "$ref": "#/spec/panels/vault_ready"
                }
              },
              {
                "x": 12,
                "y": 0,
                "width": 4,
                "height": 4,
                "content": {
                  "$ref": "#/spec/panels/es_errors"
                }
              },
              {
                "x": 16,
                "y": 0,
                "width": 4,
                "height": 4,
                "content": {
                  "$ref": "#/spec/panels/argo_unhealthy"
                }
              },
              {
                "x": 20,
                "y": 0,
                "width": 4,
                "height": 4,
                "content": {
                  "$ref": "#/spec/panels/alerts"
                }
              }
            ]
          }
        },
        {
          "kind": "Grid",
          "spec": {
            "display": {
              "title": "Keycloak : trafic",
              "collapse": {
                "open": true
              }
            },
            "items": [
              {
                "x": 0,
                "y": 0,
                "width": 12,
                "height": 7,
                "content": {
                  "$ref": "#/spec/panels/kc_rps"
                }
              },
              {
                "x": 12,
                "y": 0,
                "width": 12,
                "height": 7,
                "content": {
                  "$ref": "#/spec/panels/kc_5xx"
                }
              },
              {
                "x": 0,
                "y": 7,
                "width": 12,
                "height": 7,
                "content": {
                  "$ref": "#/spec/panels/kc_p95"
                }
              },
              {
                "x": 12,
                "y": 7,
                "width": 12,
                "height": 7,
                "content": {
                  "$ref": "#/spec/panels/kc_logins"
                }
              }
            ]
          }
        },
        {
          "kind": "Grid",
          "spec": {
            "display": {
              "title": "Keycloak : ressources",
              "collapse": {
                "open": true
              }
            },
            "items": [
              {
                "x": 0,
                "y": 0,
                "width": 8,
                "height": 7,
                "content": {
                  "$ref": "#/spec/panels/kc_db"
                }
              },
              {
                "x": 8,
                "y": 0,
                "width": 8,
                "height": 7,
                "content": {
                  "$ref": "#/spec/panels/kc_heap"
                }
              },
              {
                "x": 16,
                "y": 0,
                "width": 8,
                "height": 7,
                "content": {
                  "$ref": "#/spec/panels/kc_cpu"
                }
              }
            ]
          }
        }
      ],
      "variables": [
        {
          "kind": "ListVariable",
          "spec": {
            "name": "namespace",
            "display": {
              "name": "Environnement",
              "description": "Namespaces running a Keycloak container (rhbk = prod)."
            },
            "allowMultiple": true,
            "allowAllValue": true,
            "defaultValue": "$__all",
            "plugin": {
              "kind": "PrometheusLabelValuesVariable",
              "spec": {
                "labelName": "namespace",
                "matchers": [
                  "kube_pod_container_status_ready{container=\"keycloak\"}"
                ]
              }
            }
          }
        }
      ]
    }
  }
}
```

`rhbk-platform/argocd/applications/observability-console.yaml`
```yaml
# RHBK overview dashboard (Perses) in the console (part 2: dashboards). Needs coo-operator.
# The Logs and Traces console plugins belong to the "logging" and "tracing" Applications.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability-console
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: observability-console
  destination:
    server: https://kubernetes.default.svc
    namespace: rhbk-observability
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 20s
        factor: 2
        maxDuration: 3m
```

Déclarer les Applications dans `rhbk-platform/argocd/kustomization.yaml` (sous `resources:`) :

```yaml
  - applications/coo-operator.yaml
  - applications/observability-console.yaml
```

Autoriser les namespaces dans `rhbk-platform/argocd/appproject.yaml`, sous `spec.destinations` :

```yaml
    - server: https://kubernetes.default.svc
      namespace: openshift-cluster-observability-operator
    - server: https://kubernetes.default.svc
      namespace: rhbk-observability
```

et les ressources de niveau cluster, sous `spec.clusterResourceWhitelist` (si absentes) :

```yaml
    - group: observability.openshift.io
      kind: UIPlugin
```

Commit, push, puis :

```bash
oc patch application coo-operator -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
oc patch application observability-console -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
```

### 2.5 Vérifier

- Grafana : `https://grafana.apps.<domaine>` → **Log in with OpenShift** → **Dashboards →
  Keycloak** → choisir le namespace `rhbk` ou `rhbk-dev` en haut du tableau.
- Console : **Observe → Dashboards (Perses)**, projet `rhbk-observability`, **RHBK - vue
  d'ensemble**.

```bash
oc get grafanadatasources.grafana.integreatly.org,grafanadashboards.grafana.integreatly.org -n grafana
```

```bash
oc get uiplugin monitoring
```

### 2.6 Si on s'arrête ici

Parties 1 et 2 complètes : métriques, alertes, notifications et tableaux de bord. Pas de logs
centralisés (partie 3) ni de traces (partie 4) : les logs restent consultables pod par pod
(`oc logs`).

---

## Partie 3 : logs centralisés

**Résultat** : logs des applications (Keycloak en JSON, PostgreSQL, Vault, ESO, Grafana…) et
d'ArgoCD, conservés 7 jours, consultables dans **Observe → Logs**.

### 3.1 Prérequis

- Stockage objet NooBaa (section 0.2), ESO (conversion des identifiants du bucket).
- Pour l'affichage dans la console : le Cluster Observability Operator (étape 2.4.1, à faire
  si la partie 2 n'a pas été déployée).

### 3.2 Opérateurs (Applications `logging-operator` et `loki-operator`)

Le paquet `loki-operator` existe dans deux catalogues : prendre celui de `redhat-operators`.

`rhbk-platform/operators/logging/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - namespace.yaml
  - operatorgroup.yaml
  - subscription.yaml
```

`rhbk-platform/operators/logging/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
  labels:
    openshift.io/cluster-monitoring: "true"
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

`rhbk-platform/operators/logging/operatorgroup.yaml`
```yaml
# AllNamespaces mode (no targetNamespaces).
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-logging
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  upgradeStrategy: Default
```

`rhbk-platform/operators/logging/subscription.yaml`
```yaml
# Red Hat OpenShift Logging (collector, ClusterLogForwarder).
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  channel: stable-6.6
  name: cluster-logging
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

`rhbk-platform/argocd/applications/logging-operator.yaml`
```yaml
# Red Hat OpenShift Logging (collector, ClusterLogForwarder).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: logging-operator
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: operators/logging
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-logging
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
```

`rhbk-platform/operators/loki/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - namespace.yaml
  - operatorgroup.yaml
  - subscription.yaml
```

`rhbk-platform/operators/loki/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators-redhat
  labels:
    openshift.io/cluster-monitoring: "true"
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

`rhbk-platform/operators/loki/operatorgroup.yaml`
```yaml
# AllNamespaces mode (no targetNamespaces).
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  upgradeStrategy: Default
```

`rhbk-platform/operators/loki/subscription.yaml`
```yaml
# Loki Operator (Red Hat, catalog redhat-operators; not the community package with the same name).
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: loki-operator
  namespace: openshift-operators-redhat
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  channel: stable-6.6
  name: loki-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

`rhbk-platform/argocd/applications/loki-operator.yaml`
```yaml
# Loki Operator (Red Hat, catalog redhat-operators; not the community package with the same name).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: loki-operator
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: operators/loki
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-operators-redhat
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
```

### 3.3 Stockage et collecte (Application `logging`)

| Fichier | Rôle |
|---|---|
| `bucket.yaml` | bucket NooBaa `loki-rhbk` |
| `loki-s3-secret.yaml` | conversion des identifiants du bucket au format LokiStack (ESO, fournisseur `kubernetes`) |
| `lokistack.yaml` | LokiStack `1x.demo` (sandbox ; production : `1x.pico`), rétention 7 jours |
| `clusterlogforwarder.yaml` | collecteur : logs *application* + `openshift-gitops` (ArgoCD) |
| `uiplugin-logging.yaml` | logs dans la console |

`rhbk-platform/logging/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - bucket.yaml
  - loki-s3-secret.yaml
  - lokistack.yaml
  - clusterlogforwarder.yaml
  - uiplugin-logging.yaml
```

`rhbk-platform/logging/bucket.yaml`
```yaml
# S3 bucket for Loki, provided by ODF (NooBaa / Multicloud Object Gateway). NooBaa creates the
# bucket and writes its credentials into Secret "loki-bucket" (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY).
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: loki-bucket
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  storageClassName: openshift-storage.noobaa.io
  bucketName: loki-rhbk
```

`rhbk-platform/logging/loki-s3-secret.yaml`
```yaml
# Converts the NooBaa bucket credentials into the Secret format expected by LokiStack
# (access_key_id, access_key_secret, bucketnames, endpoint), with ESO's "kubernetes" provider
# reading the local Secret "loki-bucket". No credential in git, nothing to copy by hand.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-local-secret-reader
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: eso-local-secret-reader
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["loki-bucket"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["authorization.k8s.io"]
    resources: ["selfsubjectrulesreviews"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: eso-local-secret-reader
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: eso-local-secret-reader
subjects:
  - kind: ServiceAccount
    name: eso-local-secret-reader
    namespace: openshift-logging
---
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: local-secrets
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  provider:
    kubernetes:
      remoteNamespace: openshift-logging
      server:
        caProvider:
          type: ConfigMap
          name: kube-root-ca.crt
          key: ca.crt
      auth:
        serviceAccount:
          name: eso-local-secret-reader
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: logging-loki-s3
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: local-secrets
  target:
    name: logging-loki-s3
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      mergePolicy: Replace
      data:
        access_key_id: "{{ .access_key_id }}"
        access_key_secret: "{{ .access_key_secret }}"
        bucketnames: loki-rhbk
        endpoint: https://s3.openshift-storage.svc:443
  data:
    - secretKey: access_key_id
      remoteRef:
        key: loki-bucket
        property: AWS_ACCESS_KEY_ID
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
    - secretKey: access_key_secret
      remoteRef:
        key: loki-bucket
        property: AWS_SECRET_ACCESS_KEY
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
```

`rhbk-platform/logging/lokistack.yaml`
```yaml
# Log store. Size 1x.demo: smallest, no high availability (sandbox). Production: 1x.pico or larger.
# Object storage: NooBaa bucket (logging-loki-s3), TLS with the OpenShift service CA.
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "3"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  size: 1x.demo
  storageClassName: ocs-storagecluster-ceph-rbd
  storage:
    schemas:
      - version: v13
        effectiveDate: "2026-10-01"
    secret:
      name: logging-loki-s3
      type: s3
    tls:
      caName: openshift-service-ca.crt
      caKey: service-ca.crt
  limits:
    global:
      retention:
        days: 7
  tenants:
    mode: openshift-logging
```

`rhbk-platform/logging/clusterlogforwarder.yaml`
```yaml
# Collector (Vector) and forwarding to the LokiStack:
#  - "application" logs: every namespace except openshift-*, kube-*, default
#    (Keycloak, PostgreSQL, Vault, ESO, Grafana...);
#  - from the "infrastructure" logs, only the openshift-gitops namespace (ArgoCD).
apiVersion: v1
kind: ServiceAccount
metadata:
  name: collector
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector-collect-application-logs
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: collect-application-logs
subjects:
  - kind: ServiceAccount
    name: collector
    namespace: openshift-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector-collect-infrastructure-logs
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: collect-infrastructure-logs
subjects:
  - kind: ServiceAccount
    name: collector
    namespace: openshift-logging
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: logging-collector-logs-writer
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: logging-collector-logs-writer
subjects:
  - kind: ServiceAccount
    name: collector
    namespace: openshift-logging
---
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: collector
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "4"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  serviceAccount:
    name: collector
  inputs:
    - name: infrastructure-containers
      type: infrastructure
      infrastructure:
        sources:
          - container
  filters:
    - name: keep-only-openshift-gitops
      type: drop
      drop:
        - test:
            - field: .kubernetes.namespace_name
              notMatches: "^openshift-gitops$"
  outputs:
    - name: default-lokistack
      type: lokiStack
      lokiStack:
        target:
          name: logging-loki
          namespace: openshift-logging
        authentication:
          token:
            from: serviceAccount
      tls:
        ca:
          configMapName: openshift-service-ca.crt
          key: service-ca.crt
  pipelines:
    - name: applications
      inputRefs:
        - application
      outputRefs:
        - default-lokistack
    - name: argocd
      inputRefs:
        - infrastructure-containers
      filterRefs:
        - keep-only-openshift-gitops
      outputRefs:
        - default-lokistack
```

`rhbk-platform/logging/uiplugin-logging.yaml`
```yaml
# Console plugin of the Cluster Observability Operator: logs from the LokiStack in the OpenShift
# console (Observe -> Logs, and the "Aggregated Logs" tab of pods). Part of the logs (part 3);
# needs the Cluster Observability Operator (coo-operator) for the UIPlugin CRD.
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: logging
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  type: Logging
  logging:
    lokiStack:
      name: logging-loki
      namespace: openshift-logging
    schema: viaq
```

`rhbk-platform/argocd/applications/logging.yaml`
```yaml
# Log store (LokiStack on a NooBaa bucket) and log forwarding (ClusterLogForwarder).
# Needs logging-operator and loki-operator, and coo-operator for the Logs console plugin.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: logging
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: logging
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-logging
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
    retry:
      limit: 6
      backoff:
        duration: 20s
        factor: 2
        maxDuration: 5m
```

Déclarer les Applications dans `rhbk-platform/argocd/kustomization.yaml` (sous `resources:`) :

```yaml
  - applications/logging-operator.yaml
  - applications/loki-operator.yaml
  - applications/logging.yaml
```

Autoriser les namespaces dans `rhbk-platform/argocd/appproject.yaml`, sous `spec.destinations` :

```yaml
    - server: https://kubernetes.default.svc
      namespace: openshift-logging
    - server: https://kubernetes.default.svc
      namespace: openshift-operators-redhat
```

et les ressources de niveau cluster, sous `spec.clusterResourceWhitelist` (si absentes) :

```yaml
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
    - group: observability.openshift.io
      kind: UIPlugin
```

Commit, push, puis :

```bash
oc patch application loki-operator -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
oc patch application logging-operator -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
oc patch application logging -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
```

### 3.4 Keycloak : logs JSON

Option d'exécution dans `base/keycloak/keycloak.yaml`, dans `additionalOptions` (à la suite
des options déjà présentes, avant `scheduling:` ; si le bloc n'existe pas encore, ajouter
aussi la ligne `additionalOptions:`, comme à l'étape 1.3) : rolling update, sans rebuild.

```yaml
    # [Observability part 3 - logs] JSON console logs (runtime option): fields (level, loggerName,
    # message...) can be filtered in Loki with the "| json" LogQL parser.
    - name: log-console-output
      value: json
```


### 3.5 Vérifier

```bash
oc get lokistack logging-loki -n openshift-logging && oc get clusterlogforwarder collector -n openshift-logging
```

```bash
oc get pods -n openshift-logging
```

Un pod `collector-*` par nœud. L'avertissement de LokiStack « ingester replicas (1) » est
normal en `1x.demo`. Console : **Observe → Logs**, namespace `rhbk-dev`, requête
`{kubernetes_namespace_name="rhbk-dev", kubernetes_container_name="keycloak"} | json | level=~"warn|error"`
(autres requêtes : section 15.9 du guide).

### 3.6 Si on s'arrête ici

Logs centralisés en plus des parties déployées. Pas de traces (partie 4).

---

## Partie 4 : traces

**Résultat** : traces de bout en bout (requête HTTP → traitement Keycloak → requêtes SQL),
100 % des requêtes en dev, 10 % en prod, conservées 72 heures, dans **Observe → Traces**.

### 4.1 Prérequis

- Option A : stockage objet NooBaa (section 0.2) et ESO. Option B : seulement une classe de
  stockage en bloc (`ocs-storagecluster-ceph-rbd`, ou `thin-csi`…) ; voir 4.3.
- Pour l'affichage dans la console : le Cluster Observability Operator (étape 2.4.1).

### 4.2 Opérateurs (Applications `tempo-operator` et `otel-operator`)

`rhbk-platform/operators/tempo/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - namespace.yaml
  - operatorgroup.yaml
  - subscription.yaml
```

`rhbk-platform/operators/tempo/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-tempo-operator
  labels:
    openshift.io/cluster-monitoring: "true"
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

`rhbk-platform/operators/tempo/operatorgroup.yaml`
```yaml
# AllNamespaces mode (no targetNamespaces).
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-tempo-operator
  namespace: openshift-tempo-operator
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  upgradeStrategy: Default
```

`rhbk-platform/operators/tempo/subscription.yaml`
```yaml
# Tempo Operator (Red Hat build of Tempo): trace storage.
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: tempo-product
  namespace: openshift-tempo-operator
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  channel: stable
  name: tempo-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

`rhbk-platform/argocd/applications/tempo-operator.yaml`
```yaml
# Tempo Operator (Red Hat build of Tempo): trace storage.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tempo-operator
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: operators/tempo
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-tempo-operator
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
```

`rhbk-platform/operators/otel/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - namespace.yaml
  - operatorgroup.yaml
  - subscription.yaml
```

`rhbk-platform/operators/otel/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-opentelemetry-operator
  labels:
    openshift.io/cluster-monitoring: "true"
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
```

`rhbk-platform/operators/otel/operatorgroup.yaml`
```yaml
# AllNamespaces mode (no targetNamespaces).
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-opentelemetry-operator
  namespace: openshift-opentelemetry-operator
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  upgradeStrategy: Default
```

`rhbk-platform/operators/otel/subscription.yaml`
```yaml
# Red Hat build of OpenTelemetry: OpenTelemetry Collector.
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: opentelemetry-product
  namespace: openshift-opentelemetry-operator
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  channel: stable
  name: opentelemetry-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
```

`rhbk-platform/argocd/applications/otel-operator.yaml`
```yaml
# Red Hat build of OpenTelemetry: OpenTelemetry Collector.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: otel-operator
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: operators/otel
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-opentelemetry-operator
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
```

### 4.3 Stockage, Collector et affichage : option A ou option B

Deux façons de stocker les traces. **Choisir l'une ou l'autre**, jamais les deux : elles utilisent
le même namespace (`rhbk-tracing`), le même Collector et les mêmes droits, et l'API refuse un
TempoMonolithic à côté d'un TempoStack du même nom. Keycloak, la console et les requêtes TraceQL
sont identiques dans les deux cas.

| | **Option A : TempoStack + stockage objet** (référence) | **Option B : TempoMonolithic + volume persistant** |
|---|---|---|
| Application, dossier | `tracing`, `tracing/` | `tracing-pv`, `tracing-pv/` |
| Stockage des traces | bucket S3 (NooBaa `tempo-rhbk`), identifiants convertis par ESO | PVC classique (`backend: pv`, 10 Gi) : ni bucket, ni secret S3 |
| Architecture | composants séparés (distributor, ingester, querier, compactor, passerelle…) | un seul pod (Tempo, passerelle, OPA) |
| Haute disponibilité, montée en charge | possibles (tailles `1x.pico` et plus) | non : traces non reçues pendant un redémarrage du pod |
| Rétention (72 h) | `spec.retention` | `extraConfig` (paramètre Tempo `block_retention`) |
| Passerelle (export du Collector) | port **8090** | port **4317** |
| Adapté à | production, volumes importants | test, petits volumes, cluster sans stockage objet |

L'option B a été testée à côté de l'option A, dans un namespace séparé : traces reçues, lues dans
la console (**Observe → Traces**), conservées après suppression du pod Tempo.

#### 4.3.1 Option A : TempoStack et stockage objet (Application `tracing`)

| Fichier | Rôle |
|---|---|
| `bucket.yaml`, `tempo-s3-secret.yaml` | bucket NooBaa `tempo-rhbk` et identifiants au format TempoStack (ESO) |
| `tempostack.yaml` | TempoStack `1x.demo`, rétention 72 h (forme normalisée `72h0m0s`), tenant `rhbk`, droits d'écriture et de lecture |
| `collector.yaml` | OpenTelemetry Collector : reçoit l'OTLP de Keycloak, ajoute les attributs Kubernetes, envoie à la passerelle Tempo avec son jeton |
| `uiplugin-distributed-tracing.yaml` | traces dans la console |

`rhbk-platform/tracing/kustomization.yaml`
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - namespace.yaml
  - bucket.yaml
  - tempo-s3-secret.yaml
  - tempostack.yaml
  - collector.yaml
  - uiplugin-distributed-tracing.yaml
```

`rhbk-platform/tracing/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

`rhbk-platform/tracing/bucket.yaml`
```yaml
# S3 bucket for Tempo (ODF / NooBaa). Credentials written by NooBaa into Secret "tempo-bucket".
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: tempo-bucket
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  storageClassName: openshift-storage.noobaa.io
  bucketName: tempo-rhbk
```

`rhbk-platform/tracing/tempo-s3-secret.yaml`
```yaml
# Converts the NooBaa bucket credentials into the Secret format expected by TempoStack
# (endpoint, bucket, access_key_id, access_key_secret) with ESO's "kubernetes" provider.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: eso-local-secret-reader
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: eso-local-secret-reader
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["tempo-bucket"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["authorization.k8s.io"]
    resources: ["selfsubjectrulesreviews"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: eso-local-secret-reader
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: eso-local-secret-reader
subjects:
  - kind: ServiceAccount
    name: eso-local-secret-reader
    namespace: rhbk-tracing
---
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: local-secrets
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  provider:
    kubernetes:
      remoteNamespace: rhbk-tracing
      server:
        caProvider:
          type: ConfigMap
          name: kube-root-ca.crt
          key: ca.crt
      auth:
        serviceAccount:
          name: eso-local-secret-reader
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: tempo-s3
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: local-secrets
  target:
    name: tempo-s3
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      mergePolicy: Replace
      data:
        access_key_id: "{{ .access_key_id }}"
        access_key_secret: "{{ .access_key_secret }}"
        bucket: tempo-rhbk
        endpoint: https://s3.openshift-storage.svc:443
  data:
    - secretKey: access_key_id
      remoteRef:
        key: tempo-bucket
        property: AWS_ACCESS_KEY_ID
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
    - secretKey: access_key_secret
      remoteRef:
        key: tempo-bucket
        property: AWS_SECRET_ACCESS_KEY
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
        nullBytePolicy: Ignore
```

`rhbk-platform/tracing/tempostack.yaml`
```yaml
# Trace store. Size 1x.demo (sandbox, no high availability). Multi-tenant "openshift" mode:
# a gateway authenticates writers and readers with their OpenShift token; single tenant "rhbk"
# for prod and dev (environments are told apart by the k8s.namespace.name attribute).
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoStack
metadata:
  name: tempo
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "3"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  size: 1x.demo
  storageClassName: ocs-storagecluster-ceph-rbd
  storage:
    secret:
      name: tempo-s3
      type: s3
    tls:
      enabled: true
      caName: openshift-service-ca.crt
  retention:
    global:
      traces: 72h0m0s   # normalized form (the API rewrites "72h")
  tenants:
    mode: openshift
    authentication:
      - tenantName: rhbk
        tenantId: 1e5c2f3a-9d1b-4f6e-8a7c-2b4d6e8f0a12
  template:
    gateway:
      enabled: true
    queryFrontend:
      jaegerQuery:
        enabled: true
---
# Allows writing traces to tenant "rhbk" (used by the collector) ...
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tempostack-rhbk-traces-writer
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: ["tempo.grafana.com"]
    resources: ["rhbk"]
    resourceNames: ["traces"]
    verbs: ["create"]
---
# ... and reading them (bind it to users or groups who must see traces; cluster admins already can).
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tempostack-rhbk-traces-reader
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: ["tempo.grafana.com"]
    resources: ["rhbk"]
    resourceNames: ["traces"]
    verbs: ["get"]
```

`rhbk-platform/tracing/collector.yaml`
```yaml
# OpenTelemetry Collector: receives OTLP from Keycloak (grpc 4317, http 4318), adds Kubernetes
# attributes (namespace, pod...), and forwards to the Tempo gateway with its ServiceAccount token.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector-tempostack-rhbk-traces-writer
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tempostack-rhbk-traces-writer
subjects:
  - kind: ServiceAccount
    name: otel-collector
    namespace: rhbk-tracing
---
# k8sattributes processor: read pods, namespaces and replicasets.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector-k8sattributes
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector-k8sattributes
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-collector-k8sattributes
subjects:
  - kind: ServiceAccount
    name: otel-collector
    namespace: rhbk-tracing
---
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "4"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  mode: deployment
  serviceAccount: otel-collector
  config:
    extensions:
      bearertokenauth:
        filename: /var/run/secrets/kubernetes.io/serviceaccount/token
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 75
        spike_limit_percentage: 15
      k8sattributes: {}
      batch: {}
    exporters:
      otlp/tempo:
        endpoint: tempo-tempo-gateway.rhbk-tracing.svc.cluster.local:8090
        tls:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
        auth:
          authenticator: bearertokenauth
        headers:
          X-Scope-OrgID: rhbk
    service:
      extensions: [bearertokenauth]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlp/tempo]
```

`rhbk-platform/tracing/uiplugin-distributed-tracing.yaml`
```yaml
# Console plugin of the Cluster Observability Operator: traces from the TempoStack in the
# OpenShift console (Observe -> Traces). Part of the traces (part 4); needs the Cluster
# Observability Operator (coo-operator) for the UIPlugin CRD.
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: distributed-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  type: DistributedTracing
```

`rhbk-platform/argocd/applications/tracing.yaml`
```yaml
# Trace store (TempoStack on a NooBaa bucket) and OpenTelemetry Collector, namespace rhbk-tracing.
# Needs tempo-operator and otel-operator, and coo-operator for the Traces console plugin.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tracing
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: tracing
  destination:
    server: https://kubernetes.default.svc
    namespace: rhbk-tracing
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
    retry:
      limit: 6
      backoff:
        duration: 20s
        factor: 2
        maxDuration: 5m
```

Déclarer les Applications dans `rhbk-platform/argocd/kustomization.yaml` (sous `resources:`) :

```yaml
  - applications/tempo-operator.yaml
  - applications/otel-operator.yaml
  - applications/tracing.yaml
```

Autoriser les namespaces dans `rhbk-platform/argocd/appproject.yaml`, sous `spec.destinations` :

```yaml
    - server: https://kubernetes.default.svc
      namespace: openshift-tempo-operator
    - server: https://kubernetes.default.svc
      namespace: openshift-opentelemetry-operator
    - server: https://kubernetes.default.svc
      namespace: rhbk-tracing
```

et les ressources de niveau cluster, sous `spec.clusterResourceWhitelist` (si absentes) :

```yaml
    - group: rbac.authorization.k8s.io
      kind: ClusterRole
    - group: rbac.authorization.k8s.io
      kind: ClusterRoleBinding
    - group: observability.openshift.io
      kind: UIPlugin
```

Commit, push, puis :

```bash
oc patch application tempo-operator -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
oc patch application otel-operator -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
oc patch application tracing -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
```

**Taille du bucket.** Un bucket S3 n'a **pas de taille fixée à l'avance**, contrairement à un
PVC. `bucket.yaml` (ObjectBucketClaim) ne demande ni taille ni quota, et la classe de bucket NooBaa
(`noobaa-default-bucket-class`) n'en impose pas non plus. Derrière NooBaa, le stockage réel est ici
un bucket AWS S3 (backing store `noobaa-default-backing-store`, type `aws-s3`) : le bucket grossit
avec les écritures. Ce qui borne son volume est la **rétention de 72 h** (les blocs plus anciens
sont supprimés par le compactor) et l'**échantillonnage** (10 % en prod, section 4.4). Mesuré sur
le cluster de démonstration : environ 18 Mio pour `tempo-rhbk` (90 Mio pour `loki-rhbk`).

Voir l'occupation dans **Observe → Metrics** :

```
NooBaa_bucket_used_bytes{bucket_name="tempo-rhbk"}
```

À ne pas confondre : le seul volume de taille fixe de l'option A est le **PVC de l'ingester**
(`data-tempo-tempo-ingester-0`, 10 Gi, classe `storageClassName` du TempoStack, taille par défaut
car `storageSize` n'est pas renseigné). Il contient le journal d'écriture (WAL) et les traces
récentes avant leur envoi dans le bucket, pas les traces conservées :

```bash
oc get pvc -n rhbk-tracing
```

Pour **plafonner** le bucket, il faut un quota NooBaa (`spec.additionalConfig.maxSize` de
l'ObjectBucketClaim, ou quota sur la classe de bucket). Non mis en place ni testé ici : une fois le
quota atteint, Tempo ne peut plus écrire et les nouvelles traces sont perdues.

#### 4.3.2 Option B : TempoMonolithic et volume persistant (Application `tracing-pv`)

| Fichier | Rôle |
|---|---|
| `namespace.yaml` | namespace `rhbk-tracing` (identique à l'option A) |
| `tempomonolithic.yaml` | TempoMonolithic `tempo`, volume de 10 Gi, rétention 72 h, tenant `rhbk`, droits d'écriture et de lecture (mêmes ClusterRoles que l'option A) ; `timeout: 0s` déclaré (valeur ajoutée par l'API, sinon `OutOfSync` permanent) |
| `collector.yaml` | identique à l'option A, sauf le port de la passerelle : **4317** |
| `uiplugin-distributed-tracing.yaml` | traces dans la console (identique à l'option A) |

Pour une autre classe de stockage (par exemple `thin-csi`), adapter `storageClassName`.

`rhbk-platform/tracing-pv/kustomization.yaml`
```yaml
# Option B of the traces (part 4): TempoMonolithic on a persistent volume, no object storage.
# Replaces tracing/ (option A, TempoStack on S3): deploy one or the other, never both
# (same namespace, Collector and ClusterRoles). Keycloak is unchanged (same Collector address).
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
labels:
  - pairs:
      app.kubernetes.io/part-of: rhbk-platform
resources:
  - namespace.yaml
  - tempomonolithic.yaml
  - collector.yaml
  - uiplugin-distributed-tracing.yaml
```

`rhbk-platform/tracing-pv/namespace.yaml`
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
```

`rhbk-platform/tracing-pv/tempomonolithic.yaml`
```yaml
# Trace store, option B: TempoMonolithic (a single pod: Tempo, gateway, OPA) writing traces on a
# persistent volume (backend pv): no bucket, no S3 secret. No high availability: traces are not
# received while the pod restarts. Multi-tenant "openshift" mode, single tenant "rhbk", as option A.
apiVersion: tempo.grafana.com/v1alpha1
kind: TempoMonolithic
metadata:
  name: tempo
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "3"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  storage:
    traces:
      backend: pv
      size: 10Gi
      storageClassName: ocs-storagecluster-ceph-rbd
  multitenancy:
    enabled: true
    mode: openshift
    authentication:
      - tenantName: rhbk
        tenantId: 1e5c2f3a-9d1b-4f6e-8a7c-2b4d6e8f0a12
  # No retention field in TempoMonolithic: Tempo setting (the operator warns that extraConfig
  # overrides its configuration; this single key was tested).
  extraConfig:
    tempo:
      compactor:
        compaction:
          block_retention: 72h
  # Default added by the API: declared to avoid a permanent OutOfSync in ArgoCD.
  timeout: 0s
---
# Allows writing traces to tenant "rhbk" (used by the collector) ...
# Same names as option A (tracing/tempostack.yaml): they apply to any Tempo instance with tenant "rhbk".
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tempostack-rhbk-traces-writer
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: ["tempo.grafana.com"]
    resources: ["rhbk"]
    resourceNames: ["traces"]
    verbs: ["create"]
---
# ... and reading them (bind it to users or groups who must see traces; cluster admins already can).
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tempostack-rhbk-traces-reader
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: ["tempo.grafana.com"]
    resources: ["rhbk"]
    resourceNames: ["traces"]
    verbs: ["get"]
```

`rhbk-platform/tracing-pv/collector.yaml`
```yaml
# OpenTelemetry Collector: receives OTLP from Keycloak (grpc 4317, http 4318), adds Kubernetes
# attributes (namespace, pod...), and forwards to the Tempo gateway with its ServiceAccount token.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: otel-collector
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "0"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector-tempostack-rhbk-traces-writer
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: tempostack-rhbk-traces-writer
subjects:
  - kind: ServiceAccount
    name: otel-collector
    namespace: rhbk-tracing
---
# k8sattributes processor: read pods, namespaces and replicasets.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-collector-k8sattributes
  annotations:
    argocd.argoproj.io/sync-wave: "0"
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-collector-k8sattributes
  annotations:
    argocd.argoproj.io/sync-wave: "0"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-collector-k8sattributes
subjects:
  - kind: ServiceAccount
    name: otel-collector
    namespace: rhbk-tracing
---
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel
  namespace: rhbk-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "4"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  mode: deployment
  serviceAccount: otel-collector
  config:
    extensions:
      bearertokenauth:
        filename: /var/run/secrets/kubernetes.io/serviceaccount/token
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      memory_limiter:
        check_interval: 1s
        limit_percentage: 75
        spike_limit_percentage: 15
      k8sattributes: {}
      batch: {}
    exporters:
      otlp/tempo:
        # TempoMonolithic gateway: OTLP gRPC on port 4317 (8090 with a TempoStack).
        endpoint: tempo-tempo-gateway.rhbk-tracing.svc.cluster.local:4317
        tls:
          ca_file: /var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt
        auth:
          authenticator: bearertokenauth
        headers:
          X-Scope-OrgID: rhbk
    service:
      extensions: [bearertokenauth]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlp/tempo]
```

`rhbk-platform/tracing-pv/uiplugin-distributed-tracing.yaml`
```yaml
# Console plugin of the Cluster Observability Operator: traces from the Tempo instance in the
# OpenShift console (Observe -> Traces). Part of the traces (part 4); needs the Cluster
# Observability Operator (coo-operator) for the UIPlugin CRD.
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: distributed-tracing
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  type: DistributedTracing
```

`rhbk-platform/argocd/applications/tracing-pv.yaml`
```yaml
# Traces, option B (docs/observabilite.md, part 4): TempoMonolithic on a persistent volume and
# OpenTelemetry Collector, namespace rhbk-tracing. Replaces the "tracing" Application (option A):
# list one or the other in argocd/kustomization.yaml, never both. Not listed by default.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: tracing-pv
  namespace: openshift-gitops
spec:
  project: platform
  source:
    repoURL: https://github.com/msakho/rhbk-platform.git
    targetRevision: main
    path: tracing-pv
  destination:
    server: https://kubernetes.default.svc
    namespace: rhbk-tracing
  syncPolicy:
    # Platform: manual sync (review the diff, then Sync).
    syncOptions:
      - ServerSideApply=true
    retry:
      limit: 6
      backoff:
        duration: 20s
        factor: 2
        maxDuration: 5m
```

Déclarer l'Application dans `rhbk-platform/argocd/kustomization.yaml` (sous `resources:`), **à la
place** de `applications/tracing.yaml` :

```yaml
  - applications/tempo-operator.yaml
  - applications/otel-operator.yaml
  - applications/tracing-pv.yaml
```

AppProject : mêmes entrées que l'option A (namespaces `openshift-tempo-operator`,
`openshift-opentelemetry-operator`, `rhbk-tracing` ; `ClusterRole`, `ClusterRoleBinding`, `UIPlugin`).
Commit, push, puis :

```bash
oc patch application tempo-operator -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
oc patch application otel-operator -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
oc patch application tracing-pv -n openshift-gitops --type merge -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"main"}}}'
```

**Passer de l'option A à l'option B sur un cluster déjà en place** (les traces stockées dans le
bucket sont perdues) :

1. dans `argocd/kustomization.yaml`, remplacer `applications/tracing.yaml` par
   `applications/tracing-pv.yaml` ; commit, push. `platform-root` retire l'Application `tracing`
   sans supprimer ses ressources (pas de finalizer) ;
2. supprimer le TempoStack (l'API refuse sinon le TempoMonolithic du même nom) :
```bash
oc delete tempostack tempo -n rhbk-tracing
```

3. synchroniser `tracing-pv` : elle reprend le namespace, le Collector et les droits, et crée le
   TempoMonolithic. Les traces sont de nouveau reçues une fois le pod `tempo-tempo-0` prêt ;
4. facultatif : retirer le bucket de l'option A et la conversion de ses identifiants (fichiers
   `bucket.yaml` et `tempo-s3-secret.yaml`) :
```bash
oc delete externalsecret tempo-s3 -n rhbk-tracing && oc delete secretstore local-secrets -n rhbk-tracing && oc delete rolebinding,role,serviceaccount eso-local-secret-reader -n rhbk-tracing
```

```bash
oc delete objectbucketclaim tempo-bucket -n rhbk-tracing
```


### 4.4 Keycloak : traçage, en deux commits

**Commit 1, options seules** (ignorées tant que l'image n'a pas le traçage) : dans
`base/keycloak/keycloak.yaml`, juste après le bloc `ingress:` (`enabled: false`) :

```yaml
  # [Observability part 4 - traces] OpenTelemetry traces sent to the collector of the platform
  # (namespace rhbk-tracing).
  # tracing.enabled is a BUILD-time option: it is set together with the image built with
  # KC_TRACING_ENABLED=true (custom-rhbk/Containerfile). samplerRatio: share of traced requests.
  tracing:
    endpoint: http://otel-collector.rhbk-tracing.svc.cluster.local:4317
    samplerRatio: 1
```

et, pour la prod (10 % des requêtes tracées, tirées au sort par Keycloak : section 15.10 du
guide), à la fin de `overlays/prod/patch-keycloak.yaml` :

```yaml
- op: replace
  path: /spec/tracing/samplerRatio
  value: 0.1
```

**Commit 2, image** : dans `custom-rhbk/Containerfile`, après les autres lignes `ENV`
(juste avant la ligne vide qui précède `WORKDIR`) :

```dockerfile
# [Observability part 4 - traces] OpenTelemetry tracing: build-time option. Endpoint and sampler
# ratio are runtime options (spec.tracing in the Keycloak CR).
ENV KC_TRACING_ENABLED=true
```

Rebuild, push, nouveau digest (section 0.3), et dans le même commit, dans le CR, juste sous
la ligne `tracing:` :

```yaml
    enabled: true          # build-time: matches the image (KC_TRACING_ENABLED)
```


En prod, ce commit provoque un recreate (coupure d'environ 1 minute).

### 4.5 Vérifier

Option A :

```bash
oc get tempostack tempo -n rhbk-tracing && oc get opentelemetrycollector otel -n rhbk-tracing
```

Option B (pod `tempo-tempo-0` à 3/3, PVC `Bound`) :

```bash
oc get tempomonolithic tempo -n rhbk-tracing && oc get pods,pvc -n rhbk-tracing
```

```bash
oc get uiplugin distributed-tracing
```

Dans les logs de Keycloak, l'avertissement « UNAVAILABLE » sur `tracing-*` disparaît avec la
nouvelle image. Console : **Observe → Traces**, instance `rhbk-tracing / tempo`, tenant
`rhbk`, requête `{resource.service.name="rhbk-dev"}` (autres requêtes : section 15.10 du
guide).

### 4.6 Générer et montrer des traces

Démonstration de bout en bout, une fois Keycloak sur l'image avec le traçage (commit 2 de
l'étape 4.4). Utiliser **dev** : 100 % de ses requêtes sont tracées, contre 10 % en prod.

**1. Générer du trafic.** Le plus parlant est une vraie connexion à la console d'administration,
`https://dev-rhbk-admin.<domaine>/admin/`. Compléter par quelques appels :

```bash
for i in 1 2 3 4 5; do curl -s -o /dev/null https://dev-rhbk.apps.cluster-nnljw.nnljw.sandbox742.opentlc.com/realms/master/.well-known/openid-configuration; done
```

**2. Afficher les traces.** Console, **Observe → Traces** : instance `rhbk-tracing / tempo`,
tenant `rhbk`, période `Last 15 minutes`. Requêtes, de la plus large à la plus précise :

| Requête | Ce qu'elle montre |
|---|---|
| `{resource.service.name="rhbk-dev"}` | toutes les traces de dev, y compris les tâches de fond (`DefaultKeycloakTransactionManager.commit`, `SELECT rhbk.JGROUPS_PING`…) |
| `{resource.service.name="rhbk-dev" && span.http.request.method="GET"}` | uniquement les requêtes HTTP (`GET /realms/{realm}/…`, `GET /admin/…`) |
| `{resource.service.name="rhbk-dev" && span.http.route=~"/realms/.*"}` | les requêtes sur les realms (applications, connexions) |
| `{resource.service.name="rhbk-dev" && span.db.system="postgresql"}` | les traces qui touchent la base |
| `{resource.service.name="rhbk-dev" && duration > 100ms}` | les requêtes lentes |
| `{resource.service.name="rhbk-dev" && span.kc.realmName="master"}` | les traces d'un realm (attributs Keycloak `kc.realmName`, `kc.clientId`…) |
| `{resource.service.name="rhbk-prod"}` | la prod (moins de traces : échantillonnage à 10 %) |

**3. Montrer le bout en bout.** Ouvrir une trace de requête HTTP, de préférence celle de la
connexion (`POST …/login-actions/authenticate`). La vue en cascade montre :

1. le **span HTTP** : méthode, route, code de retour, durée totale ;
2. les **spans internes de Keycloak** : authentification, transaction, sessions ;
3. les **spans SQL** : chaque requête vers PostgreSQL (`db.statement`) et sa durée.

Chaque span porte les attributs ajoutés par le Collector (`k8s.namespace.name`,
`k8s.pod.name`) : on voit quel pod a traité la requête, utile en prod avec 2 replicas.

**4. Lien avec les logs** (si la partie 3 est en place). Les logs écrits par Keycloak pendant une
requête tracée contiennent l'identifiant de la trace (`mdc.traceId` dans le JSON). Copier
l'identifiant d'une trace, puis dans **Observe → Logs** :

```
{kubernetes_namespace_name="rhbk-dev", kubernetes_container_name="keycloak"} |= "<traceId>"
```

Seules les requêtes pendant lesquelles Keycloak écrit un log (avertissement, erreur, connexion
refusée…) ont des lignes correspondantes.

**Valider sans la console** (même source que la console ; jeton de l'utilisateur, non affiché) :

```bash
oc port-forward -n rhbk-tracing svc/tempo-tempo-gateway 18082:8080 &
```

```bash
curl -sk -G -H "Authorization: Bearer $(oc whoami -t)" "https://localhost:18082/api/traces/v1/rhbk/tempo/api/search" --data-urlencode 'q={resource.service.name="rhbk-dev"}' --data-urlencode "start=$(( $(date +%s) - 900 ))" --data-urlencode "end=$(date +%s)" | python3 -c 'import json,sys;[print(t["traceID"],t.get("rootTraceName")) for t in json.load(sys.stdin).get("traces",[])]'
```

```bash
kill %1
```

Une ligne par trace des 15 dernières minutes : identifiant et nom de la requête racine.

### 4.7 Si on s'arrête ici

Les 4 parties sont en place.

---

## Exemple : ne déployer que les parties 1 et 2

| Étape | Faire | Ne pas faire |
|---|---|---|
| Plateforme | 1.2 (`platform-monitoring`), 2.3 (`grafana-operator`, `grafana`), 2.4 (`coo-operator`, `observability-console`) | 3.2, 3.3, 4.2, 4.3 (A ou B) |
| Containerfile | lignes `[Observability part 2]` (2.2), en plus des lignes `[Observability part 1]` du socle | pas de `KC_TRACING_ENABLED` (partie 4) |
| CR Keycloak | `metrics-enabled`, `prometheusrule.yaml` (1.3) ; `features`, `http-metrics-histograms-enabled` (2.2) | pas de bloc `tracing` (partie 4), pas de `log-console-output` (partie 3) |
| Overlay prod | — | pas de patch `samplerRatio` (partie 4) |
| AppProject et `argocd/kustomization.yaml` | entrées des parties 1 et 2 | entrées des parties 3 et 4 |

Les parties 3 et 4 pourront être ajoutées plus tard, dans n'importe quel ordre, sans toucher
aux parties 1 et 2.
