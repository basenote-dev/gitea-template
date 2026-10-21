################################################################################
# Cluster Access
################################################################################

output "kubeconfig_command" {
  description = "Adds the cluster to ~/.kube/config as platform-eks-admin (run it from an admin session in this account)"
  value       = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_name} --role-arn ${data.aws_iam_role.this["platform-eks-admin"].arn}"
}

################################################################################
# Helmfile
################################################################################

output "helmfile_values" {
  description = "Everything Helmfile needs from AWS (helmfile/values/tofu-outputs.yaml.gotmpl reads it with terragrunt output). Names, endpoints and ARNs only, no secret values"
  value = {
    region       = local.region
    cluster_name = module.eks.cluster_name

    allowed_cidrs = local.allowed_cidrs
    vpc_id        = module.vpc.vpc_id

    # Data stores
    rds_endpoint      = module.rds.db_instance_endpoint # host:port
    valkey_endpoint   = "${aws_elasticache_replication_group.valkey.primary_endpoint_address}:${aws_elasticache_replication_group.valkey.port}"
    efs_volume_handle = "${module.efs.id}::${module.efs.access_points["gitea"].id}" # EFS CSI form: <fs>::<access point>

    # Secrets Manager names External Secrets reads (db, valkey, admin, metrics)
    secret_names         = { for k, s in data.aws_secretsmanager_secret.this : k => s.name }
    gitea_admin_username = local.gitea_admin_username

    # The tagged Auto Mode NodeClass (helmfile/charts/node-pools)
    node_iam_role_name     = module.eks.node_iam_role_name
    node_subnet_ids        = module.vpc.private_subnets
    node_security_group_id = module.eks.cluster_primary_security_group_id
    resource_tags          = local.tags

    # Gitea version to deploy (main.tf locals); the chart adds "-rootless"
    gitea_image_tag = local.gitea_version
  }
}
