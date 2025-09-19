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

# パブリックサブネット (踏み台、NATゲートウェイ用)
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true # このサブネットではパブリックIPを自動割当
  tags = {
    Name = "public-subnet"
  }
}

# プライベートサブネット (Webサーバ用)
resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.2.0/24"
  tags = {
    Name = "private-subnet"
  }
}

# NATゲートウェイ用のEIP
resource "aws_eip" "nat" {
  tags = {
    Name = "nat-eip"
  }
}

# NATゲートウェイ (プライベートサブネットからのアウトバウンド通信用)
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.gw]
  tags = {
    Name = "main-nat-gw"
  }
}

# パブリックルートテーブル (インターネット向け)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
  tags = {
    Name = "public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# プライベートルートテーブル (NATゲートウェイ向け)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = {
    Name = "private-rt"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# --- 2. S3とVPCエンドポイント ---

resource "aws_s3_bucket" "image_bucket" {
  # 注意: S3バケット名は全世界で一意である必要があります。
  # 実際に使用する際は、よりユニークな名前に変更してください。
  bucket = "my-unique-image-bucket-20250919"
  tags = {
    Name = "Image Bucket"
  }
}

# S3へのゲートウェイ型VPCエンドポイント
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.ap-northeast-1.s3"
  route_table_ids   = [aws_route_table.private.id] # プライベートサブネットからS3へアクセス可能にする
}


# --- 3. セキュリティグループ ---

# 踏み台サーバ用セキュリティグループ
resource "aws_security_group" "bastion" {
  name        = "bastion-sg"
  description = "Allow SSH from anywhere"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from public"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # 本番環境ではIPを制限してください
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Webサーバ用セキュリティグループ
resource "aws_security_group" "web" {
  name        = "web-server-sg"
  description = "Allow SSH from Bastion and HTTP from VPC"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH from Bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id] # 踏み台SGからのみ許可
  }

  ingress {
    description = "HTTP from anywhere in VPC (e.g. for Load Balancer)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # VPC内部からのみ許可
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


# --- 4. EC2インスタンス ---

# 踏み台サーバ用のEIP
resource "aws_eip" "bastion" {
  tags = {
    Name = "bastion-eip"
  }
}

# 踏み台サーバ (パブリックサブネットに配置)
resource "aws_instance" "bastion" {
  ami           = "ami-0c55b159cbfafe1f0" # Amazon Linux 2
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  
  tags = {
    Name = "Bastion-Host"
  }
}

# EIPと踏み台サーバを関連付け
resource "aws_eip_association" "bastion" {
  instance_id   = aws_instance.bastion.id
  allocation_id = aws_eip.bastion.id
}

# Webサーバ (プライベートサブネットに配置)
resource "aws_instance" "web_server" {
  ami           = "ami-08a59875ad2a26a5f"
  instance_type = "m5.large"
  subnet_id     = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOF
            #!/bin/bash
            yum update -y
            yum install -y httpd
            systemctl start httpd
            systemctl enable httpd
            echo "<h1>Hello from a Private Subnet!</h1>" > /var/www/html/index.html
            EOF
  
  tags = {
    Name = "WebServer-Private"
  }
}


# --- 5. 出力 ---

output "bastion_public_ip" {
  description = "Public IP address of the Bastion Host"
  value       = aws_eip.bastion.public_ip
}

output "web_server_private_ip" {
  description = "Private IP address of the Web Server"
  value       = aws_instance.web_server.private_ip
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket for images"
  value       = aws_s3_bucket.image_bucket.id
}