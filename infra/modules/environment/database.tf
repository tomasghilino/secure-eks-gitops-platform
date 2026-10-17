locals {
  database_name = "segp"
  database_port = 5432
}

# the database gets its own small subnets, so network policies can allow exactly these addresses on its
# port; they keep the vpc's main route table, which has no route to the internet
resource "aws_subnet" "database" {
  count = length(var.zone_ids)

  vpc_id               = aws_vpc.main.id
  availability_zone_id = var.zone_ids[count.index]
  cidr_block           = cidrsubnet(var.vpc_cidr, 8, count.index + 2)

  tags = { Name = "${var.name}-database-${var.zone_ids[count.index]}" }
}

resource "aws_db_subnet_group" "main" {
  name       = var.name
  subnet_ids = aws_subnet.database[*].id
}

# only the cluster's nodes, and so its pods, reach postgres; which pods may is up to network policies
resource "aws_security_group" "database" {
  name        = "${var.name}-database"
  description = "postgres for the ${var.name} cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "postgres from the cluster nodes"
    from_port       = local.database_port
    to_port         = local.database_port
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }
}

# ephemeral: generated during the apply and never written to the terraform state
ephemeral "random_password" "database_admin" {
  length  = 32
  special = false
}

ephemeral "random_password" "database_api" {
  length  = 32
  special = false
}

# created by terraform so they are deleted with the environment instead of piling up
resource "aws_cloudwatch_log_group" "database" { # nosemgrep: terraform.aws.security.aws-cloudwatch-log-group-unencrypted.aws-cloudwatch-log-group-unencrypted
  #checkov:skip=CKV_AWS_338:the environment lives for one working session, a year of retention would outlive it
  #checkov:skip=CKV_AWS_158:encrypted with the cloudwatch default key; a customer key would not change who can read
  for_each = toset(["postgresql", "upgrade"])

  name              = "/aws/rds/instance/${var.name}/${each.key}"
  retention_in_days = 7
}

# rds loads pg_stat_statements with track_utility on, so it kept the text of ALTER ROLE ... PASSWORD,
# password included, for anyone allowed to read query statistics
resource "aws_db_parameter_group" "main" {
  name   = var.name
  family = "postgres17"

  parameter {
    name  = "pg_stat_statements.track_utility"
    value = "0"
  }

  # already the default since postgres 15 on rds, stated so a changed default can't open plain connections;
  # rds reports it as pending-reboot, and any other apply_method shows up as a change in every plan
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_db_instance" "main" {
  #checkov:skip=CKV_AWS_157:one zone is enough for staging; a standby doubles the cost
  #checkov:skip=CKV_AWS_293:the environment is destroyed at the end of every session
  #checkov:skip=CKV_AWS_118:basic cloudwatch metrics are enough; enhanced monitoring needs one more role
  #checkov:skip=CKV_AWS_354:performance insights data is encrypted with the aws managed rds key
  #checkov:skip=CKV2_AWS_30:statement logging would write the password of every ALTER ROLE to the logs
  identifier     = var.name
  engine         = "postgres"
  engine_version = "17"
  instance_class = "db.t4g.micro"

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name             = local.database_name
  username            = "segp_admin"
  password_wo         = ephemeral.random_password.database_admin.result
  password_wo_version = 1

  parameter_group_name   = aws_db_parameter_group.main.name
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false
  multi_az               = false

  iam_database_authentication_enabled   = true
  auto_minor_version_upgrade            = true
  backup_retention_period               = 1
  copy_tags_to_snapshot                 = true
  deletion_protection                   = false
  skip_final_snapshot                   = true
  apply_immediately                     = true
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  depends_on = [aws_cloudwatch_log_group.database]
}

# fixed names, so the cluster finds them in every session; deleted at once because the next session
# recreates them under the same name
resource "aws_secretsmanager_secret" "database" { # nosemgrep: terraform.aws.security.aws-secretsmanager-secret-unencrypted.aws-secretsmanager-secret-unencrypted
  #checkov:skip=CKV_AWS_149:encrypted with the aws managed secrets manager key; a customer key would not change who can read
  #checkov:skip=CKV2_AWS_57:new passwords are generated with every environment, which lives for one session
  for_each = toset(["admin", "api"])

  name                    = "${var.name}/database/${each.key}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "database_admin" {
  secret_id = aws_secretsmanager_secret.database["admin"].id
  secret_string_wo = jsonencode({
    PGHOST     = aws_db_instance.main.address
    PGPORT     = tostring(local.database_port)
    PGDATABASE = local.database_name
    PGUSER     = aws_db_instance.main.username
    PGPASSWORD = ephemeral.random_password.database_admin.result
  })
  secret_string_wo_version = 1
}

# the api's own login, created in postgres by the api chart's setup job; it never uses the admin
resource "aws_secretsmanager_secret_version" "database_api" {
  secret_id = aws_secretsmanager_secret.database["api"].id
  secret_string_wo = jsonencode({
    PGHOST     = aws_db_instance.main.address
    PGPORT     = tostring(local.database_port)
    PGDATABASE = local.database_name
    PGUSER     = "api"
    PGPASSWORD = ephemeral.random_password.database_api.result
  })
  secret_string_wo_version = 1
}

# external secrets reads this environment's secrets and nothing else
data "aws_iam_policy_document" "external_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [for s in aws_secretsmanager_secret.database : s.arn]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-database-secrets"
  role   = aws_iam_role.pod["external-secrets"].id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = local.pod_roles["external-secrets"].namespace
  service_account = local.pod_roles["external-secrets"].service_account
  role_arn        = aws_iam_role.pod["external-secrets"].arn
}
