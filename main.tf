locals {
  cluster_name = var.cluster_name
  region       = var.cluster_region
  eks_version  = var.eks_version

  vpc_cidr = "10.0.0.0/16"

  using_gpu = var.node_instance_type_gpu != null

  # fix ordering using toset
  available_azs_cpu = toset(data.aws_ec2_instance_type_offerings.availability_zones_cpu.locations)
  available_azs_gpu = toset(try(data.aws_ec2_instance_type_offerings.availability_zones_gpu[0].locations, []))

  available_azs = local.using_gpu ? tolist(setintersection(local.available_azs_cpu, local.available_azs_gpu)) : tolist(local.available_azs_cpu)

  az_count = min(length(local.available_azs), 3)
  azs      = slice(local.available_azs, 0, local.az_count)

  tags = {
    Platform        = "kubeflow-on-aws"
    KubeflowVersion = "1.7"
  }

  kf_helm_repo_path = var.kf_helm_repo_path


  managed_node_group_cpu = {
    node_group_name = "managed-ondemand-cpu"
    instance_types  = [var.node_instance_type]
    min_size        = 5
    desired_size    = 5
    max_size        = 10
    disk_size       = var.node_disk_size_cpu
    subnet_ids      = module.vpc.private_subnets
  }

  managed_node_group_gpu = local.using_gpu ? {
    node_group_name = "managed-ondemand-gpu"
    instance_types  = [var.node_instance_type_gpu]
    min_size        = 3
    desired_size    = 3
    max_size        = 5
    ami_type        = "AL2_x86_64_GPU"
    disk_size       = var.node_disk_size_gpu
    subnet_ids      = module.vpc.private_subnets
  } : null

  potential_managed_node_groups = {
    mg_cpu = local.managed_node_group_cpu,
    mg_gpu = local.managed_node_group_gpu
  }

  managed_node_groups = { for k, v in local.potential_managed_node_groups : k => v if v != null }
}

provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks_blueprints.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_blueprints.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks_blueprints.cluster_id]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks_blueprints.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_blueprints.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks_blueprints.cluster_id]
    }
  }
}

data "aws_ec2_instance_type_offerings" "availability_zones_cpu" {
  filter {
    name   = "instance-type"
    values = [var.node_instance_type]
  }

  location_type = "availability-zone"
}

data "aws_ec2_instance_type_offerings" "availability_zones_gpu" {
  count = local.using_gpu ? 1 : 0

  filter {
    name   = "instance-type"
    values = [var.node_instance_type_gpu]
  }

  location_type = "availability-zone"
}

#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------
module "eks_blueprints" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.cluster_name
  cluster_version = local.eks_version

  vpc_id             = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # configuration settings: https://github.com/aws-ia/terraform-aws-eks-blueprints/blob/main/modules/aws-eks-managed-node-groups/locals.tf
   eks_managed_node_groups = {
       instance-store = {
      instance_types = ["m5ad.large"]

      min_size     = 1
      max_size     = 3
      desired_size = 1
      ami_id = "ami-02fa5269c6a249fc6"

      block_device_mappings = {
        # Root volume
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 150
            volume_type           = "gp3"
            iops                  = 3000
            delete_on_termination = true
          }
        }
      }

  tags = local.tags
}
  tags                = local.tags
}
}

module "ebs_csi_driver_irsa" {
  source                = "../../../iaac/terraform/aws-infra/ebs-csi-driver-irsa"
  cluster_name          = local.cluster_name
  cluster_region        = local.region
  tags                  = local.tags
  eks_oidc_provider_arn = module.eks_blueprints.oidc_provider_arn
}

module "eks_blueprints_kubernetes_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0" #ensure to update this to the latest/desired version

  cluster_name      = local.cluster_name
  cluster_endpoint  = module.eks_blueprints.cluster_endpoint
  cluster_version   = module.eks_blueprints.cluster_version
  oidc_provider_arn = module.eks_blueprints.oidc_provider_arn

  depends_on = [module.ebs_csi_driver_irsa, module.eks_data_addons]

  eks_addons = {
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
    }
    coredns = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
  }

  enable_aws_load_balancer_controller = true
  enable_cert_manager                 = true

  cert_manager = {
    chart_version = "v1.10.0"
  }

  enable_aws_efs_csi_driver = true
  enable_aws_fsx_csi_driver = true


  aws_efs_csi_driver = {
    namespace     = "kube-system"
    chart_version = "2.4.1"
  }

  aws_load_balancer_controller = {
    chart_version = "v1.4.8"
  }

  aws_fsx_csi_driver = {
    namespace     = "kube-system"
    chart_version = "1.5.1"
  }

  tags = local.tags
}

module "eks_data_addons" {
  source  = "aws-ia/eks-data-addons/aws"
  version = "~> 1.0" # ensure to update this to the latest/desired version

  oidc_provider_arn = module.eks_blueprints.oidc_provider_arn

  enable_nvidia_gpu_operator = local.using_gpu
}

# todo: update the blueprints repo code to export the desired values as outputs
module "eks_blueprints_outputs" {
  source = "../../../iaac/terraform/utils/blueprints-extended-outputs"

  eks_cluster_id       = module.eks_blueprints.cluster_id
  eks_cluster_endpoint = module.eks_blueprints.cluster_endpoint
  eks_oidc_provider    = module.eks_blueprints.oidc_provider
  eks_cluster_version  = module.eks_blueprints.cluster_version

  tags = local.tags
}

module "kubeflow_components" {
  source = "./vanilla-components"

  kf_helm_repo_path              = local.kf_helm_repo_path
  addon_context                  = module.eks_blueprints_outputs.addon_context
  enable_aws_telemetry           = var.enable_aws_telemetry
  notebook_enable_culling        = var.notebook_enable_culling
  notebook_cull_idle_time        = var.notebook_cull_idle_time
  notebook_idleness_check_period = var.notebook_idleness_check_period


  tags = local.tags
}

#---------------------------------------------------------------
# Supporting Resources
#---------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = local.cluster_name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 3, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 3, k + length(local.azs))]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  # Manage so we can name
  manage_default_network_acl    = true
  default_network_acl_tags      = { Name = "${local.cluster_name}-default" }
  manage_default_route_table    = true
  default_route_table_tags      = { Name = "${local.cluster_name}-default" }
  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.cluster_name}-default" }

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = 1
  }

  tags = local.tags
}
