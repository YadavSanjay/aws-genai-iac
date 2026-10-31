# Subnets and route tables.
#
# Public and private tiers across N availability zones, with a public route
# table pointing at the IGW and one private route table per AZ.
#
# NO NAT route. Private subnets have local routes only until an egress device
# exists — see docs/design/aws-service-consolidation.md §2a for why that is a
# scheduled NAT instance rather than a NAT Gateway.

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Public occupies the low indices, private a clearly separated block, so the
  # tier is obvious from the CIDR alone when reading a route table.
  public_subnets = {
    for idx, az in local.azs : az => {
      cidr  = cidrsubnet(var.vpc_cidr, var.subnet_newbits, idx)
      index = idx
    }
  }

  private_subnets = {
    for idx, az in local.azs : az => {
      cidr  = cidrsubnet(var.vpc_cidr, var.subnet_newbits, var.private_subnet_offset + idx)
      index = idx
    }
  }
}

# --- Subnets -----------------------------------------------------------------

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id            = var.vpc_id
  availability_zone = each.key
  cidr_block        = each.value.cidr

  # FALSE even for public subnets. Auto-assignment means a workload becomes
  # internet-addressable purely by landing here, with no explicit decision
  # anywhere in code. Anything that genuinely needs a public address requests
  # one at launch, which is visible in a plan and in review.
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-${each.key}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = var.vpc_id
  availability_zone = each.key
  cidr_block        = each.value.cidr

  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-${each.key}"
    Tier = "private"
  })
}

# --- Public route table ------------------------------------------------------
# One shared table: every public subnet wants the same default route.

resource "aws_route_table" "public" {
  vpc_id = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public"
    Tier = "public"
  })
}

resource "aws_route" "public_default" {
  count = var.internet_gateway_id != "" ? 1 : 0

  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = var.internet_gateway_id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# --- Private route tables ----------------------------------------------------
# One PER AZ rather than one shared. Route tables are free, and per-AZ tables
# let a future egress device be reached without crossing an AZ boundary — which
# would otherwise incur cross-AZ data charges in both directions. Costs nothing
# now, avoids a migration later.
#
# These carry only the local route until an egress device exists.

resource "aws_route_table" "private" {
  for_each = local.private_subnets

  vpc_id = var.vpc_id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-${each.key}"
    Tier = "private"
  })
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}
