####################################### PROVEDOR ##################################

# Provider
provider "aws" {
  region = "us-east-1"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.47.0"
    }
  }
}


####################################### VPC ##################################

resource "aws_vpc" "otel" {
  cidr_block           = "10.0.0.0/20"

  tags = {
    Name = "${var.naming_prefix}-vpc"
  }
}
####################################### IGW ##################################
# Um gateway de Internet conectado à VPC para fornecer acesso à Internet a recursos nas sub-redes públicas.

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.otel.id

    tags = {
      Name = "${var.naming_prefix}-igw" 
  }
}

####################################### SUB NET - PUB ##################################
# Sub-redes públicas em duas zonas de disponibilidade diferentes para obter alta disponibilidade.  

resource "aws_subnet" "public-us-east-1a" {
  vpc_id            = aws_vpc.otel.id
  cidr_block        = "10.0.0.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name                              = "${var.naming_prefix}-publ-1"
    "kubernetes.io/role/elb"          = "1" #this instruct the kubernetes to create public load balancer in these subnets (só qd faz o deploy via helm do ALB?)
    "kubernetes.io/cluster/otel"      = "owned"
  }
}

resource "aws_subnet" "public-us-east-1b" {
  vpc_id            = aws_vpc.otel.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name                              = "${var.naming_prefix}-publ-2"
    "kubernetes.io/role/elb"          = "1" #this instruct the kubernetes to create public load balancer in these subnets (só qd faz o deploy via helm do ALB?)
    "kubernetes.io/cluster/otel"      = "owned"
  }
}
####################################### SUB NET - PRIV #################################
# Sub-redes privadas em duas zonas de disponibilidade diferentes para obter alta disponibilidade.

resource "aws_subnet" "private-us-east-1a" {
  vpc_id            = aws_vpc.otel.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1a"

  tags = {
    Name                              = "${var.naming_prefix}-private-1a" 
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/otel"      = "owned"
  }
}

resource "aws_subnet" "private-us-east-1b" {
  vpc_id            = aws_vpc.otel.id
  cidr_block        = "10.0.6.0/24"
  availability_zone = "us-east-1b"

  tags = {
    Name                              = "${var.naming_prefix}-private-1b" 
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/otel"      = "owned"
  }
}

####################################### NAT GATEWAY #################################
# Um gateway NAT em cada sub-rede pública para rotear o tráfego da sub-rede privada para a Internet.

# Necessário alocar o endereço IP elástico
resource "aws_eip" "eip_natgw" {
  domain = "vpc"

  tags = {
    Name                              = "${var.naming_prefix}-eip" 
  }
}
resource "aws_nat_gateway" "natgateway" {
  allocation_id = aws_eip.eip_natgw.id
  subnet_id     = aws_subnet.public-us-east-1a.id

  tags = {
    Name                              = "${var.naming_prefix}-nat-gw" 
  }

  depends_on = [aws_internet_gateway.igw]
}


####################################### ROUTE TABLE PUBL #################################
# Tabelas de rotas e rotas configuradas para direcionar o tráfego adequadamente entre as sub-redes, o gateway NAT e o gateway da Internet.

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.otel.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags =  {
    Name = "${var.naming_prefix}-pub-rtable"
  }
}

# Atribuir a tabela de rotas públicas à sub-rede pública
resource "aws_route_table_association" "public-us-east-1a" {

  subnet_id      = aws_subnet.public-us-east-1a.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "public-us-east-1b" {

  subnet_id      = aws_subnet.public-us-east-1b.id
  route_table_id = aws_route_table.public_route_table.id
}
####################################### ROUTE TABLE PRIV #################################
# Tabelas de rotas e rotas configuradas para direcionar o tráfego adequadamente entre as sub-redes, o gateway NAT e o gateway da Internet.

resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.otel.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.natgateway.id
  }

  tags =  {
    Name = "${var.naming_prefix}-priv-rtable"
  }
}

# Atribuir a tabela de rotas privadas à sub-rede privada
resource "aws_route_table_association" "private-us-east-1a" {
  subnet_id      = aws_subnet.private-us-east-1a.id
  route_table_id = aws_route_table.private_route_table.id
}

resource "aws_route_table_association" "private-us-east-1b" {
  subnet_id      = aws_subnet.private-us-east-1b.id
  route_table_id = aws_route_table.private_route_table.id
}

####################################### EKS #################################

# IAM role para eks --> Esta é a role que talvez eu precise configurar para ter acesso ao cluster

resource "aws_iam_role" "otel" {
  name = "eks-cluster-otel"
  tags = {
    tag-key = "eks-cluster-otel"
  }

  assume_role_policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": [
                    "eks.amazonaws.com"
                ]
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
POLICY
}

# Anexar política EKS

resource "aws_iam_role_policy_attachment" "otel-AmazonEKSClusterPolicy" {
  role       = aws_iam_role.otel.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Requisito mínimo

resource "aws_eks_cluster" "otel" {
  name     = "otel"
  role_arn = aws_iam_role.otel.arn

  vpc_config {
    subnet_ids = [
      aws_subnet.private-us-east-1a.id,
      aws_subnet.private-us-east-1b.id,
      aws_subnet.public-us-east-1a.id,
      aws_subnet.public-us-east-1b.id
    ]
  }

  depends_on = [aws_iam_role_policy_attachment.otel-AmazonEKSClusterPolicy]
}

################################## INSTÂNCIAS #################################

#   Role para único grupo de instâncias

resource "aws_iam_role" "nodes" {
  name = "eks-node-group-otel"

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

# Anexar política IAM ao grupo de nós

resource "aws_iam_role_policy_attachment" "nodes-AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.nodes.name
}

resource "aws_iam_role_policy_attachment" "nodes-AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.nodes.name
}

resource "aws_iam_role_policy_attachment" "nodes-AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.nodes.name
}

# Grupo de nós

resource "aws_eks_node_group" "private-nodes" {
  cluster_name    = aws_eks_cluster.otel.name
  node_group_name = "private-nodes"
  node_role_arn   = aws_iam_role.nodes.arn

  subnet_ids = [
    aws_subnet.private-us-east-1a.id,
    aws_subnet.private-us-east-1b.id
  ]

  capacity_type  = "ON_DEMAND"
  instance_types = ["t2.medium"]

  scaling_config {
    desired_size = 1
    max_size     = 2
    min_size     = 1
  }

  update_config {
    max_unavailable = 1
  }

  labels = {
    node = "kubenode01"
  }

    depends_on = [
    aws_iam_role_policy_attachment.nodes-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.nodes-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.nodes-AmazonEC2ContainerRegistryReadOnly,
  ]
}

# OpenID - permissões IAM com base na conta de serviço usada pelo pod

data "tls_certificate" "eks" {
  url = aws_eks_cluster.otel.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.otel.identity[0].oidc[0].issuer
}

################################## CONTINUA ... #################################
