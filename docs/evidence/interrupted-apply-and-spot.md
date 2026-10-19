# An apply cut off by a dropped connection, and a spot interruption during bootstrap

Short version: my internet dropped in the middle of `./scripts/eks-up.sh staging`. Running it again blindly would have duplicated half of the environment. I worked out the state step by step, gave Terraform back the record it had saved locally, and the rerun created exactly the 18 missing resources. Ten minutes later, AWS reclaimed one of the spot nodes while the platform was starting, and EKS replaced it without any manual step.

## What was left

```text
s3 lock file       staging/terraform.tfstate.tflock   Operation: OperationTypeApply, Created 17:26:04Z
s3 state           0 resources
aws (tag Stack=staging)   vpc, 6 subnets, igw, eip, nat, route table, flow log, eks cluster, 6 iam roles,
                          2 secrets, launch template, log groups, rds subnet + parameter groups
running terraform  none (only terraform-ls, the editor's language server)
infra/staging/errored.tfstate   38 resources, 2 tainted: aws_eks_cluster.main, aws_nat_gateway.main
```

Terraform couldn't write the state to S3 when the connection dropped, so it wrote `errored.tfstate` locally. A blind rerun would have:

1. failed on the lock;
2. once unlocked, tried all 56 resources again: "already exists" on the named ones, and silent duplicates of the VPC, subnets, NAT and IP.

## Checks before touching anything

```text
every subnet, the vpc, route table, eip and igw in aws is in errored.tfstate   -> no orphans
eks cluster ACTIVE, nat gateway available                                       -> aws finished what terraform stopped watching
```

## Recovery

```text
terraform force-unlock <lock id>       (only after confirming no terraform process holds it)
terraform state push errored.tfstate   -> 51 entries in the s3 state (38 resources + data sources)
terraform untaint aws_eks_cluster.main / aws_nat_gateway.main   (otherwise the next apply destroys and recreates them)
terraform plan                         -> Plan: 18 to add, 0 to change, 0 to destroy
./scripts/eks-up.sh staging            -> Apply complete! Resources: 18 added, 0 changed, 0 destroyed.
```

`errored.tfstate` is gitignored (`*.tfstate`). After the push it was moved out of the repository.

## The spot interruption

```text
17:57:42  autoscaling launches 2 spot instances (the nodes eks-up waited for)
18:08:04  "an instance was launched in response to an EC2 instance rebalance recommendation"
18:08:10  "instance ... was taken out of service in response to an EC2 Spot Instance interruption notice"
          node ip-10-20-44-133 NotReady, then deleted; node ip-10-20-40-50 joined
after     0 pods not Running/Completed; loki-0 and tempo-0 moved to the new node (same zone) and re-attached their volumes
```

The bootstrap still ended with every Argo CD app Synced/Healthy. The interruption also showed why production runs on-demand, and why Kyverno now runs three replicas.
