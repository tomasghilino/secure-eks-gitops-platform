# Alerts with unit tests, and a drill that followed one from start to finish

Short version: the API has three alerts. They live in its Helm chart, and their unit tests run in CI. To prove they work, I took the staging database down. Both critical alerts fired, I followed the alert to the error logs and from there to a trace that showed the cause, and the alerts cleared on their own once Argo CD restored the database.

This drill ran on the kind version of the platform, where staging still had its own Postgres StatefulSet and a single bootstrap file. On EKS the database is RDS, and the alerts are the same.

## The rules

| Alert | Fires when | For | Severity |
|---|---|---|---|
| ApiHighErrorRate | more than 5% of requests return 5xx | 5 min | critical |
| ApiHighLatency | p95 latency above 0.5 s | 10 min | warning |
| ApiUnavailable | the Deployment has no available pods | 2 min | critical |

Each rule is scoped to its own namespace, so staging and production never alert for each other.

## Tests that can fail

`tests/alerts/api.test.yaml` feeds synthetic series to `promtool`:
- 10% errors fires, 1% doesn't;
- errors in another namespace are ignored;
- requests near one second trip the latency alert;
- zero ready pods fires after two minutes.

CI renders the rules from the chart and runs the tests with the same Prometheus image the cluster uses.

```text
$ promtool test rules tests/alerts/api.test.yaml
  SUCCESS

# after changing the threshold from 0.05 to 0.5:
  FAILED:
    name: one request in ten fails,
    alertname: ApiHighErrorRate, time: 10m,
        exp: [ {alertname="ApiHighErrorRate", namespace="staging", severity="critical"} ]
        got: []
exit=1
```

## The drill

With steady test traffic running, I paused Argo CD auto-sync for `root` and `postgres-staging`, because self-heal would otherwise undo the break within seconds. Then I scaled Postgres to zero:

```text
22:11:47  kubectl scale statefulset postgres -n staging --replicas=0
22:12:20  ApiUnavailable pending      (readiness fails without the database)
22:14:20  ApiUnavailable firing
22:18:50  ApiHighErrorRate firing     90.6% of requests returned a 5xx error over the last 5 minutes.
          ApiHighLatency pending      95% of requests took up to 7.362s over the last 5 minutes.
```

Alertmanager received both critical alerts. From there, the error logs in Loki:

```text
{"level":"error","message":{"method":"POST","path":"/users","status":500,"durationMs":5001,"traceId":"19fe9a10f48c3c74172bdff44f153159"},"context":"HTTP"}
{"level":"error","message":"Error: Connection terminated due to connection timeout\n    at /app/node_modules/pg-pool/index.js:45:11 ..."}
```

Then that trace in Tempo:

```text
POST /users                 5001 ms  status=ERROR  500
request handler - /users    5001 ms
pg-pool.connect             5000 ms  status=ERROR  Connection terminated due to connection timeout
pg.connect                  5000 ms  status=ERROR  Connection terminated unexpectedly
```

The request spent its whole five seconds trying to reach Postgres, and `kubectl get statefulset postgres -n staging` showed `0/0`. To fix it I re-applied `argocd/bootstrap.yaml`, which turned auto-sync back on, and Argo CD put the replica count back to what Git says:

```text
22:20:12  kubectl apply -f argocd/bootstrap.yaml
22:20:20  api pod Ready again
22:24:33  all API alerts resolved, 5xx share back to 0
```

The error-rate alert takes a few minutes to clear because it looks at a five-minute window.
