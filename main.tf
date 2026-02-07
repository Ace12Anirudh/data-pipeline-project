terraform {
  backend "s3" {
    bucket = "terraform-state-store-900"  # Your state bucket
    key    = "pipeline/terraform.tfstate"     # The folder/file name inside
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

# --- 1. STORAGE (S3 Buckets) ---
resource "aws_s3_bucket" "data_lake" {
  bucket = "my-pipeline-bucket-unique-ace-123" # Your data bucket
  force_destroy = true 
}

# Create folders inside the bucket
resource "aws_s3_object" "raw_folder" {
  bucket = aws_s3_bucket.data_lake.id
  key    = "raw/"
}

# --- 2. SECURITY (IAM Roles) ---

# A. Lambda Role (For Trigger & Reporter)
resource "aws_iam_role" "lambda_role" {
  name = "pipeline_lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Permission to Trigger Glue Jobs
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

# Permission to Run Athena Queries & Read Glue Catalog
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
            "athena:GetQueryResults",
            "glue:GetDatabase",
            "glue:GetTable", 
            "glue:GetPartitions",
            "s3:GetBucketLocation",
            "s3:ListBucket",
            "s3:PutObject",
            "s3:GetObject"
        ], 
        Effect = "Allow", 
        Resource = "*" 
      }
    ]
  })
}

# B. Glue Role (For ETL Job & Crawler)
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

# Permission for Glue to Read/Write S3
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

# Permission for Glue Crawler to Update the Catalog
resource "aws_iam_role_policy" "glue_crawler_policy" {
  name = "glue_crawler_access"
  role = aws_iam_role.glue_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "glue:StartCrawler",
          "glue:GetCrawler",
          "glue:CreateTable",
          "glue:UpdateTable",
          "glue:GetTable",
          "glue:GetDatabase",
          "glue:BatchCreatePartition"
        ],
        Effect = "Allow",
        Resource = "*"
      },
       {
        Action = ["iam:PassRole"],
        Effect = "Allow",
        Resource = aws_iam_role.glue_role.arn
      }
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
  
  worker_type = "G.1X"
  number_of_workers = 2
}

# --- 4. DATA CATALOG (Database & Crawler) ---
resource "aws_glue_catalog_database" "pipeline_db" {
  name = "my_pipeline_db"
}

# The Crawler (Replaces the manual Table)
resource "aws_glue_crawler" "schema_discovery" {
  database_name = aws_glue_catalog_database.pipeline_db.name
  name          = "pipeline-schema-crawler"
  role          = aws_iam_role.glue_role.arn

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.bucket}/cleaned_data/"
  }
}

# --- 5. COMPUTE (Lambda Triggers) ---

# Trigger Function (Starts Glue)
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

# Reporter Function (Runs Athena)
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
  
  timeout = 60

  environment {
    variables = {
      BUCKET_NAME = aws_s3_bucket.data_lake.bucket
    }
  }
}

# --- 6. AUTOMATION (Triggers) ---

# S3 -> Lambda Trigger
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.data_lake.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.data_lake.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.trigger.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "raw/"
  }
  
  depends_on = [aws_lambda_permission.allow_s3]
}

# EventBridge -> Reporter Trigger (Daily at 8am)
resource "aws_cloudwatch_event_rule" "daily_trigger" {
  name        = "daily-report-trigger"
  description = "Triggers the report Lambda every day at 8 AM"
  schedule_expression = "cron(30 2 * * ? *)"
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