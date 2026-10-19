# Tearing an environment down, and checking nothing is left

Short version: `scripts/eks-down.sh` removes a whole environment in about ten minutes. It deletes what Kubernetes created in AWS behind Terraform's back before Terraform destroys the rest, then checks that nothing billable is left. This is the staging teardown after the External Secrets demo, plus the control plane log measurement that decided how much logging staging keeps.

## What the control plane logs cost

```text
10-minute buckets: 18.2, 17.1, 17.0, 16.9, 17.0 MB  ->  ~100 MB/h, ~0.05 USD/h at 0.50 USD per GB ingested
```

That's about 15% of what staging costs per hour (~0.32 USD/h with RDS), almost all of it the audit log.

## The teardown

```text
$ AUTO_APPROVE=1 ./scripts/eks-down.sh
==> stop argo cd            (application controller scaled to 0, so it can't recreate what gets deleted)
==> load balancers          none
==> volumes                 namespace "monitoring" deleted (loki and tempo claims) -> 0 pvc volumes left
==> terraform
  aws_nat_gateway.main: Destruction complete after 1m1s
  aws_db_instance.main: Destruction complete after 1m52s
  aws_eks_node_group.main: Destruction complete after 4m32s
  aws_eks_cluster.main: Destruction complete after 2m49s
  Destroy complete! Resources: 53 destroyed.
==> leftovers
eks clusters 0 · nat gateways 0 · elastic ips 0 · pvc volumes 0 · load balancers 0
nothing left running   (exit 0)

independent checks: rds instances 0 · segp-staging secrets 0 · project vpcs 0 · ec2 running 0
                    ebs volumes 0 · eks and rds log groups 0 · kube context removed
```

The Secrets Manager secrets were deleted immediately (`recovery_window_in_days = 0`), so the next session can recreate them under the same names. The PVC volumes are the classic leftover: they are created by the EBS CSI driver, not by Terraform, which is why the script deletes their claims and waits for 0 volumes before destroying the cluster.
