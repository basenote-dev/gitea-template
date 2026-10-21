# aws

Plain OpenTofu for every AWS resource Gitea runs on. There is no Terragrunt here:
`bootstrap/gitea` adds the backend, provider and encryption, and runs Helmfile after it.

| Section in `main.tf` | What |
| --- | --- |
| VPC | /16 over 3 AZs: public, private (nodes and pods) and database subnets, one NAT gateway, flow logs |
| EKS | Auto Mode cluster `gitea`, Kubernetes 1.37, access entries only: `github-apply` and `platform-eks-admin` admin, `github-plan` view |
| EKS Add-ons | EFS CSI driver and CloudWatch Observability with Pod Identity roles, Container Insights log groups |
| External Secrets Pod Identity | Role for External Secrets Operator that can read only the five `gitea/*` secrets |
| Security Groups | PostgreSQL 5432, Valkey 6379, NFS 2049, each only from the cluster primary security group |
| RDS | PostgreSQL 17, `db.m7g.large`, single AZ, no deletion protection |
| ElastiCache Valkey | Valkey 8.2, one `cache.m7g.large` node, TLS and auth token |
| EFS | Elastic throughput, mount targets in the private subnets, access point uid/gid 1000 at `/gitea`, AWS Backup |
| Gitea Upgrade Snapshot | Manual RDS snapshot before each Gitea minor/major upgrade |

Every setting is a local in `main.tf`. Passwords never pass through OpenTofu state: bootstrap
creates the `gitea/*` secrets, and RDS and Valkey get theirs through write-only arguments.

Gitea is served over plain HTTP at the ALB's hostname and SSH at the NLB's. The apply prints
both.

`terragrunt output -raw kubeconfig_command` (from `bootstrap/gitea`) prints the
`aws eks update-kubeconfig` command; it assumes `platform-eks-admin`. `helmfile_values` is the
interface to Helmfile (`helmfile/values/tofu-outputs.yaml.gotmpl`).
