/*
 * Determine most recent ECS optimized AMI
 */
data "aws_ami" "ecs_ami" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn-ami-*-amazon-ecs-optimized"]
  }
}

/*
 * Create ECS cluster
 */
resource "aws_ecs_cluster" "ecs_cluster" {
  name = "ecs-cluster"
}

/*
 * Create ECS IAM Instance Role and Policy
 * Use random id in naming of roles to prevent collisions
 * should other ECS clusters be created in same AWS account
 * using this same code.
 */
resource "random_id" "code" {
  byte_length = 4
}

resource "aws_iam_role" "ecsInstanceRole" {
  name = "ecsInstanceRole-${random_id.code.hex}"

  assume_role_policy = <<EOF
{
 "Version": "2008-10-17",
 "Statement": [
   {
     "Sid": "",
     "Effect": "Allow",
     "Principal": {
       "Service": "ec2.amazonaws.com"
     },
     "Action": "sts:AssumeRole"
   }
 ]
}
EOF
}

resource "aws_iam_role_policy" "ecsInstanceRolePolicy" {
  name = "ecsInstanceRolePolicy-${random_id.code.hex}"
  role = "${aws_iam_role.ecsInstanceRole.id}"

  policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Effect": "Allow",
     "Action": [
       "ecs:CreateCluster",
       "ecs:DeregisterContainerInstance",
       "ecs:DiscoverPollEndpoint",
       "ecs:Poll",
       "ecs:RegisterContainerInstance",
       "ecs:StartTelemetrySession",
       "ecs:Submit*",
       "ecr:GetAuthorizationToken",
       "ecr:BatchCheckLayerAvailability",
       "ecr:GetDownloadUrlForLayer",
       "ecr:BatchGetImage",
       "logs:CreateLogStream",
       "logs:PutLogEvents"
     ],
     "Resource": "*"
   }
 ]
}
EOF
}

/*
 * Create ECS IAM Service Role and Policy
 */
resource "aws_iam_role" "ecsServiceRole" {
  name = "ecsServiceRole-${random_id.code.hex}"

  assume_role_policy = <<EOF
{
 "Version": "2008-10-17",
 "Statement": [
   {
     "Sid": "",
     "Effect": "Allow",
     "Principal": {
       "Service": "ecs.amazonaws.com"
     },
     "Action": "sts:AssumeRole"
   }
 ]
}
EOF
}

resource "aws_iam_role_policy" "ecsServiceRolePolicy" {
  name = "ecsServiceRolePolicy-${random_id.code.hex}"
  role = "${aws_iam_role.ecsServiceRole.id}"

  policy = <<EOF
{
 "Version": "2012-10-17",
 "Statement": [
   {
     "Effect": "Allow",
     "Action": [
       "ec2:AuthorizeSecurityGroupIngress",
       "ec2:Describe*",
       "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
       "elasticloadbalancing:DeregisterTargets",
       "elasticloadbalancing:Describe*",
       "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
       "elasticloadbalancing:RegisterTargets"
     ],
     "Resource": "*"
   }
 ]
}
EOF
}

resource "aws_iam_instance_profile" "ecsInstanceProfile" {
  name = "ecsInstanceProfile-${random_id.code.hex}"
  role = "${aws_iam_role.ecsInstanceRole.name}"
}

/*
 * Create VPC
 */
resource "aws_vpc" "vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "vpc-terraform"
  }
}

/*
 * Get default security group for reference later
 */
data "aws_security_group" "vpc_default_sg" {
  name   = "default"
  vpc_id = "${aws_vpc.vpc.id}"
}

/*
 * Create public and private subnets for each availability zone
 */
resource "aws_subnet" "public_subnet" {
  count             = "${length(var.aws_zones)}"
  vpc_id            = "${aws_vpc.vpc.id}"
  availability_zone = "${element(var.aws_zones, count.index)}"
  cidr_block        = "10.0.${(count.index + 1) * 10}.0/24"

  tags {
    Name = "public-${element(var.aws_zones, count.index)}"
  }
}

resource "aws_subnet" "private_subnet" {
  count             = "${length(var.aws_zones)}"
  vpc_id            = "${aws_vpc.vpc.id}"
  availability_zone = "${element(var.aws_zones, count.index)}"
  cidr_block        = "10.0.${(count.index + 1) * 11}.0/24"

  tags {
    Name = "private-${element(var.aws_zones, count.index)}"
  }
}

/*
 * Create internet gateway for VPC
 */
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = "${aws_vpc.vpc.id}"
}

/*
 * Create NAT gateway and allocate Elastic IP for it
 */
resource "aws_eip" "gateway_eip" {}

resource "aws_nat_gateway" "nat_gateway" {
  allocation_id = "${aws_eip.gateway_eip.id}"
  subnet_id     = "${aws_subnet.public_subnet.0.id}"
  depends_on    = ["aws_internet_gateway.internet_gateway"]
}

/*
 * Routes for private subnets to use NAT gateway
 */
resource "aws_route_table" "nat_route_table" {
  vpc_id = "${aws_vpc.vpc.id}"
}

resource "aws_route" "nat_route" {
  route_table_id         = "${aws_route_table.nat_route_table.id}"
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = "${aws_nat_gateway.nat_gateway.id}"
}

resource "aws_route_table_association" "private_route" {
  count          = "${length(var.aws_zones)}"
  subnet_id      = "${element(aws_subnet.private_subnet.*.id, count.index)}"
  route_table_id = "${aws_route_table.nat_route_table.id}"
}

