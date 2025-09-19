terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

# --- 1. ネットワークインフラ ---

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "main-vpc"
  }
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
  tags = {
    Name = "main-igw"
  }
}

# パブリックサブネットa (ap-northeast-1a)
resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-1a"
  map_public_ip_on_launch = true
  tags = {
    Name = "public-subnet-a"
  }
}

# パブリックサブネットc (ap-northeast-1c)
resource "aws_subnet" "public_c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = "ap-northeast-1c"
  map_public_ip_on_launch = true
  tags = {
    Name = "public-subnet-c"
  }
}

# プライベートサブネットa (ap-northeast-1a)
resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-1a"
  tags = {
    Name = "private-subnet-a"
  }
}

# プライベートサブネットc (ap-northeast-1c)
resource "aws_subnet" "private_c" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "ap-northeast-1c"
  tags = {
    Name = "private-subnet-c"
  }
}

resource "aws_eip" "nat" {
  tags = { Name = "nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_a.id
  depends_on    = [aws_internet_gateway.gw]
  tags = { Name = "main-nat-gw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = { Name = "public-rt" }
}

resource "aws_route_table_association" "public_a" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "public_c" {
  subnet_id      = aws_subnet.public_c.id
  route_table_id = aws_route_table.public.id
}


resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "private-rt" }
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}
resource "aws_route_table_association" "private_c" {
  subnet_id      = aws_subnet.private_c.id
  route_table_id = aws_route_table.private.id
}

# --- 2. S3とVPCエンドポイント ---
resource "aws_s3_bucket" "image_bucket" {
  bucket = "my-unique-image-bucket-20250919"
  tags = { Name = "Image Bucket" }
}
resource "aws_vpc_endpoint" "s3" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.ap-northeast-1.s3"
  route_table_ids = [aws_route_table.private.id]
}

# --- 3. セキュリティグループ ---
resource "aws_security_group" "alb" {
  name        = "alb-sg"
  description = "Allow HTTP from anywhere"
  vpc_id      = aws_vpc.main.id
  ingress {
    description = "HTTP from public"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "bastion" {
  name        = "bastion-sg"
  description = "Allow SSH from anywhere"
  vpc_id      = aws_vpc.main.id
  ingress {
    description = "SSH from public"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "web" {
  name        = "web-server-sg"
  description = "Allow SSH from Bastion and HTTP from ALB"
  vpc_id      = aws_vpc.main.id
  ingress {
    description     = "SSH from Bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }
  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- 4. ALB関連のリソース ---
resource "aws_lb" "main" {
  name               = "main-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_a.id, aws_subnet.public_c.id]
  tags = {
    Name = "main-alb"
  }
}
resource "aws_lb_target_group" "web" {
  name     = "web-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check {
    path = "/"
  }
  tags = {
    Name = "web-tg"
  }
}

# ## 変更点 ## ALBターゲットを2台分に修正
resource "aws_lb_target_group_attachment" "web_a" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web_server_a.id
  port             = 80
}
resource "aws_lb_target_group_attachment" "web_c" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web_server_c.id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# --- 5. EC2インスタンス ---
resource "aws_eip" "bastion" {
  tags = { Name = "bastion-eip" }
}
resource "aws_instance" "bastion" {
  ami           = "ami-08f0737412a47a5ed" # Amazon Linux 2023
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_a.id # 踏み台はAZ 'a' に配置
  vpc_security_group_ids = [aws_security_group.bastion.id]
  tags = { Name = "Bastion-Host" }
}
resource "aws_eip_association" "bastion" {
  instance_id   = aws_instance.bastion.id
  allocation_id = aws_eip.bastion.id
}

# ## 変更点 ## Webサーバを2台に増やし、AZ 'a' と 'c' に分散
resource "aws_instance" "web_server_a" {
  ami           = "ami-08f0737412a47a5ed" # Amazon Linux 2023
  instance_type = "m5.large"
  subnet_id     = aws_subnet.private_a.id # AZ 'a' のプライベートサブネットに配置
  vpc_security_group_ids = [aws_security_group.web.id]
  user_data = <<-EOF
            #!/bin/bash
            yum update -y
            yum install -y httpd
            systemctl start httpd
            systemctl enable httpd
            echo "<h1>Hello from AZ-a!</h1>" > /var/www/html/index.html
            EOF
  tags = { Name = "WebServer-Private-a" }
}

resource "aws_instance" "web_server_c" {
  ami           = "ami-0c55b159cbfafe1f0" # Amazon Linux 2
  instance_type = "m5.large"
  subnet_id     = aws_subnet.private_c.id # AZ 'c' のプライベートサブネットに配置
  vpc_security_group_ids = [aws_security_group.web.id]
  user_data = <<-EOF
            #!/bin/bash
            yum update -y
            yum install -y httpd
            systemctl start httpd
            systemctl enable httpd
            echo "<h1>Hello from AZ-c!</h1>" > /var/www/html/index.html
            EOF
  tags = { Name = "WebServer-Private-c" }
}

# --- 6. 出力 ---
output "alb_dns_name" {
  description = "DNS name of the ALB"
  value       = aws_lb.main.dns_name
}
output "bastion_public_ip" {
  description = "Public IP address of the Bastion Host"
  value       = aws_eip.bastion.public_ip
}

# ## 変更点 ## Webサーバが複数台になったためリストで出力
output "web_server_private_ips" {
  description = "Private IP addresses of the Web Servers"
  value       = [aws_instance.web_server_a.private_ip, aws_instance.web_server_c.private_ip]
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for images"
  value       = aws_s3_bucket.image_bucket.id
}

terraform {
  backend "s3" {
    bucket         = "my-terraform-state-bucket-20250919"
    key            = "path/to/your/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "terraform-locks"
  }
}