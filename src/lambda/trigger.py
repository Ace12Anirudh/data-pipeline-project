import boto3
import os

glue = boto3.client('glue')

def handler(event, context):
    # Get the Glue Job Name from environment variables
    job_name = os.environ['GLUE_JOB_NAME']
    processed_bucket = os.environ['PROCESSED_BUCKET']
    
    # Loop through records (in case multiple files upload at once)
    for record in event['Records']:
        bucket_name = record['s3']['bucket']['name']
        file_key = record['s3']['object']['key']
        
        # Define where the file is (Source) and where it should go (Target)
        input_path = f"s3://{bucket_name}/{file_key}"
        output_path = f"s3://{processed_bucket}/cleaned_data/"
        
        print(f"Starting Glue job for {input_path}")
        
        # Trigger the Glue Job
        glue.start_job_run(
            JobName=job_name,
            Arguments={
                '--input_path': input_path,
                '--output_path': output_path
            }
        )
        
    return {"statusCode": 200, "body": "Job Triggered"}