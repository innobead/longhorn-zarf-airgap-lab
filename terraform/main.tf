data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# --- Network -------------------------------------------------------------------
# One subnet, two route tables. While var.airgap = false the node routes to the internet
# (bootstrap + `lab prep` build every package). Flipping var.airgap = true swaps in a
# route table with no internet route; SSM (interface endpoints) and S3 (gateway endpoint)
# keep working, so the node stays manageable and `lab sync` still works.

data "aws_ec2_instance_type_offerings" "az" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

locals {
  az = coalesce(var.availability_zone, sort(data.aws_ec2_instance_type_offerings.az.locations)[0])
}

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "node" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 0)
  availability_zone       = local.az
  map_public_ip_on_launch = true
  tags                    = { Name = local.name }
}

resource "aws_route_table" "online" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
  tags = { Name = "${local.name}-online" }
}

# VPC-local route only, plus the S3 gateway endpoint route.
resource "aws_route_table" "airgap" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${local.name}-airgap" }
}

resource "aws_route_table_association" "node" {
  subnet_id      = aws_subnet.node.id
  route_table_id = var.airgap ? aws_route_table.airgap.id : aws_route_table.online.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.lab.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.online.id, aws_route_table.airgap.id]
  tags              = { Name = "${local.name}-s3" }
}

resource "aws_security_group" "endpoints" {
  name   = "${local.unique}-endpoints"
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "${local.name}-endpoints" }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_subnet.node.cidr_block]
  }
}

resource "aws_vpc_endpoint" "ssm" {
  for_each            = toset(["ssm", "ssmmessages", "ec2messages"])
  vpc_id              = aws_vpc.lab.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.node.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "${local.name}-${each.key}" }
}

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name   = "${var.prefix}-${var.name}"
  unique = "${local.name}-${random_id.suffix.hex}"
}

# --- Lab content (packages + scripts) shipped to the VM via S3 ---------------

resource "aws_s3_bucket" "lab" {
  bucket        = local.unique
  force_destroy = true
  tags          = { Name = local.unique }
}

resource "aws_s3_bucket_public_access_block" "lab" {
  bucket                  = aws_s3_bucket.lab.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  lab_root  = "${path.module}/.."
  lab_files = setunion(fileset(local.lab_root, "packages/**"), fileset(local.lab_root, "scripts/**"), fileset(local.lab_root, "tests/**"))
}

resource "aws_s3_object" "lab" {
  for_each = local.lab_files
  bucket   = aws_s3_bucket.lab.id
  key      = each.value
  source   = "${local.lab_root}/${each.value}"
  etag     = filemd5("${local.lab_root}/${each.value}")
}

# --- IAM: SSM Session Manager + read the lab bucket --------------------------------

resource "aws_iam_role" "node" {
  name = local.unique
  tags = { Name = local.unique }
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "lab_bucket" {
  role = aws_iam_role.node.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.lab.arn },
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.lab.arn}/*" },
    ]
  })
}

resource "aws_iam_instance_profile" "node" {
  name = local.unique
  role = aws_iam_role.node.name
  tags = { Name = local.unique }
}

# --- Security group: no inbound (access is via SSM) --------------------------------
# Air-gapped egress: HTTPS to the VPC (SSM endpoints) and the S3 prefix list only. The
# route table already blocks the internet; this keeps the SG honest too.

data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${var.region}.s3"
}

resource "aws_security_group" "node" {
  name   = local.unique
  vpc_id = aws_vpc.lab.id
  tags   = { Name = local.name }

  dynamic "egress" {
    for_each = var.airgap ? [] : [1]
    content {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  dynamic "egress" {
    for_each = var.airgap ? [1] : []
    content {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  dynamic "egress" {
    for_each = var.airgap ? [1] : []
    content {
      from_port       = 443
      to_port         = 443
      protocol        = "tcp"
      prefix_list_ids = [data.aws_ec2_managed_prefix_list.s3.id]
    }
  }
}

# --- Node: single-node K3s -----------------------------------------------------------

resource "aws_instance" "node" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.node.id
  vpc_security_group_ids      = [aws_security_group.node.id]
  iam_instance_profile        = aws_iam_instance_profile.node.name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    bucket       = aws_s3_bucket.lab.id
    region       = var.region
    zarf_version = var.zarf_version
    v1_disk_gb   = var.v1_disk_gb
    v2_disk_gb   = var.v2_disk_gb
    auto_prep    = var.auto_prep
  })

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
    tags                  = { Name = "${local.name}-root" }
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    tags                  = { Name = "${local.name}-longhorn-v1" }
    volume_size           = var.v1_disk_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  ebs_block_device {
    device_name           = "/dev/sdg"
    tags                  = { Name = "${local.name}-longhorn-v2" }
    volume_size           = var.v2_disk_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = { Name = local.name }

  depends_on = [
    aws_route_table_association.node, aws_vpc_endpoint.s3, aws_vpc_endpoint.ssm,
    aws_s3_object.lab, aws_iam_role_policy.lab_bucket, aws_iam_role_policy_attachment.ssm,
  ]

  lifecycle {
    ignore_changes = [ami]
    precondition {
      condition     = var.v1_disk_gb != var.v2_disk_gb && var.v1_disk_gb != var.root_volume_gb && var.v2_disk_gb != var.root_volume_gb
      error_message = "root_volume_gb, v1_disk_gb and v2_disk_gb must all differ (disks are identified by size)."
    }
  }
}
