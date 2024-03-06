provider "aws" {
  region = "us-east-1"
}

data "aws_availability_zones" "available" {}
locals {
  name     = "ex-${basename(path.cwd)}"
  region   = "us-east-1"
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)
  tags = {
    Name       = local.name
    Example    = local.name
    Repository = "https://github.com/terraform-aws-modules/terraform-aws-ec2-instance"
  }
}
################################################################################
# VPC Configuration
################################################################################

module "vpc" {
  source             = "terraform-aws-modules/vpc/aws"
  public_subnets     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  version            = "5.4.0"
  enable_nat_gateway = true
  single_nat_gateway = true
  name               = local.name
  cidr               = local.vpc_cidr
  azs                = local.azs
  private_subnets    = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 4)]
  tags               = local.tags
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"
  vpc_id  = module.vpc.vpc_id
  endpoints = { for service in toset(["ssm", "ssmmessages", "ec2messages"]) :
    replace(service, ".", "_") =>
    {
      service             = service
      subnet_ids          = module.vpc.private_subnets
      private_dns_enabled = true
      tags                = { Name = "${local.name}-${service}" }
    }
  }
  create_security_group      = true
  security_group_name_prefix = "${local.name}-vpc-endpoints-"
  security_group_description = "VPC endpoint security group"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from subnets"
      cidr_blocks = module.vpc.private_subnets_cidr_blocks
    }
  }
  tags = local.tags
}

module "security_group_instance" {
  source       = "terraform-aws-modules/security-group/aws"
  version      = "~> 5.0"
  name         = "${local.name}-ec2"
  description  = "Security Group for EC2 Instance Egress"
  egress_rules = ["all-all"]
  vpc_id       = module.vpc.vpc_id
  tags         = local.tags
}

# AWS S3 File Gateway setup
module "ec2_sgw" {
  source                        = "aws-ia/storagegateway/aws//modules/ec2-sgw"
  vpc_id                        = module.vpc.vpc_id
  subnet_id                     = module.vpc.public_subnets[0]
  name                          = "my-storage-gateway"
  availability_zone             = data.aws_availability_zones.available.names[0]
  ingress_cidr_block_activation = "0.0.0.0/0"
  create_security_group         = true
  ingress_cidr_blocks           = "0.0.0.0/0"

}

module "sgw" {
  depends_on         = [module.ec2_sgw]
  source             = "aws-ia/storagegateway/aws//modules/aws-sgw"
  gateway_name       = "my-storage-gateway"
  gateway_ip_address = module.ec2_sgw.public_ip
  join_smb_domain    = false
  gateway_type       = "FILE_S3"
}

resource "aws_storagegateway_nfs_file_share" "example" {
  client_list     = ["0.0.0.0/0"]
  gateway_arn     = module.sgw.storage_gateway.arn
  location_arn    = "arn:aws:s3:::halo-data-bucket-demo"
  role_arn        = aws_iam_role.sgw_s3_access_role.arn
  file_share_name = "halo_nfs_share"
}


# IAM Role for Storage Gateway to access S3 bucket in ryan_test_dev
resource "aws_iam_role" "sgw_s3_access_role" {
  name = "SGW-S3-Access-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "storagegateway.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# IAM Policy to allow access to the specific S3 bucket in ryan_test_dev
resource "aws_iam_policy" "sgw_s3_bucket_access" {
  name = "SGW-S3-Bucket-Access-Policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ],
        Resource = [
          "arn:aws:s3:::my-tf-test-buckdfdsfdsfdsfet",
          "arn:aws:s3:::my-tf-test-buckdfdsfdsfdsfet/*"
        ]
      }
    ]
  })
}

# Attach the policy to the role
resource "aws_iam_role_policy_attachment" "sgw_s3_access_attach" {
  role       = aws_iam_role.sgw_s3_access_role.name
  policy_arn = aws_iam_policy.sgw_s3_bucket_access.arn
}