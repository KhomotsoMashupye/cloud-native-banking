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
