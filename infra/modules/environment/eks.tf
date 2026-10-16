locals {
  # the versions eks marks as default for 1.35, pinned so every session builds the same cluster
  addon_versions = {
    coredns            = "v1.13.2-eksbuild.50"
    kube_proxy         = "v1.35.3-eksbuild.29"
    vpc_cni            = "v1.22.4-eksbuild.3"
    pod_identity_agent = "v1.3.10-eksbuild.3"
    ebs_csi_driver     = "v1.67.0-eksbuild.1"
  }

  # add-ons that call aws get their own role through pod identity instead of borrowing the node's
  pod_roles = {
    vpc-cni = {
      namespace       = "kube-system"
      service_account = "aws-node"
      policy_arn      = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    }
    ebs-csi = {
      namespace       = "kube-system"
      service_account = "ebs-csi-controller-sa"
      policy_arn      = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    }
  }
}

data "aws_iam_policy_document" "cluster_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_trust.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

data "aws_iam_policy_document" "cluster_secrets" {
  statement {
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey", "kms:ListGrants"]
    resources = [var.cluster_secrets_key_arn]
  }
}

resource "aws_iam_role_policy" "cluster_secrets" {
  name   = "encrypt-secrets"
  role   = aws_iam_role.cluster.id
  policy = data.aws_iam_policy_document.cluster_secrets.json
}

# managed here so it is deleted with the environment instead of piling up
resource "aws_cloudwatch_log_group" "cluster" { # nosemgrep: terraform.aws.security.aws-cloudwatch-log-group-unencrypted.aws-cloudwatch-log-group-unencrypted
  #checkov:skip=CKV_AWS_338:the environment lives for one working session, a year of retention would outlive it
  #checkov:skip=CKV_AWS_158:encrypted with the cloudwatch default key; a customer key would not change who can read
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = 7
}

resource "aws_eks_cluster" "main" { # nosemgrep: terraform.lang.security.eks-public-endpoint-enabled.eks-public-endpoint-enabled
  #checkov:skip=CKV_AWS_39:the public endpoint only accepts admin_cidr; a private-only endpoint needs a vpn or bastion
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  # the core add-ons are installed below as managed add-ons, pinned and with their own roles
  bootstrap_self_managed_addons = false

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # access entries only: who can use the cluster is managed in aws, not in the aws-auth configmap
  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = [var.admin_cidr]
  }

  encryption_config {
    resources = ["secrets"]

    provider {
      key_arn = var.cluster_secrets_key_arn
    }
  }

  # when standard support ends eks upgrades the cluster instead of billing extended support at 0.60 usd/h
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [
    aws_cloudwatch_log_group.cluster,
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy.cluster_secrets,
  ]
}

resource "aws_eks_access_entry" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = var.admin_role_arn
}

resource "aws_eks_access_policy_association" "admin" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_eks_access_entry.admin.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

data "aws_iam_policy_document" "pod_trust" {
  for_each = local.pod_roles

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # pod identity tags every session, so only this service account in this cluster can use the role
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-name"
      values   = [var.name]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [each.value.namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.value.service_account]
    }
  }
}

resource "aws_iam_role" "pod" {
  for_each = local.pod_roles

  name               = "${var.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_trust[each.key].json
}

resource "aws_iam_role_policy_attachment" "pod" {
  for_each = local.pod_roles

  role       = aws_iam_role.pod[each.key].name
  policy_arn = each.value.policy_arn
}

# networking add-ons go in before the nodes, or the nodes never become ready
resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = local.addon_versions.pod_identity_agent
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "vpc-cni"
  addon_version = local.addon_versions.vpc_cni

  # without this the cni accepts networkpolicy objects and silently enforces none of them
  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  pod_identity_association {
    role_arn        = aws_iam_role.pod["vpc-cni"].arn
    service_account = local.pod_roles["vpc-cni"].service_account
  }

  depends_on = [aws_eks_addon.pod_identity_agent, aws_iam_role_policy_attachment.pod]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "kube-proxy"
  addon_version = local.addon_versions.kube_proxy
}

data "aws_iam_policy_document" "node_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# only what the kubelet needs: join the cluster and pull images
resource "aws_iam_role" "node" {
  name               = "${var.name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_trust.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_launch_template" "node" {
  name_prefix            = "${var.name}-node-"
  update_default_version = true

  # hop limit 1: pods without host networking can't reach the node's metadata service and its credentials
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-node" }
  }
}

# no ssh key and no public ips: nodes are reached through kubectl, never logged into
resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.name}-${lower(var.node_capacity_type)}"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.private[*].id
  ami_type        = "AL2023_x86_64_STANDARD"
  capacity_type   = var.node_capacity_type
  instance_types  = var.node_instance_types

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.vpc_cni,
    aws_eks_addon.kube_proxy,
  ]
}

resource "aws_eks_addon" "coredns" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "coredns"
  addon_version = local.addon_versions.coredns

  depends_on = [aws_eks_node_group.main]
}

# volumes for prometheus and loki; it also creates a default storage class
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = local.addon_versions.ebs_csi_driver

  configuration_values = jsonencode({
    defaultStorageClass = { enabled = true }
  })

  pod_identity_association {
    role_arn        = aws_iam_role.pod["ebs-csi"].arn
    service_account = local.pod_roles["ebs-csi"].service_account
  }

  depends_on = [aws_eks_node_group.main, aws_iam_role_policy_attachment.pod]
}
