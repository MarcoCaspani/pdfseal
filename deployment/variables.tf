variable "region" {
  description = "The AWS region to deploy resources in"
  type        = string
}

variable "iam_user_name" {
  description = "The IAM user name that will create and manage the resources"
  type        = string
}

variable "website_domain" {
  description = "The domain name for the website (e.g., example.com)"
  type        = string
}

variable "pdf_bucket_name" {
  type        = string
  description = "Name of the S3 bucket for PDFs"
}

variable "lambda_function_name" {
    type        = string
    description = "Name of the Lambda function"
}
