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
provider "aws" {
  alias  = "replica"
  region = "eu-west-1" # For Disaster recovery
}
# KMS KEY 

resource "aws_kms_key" "banking_key" {
  description             = "Master key for banking data"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  multi_region            = true 
}

# The Replica Key in the second region

resource "aws_kms_replica_key" "banking_key_replica" {
  provider                = aws.replica
  description             = "Replica of banking master key"
  primary_key_arn         = aws_kms_key.banking_key.arn
  deletion_window_in_days = 30
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
  count  = length(var.public_subnet_cidrs)
  domain = "vpc"
}

resource "aws_nat_gateway" "eks_nat" {
  count         = length(var.public_subnet_cidrs)
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
  count  = length(var.private_subnet_cidrs)
  vpc_id = aws_vpc.eks_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.eks_nat[count.index].id
  }
  tags = { Name = "eks-private-rt-${count.index + 1}" }
}
# Route Table Association

resource "aws_route_table_association" "eks_private_assoc" {
  count          = 2
  subnet_id      = aws_subnet.eks_private_subnet[count.index].id
  route_table_id = aws_route_table.eks_private_rt[count.index].id
}

# EKS Cluster Security Group

resource "aws_security_group" "eks_cluster_sg" {
  name        = "banking-cluster-sg"
  description = "Cluster communication with worker nodes"
  vpc_id      = aws_vpc.eks_vpc.id

  tags = { Name = "eks-cluster-sg" }
}


resource "aws_vpc_security_group_egress_rule" "cluster_to_nodes" {
  security_group_id = aws_security_group.eks_cluster_sg.id
  
  referenced_security_group_id = aws_security_group.eks_nodes_sg.id
  ip_protocol                  = "-1"
}
# EKS Cluster Role

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

# Cluster Autoscaler

resource "aws_iam_policy" "cluster_autoscaler" {
  name        = "EKSClusterAutoscalerPolicy"
  description = "Allows EKS to scale EC2 instances"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeTags",
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ca_attach" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"

  set {
    name  = "autoDiscovery.clusterName"
    value = aws_eks_cluster.eks_cluster.name
  }

  set {
    name  = "awsRegion"
    value = "af-south-1" 
  }
}


# EKS Cluster

resource "aws_eks_cluster" "eks_cluster" {
  name     = "eks-banking-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = "1.31"

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.banking_key.arn
    }
  }

  vpc_config {
    subnet_ids              = aws_subnet.eks_private_subnet[*].id
    
    security_group_ids      = [aws_security_group.eks_cluster_sg.id]
    
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

# EKS Nodes Security Group

resource "aws_security_group" "eks_nodes_sg" {
  name        = "banking-nodes-sg"
  description = "Security group for all nodes in the cluster"
  vpc_id      = aws_vpc.eks_vpc.id

  tags = {
    Name                                        = "banking-nodes-sg"
    "kubernetes.io/cluster/eks-banking-cluster" = "owned"
  }
}


resource "aws_vpc_security_group_ingress_rule" "nodes_internal" {
  security_group_id = aws_security_group.eks_nodes_sg.id
  
  referenced_security_group_id = aws_security_group.eks_nodes_sg.id
  ip_protocol                  = "-1"
}

# Allow traffic ALB

resource "aws_vpc_security_group_ingress_rule" "alb_to_nodes" {
  security_group_id = aws_security_group.eks_nodes_sg.id
  
  referenced_security_group_id = aws_security_group.alb_sg.id
  from_port                    = 0
  to_port                      = 65535
  ip_protocol                  = "tcp"
}

# Standard Outbound 

resource "aws_vpc_security_group_egress_rule" "nodes_outbound" {
  security_group_id = aws_security_group.eks_nodes_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
# EKS Node Group Role

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


# EKS Node Group

resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "banking-node-group"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.eks_private_subnet[*].id
  ami_type        = "AL2023_x86_64_STANDARD"

  
  launch_template {
    id      = aws_launch_template.eks_nodes_lt.id
    version = aws_launch_template.eks_nodes_lt.latest_version
  }

  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }
  update_config {
    max_unavailable = 1
  }

  timeouts {
    delete = "20m"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_policies,
    aws_launch_template.eks_nodes_lt
  ]
}

# Launch Template for EKS Nodes

