import boto3
import time
import os
from datetime import datetime

athena = boto3.client('athena')
s3 = boto3.client('s3')

def handler(event, context):
    bucket = os.environ['BUCKET_NAME']
    database = 'my_pipeline_db' # Athena's default database
    output_location = f's3://{bucket}/reports/'
    
    # The Query: Calculate total revenue
    query = """
    SELECT 
        count(*) as total_orders, 
        sum(cast(Total_Cost as double)) as total_revenue, 
        current_date as report_date 
    FROM cleaned_data
    """
    
    # 1. Run the Query
    print(f"Starting daily report query...")
    response = athena.start_query_execution(
        QueryString=query,
        QueryExecutionContext={'Database': database},
        ResultConfiguration={'OutputLocation': output_location}
    )
    
    query_id = response['QueryExecutionId']
    
    # 2. Wait for it to finish (Simple poller)
    status = 'RUNNING'
    while status in ['RUNNING', 'QUEUED']:
        time.sleep(2)
        response = athena.get_query_execution(QueryExecutionId=query_id)
        status = response['QueryExecution']['Status']['State']
        
    if status == 'SUCCEEDED':
        print(f"Report Generated! Saved to: {output_location}/{query_id}.csv")
        return {"statusCode": 200, "body": "Report Generated Successfully"}
    else:
        raise Exception(f"Query Failed: {status}")