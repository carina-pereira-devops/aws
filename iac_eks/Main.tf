############################################ GERAL ##################################

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

# Provider AWS
provider "aws" {
  region = var.region
}

# Resgatando informações do nome do cluster
locals {
  cluster_name = "eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

############################################# VPC ##################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"

  name = "eks-vpc"
  cidr = "10.0.0.0/16"

# Redundância em duas Zonas de Disponibilidade
  azs             = ["us-east-1a", "us-east-1b"]

# Sub-Redes
  public_subnets  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnets = ["10.0.2.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true # habilita nat_gateway
  single_nat_gateway   = false # se true apenas um para toda VPC
  one_nat_gateway_per_az = true # para que exista uma nat gateway por AZ, e não por subnet
  enable_vpn_gateway = false # não habilitar gateway de VPN

}

##################################### SG ####################################

module "grpc_sg" {
  source      = "terraform-aws-modules/security-group/aws"
  name        = "grpc"
  description = "allow grpc traffic"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 50051
      to_port     = 50051
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
    }
  ]
}

############################################### EKS ####################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.5"

  cluster_name    = local.cluster_name
  cluster_version = "1.29"

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    devops = {
      min_size     = 1
      max_size     = 3
      desired_size = 2
      instance_types = ["t2.micro"]
    }
  }
}

############################################### ALB ####################################

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 6.0"

  name = "eks-alb"

  load_balancer_type = "application"

  vpc_id          = module.vpc.vpc_id
  subnets         = module.vpc.private_subnets
  security_groups = [module.vpc.default_security_group_id, module.grpc_sg.security_group_id]

  target_groups = [
    {
      backend_protocol = "HTTPS"
      protocol_version = "gRPC"
      backend_port     = 50051
      target_type      = "ip"
      health_check = {
        enable              = true
        interval            = 30
        path                = "/"
        port                = "traffic-port"
        healthy_threshold   = 3
        unhealthy_threshold = 3
        timeout             = 5
        protocol            = "HTTPS"
        matcher             = "12"
      }
    }
  ]

  https_listeners = [
    {
      port               = 50051
      protocol           = "HTTPS"
      certificate_arn    = aws_acm_certificate.self_signed.arn
      target_group_index = 0
    }
  ]
}

########################################################################################