resource "aws_launch_template" "eks_nodes_lt" {
  name_prefix   = "banking-nodes-lt-"
  description   = "Launch template for banking EKS nodes"
  instance_type = "t3.medium"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.banking_key.arn
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true 
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "banking-eks-node"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
# WAF

resource "aws_wafv2_web_acl" "banking_waf" {
  name        = "banking-production-waf"
  description = " WAF for Banking Microservices"
  scope       = "REGIONAL" 
  
  default_action {
    allow {}
  }

  #  RULE 1: Amazon IP Reputation List 
  
  rule {
    name     = "AWS-AmazonIpReputationList"
    priority = 1
    override_action { 
      none {} 
      }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "IpReputationMetric"
      sampled_requests_enabled   = true
    }
  }

  # Core Rule Set (OWASP Top 10)

  rule {
    name     = "AWS-CommonRuleSet"
    priority = 2
    override_action {
       none {} 
       }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  #  Rate Limiting (The Brute Force Shield) 
  
  rule {
    name     = "OverallRateLimit"
    priority = 3
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "OverallRateLimitMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "BankingWAFMainMetric"
    sampled_requests_enabled   = true
  }
}
# WAF Logs

resource "aws_cloudwatch_log_group" "waf_logs" {
  name              = "aws-waf-logs-banking" 
  retention_in_days = 90
}

resource "aws_wafv2_web_acl_logging_configuration" "banking_waf_logging" {
  log_destination_configs = [aws_cloudwatch_log_group.waf_logs.arn]
  resource_arn            = aws_wafv2_web_acl.banking_waf.arn
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
    
   security_groups = [aws_security_group.eks_nodes_sg.id]
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
# Random Database Password

resource "random_password" "db_master_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Primary RDS Instance

resource "aws_db_instance" "primary_db" {
  identifier           = "banking-db-primary"
  engine               = "postgres"
  
  engine_version       = "16" 
  
  instance_class       = "db.t3.medium"
  allocated_storage    = 20
  db_name              = "bankingdb"
  username             = "postgres"
  password             = random_password.db_master_password.result
  backup_retention_period   = 7
  apply_immediately = true
  
  db_subnet_group_name   = aws_db_subnet_group.rds_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  storage_encrypted    = true
  kms_key_id           = aws_kms_key.banking_key.arn
  
  multi_az             = true
  skip_final_snapshot  = false
  publicly_accessible  = false
}


# Read Replica

resource "aws_db_instance" "read_replica" {
  identifier            = "banking-db-replica"
  replicate_source_db   = aws_db_instance.primary_db.identifier
  instance_class        = "db.t3.medium"
  vpc_security_group_ids = [aws_security_group.rds_sg.id]
  skip_final_snapshot   = true
  parameter_group_name  = aws_db_instance.primary_db.parameter_group_name
}
# Elasticache

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id          = "banking-cache"
  description                   = "Cache for transaction sessions"
  node_type                     = "cache.t3.medium"
  num_cache_clusters            = 2
  parameter_group_name          = "default.redis7"
  port                          = 6379
  subnet_group_name             = aws_elasticache_subnet_group.main.name
  security_group_ids            = [aws_security_group.redis_sg.id]
  automatic_failover_enabled     = true
}
# Elasticache Subnet Group

resource "aws_elasticache_subnet_group" "main" {
  name       = "banking-cache-subnets"
  subnet_ids = var.private_subnet_ids
}
# Elasticache Security Group

resource "aws_security_group" "redis_sg" {
  name        = "banking-redis-sg"
  description = "Allow EKS nodes to talk to Redis"
  vpc_id      = aws_vpc.eks_vpc.id

  ingress {
    description     = "Redis from EKS Nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    # This is the "Magic Link" to your existing EKS node SG
    security_groups = [aws_security_group.eks_nodes_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "banking-redis-sg"
  }
}
# AWS Xray

resource "aws_xray_sampling_rule" "bank_sampling" {
  rule_name      = "BankingApp"
  priority       = 1000
  version        = 1
  reservoir_size = 1
  fixed_rate     = 0.05
  url_path       = "*"
  host           = "*"
  http_method    = "*"
  service_type   = "*"
  service_name   = "*"
  resource_arn   = "*"
}
resource "aws_iam_role_policy_attachment" "node_xray" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# SECRETS MANAGER

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_secret.id
  secret_string = random_password.db_master_password.result

}

resource "aws_secretsmanager_secret" "db_secret" {
  name       = "banking/prod/db-password"
  kms_key_id = aws_kms_key.banking_key.arn
  replica {
    region = "eu-west-1"
  }
}

resource "aws_vpc_endpoint" "secrets_endpoint" {
  vpc_id              = aws_vpc.eks_vpc.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.eks_private_subnet[*].id
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true
}

# Security Group for the Endpoints
resource "aws_security_group" "vpc_endpoint_sg" {
  name        = "banking-vpc-endpoint-sg"
  vpc_id      = aws_vpc.eks_vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.eks_vpc.cidr_block] # Only allow traffic from within the VPC
  }
}