/*
 * Routes for public subnets to use internet gateway
 */
resource "aws_route_table" "igw_route_table" {
  vpc_id = "${aws_vpc.vpc.id}"
}

resource "aws_route" "igw_route" {
  route_table_id         = "${aws_route_table.igw_route_table.id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = "${aws_internet_gateway.internet_gateway.id}"
}

resource "aws_route_table_association" "public_route" {
  count          = "${length(var.aws_zones)}"
  subnet_id      = "${element(aws_subnet.public_subnet.*.id, count.index)}"
  route_table_id = "${aws_route_table.igw_route_table.id}"
}

/*
 * Create DB Subnet Group for private subnets
 */
resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "db-subnet"
  subnet_ids = ["${aws_subnet.private_subnet.*.id}"]
}

/*
 * Generate user_data from template file
 */
data "template_file" "user_data" {
  template = "${file("${path.module}/user-data.sh")}"

  vars {
    ecs_cluster_name = "${aws_ecs_cluster.ecs_cluster.name}"
  }
}

/*
 * Create Launch Configuration
 */
resource "aws_launch_configuration" "as_conf" {
  image_id             = "${data.aws_ami.ecs_ami.id}"
  instance_type        = "t2.micro"
  security_groups      = ["${data.aws_security_group.vpc_default_sg.id}"]
  iam_instance_profile = "${aws_iam_instance_profile.ecsInstanceProfile.id}"

  root_block_device {
    volume_size = "8"
  }

  user_data = "${data.template_file.user_data.rendered}"

  lifecycle {
    create_before_destroy = true
  }
}

/*
 * Create Auto Scaling Group
 */
resource "aws_autoscaling_group" "asg" {
  name = "asg-${aws_launch_configuration.as_conf.name}"

  //availability_zones        = "${var.aws_zones}"
  vpc_zone_identifier       = ["${aws_subnet.private_subnet.*.id}"]
  min_size                  = "3"
  max_size                  = "3"
  desired_capacity          = "3"
  launch_configuration      = "${aws_launch_configuration.as_conf.id}"
  health_check_type         = "EC2"
  health_check_grace_period = "120"
  default_cooldown          = "30"

  lifecycle {
    create_before_destroy = true
  }
}

/*
 * Create RDS instance
 */
resource "aws_db_instance" "db_instance" {
  engine                 = "mariadb"
  allocated_storage      = "8"
  instance_class         = "db.t2.micro"
  name                   = "mydatabase"
  identifier             = "mydatabase"
  username               = "dbuser"
  password               = "dbpass1234"
  db_subnet_group_name   = "${aws_db_subnet_group.db_subnet_group.name}"
  vpc_security_group_ids = ["${aws_security_group.vpc_default_sg.id}"]
  skip_final_snapshot    = true
}


/*
 * Create security group for public HTTPS access
 */
resource "aws_security_group" "public_http" {
  name        = "public-http"
  description = "Allow HTTP traffic from public"
  vpc_id      = "${aws_vpc.vpc.id}"
}

resource "aws_security_group_rule" "public_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  security_group_id = "${aws_security_group.public_http.id}"
  cidr_blocks       = ["0.0.0.0/0"]
}

/*
 * Create application load balancer
 */
resource "aws_alb" "alb" {
  name            = "alb-myapp"
  internal        = false
  security_groups = ["${aws_security_group.vpc_default_sg.id}", "${aws_security_group.public_http.id}"]
  subnets         = ["${aws_subnet.public_subnet.ids}"]
}

/*
 * Create target group for ALB
 */
resource "aws_alb_target_group" "default" {
  name     = "tg-myapp"
  port     = "80"
  protocol = "HTTP"
  vpc_id   = "${aws_vpc.vpc.id}"

  stickiness {
    type = "lb_cookie"
  }
}

/*
 * Create listeners to connect ALB to target group
 */
resource "aws_alb_listener" "https" {
  load_balancer_arn = "${aws_alb.alb.arn}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_alb_target_group.default.arn}"
    type             = "forward"
  }
}

/*
 * Render task definition from template
 */
data "template_file" "task_def" {
  template = "${file("${path.module}/task-definition.json")}"

  vars {
    mysql_host = "${aws_db_instance.db_instance.address}"
    hostname   = "https://${aws_alb.alb.dns_name}/"
  }
}

/*
 * Create task definition
 */
resource "aws_ecs_task_definition" "td" {
  family                = "myapp"
  container_definitions = "${data.template_file.task_def.rendered}"
  network_mode          = "bridge"
}

/*
 * Create ECS Service
 */
resource "aws_ecs_service" "service" {
  name                               = "myapp"
  cluster                            = "${aws_ecs_cluster.ecs_cluster.name}"
  desired_count                      = "${length(var.aws_zones)}"
  iam_role                           = "${aws_iam_role.ecsServiceRole.arn}"
  deployment_maximum_percent         = "200"
  deployment_minimum_healthy_percent = "50"

  ordered_placement_strategy {
    type  = "spread"
    field = "instanceId"
  }

  load_balancer {
    target_group_arn = "${aws_alb_target_group.default.arn}"
    container_name   = "web"
    container_port   = "80"
  }

  task_definition = "${aws_ecs_task_definition.td.family}:${aws_ecs_task_definition.td.revision}"
}
