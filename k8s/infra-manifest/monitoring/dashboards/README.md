# Vendored Grafana dashboards

Dashboard JSON for the infra components. Committed here rather than fetched by
`gnetId` at runtime so that what is reviewed is what runs, and Grafana's startup
does not depend on grafana.com being reachable.

`dashboards-cm/` holds the generated ConfigMaps — that is what ArgoCD syncs (app
`k8s/argocd/infra-apps/dashboards.yaml`). **Edit the JSON here, then regenerate.**

## Sources

| File | Source | Notes |
|---|---|---|
| `traefik.json` | grafana.com **17346** | Needs `metrics.prometheus.addRoutersLabels: true` (set in traefik values) |
| `cloudnative-pg.json` | grafana.com **20417** | Per-database panels stay empty until a project creates a CNPG cluster |
| `cert-manager.json` | grafana.com **11001** | Certificate expiry countdown |
| `velero.json` | grafana.com **11055** | Backup success/failure/duration |
| `external-secrets.json` | [external-secrets repo][eso] | |
| `minio.json` | [minio repo][minio] | Scraped via `minio/servicemonitor.yaml`, not the chart |
| `thanos-query.json` / `-store` / `-compact` | [thanos repo][thanos] | |
| `loki.json` | [loki repo][loki] | |
| `namespace-usage.json` | hand-written | Shipped via `governance/`, not here |

[eso]: https://github.com/external-secrets/external-secrets/blob/main/docs/snippets/dashboard.json
[minio]: https://github.com/minio/minio/blob/master/docs/metrics/prometheus/grafana/minio-dashboard.json
[thanos]: https://github.com/thanos-io/thanos/tree/main/examples/dashboards
[loki]: https://github.com/grafana/loki/tree/main/production/loki-mixin-compiled/dashboards

## Regenerating the ConfigMaps

After adding or editing any JSON in this directory:

```bash
cd k8s/infra-manifest/monitoring
python3 - <<'PY'
import json, glob, os, yaml
os.chdir('dashboards'); out='../dashboards-cm'
class L(str): pass
yaml.add_representer(L, lambda d, s: d.represent_scalar('tag:yaml.org,2002:str', s, style='|'))
for p in sorted(glob.glob('*.json')):
    if p == 'namespace-usage.json': continue      # shipped via governance/
    name = p[:-5]
    cm = {'apiVersion':'v1','kind':'ConfigMap',
          'metadata':{'name':f'dashboard-{name}','namespace':'monitoring',
                      'labels':{'grafana_dashboard':'1'}},
          'data':{p: L(open(p).read())}}
    open(os.path.join(out, name+'.yaml'),'w').write(
        yaml.dump(cm, default_flow_style=False, width=10**6, sort_keys=False, allow_unicode=True))
    print(name)
PY
```

Commit **both** the JSON and the regenerated `dashboards-cm/*.yaml`.

## Adding a new dashboard

1. Download the JSON (`https://grafana.com/api/dashboards/<id>/revisions/latest/download`)
   or take it from the project's own repo — upstream repos are usually more
   current than grafana.com, and the IDs are easy to misremember.
2. **Strip `__inputs` / `__requires`.** They are import-wizard metadata; the
   sidecar does not run the wizard, so any `${DS_*}` they define stays literal and
   the dashboard renders empty.
3. **Point datasource template variables at the real datasource names**
   (`Prometheus`, `Loki`, `Thanos` — see `kube-prometheus-stack-values.yaml`) by
   setting each variable's `current`, so it renders without touching the picker.
4. **Check the metrics actually exist** before trusting the dashboard — a panel
   querying a metric nothing exports is silently empty, not an error:
   ```bash
   kubectl -n monitoring port-forward svc/kps-kube-prometheus-stack-prometheus 9099:9090 &
   curl -s 'http://localhost:9099/api/v1/label/__name__/values' | grep -o '"<metric_prefix>[^"]*"' | head
   ```
5. Regenerate the ConfigMaps and commit.
