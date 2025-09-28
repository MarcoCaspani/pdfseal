# Pdfseal 
Serverless PDF watermarking service using AWS Lambda, S3, and API Gateway to seal documents 
and prevent unauthorized distribution.

---

# Setup

First install the requirements in a folder named "modules" inside the src folder.
```bash
cd src
mkdir "modules"
pip install -r requirements.txt -t modules/
```

Delete the two folders with the pillow package. Otherwise, it will not work in AWS Lambda 
because it imports the local pillow package instead of the AWS Lambda layer
* PIL 
* pillow-*
```bash
cd src
rm -rf modules/pillow-*
rm -rf modules/PIL
```

and create a "__init__.py" file in the "modules" folder. This is needed to make Python treat the directory as a package.
```bash
touch modules/__init__.py
```

Finally, place your **_master.pdf_** file to be watermarked in the src folder.


# Deploy

```bash
cd deployment
terraform init
terraform apply
```


---

# Troubleshooting

## Testing payload
```json
{
    "payload": {
    "name": "test",
    "email": "info@test.com",
    "orderId": "123456"
    }
}
```

Testing the API with CLI. Replace the API_GATEWAY_URL with the url from the output of terraform apply.
```bash
curl -X GET "<<API_GATEWAY_URL>>/pdf" \
  -H "Content-Type: application/json" \
  -H "Accept: application/pdf" \
  -d '{"payload": {"name": "test_name", "email": "info@test.com", "orderId": "123456"}}' \
  -o order.pdf
```
## Check project structure

Your project structure should look like this:
```pdfseal/
pdfseal/
│├── assets/
│   ├── master.pdf
│├── deployment/
│   ├── main.tf
│   └── ...
│── src/
│   ├── modules/
│   │   ├── __init__.py
│   │   ├── reportlab/
│   │   ├── pypdf/
│   │   ├── boto3/
│   │   └── ...
│   ├── sealer.py
│   ├── requirements.txt
│   └── ...
├── .gitignore
└── README.md
```

# Issues encountered during development

## Error: "Unable to import module 'sealer': cannot import name '_imaging' from 'PIL'",

Solution: **Use a Pre-built Pillow Layer in AWS Lambda**


Packages that have C extensions, like Pillow (PIL). The _imaging module is a compiled part of Pillow that must match the Lambda Linux environment, so a regular local install (especially on macOS or Windows) won’t work.

Find the amazon resource name (ARN) for a pre-built Pillow layer compatible with your Lambda runtime. 
You can find these ARNs in various online repositories or AWS documentation. For example on:
https://github.com/keithrozario/Klayers?tab=readme-ov-file#get-latest-arn-for-all-packages-in-region
   (https://api.klayers.cloud/api/v2/p3.9/layers/latest/eu-west-1/)

ARN example: arn:aws:lambda:eu-west-1:770693421928:layer:Klayers-p312-Pillow:7

## Error: no resource-based policy allows the lambda:GetLayerVersion action

Original error

Error: updating Lambda Function (python_terraform_lambda_pdfsealer) configuration: 
operation error Lambda: UpdateFunctionConfiguration, https response error StatusCode: 403, 
RequestID: 796fea8f-de69-47da-9f64-f9bd9941139c, api error AccessDeniedException: 
User: arn:aws:iam::349347233549:user/ben-gates is not authorized to perform: lambda:GetLayerVersion 
on resource: **arn:aws:lambda:eu-west-1:770693421928:layer:Klayers-python39-Pillow:14** because 
no resource-based policy allows the lambda:GetLayerVersion action

Solution:
Make sure that the **ARN name is correct** and that the layer exists in the region you are deploying to.

_Originally, we thought that the error was due to insufficient permissions of the user, but it was actually a wrong ARN._

## Testing API with Postman always returns 500 Internal Server Error, while testing with AWS Test event always works

Solution: 
Allow the API Gateway to call the Lambda function, in Terraform.

```terraform
resource "aws_lambda_permission" "apigw_invoke" {
    statement_id  = "AllowAPIGatewayInvoke"
    action        = "lambda:InvokeFunction"
    function_name = aws_lambda_function.lambda_function.function_name
    principal     = "apigateway.amazonaws.com"
    source_arn    = "${aws_apigatewayv2_api.pdf_api.execution_arn}/*/*"
}
```

## The payload is too large
"Response payload size exceeded maximum allowed payload size (6291556 bytes)"

Solutions applied:
1) Compress the pdf. However this helped until the pdf could be compressed within 5MB
2) Save the pdf in the S3 bucket and return a pre-signed URL. This works with any size of pdf.

