provider "aws" {
  region = "us-east-1"
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

# 1. PUBLIC NGINX PROXY INSTANCE
resource "aws_instance" "helloworld_proxy" {
  ami                    = "ami-0c7217cdde317cfec" # Standard Amazon Linux 2023 AMI
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.helloworld_public_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              # Install Nginx
              dnf install -y nginx
              systemctl enable nginx

              # Configure the Reverse Proxy pointing to the instance Private DNS
              # Replace with your actual backend DNS name or dynamic variable
              cat << 'NGINX_CONF' > /etc/nginx/conf.d/go_proxy.conf
              server {
                  listen 80;
                  server_name _;
                  location / {
                      proxy_pass http://ec2.internal;
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

# 2. ISOLATED APP INSTANCE
resource "aws_instance" "helloworld_app" {
  ami                    = "ami-0c7217cdde317cfec"
  instance_type          = "t3.micro"
  subnet_id              = module.vpc.intra_subnets[0]
  vpc_security_group_ids = [aws_security_group.helloworld_private_sg.id]

  user_data = <<-EOF
              #!/bin/bash
              # Create app directory structure
              mkdir -p /opt/myapp
              cd /opt/myapp

              # Download your binary (Example: pulling from a secure S3 bucket)
              # Note: Requires an IAM instance profile attached to the EC2 to
              # access S3
              aws s3 cp s3://my-deployment-bucket/my-app-binary .
              chmod +x my-app-binary

              # Create the systemd service file dynamically
              cat << 'SERVICE' > /etc/systemd/system/myapp.service
              [Unit]
              Description=Web Application
              After=network.target

              [Service]
              Type=simple
              User=ec2-user
              WorkingDirectory=/opt/myapp
              ExecStart=/opt/myapp/my-app-binary
              Restart=always

              [Install]
              WantedBy=multi-user.target
              SERVICE

              # Start the application
              systemctl daemon-reload
              systemctl enable myapp.service
              systemctl start myapp.service
              EOF

  tags = {
    Name = "helloworld-app"
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

