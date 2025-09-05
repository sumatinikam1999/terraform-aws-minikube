#####
# Setup AWS provider
# (Retrieve AWS credentials from env variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY)
#####

provider "aws" {
  region = var.aws_region
}

#####
# Generate kubeadm token
#####

module "kubeadm-token" {
  source = "scholzj/kubeadm-token/random"
}

#####
# Security Group
#####

data "aws_subnet" "minikube_subnet" {
  id = var.aws_subnet_id
}

resource "aws_security_group" "minikube" {
  vpc_id = data.aws_subnet.minikube_subnet.vpc_id
  name   = var.cluster_name

  tags = merge(
    {
      "Name"                                               = var.cluster_name
      format("kubernetes.io/cluster/%v", var.cluster_name) = "owned"
    },
    var.tags,
  )

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_access_cidr]
  }

  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.api_access_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#####
# IAM role
#####

resource "aws_iam_policy" "minikube_policy" {
  name        = var.cluster_name
  path        = "/"
  description = "Policy for role ${var.cluster_name}"
  policy      = file("${path.module}/template/policy.json.tpl")
}

resource "aws_iam_role" "minikube_role" {
  name = var.cluster_name

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF

}

resource "aws_iam_policy_attachment" "minikube-attach" {
  name       = "minikube-attachment"
  roles      = [aws_iam_role.minikube_role.name]
  policy_arn = aws_iam_policy.minikube_policy.arn
}

resource "aws_iam_instance_profile" "minikube_profile" {
  name = var.cluster_name
  role = aws_iam_role.minikube_role.name
}

##########
# Bootstraping scripts
##########

data "cloudinit_config" "minikube_cloud_init" {
  gzip          = true
  base64_encode = true

  part {
    filename     = "init-aws-minikube.sh"
    content_type = "text/x-shellscript"
    content      = templatefile("${path.module}/scripts/init-aws-minikube.sh", { kubeadm_token = module.kubeadm-token.token, dns_name = "${var.cluster_name}.${var.hosted_zone}", ip_address = aws_eip.minikube.public_ip, cluster_name = var.cluster_name, kubernetes_version = var.kubernetes_version, aws_region = var.aws_region, addons = join(" ", var.addons) })
  }
}

##########
# Keypair
##########

resource "aws_key_pair" "minikube_keypair" {
  key_name   = var.cluster_name
  public_key = file(var.ssh_public_key)
}

#####
# EC2 instance
#####

data "aws_ami" "centos_linux" {
  most_recent = true
  owners      = ["125523088429"]

  filter {
    name   = "name"
    values = ["CentOS Stream 10 x86_64 202*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_eip" "minikube" {
  domain = "vpc"
}

resource "aws_instance" "minikube" {
  # Instance type - any of the c4 should do for now
  instance_type = var.aws_instance_type

  ami = length(var.ami_image_id) > 0 ? var.ami_image_id : data.aws_ami.centos_linux.id

  key_name = aws_key_pair.minikube_keypair.key_name

  subnet_id = var.aws_subnet_id

  associate_public_ip_address = false

  vpc_security_group_ids = [
    aws_security_group.minikube.id,
  ]

  iam_instance_profile = aws_iam_instance_profile.minikube_profile.name

  user_data_base64 = "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"

  tags = merge(
    {
      "Name"                                               = var.cluster_name
      format("kubernetes.io/cluster/%v", var.cluster_name) = "owned"
    },
    var.tags,
  )

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp2"
    volume_size           = "50"
    delete_on_termination = true
  }

  lifecycle {
    ignore_changes = [
      ami,
      user_data,
      associate_public_ip_address,
    ]
  }
}

resource "aws_eip_association" "minikube_assoc" {
  instance_id   = aws_instance.minikube.id
  allocation_id = aws_eip.minikube.id
}

#####
# DNS record
#####

data "aws_route53_zone" "dns_zone" {
  name         = "${var.hosted_zone}."
  private_zone = var.hosted_zone_private
}

resource "aws_route53_record" "minikube" {
  zone_id = data.aws_route53_zone.dns_zone.zone_id
  name    = "${var.cluster_name}.${var.hosted_zone}"
  type    = "A"
  records = [aws_eip.minikube.public_ip]
  ttl     = 300
}

