data "aws_region" "current" {}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

# every connection, accepted or rejected, ends up in the shared log bucket
resource "aws_flow_log" "main" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = "${var.flow_logs_bucket_arn}/${var.name}/"
  max_aggregation_interval = 60

  tags = { Name = var.name }
}

# with no rules, anything placed in the default group by mistake can't talk to anything
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = var.name }
}

# only the nat gateway and load balancers live here, so nothing gets a public ip by default
resource "aws_subnet" "public" {
  count = length(var.zone_ids)

  vpc_id               = aws_vpc.main.id
  availability_zone_id = var.zone_ids[count.index]
  cidr_block           = cidrsubnet(var.vpc_cidr, 8, count.index)

  tags = {
    Name                     = "${var.name}-public-${var.zone_ids[count.index]}"
    "kubernetes.io/role/elb" = "1"
  }
}

# every pod takes an address from these subnets, hence /19 each
resource "aws_subnet" "private" {
  count = length(var.zone_ids)

  vpc_id               = aws_vpc.main.id
  availability_zone_id = var.zone_ids[count.index]
  cidr_block           = cidrsubnet(var.vpc_cidr, 3, count.index + 1)

  tags = {
    Name                              = "${var.name}-private-${var.zone_ids[count.index]}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.name}-nat" }
}

# a single nat in one zone: if that zone fails, the nodes lose internet access; accepted to pay for one nat, not two
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = { Name = var.name }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count = length(var.zone_ids)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  count = length(var.zone_ids)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ecr serves image layers from s3, so this free endpoint keeps most pull traffic off the paid nat
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-s3" }
}
