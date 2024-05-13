resource "kubernetes_namespace_v1" "cluster_autoscaler" {
  metadata {
    name = "cluster-autoscaler"
  }
  depends_on = [module.eks]
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.37.0"
  namespace  = kubernetes_namespace_v1.cluster_autoscaler.metadata[0].name

  values = [
    templatefile("${path.module}/cluster_autoscaler.yaml", {
      cluster_name = local.name
      region       = local.region
      sa_name      = "cluster-autoscaler"
      role_arn     = module.aws_cluster_autoscaler_irsa.iam_role_arn
    })
  ]

  depends_on = [
    module.eks,
    module.aws_cluster_autoscaler_irsa,
  ]
}
module "aws_cluster_autoscaler_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.0"

  role_name_prefix                 = "cluster-autoscaler"
  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [local.name]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["cluster-autoscaler:cluster-autoscaler"]
    }
  }
}