# Amazon ECR Repository

resource "aws_ecr_repository" "banking_app_repo" {
  name                 = "banking-microservice"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}
# ECR API Endpoint (Authentication)

resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.eks_vpc.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.eks_private_subnet[*].id
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true
  tags                = { Name = "ecr-api-endpoint" }
}

# ECR Docker Endpoint (Image Layers)

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.eks_vpc.id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.eks_private_subnet[*].id
  security_group_ids  = [aws_security_group.vpc_endpoint_sg.id]
  private_dns_enabled = true
  tags                = { Name = "ecr-dkr-endpoint" }
}
resource "aws_cognito_user_pool" "banking_user_pool" {
  name = "banking-app-users"

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_numbers   = true
    require_symbols   = true
    require_uppercase = true
  }

  auto_verified_attributes = ["email"]
  deletion_protection = "ACTIVE" 
}
#COGNITO

resource "aws_cognito_user_pool_client" "banking_client" {
  name         = "banking-web-client"
  user_pool_id = aws_cognito_user_pool.banking_user_pool.id
  
  explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}
#  TLS certificate for the EKS OIDC issuer

data "tls_certificate" "eks" {
  url = aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer
}

# OIDC Provider in IAM

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.eks_cluster.identity[0].oidc[0].issuer
}
# The Trust Policy
resource "aws_iam_role" "notifications_irsa" {
  name = "banking-notifications-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.eks.arn
        }
        Condition = {
          StringEquals = {
            # This limits the role to a specific Namespace and ServiceAccount name in K8s
            "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub" = "system:serviceaccount:banking:notifications-sa"
          }
        }
      }
    ]
  })
}

# The "Permission Policy" 

resource "aws_iam_role_policy" "notifications_sns_policy" {
  name = "notifications-sns-access"
  role = aws_iam_role.notifications_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.banking_alerts.arn
      }
    ]
  })
}
# CLOUDWATCH LOG GROUP

resource "aws_cloudwatch_log_group" "eks_log_group" {
  name              = "/aws/eks/banking-cluster/logs"
  retention_in_days = 7
}
resource "aws_cloudwatch_log_group" "vpc_flow_log_group" {
  name              = "/aws/vpc/banking-flow-logs"
  retention_in_days = 30 
}

# IAM Role for the Flow Log service

resource "aws_iam_role" "vpc_flow_log_role" {
  name = "banking-vpc-flow-log-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

#  Role Policy

resource "aws_iam_role_policy" "vpc_flow_log_policy" {
  name = "banking-vpc-flow-log-policy"
  role = aws_iam_role.vpc_flow_log_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Effect   = "Allow"
      Resource = "${aws_cloudwatch_log_group.vpc_flow_log_group.arn}:*"
    }]
  })
}

# VPC Flow Logs

resource "aws_flow_log" "eks_vpc_flow_log" {
  iam_role_arn    = aws_iam_role.vpc_flow_log_role.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_log_group.arn
  traffic_type    = "ALL" # Captures both 'Accept' and 'Reject' traffic
  vpc_id          = aws_vpc.eks_vpc.id
}

# SNS 
resource "aws_sns_topic" "banking_alerts" {
  name = "banking-transaction-alerts"
  
  kms_master_key_id = aws_kms_key.banking_key.arn
}

# SQS Queue (Processing)

resource "aws_sqs_queue" "transaction_queue" {
  name                      = "banking-transaction-queue"
  delay_seconds             = 0
  max_message_size          = 262144
  message_retention_seconds = 86400 
  receive_wait_time_seconds = 10    
  
  sqs_managed_sse_enabled = true
}

# SNS to SQS Subscription

resource "aws_sns_topic_subscription" "alerts_to_queue" {
  topic_arn = aws_sns_topic.banking_alerts.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.transaction_queue.arn
  
  raw_message_delivery = true
}

# SQS Policy (Allow SNS to Push)

resource "aws_sqs_queue_policy" "sns_to_sqs_policy" {
  queue_url = aws_sqs_queue.transaction_queue.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.transaction_queue.arn
        Condition = {
          ArnEquals = { "aws:SourceArn" = aws_sns_topic.banking_alerts.arn }
        }
      }
    ]
  })
}
# CLOUDWATCH LOG GROUP 

