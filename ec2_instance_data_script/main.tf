provider "aws" {
  region = "us-east-1"
}

# ============================================================
# DATA
# ============================================================
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  bucket_name = "application-bin-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}-an"
}

data "aws_s3_bucket" "application_binary_bucket" {
  bucket = local.bucket_name
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# using the amazon linux image for the app instance because
# it already ships with the aws cli and i can fetch the
# application binary hosted on s3 bucket quickly
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023*-x86_64"]
  }
}

data "aws_key_pair" "my_keypair" {
  key_name           = "ec2-keypair"
  include_public_key = true
}

# ============================================================
# ROLE
# ============================================================
resource "aws_iam_role" "helloworld_ec2_s3_role" {
  name = "helloworld-app-s3-reader-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "helloworld_s3_read_policy" {
  name = "helloworld-s3-read-object-policy"
  role = aws_iam_role.helloworld_ec2_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          data.aws_s3_bucket.application_binary_bucket.arn,
          "${data.aws_s3_bucket.application_binary_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "helloworld_ec2_profile" {
  name = "helloworld-app-ec2-instance-profile"
  role = aws_iam_role.helloworld_ec2_s3_role.name
}

# ============================================================
# EC2 INSTANCES
# ============================================================
resource "aws_instance" "helloworld_proxy" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.helloworld_public_sg.id]
  key_name               = data.aws_key_pair.my_keypair.key_name

  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              # Install Nginx
              apt install nginx -y
              systemctl enable nginx

              # remove default site links or configs if they exist
              rm -f /etc/nginx/sites-enabled/default
              rm -f /etc/nginx/conf.d/default.conf

              sed -i '/server {/,/}/s/^/#/' /etc/nginx/nginx.conf

              # Configure the Reverse Proxy pointing to the instance Private DNS
              # Replace with your actual backend DNS name or dynamic variable
              cat << 'NGINX_CONF' > /etc/nginx/conf.d/go_proxy.conf
              server {
                  listen 80;
                  server_name _;
                  location / {
                      proxy_pass http://${aws_instance.helloworld_app.private_ip}:8080;
                      proxy_set_header Host $host;
                      proxy_set_header X-Real-IP $remote_addr;
                  }
              }
              NGINX_CONF

              # Allow Nginx network connections through SELinux
              # setsebool -P httpd_can_network_connect 1

              # Restart to apply configuration
              systemctl restart nginx
              EOF

  tags = { Name = "helloworld-proxy" }
}

resource "aws_instance" "helloworld_app" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.intra_subnets[0]
  vpc_security_group_ids = [aws_security_group.helloworld_private_sg.id]
  key_name               = data.aws_key_pair.my_keypair.key_name

  # attach instance profile
  iam_instance_profile = aws_iam_instance_profile.helloworld_ec2_profile.name

  user_data_base64 = base64encode(<<-EOF
              #!/bin/bash
              # Create app directory structure
              mkdir -p /opt/app
              cd /opt/app

              # Note: Requires an IAM instance profile attached to the EC2 to
              # access S3
              aws s3 cp s3://${data.aws_s3_bucket.application_binary_bucket.bucket}/app .

              chmod +x app

              # Create the systemd service file dynamically
              cat << 'SERVICE' > /etc/systemd/system/app.service
              [Unit]
              Description=simple hello world application
              After=network.target

              [Service]
              Type=simple
              User=ec2-user
              WorkingDirectory=/opt/app
              ExecStart=/opt/app/app
              Restart=always

              [Install]
              WantedBy=multi-user.target
              SERVICE

              # Start the application
              systemctl daemon-reload
              systemctl enable app.service
              systemctl start app.service
              EOF
  )

  tags = {
    Name = "helloworld-app"
  }
}

# ============================================================
# VPC AND SECURITY GROUPS
# ============================================================
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "helloworld-terraform-module-vpc"
  cidr = "10.0.0.0/16"

  # Define Available Zones and corresponding subnet ranges
  azs            = ["us-east-1a", "us-east-1b", "us-east-1c"]
  intra_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  public_subnets = ["10.0.201.0/24", "10.0.202.0/24", "10.0.203.0/24"]

  create_igw = true

  enable_nat_gateway = false
  single_nat_gateway = false
  enable_vpn_gateway = false

  # allows instances to be able to resolve *.ec2.internal hostnames
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Terraform = "true"
  }
}

# vpc endpoint to allow instances in the intra subnets to read/write from/to s3 bucket
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = module.vpc.vpc_id
  service_name = "com.amazonaws.${data.aws_region.current.region}.s3"

  vpc_endpoint_type = "Gateway"

  route_table_ids = module.vpc.intra_route_table_ids

  tags = {
    Name = "helloworld-s3-isolated-gateway"
  }
}

# exactly the same as the above aws_vpc_endpoint declaration but uses terraform module system
# designed exactly for this
# module "vpc_endpoints" {
#   source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
#   version = "~> 5.0"
#   vpc_id  = module.vpc.vpc_id
# 
#   endpoints = {
#     s3 = {
#       service         = "s3"
#       service_type    = "Gateway"
#       route_table_ids = module.vpc.intra_route_table_ids
#       tags = {
#         Name = "helloworld-s3-isolated-gateway"
#       }
#     }
#   }
# }

resource "aws_security_group" "helloworld_public_sg" {
  name        = "helloworld-public-sg"
  description = "allows public web traffic"

  vpc_id = module.vpc.vpc_id

  ingress {
    description = "allows http web traffic from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ssh access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "allows anyone to ping the server"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "allows all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "helloworld-public-sg"
  }
}

resource "aws_security_group" "helloworld_private_sg" {
  name        = "helloworld-private-sg"
  description = "private security group only allows traffic within the same vpc"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "allows inbound traffic only from the other security group"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    # restrict source by sg id
    security_groups = [aws_security_group.helloworld_public_sg.id]
  }

  ingress {
    description     = "allows pinging from within vpc"
    from_port       = -1
    to_port         = -1
    protocol        = "icmp"
    security_groups = [aws_security_group.helloworld_public_sg.id]
  }

  ingress {
    description     = "allows ssh from within vpc"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.helloworld_public_sg.id]
  }

  egress {
    description = "allows outbound traffic only within the vpc"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "helloworld-private-sg"
  }
}

