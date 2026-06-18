# original source: https://medium.com/@olayinkasamuel44/using-terraform-and-fargate-to-create-amazons-ecs-e3308c1b9166

resource "aws_alb" "main" {
  name            = "cb-load-balancer"
  subnets         = aws_subnet.public.*.id
  security_groups = [aws_security_group.lb.id]
}

resource "aws_alb_target_group" "app" {
  name        = "cb-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    healthy_threshold   = "3"
    interval            = "30"
    protocol            = "HTTP"
    matcher             = "200"
    timeout             = "3"
    path                = var.health_check_path
    unhealthy_threshold = "2"
  }
}

# Redirect all traffic from the ALB to the target group
resource "aws_alb_listener" "front_end" {
  load_balancer_arn = aws_alb.main.id
  port              = var.app_port
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_alb_target_group.app.id
    type             = "forward"
  }
}

# ---------------------------------------------------------------------------
# PRODUCTION HTTPS LISTENER  (cert-gated; inert by default)
#
# KNOWN GAP: the HTTP listener above terminates in cleartext, so the CI bearer
# token and the submitted source code cross the network unencrypted. The fix is
# a TLS-terminating 443 listener. It is gated on var.certificate_arn, so it
# becomes ZERO resources when that var is empty (the default). In the AWS
# Academy lab there is no domain to validate a public ACM cert against, which is
# why this is staged-but-off rather than enabled -- the demo runs HTTP-only and
# `terraform plan` shows no change from this block.
#
# To turn it on in production:
#   1. Request an ACM cert for a domain (e.g. sast.example.com); pass its ARN
#      as var.certificate_arn.
#   2. Open 443 on the ALB security group "lb" (security.tf): add an ingress
#      from_port = to_port = 443 (ideally scoped to GitHub Actions IP ranges,
#      not 0.0.0.0/0).
#   3. Convert the HTTP listener above into a 301 redirect to 443 (replace its
#      default_action with:
#        redirect { port = "443" protocol = "HTTPS" status_code = "HTTP_301" })
#      so nothing is ever served in the clear.
#   4. Set the GitHub secret SCANNER_URL to https://<domain>.
# ---------------------------------------------------------------------------
resource "aws_alb_listener" "front_end_https" {
  count = var.certificate_arn != "" ? 1 : 0

  load_balancer_arn = aws_alb.main.id
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    target_group_arn = aws_alb_target_group.app.id
    type             = "forward"
  }
}