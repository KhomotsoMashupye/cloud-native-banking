terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# VPC 

resource "aws_vpc" "eks_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "eks-vpc" }
}
# INTERNET GATEWAY

resource "aws_internet_gateway" "eks_igw" {
  vpc_id = aws_vpc.eks_vpc.id
  tags   = { Name = "eks-igw" }
}
# PUBLIC SUBNETS

resource "aws_subnet" "eks_public_subnet" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                     = "eks-public-${count.index + 1}"
    "kubernetes.io/cluster/eks-banking-cluster" = "shared"
    "kubernetes.io/role/elb"                 = "1"
  }
}
#PUBLIC ROUTE TABLE

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.eks_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eks_igw.id
  }
  tags = { Name = "eks-public-rt" }
}

resource "aws_route_table_association" "public_assoc" {
  count          = length(aws_subnet.eks_public_subnet)
  subnet_id      = aws_subnet.eks_public_subnet[count.index].id
  route_table_id = aws_route_table.public_rt.id
}

# NAT GATEWAY

resource "aws_eip" "eks_nat_eip" {
  count  = 2
  domain = "vpc"
}

resource "aws_nat_gateway" "eks_nat" {
  count         = 2
  allocation_id = aws_eip.eks_nat_eip[count.index].id
  subnet_id     = aws_subnet.eks_public_subnet[count.index].id
  tags          = { Name = "eks-nat-${count.index + 1}" }
}
# PRIVATE SUBNETS

resource "aws_subnet" "eks_private_subnet" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                                     = "eks-private-${count.index + 1}"
    "kubernetes.io/cluster/eks-banking-cluster" = "shared"
    "kubernetes.io/role/internal-elb"        = "1"
  }
}
# PRIVATE ROUTE TABLE 

resource "aws_route_table" "eks_private_rt" {
  count  = 2
  vpc_id = aws_vpc.eks_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.eks_nat[count.index].id
  }
  tags = { Name = "eks-private-rt-${count.index + 1}" }
}

resource "aws_route_table_association" "eks_private_assoc" {
  count          = 2
  subnet_id      = aws_subnet.eks_private_subnet[count.index].id
  route_table_id = aws_route_table.eks_private_rt[count.index].id
}
# EKS Cluster Setup

resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role-usw2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "eks_cluster" {
  name     = "eks-banking-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = "1.31"

  vpc_config {
    subnet_ids              = aws_subnet.eks_private_subnet[*].id
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_cloudwatch_log_group.eks_cluster_logs
  ]
}


# Managed Node Group

resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-group-role-usw2"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy" # Policy path fix
  ])
  role       = aws_iam_role.eks_node_role.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "banking-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.eks_private_subnet[*].id
  ami_type        = "AL2023_x86_64_STANDARD" 
  instance_types  = ["t3.medium"]

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }

  timeouts {
    delete = "20m"
  }

  depends_on = [aws_iam_role_policy_attachment.node_policies]
}
# RDS Security Group

resource "aws_security_group" "rds_sg" {
  name        = "banking-rds-sg"
  description = "Allow inbound traffic from EKS nodes"
  vpc_id      = aws_vpc.eks_vpc.id

  ingress {
    description     = "Postgres from EKS Nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    
    security_groups = [aws_eks_cluster.eks_cluster.vpc_config[0].cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS Subnet Group

resource "aws_db_subnet_group" "rds_subnets" {
  name       = "banking-db-subnet-group"
  subnet_ids = aws_subnet.eks_private_subnet[*].id

  tags = { Name = "Banking DB Subnets" }
}

# Primary RDS Instance

resource "aws_db_instance" "primary_db" {
  identifier           = "banking-db-primary"
  engine               = "postgres"
  
  engine_version       = "16.11" 
  
  instance_class       = "db.t3.medium"
  allocated_storage    = 20
  db_name              = "bankingdb"
  username             = "postgres"
  password             = var.db_password
  backup_retention_period   = 7
  apply_immediately = true
  
  db_subnet_group_name   = aws_db_subnet_group.rds_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  
  multi_az             = false
  skip_final_snapshot  = true
  publicly_accessible  = false
}
variable "db_password" {
  description = "Master password for the RDS database"
  type        = string
  sensitive   = true 
}

# Read Replica

resource "aws_db_instance" "read_replica" {
  identifier            = "banking-db-replica"
  replicate_source_db   = aws_db_instance.primary_db.identifier
  instance_class        = "db.t3.medium"
  # Read replicas inherit the engine/version but need their own SG
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot   = true
  parameter_group_name  = aws_db_instance.primary_db.parameter_group_name
}


