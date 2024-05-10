locals {
  name        = "spread"
  region      = "eu-west-1"
  eks_version = "1.28"
  cidr        = "10.10.0.0/16"
  azs         = slice(data.aws_availability_zones.available.names, 0, 3)
}
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}
provider "aws" {
  region = local.region
}
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--output", "json"]
  }
}
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--output", "json"]
    }
  }
}
data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}
data "aws_ami" "eks_default" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amazon-eks-node-${local.eks_version}-v*"]
  }
}
module "vpc" {
  source             = "terraform-aws-modules/vpc/aws"
  version            = "~> 5.0"
  name               = local.name
  cidr               = local.cidr
  azs                = local.azs
  public_subnets     = [for k, v in local.azs : cidrsubnet(local.cidr, 8, k)]
  private_subnets    = [for k, v in local.azs : cidrsubnet(local.cidr, 8, k + 10)]
  enable_nat_gateway = true
  single_nat_gateway = true
}
module "eks" {
  source                         = "terraform-aws-modules/eks/aws"
  version                        = "~> 20.0"
  cluster_name                   = local.name
  cluster_version                = local.eks_version
  cluster_endpoint_public_access = true
  cluster_addons                 = { coredns = { most_recent = true } }
  cluster_service_ipv4_cidr      = "10.127.0.0/16" # may be ignored since we use cilium's kube-proxy replacement
  vpc_id                         = module.vpc.vpc_id
  control_plane_subnet_ids       = module.vpc.private_subnets
  node_security_group_additional_rules = {
    ingress_self_all = { # cilium requires many ports to be open node-by-node
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }
  cloudwatch_log_group_retention_in_days   = 1
  attach_cluster_encryption_policy         = false # KMS only causes problems when destroyed regurarly
  create_kms_key                           = false # KMS only causes problems when destroyed regurarly
  cluster_encryption_config                = {}    # KMS only causes problems when destroyed regurarly
  enable_cluster_creator_admin_permissions = true
  access_entries                           = {}
  eks_managed_node_group_defaults = {
    capacity_type  = "SPOT"
    ami_type       = "AL2_x86_64"
    ami_id         = data.aws_ami.eks_default.image_id
    instance_types = ["t3a.medium", "t3.medium", "t2.medium"]
    desired_size   = 1
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
    }
    enable_bootstrap_user_data = true # required due to AMI ID explicitly set 
  }
  eks_managed_node_groups = {
    workers-a = {
      name       = "workers-a"
      subnet_ids = [module.vpc.private_subnets[0]]
    }
    workers-b = {
      name       = "workers-b"
      subnet_ids = [module.vpc.private_subnets[1]]
    }
    workers-c = {
      name       = "workers-c"
      subnet_ids = [module.vpc.private_subnets[2]]
    }
  }
}
resource "null_resource" "purge_aws_networking" {
  triggers = {
    eks = module.eks.cluster_endpoint # only do this when the cluster changes (e.g create/recreate)
  }
  provisioner "local-exec" { # this is required as the manifests are there even if you don't deploy the addon
    command = <<EOT
      aws eks --region ${local.region} update-kubeconfig --name ${local.name} --alias ${local.name}
      curl -LO https://dl.k8s.io/release/v${local.eks_version}.0/bin/linux/amd64/kubectl
      chmod 0755 ./kubectl
      ./kubectl -n kube-system delete daemonset kube-proxy --ignore-not-found
      ./kubectl -n kube-system delete daemonset aws-node --ignore-not-found
      rm ./kubectl
    EOT
  }
  depends_on = [module.eks.aws_eks_cluster]
}
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.isovalent.com"
  chart      = "cilium"
  version    = "1.15.4"
  namespace  = "kube-system"
  wait       = true
  timeout    = 3600
  values = [
    templatefile("${path.module}/cilium.yaml", {
      cluster_endpoint = trim(module.eks.cluster_endpoint, "https://") # used for kube-proxy replacement
      cluster_name     = local.name                                    # used for ENI tagging
    })
  ]
  depends_on = [
    null_resource.purge_aws_networking,
  ]
}
