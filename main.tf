terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# AWSプロバイダーとリージョンの設定
provider "aws" {
  region = "ap-northeast-1" # 東京リージョン
}

# 利用可能なVPCを検索する
data "aws_vpcs" "all" {}

# 上で見つけたVPCの中から、利用可能なサブネットを検索する
data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = data.aws_vpcs.all.ids
  }
}

# EC2インスタンスに適用するセキュリティグループ
resource "aws_security_group" "web_sg" {
  name        = "web-server-sg"
  description = "Allow HTTP and SSH inbound traffic"

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from anywhere"
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

# EC2インスタンス本体
resource "aws_instance" "web_server" {
  ami           = "ami-0c55b159cbfafe1f0" # Amazon Linux 2 AMI (東京リージョン)
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.web_sg.id]

  # インスタンス起動時に実行されるスクリプト
  user_data = <<-EOF
            #!/bin/bash
            yum update -y
            yum install -y httpd
            systemctl start httpd
            systemctl enable httpd
            echo "<h1>Hello from Terraform on AWS! v2 - Updated!</h1>" > /var/www/html/index.html
            EOF

  tags = {
    Name = "WebServer-from-Terraform"
  }
}

# 完了後にサーバーのURLを出力する
output "website_url" {
  value = "http://${aws_instance.web_server.public_dns}"
}