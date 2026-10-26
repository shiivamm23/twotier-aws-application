resource "aws_ecr_repository" "app" {
  name         = "${var.project}-app"
  force_delete = true # lets 'terraform destroy' delete the repo even with images

  image_scanning_configuration {
    scan_on_push = true
  }
}
