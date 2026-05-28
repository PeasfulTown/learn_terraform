provider "aws" {
  region = "us-east-1"
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  filter {
    name   = "name"
    values = ["al2023-ami-2023*"]
  }

  filter {
    name   = "free-tier-eligible"
    values = ["true"]
  }

  owners = ["amazon"]
}

resource "aws_instance" "helloworld_public_instance" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.helloworld_public_1_subnet.id
  vpc_security_group_ids = [aws_security_group.helloworld_public_sg.id]

  tags = {
    Name = "helloworld-public-instance"
  }
}

resource "aws_instance" "helloworld_private_instance" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.helloworld_private_1_subnet.id
  vpc_security_group_ids = [aws_security_group.helloworld_private_sg.id]

  tags = {
    Name = "helloworld-private-instance"
  }
}

resource "aws_security_group" "helloworld_public_sg" {
  name        = "helloworld-public-sg"
  description = "security group for hello world public ec2 instances"

  vpc_id = aws_vpc.helloworld_vpc.id

  ingress {
    description = "allows ssh from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "allows all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "helloworld-public-ec2-sg"
  }
}

resource "aws_security_group" "helloworld_private_sg" {
  name        = "helloworld-private-sg"
  description = "security group for hello world private ec2 instances"

  vpc_id = aws_vpc.helloworld_vpc.id

  ingress {
    description = "allows ssh only from within the vpc"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.helloworld_vpc.cidr_block]
  }

  egress {
    description = "allows all outbound traffic via NAT gateway"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 means all protocols
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "helloworld-private-ec2-sg"
  }
}

# main vpc
resource "aws_vpc" "helloworld_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "helloworld-vpc"
  }
}

# public subnet
resource "aws_subnet" "helloworld_public_1_subnet" {
  vpc_id     = aws_vpc.helloworld_vpc.id
  cidr_block = "10.0.101.0/24"

  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true # makes it public subnet

  tags = {
    Name = "helloworld-subnet-public-1"
  }
}

# internet gateway
resource "aws_internet_gateway" "helloworld_igw" {
  vpc_id = aws_vpc.helloworld_vpc.id

  tags = {
    Name = "helloworld-igw"
  }
}

# custom route table for public traffic
resource "aws_route_table" "helloworld_public_rt" {
  vpc_id = aws_vpc.helloworld_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.helloworld_igw.id
  }

  tags = {
    Name = "helloworld-public-rt"
  }
}

# assosiate the route table to the public subnet
resource "aws_route_table_association" "helloworld_public_1_assoc" {
  subnet_id      = aws_subnet.helloworld_public_1_subnet.id
  route_table_id = aws_route_table.helloworld_public_rt.id
}

# private subnet
resource "aws_subnet" "helloworld_private_1_subnet" {
  vpc_id     = aws_vpc.helloworld_vpc.id
  cidr_block = "10.0.201.0/24"

  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false

  tags = {
    Name = "helloworld-subnet-private-1"
  }
}

# allocate elastic ip for NAT gateway
resource "aws_eip" "helloworld_nat_eip" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.helloworld_igw]

  tags = {
    Name = "helloworld-nat-eip"
  }
}

resource "aws_nat_gateway" "helloworld_nat" {
  allocation_id = aws_eip.helloworld_nat_eip.id
  # nat gateway must reside on the public subnet
  subnet_id = aws_subnet.helloworld_public_1_subnet.id

  tags = {
    Name = "helloworld-nat-gateway"
  }

  # ensure proper ordering of resource creation
  # nat gateway creation will fail if the internet gateway
  # isn't ready
  depends_on = [aws_internet_gateway.helloworld_igw]
}

# route table for the private subnet
resource "aws_route_table" "helloworld_private_rt" {
  vpc_id = aws_vpc.helloworld_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    # route traffic to NAT instead of internet gateway
    nat_gateway_id = aws_nat_gateway.helloworld_nat.id
  }

  tags = {
    Name = "helloworld-private-rt"
  }
}

# associate private subnet to its route table
resource "aws_route_table_association" "helloworld_private_1_assoc" {
  subnet_id      = aws_subnet.helloworld_private_1_subnet.id
  route_table_id = aws_route_table.helloworld_private_rt.id
}