resource "aws_cloudwatch_log_group" "eks_cluster_logs" {
  name              = "/aws/eks/eks-banking-cluster/cluster"
  retention_in_days = 7
}
# S3 DATA LAKE 

resource "aws_s3_bucket" "analytics_lake" {
  bucket        = "banking-analytics-lake-2242"
  force_destroy = false
}
resource "aws_s3_bucket_server_side_encryption_configuration" "lake_encryption" {
  bucket = aws_s3_bucket.analytics_lake.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.banking_key.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

resource "aws_s3_bucket_versioning" "analytics_lake_versioning" {
  bucket = aws_s3_bucket.analytics_lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Public Access Block

resource "aws_s3_bucket_public_access_block" "analytics_block" {
  bucket = aws_s3_bucket.analytics_lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_vpc_endpoint" "s3_endpoint" {
  vpc_id       = aws_vpc.eks_vpc.id
  service_name = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids = concat(
    [aws_route_table.public_rt.id],
    aws_route_table.eks_private_rt[*].id
  )
  tags = { Name = "s3-endpoint" }
}
# AWS GLUE

resource "aws_glue_catalog_database" "analytics_db" {
  name = "banking_analytics"
}

# Glue Crawler

resource "aws_glue_crawler" "s3_crawler" {
  name          = "banking-s3-crawler"
  role          = aws_iam_role.glue_role.arn
  database_name = aws_glue_catalog_database.analytics_db.name

  s3_target {
    path = "s3://${aws_s3_bucket.analytics_lake.bucket}/data/"
  }
}

resource "aws_iam_role" "glue_role" {
  name = "banking-glue-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "glue.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}
resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_access" {
  name = "glue-s3-datalake-access"
  role = aws_iam_role.glue_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.analytics_lake.arn,
          "${aws_s3_bucket.analytics_lake.arn}/*"
        ]
      }
    ]
  })
}

# Athena Query Results Bucket

resource "aws_s3_bucket" "athena_results" {
  bucket        = "banking-athena-results-2026"
  force_destroy = true
}

# Athena Workgroup

resource "aws_athena_workgroup" "analytics" {
  name = "banking-analytics-workgroup"

  configuration {
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"
    }
  }
}# AWS Macie

resource "aws_macie2_account" "banking_macie" {
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  status                       = "ENABLED"
}
resource "aws_macie2_classification_job" "daily_pii_scan" {
  job_type = "SCHEDULED"
  name     = "daily-transaction-log-scan"
  
  schedule_frequency {
    daily_schedule = "ENABLED"
  }

  s3_job_definition {
    bucket_definitions {
      account_id = data.aws_caller_identity.current.account_id
      buckets    = [aws_s3_bucket.transaction_logs.id]
    }
  }
  sampling_percentage = 50 
  
  depends_on = [aws_macie2_account.banking_macie]
}
# AWS Guard Duty

resource "aws_guardduty_detector" "banking_guardduty" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

# Kubernetes Audit Logs

resource "aws_guardduty_detector_feature" "eks_audit" {
  detector_id = aws_guardduty_detector.banking_guardduty.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

# Runtime Monitoring

resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  detector_id = aws_guardduty_detector.banking_guardduty.id
  name        = "EKS_RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}
# Malware Protection

resource "aws_guardduty_detector_feature" "malware_protection" {
  detector_id = aws_guardduty_detector.banking_guardduty.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "ENABLED"
}

# Guard Duty Alerts

resource "aws_sns_topic" "guardduty_alerts" {
  name = "banking-guardduty-alerts"
}

resource "aws_sns_topic_subscription" "email_alert" {
  topic_arn = aws_sns_topic.guardduty_alerts.arn
  protocol  = "email"
  endpoint  = "your-email@example.com"
}

# Event Rule

resource "aws_cloudwatch_event_rule" "guardduty_finding_rule" {
  name        = "guardduty-severity-filter"
  description = "Trigger SNS for Medium and High GuardDuty findings"

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      # This logic says: "Only alert if severity is 4 or higher"
      severity = [{ numeric = [">=", 4] }]
    }
  })
}
# SNS Target

resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.guardduty_finding_rule.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.guardduty_alerts.arn
}

# Topic Policy

resource "aws_sns_topic_policy" "default" {
  arn    = aws_sns_topic.guardduty_alerts.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

data.aws_iam_policy_document "sns_topic_policy" {
  statement {
    actions = ["sns:Publish"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    resources = [aws_sns_topic.guardduty_alerts.arn]
  }
}