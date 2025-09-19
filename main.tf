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

# --- ▼▼▼ ここから追加 ▼▼▼ ---
# このリージョンで利用可能なVPCを検索する
data "aws_vpcs" "all" {}

# 上で見つかったVPCに属するサブネットを検索する
data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = data.aws_vpcs.all.ids
  }
}
# --- ▲▲▲ ここまで追加 ▲▲▲ ---

# EC2インスタンスに適用するセキュリティグループ
resource "aws_security_group" "web_sg" {
  name        = "web-server-sg"
  description = "Allow HTTP and SSH inbound traffic"
  # どのVPCに作成するかを明示的に指定
  vpc_id      = data.aws_vpcs.all.ids[0] # <-- 変更点

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
    cidr_blocks = ["0.0.0.0/0"]
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
  ami           = "ami-0c55b159cbfafe1f0" 
  instance_type = "t2.micro"
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  # どのサブネットに配置するかを明示的に指定
  subnet_id     = data.aws_subnets.selected.ids[0] # <-- 変更点
  # パブリックIPアドレスを自動で割り当てる設定
  associate_public_ip_address = true # <-- 重要な追加点

  user_data = <<-EOF
            #!/bin/bash
            yum update -y
            yum install -y httpd
            systemctl start httpd
            systemctl enable httpd
            echo "<h1>Hello from Terraform on AWS! v1</h1>" > /var/www/html/index.html
            EOF
  
  tags = {
    Name = "WebServer-from-Terraform"
  }
}

# 完了後にサーバーのURLを出力する
output "website_url" {
  value = "http://${aws_instance.web_server.public_dns}"
}