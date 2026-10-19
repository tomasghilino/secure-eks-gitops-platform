# Staging moves to RDS: passwords that never touch Git, the Terraform state or the logs

Short version: the API now uses an RDS PostgreSQL 17 database, reached over verified TLS. It logs in as its own `api` role, which can't administer anything. Terraform generates both passwords during the apply without ever storing them. Secrets Manager holds them, and External Secrets (with its own Pod Identity role) copies them into the namespace. Checking the result turned up one real leak: `pg_stat_statements` kept the `ALTER ROLE ... PASSWORD` text. I fixed it with a parameter group and proved the fix.

## How the password travels

```text
terraform apply
  ephemeral random_password (admin, api)  -- never written to the state
     ├─> aws_db_instance.password_wo                    (write-only)
     └─> secrets manager segp-staging/database/{admin,api}   (secret_string_wo, write-only)
external secrets (pod identity, can read only those two secrets)
     └─> Secret db-admin, Secret db-credentials in namespace staging
api chart
     ├─ api-database-setup job (admin): CREATE ROLE api, password from the env, grants on schema public only
     ├─ api-migrate job (api): creates the tables, so they belong to api
     └─ api pods (api): PGSSLMODE=verify-full, NODE_EXTRA_CA_CERTS = rds us-east-1 CA bundle
```

## Applied and checked

```text
terraform plan: 14 to add (database subnets, subnet group, security group, rds, 2 log groups,
                2 secrets + versions, external secrets role, policy, pod identity association)
aws_db_instance.main: Creation complete after 7m45s
Checkov 249 passed, 0 failed, 30 skipped (each with a reason) · TFLint 0 · Semgrep 0 · Gitleaks no leaks

$ terraform state pull   (only shows whether a field is set)
aws_db_instance main            password: null · password_wo: null
secret_version database_admin   secret_string: empty · secret_string_wo: null
secret_version database_api     secret_string: empty · secret_string_wo: null
random_password resources in state: none
```

## In the cluster

```text
external-secrets app      Synced/Healthy, namespace enforces Pod Security "restricted"
                          image v2.12.0 pinned by digest, cosign identity release.yml@refs/heads/main (ci.yml rejected)
secretstore aws-secrets-manager   Ready True
externalsecret db-admin / db-credentials   Ready True, keys PGDATABASE PGHOST PGPASSWORD PGPORT PGUSER
configmap rds-ca          3 certificates (us-east-1 RSA2048, RSA4096, ECC384)
api-database-setup        Completed (prints nothing: --quiet, no echo)
api-migrate               Migrations complete! (as api, against rds)
api                       health/ready 200 · POST 201 · GET returns the 1 user of the fresh database
```

## Inside the database

```text
connection   usename api · ssl t · TLSv1.3
role         segp_admin: rds_superuser, createrole, createdb
role         api: superuser f · createrole f · createdb f · rds_superuser f
tables       pgmigrations owner api · users owner api
log_statement none
```

## Finding: pg_stat_statements kept the password

RDS preloads `pg_stat_statements` with `track_utility = on`, so it tracks utility commands like `ALTER ROLE`:

```text
2 statements about role api
ALTER ROLE api WITH LOGIN PASSWORD '<redacted by this check>'   [contains a quoted password: true]
```

Anyone who may read other users' query statistics could read it: the admin, but also a monitoring login with `pg_read_all_stats`, such as a Postgres exporter. Fix:

```text
+ aws_db_parameter_group.main   pg_stat_statements.track_utility = 0, rds.force_ssl = 1
~ aws_db_instance.main          parameter_group_name default.postgres17 -> segp-staging   (reboot)
pg_stat_statements_reset()      what was already stored is gone
SHOW pg_stat_statements.track_utility   off
forced re-sync of the api (setup job ran ALTER ROLE again)
0 stored statements about role api · 0 stored statements with a quoted password
```

## TLS is enforced and verified

```text
PGSSLMODE=disable                 FATAL: no pg_hba.conf entry ... no encryption
verify-full + rds ca              connected over TLSv1.3
verify-full + generic public cas  SSL error: certificate verify failed
```

The database sits at 10.20.2.x, inside the database subnets, which are the only addresses the api's network policy allows on 5432.

## Cleanup

The in-cluster Postgres from kind days (StatefulSet, Service, NetworkPolicy, PVC) was orphaned when its Argo CD app left the staging root. I deleted it and waited until its EBS volume was gone, because an orphaned volume keeps billing.
