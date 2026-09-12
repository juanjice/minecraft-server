data "aws_vpc" "default" {
  default = true
}

data "aws_internet_gateway" "default" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_subnet" "minecraft" {
  vpc_id            = data.aws_vpc.default.id
  cidr_block        = var.subnet_cidr
  availability_zone = var.availability_zone

  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-subnet" }
}

resource "aws_route_table" "minecraft" {
  vpc_id = data.aws_vpc.default.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = data.aws_internet_gateway.default.id
  }

  tags = { Name = "${var.project_name}-rt" }
}

resource "aws_route_table_association" "minecraft" {
  subnet_id      = aws_subnet.minecraft.id
  route_table_id = aws_route_table.minecraft.id
}

resource "aws_security_group" "minecraft" {
  name        = "${var.project_name}-sg"
  description = "Acceso SSH administrativo y puerto del servidor Minecraft"
  vpc_id      = data.aws_vpc.default.id

  tags = { Name = "${var.project_name}-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.ssh_allowed_cidrs)

  security_group_id = aws_security_group.minecraft.id
  description       = "SSH"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "minecraft" {
  for_each = toset(var.minecraft_allowed_cidrs)

  security_group_id = aws_security_group.minecraft.id
  description       = "Minecraft Java Edition"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = var.server_port
  to_port           = var.server_port
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.minecraft.id
  description       = "Salida libre: paquetes de Ubuntu, jar de Paper, API de Mojang"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
