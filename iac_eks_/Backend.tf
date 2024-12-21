# Antes de construção da infra, é necessário armazenar em um local seguro o TFstate do Terraform
terraform {
  backend "s3" {}
}