terraform {
  backend "s3" {
    bucket = "my-terraform-state-store-900"  # <--- YOUR NEW BUCKET NAME HERE
    key    = "pipeline/terraform.tfstate"     # The folder/file name inside the bucket
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

# --- 1. STORAGE (S3 Buckets) ---
# We need a unique bucket name. Change 'unique-id-123' to something random!
resource "aws_s3_bucket" "data_lake" {
  bucket = "my-pipeline-bucket-unique-ace-123"
  force_destroy = true # Allows deleting bucket even if it has files (for testing)
}

# Create folders inside the bucket
resource "aws_s3_object" "raw_folder" {
  bucket = aws_s3_bucket.data_lake.id
  key    = "raw/"
}

# --- 2. SECURITY (IAM Roles) ---
# This allows Lambda to log to CloudWatch and start Glue jobs
resource "aws_iam_role" "lambda_role" {
  name = "pipeline_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

# Attach permission policy to Lambda
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_glue_policy" {
  name = "lambda_trigger_glue"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Action = ["glue:StartJobRun"], Effect = "Allow", Resource = "*" }
    ]
  })
}

# This allows Glue to read/write S3
resource "aws_iam_role" "glue_role" {
  name = "pipeline_glue_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "glue.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_access" {
  name = "glue_s3_access"
  role = aws_iam_role.glue_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Action = ["s3:GetObject", "s3:PutObject"], Effect = "Allow", Resource = "${aws_s3_bucket.data_lake.arn}/*" }
    ]
  })
}

# --- 3. COMPUTE (Glue Job) ---
resource "aws_glue_job" "etl_job" {
  name     = "csv-to-parquet-cleaner"
  role_arn = aws_iam_role.glue_role.arn
  glue_version = "4.0"

  command {
    script_location = "s3://${aws_s3_bucket.data_lake.bucket}/scripts/etl_script.py"
    python_version  = "3"
  }
  
  # Standard worker type (G.1X is cost effective)
  worker_type = "G.1X"
  number_of_workers = 2
}

# --- 4. COMPUTE (Lambda Function) ---
# Zip the code first (Terraform does this for you)
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "src/lambda/trigger.py"
  output_path = "lambda_function.zip"
}

resource "aws_lambda_function" "trigger" {
  filename      = "lambda_function.zip"
  function_name = "pipeline-trigger"
  role          = aws_iam_role.lambda_role.arn
  handler       = "trigger.handler"
  runtime       = "python3.9"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      GLUE_JOB_NAME    = aws_glue_job.etl_job.name
      PROCESSED_BUCKET = aws_s3_bucket.data_lake.bucket
    }
  }
}

# --- 5. AUTOMATION (Trigger Connection) ---
# Give S3 permission to call Lambda
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.data_lake.arn
}

# Tell S3 to notify Lambda when a file lands in raw/
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.data_lake.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.trigger.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "raw/"
  }
  
  depends_on = [aws_lambda_permission.allow_s3]
}

# --- 6. REPORTING (Daily Scheduler) ---

# The Reporter Lambda Function
data "archive_file" "report_zip" {
  type        = "zip"
  source_file = "src/lambda/daily_report.py"
  output_path = "report_function.zip"
}

resource "aws_lambda_function" "reporter" {
  filename      = "report_function.zip"
  function_name = "daily-reporter"
  role          = aws_iam_role.lambda_role.arn
  handler       = "daily_report.handler"
  runtime       = "python3.9"
  source_code_hash = data.archive_file.report_zip.output_base64sha256
  
  timeout = 60 # Give it time to run the query

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.data_lake.bucket
    }
  }
}

resource "aws_glue_catalog_database" "pipeline_db" {
  name = "my_pipeline_db"
}

# Grant Lambda permission to run Athena
resource "aws_iam_role_policy" "lambda_athena_policy" {
  name = "lambda_athena_access"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { 
        Action = [
            "athena:StartQueryExecution", 
            "athena:GetQueryExecution", 
            "athena:GetQueryResults",      # Added this just in case
            "glue:GetDatabase",            # <--- THIS WAS MISSING
            "glue:GetTable", 
            "glue:GetPartitions",
            "s3:GetBucketLocation",
            "s3:ListBucket",
            "s3:PutObject",                # Needed to write the report
            "s3:GetObject"
        ], 
        Effect = "Allow", 
        Resource = "*" 
      }
    ]
  })
}

# EventBridge Scheduler (The Alarm Clock)
resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name        = "daily-report-trigger"
  description = "Triggers the report Lambda every day at 8am"
  schedule_expression = "cron(0 8 * * ? *)" # Runs at 08:00 UTC daily
}

resource "aws_cloudwatch_event_target" "trigger_lambda" {
  rule      = aws_cloudwatch_event_rule.daily_trigger.name
  target_id = "SendDailyReport"
  arn       = aws_lambda_function.reporter.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reporter.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily_trigger.arn
}