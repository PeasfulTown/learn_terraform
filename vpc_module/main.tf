provider "aws" {
  region = "us-east-1"
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22*"]
  }

  owners = ["679593333241"]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "helloworld-terraform-module-vpc"
  cidr = "10.0.0.0/16"

  # Define Available Zones and corresponding subnet ranges
  azs             = ["us-east-1a", "us-east-1b", "us-east-1c"]
  intra_subnets   = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
  public_subnets  = ["10.0.201.0/24", "10.0.202.0/24", "10.0.203.0/24"]

  create_igw = true

  enable_nat_gateway = false
  single_nat_gateway = false
  enable_vpn_gateway = false

  # allows instances to be able to resolve *.ec2.internal hostnames
  enable_dns_hostnames = true
  enable_dns_support = true

  tags = {
    Terraform = "true"
  }
}

resource "aws_security_group" "helloworld_public_sg" {
  name = "helloworld-public-sg"
  description = "allows public web traffic"

  vpc_id = module.vpc.vpc_id

  ingress {
    description = "allows http web traffic from anywhere"
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ssh access"
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "allows all outbound traffic"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags = {
    Name = "helloworld-public-sg"
  }
}

resource "aws_security_group" "helloworld_private_sg" {
  name = "helloworld-private-sg"
  description = "private security group only allows traffic within the same vpc"
  vpc_id = module.vpc.vpc_id

  ingress {
    description = "allows inbound traffic only from the other security group"
    from_port = 8080
    to_port = 8080
    protocol = "tcp"
    # restrict source by sg id
    security_groups = [aws_security_group.helloworld_public_sg.id]
  }

  egress {
    description = "allows outbound traffic only within the vpc"
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "helloworld-private-sg"
  }
}

resource "aws_instance" "helloworld_nginx" {
  ami = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
  subnet_id = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.helloworld_public_sg.id]
}

resource "aws_instance" "helloworld_app" {
  ami = data.aws_ami.ubuntu
  instance_type = "t3.micro"
  subnet_id = module.vpc.intra_subnets[0]
  vpc_security_group_ids = [aws_security_group.helloworld_private_sg.id]
}
