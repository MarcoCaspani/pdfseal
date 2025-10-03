terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.99.1"
    }
  }
}

provider "aws" {
    region = var.region
}

# -------------------
# S3 Bucket declarations

# Create an S3 bucket to put the PDF to be watermarked
resource "aws_s3_bucket" "pdf_bucket" {
  bucket = var.pdf_bucket_name # must be globally unique
}

# Enable versioning on the bucket (optional, to keep track of changes if you update the master PDF)
resource "aws_s3_bucket_versioning" "pdf_bucket_versioning" {
 bucket = aws_s3_bucket.pdf_bucket.id
 versioning_configuration {
   status = "Enabled"
 }
}

# Upload the master PDF to the bucket
resource "aws_s3_object" "master_pdf" {
  bucket = aws_s3_bucket.pdf_bucket.id
  key    = "pdfs/master.pdf"
  source = "${path.module}/../assets/master.pdf"
  etag   = filemd5("${path.module}/../assets/master.pdf")
}

# Attach a policy to the Lambda execution role to allow reading and writing from the S3 bucket
# We allow writing as well to store the watermarked PDFs back to the bucket for temporary access
resource "aws_iam_role_policy" "lambda_s3_access" {
  name = "lambda_s3_access"
  role = aws_iam_role.iam_for_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "${aws_s3_bucket.pdf_bucket.arn}/pdfs/master.pdf",   # read master PDF
          "${aws_s3_bucket.pdf_bucket.arn}/stamped/*"          # allows writing watermarked PDFs without touching the master PDF.
        ]
      }
    ]
  })
}

# Lifecycle rule to automatically delete watermarked PDFs after 1 day
# This is optional but helps manage storage and costs
resource "aws_s3_bucket_lifecycle_configuration" "stamped_cleanup" {
  bucket = aws_s3_bucket.pdf_bucket.id

  rule {
    id     = "DeleteStampedPDFs"
    status = "Enabled"

    # Apply only to objects under 'stamped/' prefix
    filter {
      prefix = "stamped/"
    }

    expiration {
      days = 1   # delete objects 1 day after creation
    }
  }
}

# -------------------
# API Gateway declarations

resource "aws_apigatewayv2_api" "pdf_api" {
  name          = "pdf-watermark-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.website_domains  # domains allowed to access the API
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.pdf_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.lambda_function.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.pdf_api.id
  route_key = "POST /pdf"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.pdf_api.id
  name        = "$default"
  auto_deploy = true
}

# grant API Gateway permission to invoke the Lambda function to the iam user
resource "aws_iam_user_policy" "iam_user_full_apigw" {
  name = "iam-user-full-apigw"
  user = var.iam_user_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "apigateway:*"
        Resource = "*"
      }
    ]
  })
}

# Permission for API Gateway to invoke the Lambda function
resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.pdf_api.execution_arn}/*/*"
}

# Finally, output the API endpoint to easily access it after deployment
output "api_url" {
  value = aws_apigatewayv2_api.pdf_api.api_endpoint
}

# -------------------
# Lambda function declarations and IAM role

data "aws_iam_policy_document" "assume_role" {
    statement {
      actions = ["sts:AssumeRole"]

      principals {
            type        = "Service"
            identifiers = ["lambda.amazonaws.com"]
      }

      effect = "Allow"
    }
}

resource "aws_iam_role" "iam_for_lambda" {
    name               = "iam_for_lambda"
    assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

data "archive_file" "lambda_zip" {
    type        = "zip"
    source_dir = "${path.module}/../src" # directory containing your lambda function code
    output_path = "${path.module}/lambda_function_src.zip"
}

resource "aws_lambda_function" "lambda_function" {
    function_name = var.lambda_function_name
    role          = aws_iam_role.iam_for_lambda.arn

    filename      = data.archive_file.lambda_zip.output_path
    source_code_hash = data.archive_file.lambda_zip.output_base64sha256

    runtime       = "python3.12"
    handler       = "sealer.lambda_handler"
    layers = ["arn:aws:lambda:eu-west-1:770693421928:layer:Klayers-p312-Pillow:7"]

    timeout   = 30

    environment {
      variables = {
        PDF_BUCKET = aws_s3_bucket.pdf_bucket.bucket
        MASTER_KEY = aws_s3_object.master_pdf.key
      }
    }
}