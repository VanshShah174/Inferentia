# =============================================================================
# VPC module — network foundation for the EKS platform
# =============================================================================
# Builds a standard public/private VPC across N availability zones:
#   - 1 public subnet + 1 private subnet PER AZ
#   - Internet Gateway for public egress
#   - 1 NAT Gateway (single, cost-conscious) for private subnet egress
#   - route tables wiring public->IGW and private->NAT
#
# Terraform concepts demonstrated here:
#   - locals + for expressions to BUILD a subnet map (name -> {az, cidr})
#   - cidrsubnet() to carve subnet CIDRs deterministically from the VPC CIDR
#   - for_each (not count) for stable, name-keyed subnet addressing
#   - EKS discovery tags (kubernetes.io/role/*) so the AWS LB controller and
#     EKS can auto-discover subnets
# =============================================================================

locals {
  az_count = length(var.availability_zones)

  # Build a map of PUBLIC subnets: key -> { az, cidr }.
  # cidrsubnet(prefix, newbits, netnum): split the /16 into /20s.
  # Public subnets take netnum 0..az_count-1.
  public_subnets = {
    for idx, az in var.availability_zones :
    "public-${az}" => {
      az   = az
      cidr = cidrsubnet(var.vpc_cidr, 4, idx)
    }
  }

  # Private subnets take netnum az_count..2*az_count-1 (a distinct block).
  private_subnets = {
    for idx, az in var.availability_zones :
    "private-${az}" => {
      az   = az
      cidr = cidrsubnet(var.vpc_cidr, 4, idx + local.az_count)
    }
  }
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for EKS private DNS

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway (public egress)
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# -----------------------------------------------------------------------------
# Public subnets (for_each over the built map)
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-${each.key}"
    # EKS + AWS Load Balancer Controller discover PUBLIC subnets via this tag
    "kubernetes.io/role/elb" = "1"
  }
}

# -----------------------------------------------------------------------------
# Private subnets (for_each over the built map)
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name = "${var.name_prefix}-${each.key}"
    # EKS discovers PRIVATE subnets (for internal LBs / nodes) via this tag
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# -----------------------------------------------------------------------------
# NAT Gateway (single, cost-conscious) — placed in the FIRST public subnet
# -----------------------------------------------------------------------------
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "${var.name_prefix}-nat-eip"
  }
}

resource "aws_nat_gateway" "this" {
  # Put the NAT in the first public subnet (deterministic pick).
  allocation_id = aws_eip.nat.id
  subnet_id     = values(aws_subnet.public)[0].id

  tags = {
    Name = "${var.name_prefix}-nat"
  }

  depends_on = [aws_internet_gateway.this]
}

# -----------------------------------------------------------------------------
# Route tables
# -----------------------------------------------------------------------------
# Public: default route -> IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "${var.name_prefix}-rt-public"
  }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private: default route -> NAT
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags = {
    Name = "${var.name_prefix}-rt-private"
  }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
