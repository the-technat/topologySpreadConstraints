locals {
  name           = "spread"
  region         = "eu-west-1"
  eks_version    = "1.28"
  vpc_cidr       = "10.123.0.0/16"
  service_cidr   = "172.20.0.0/16"
  azs            = slice(data.aws_availability_zones.available.names, 0, 3)
  instance_types = ["t3a.medium", "t3.medium", "t2.medium"] # must be AMD64 
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
  cidr               = local.vpc_cidr
  azs                = local.azs
  public_subnets     = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets    = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 10)]
  enable_nat_gateway = true
  single_nat_gateway = true
}
module "eks" {
  source                         = "terraform-aws-modules/eks/aws"
  version                        = "~> 20.0"
  cluster_name                   = local.name
  cluster_version                = local.eks_version
  cluster_endpoint_public_access = true
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }
  cluster_service_ipv4_cidr                = local.service_cidr
  vpc_id                                   = module.vpc.vpc_id
  control_plane_subnet_ids                 = module.vpc.private_subnets
  cloudwatch_log_group_retention_in_days   = 1
  attach_cluster_encryption_policy         = false # KMS only causes problems when destroyed regurarly
  create_kms_key                           = false # KMS only causes problems when destroyed regurarly
  cluster_encryption_config                = {}    # KMS only causes problems when destroyed regurarly
  enable_cluster_creator_admin_permissions = true
  access_entries                           = {}
  eks_managed_node_group_defaults = {
    capacity_type = "SPOT"
    ami_type      = "AL2_x86_64"
    ami_id        = data.aws_ami.eks_default.image_id
    desired_size  = 1
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
