import sys
import re
import boto3  # <--- NEW: Needed to talk to the Glue Crawler
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

# 1. Initialize Glue and Spark
args = getResolvedOptions(sys.argv, ['JOB_NAME', 'input_path', 'output_path'])
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# 2. Read ANY CSV file (Generic)
# "inferSchema" tells Spark to guess if it's a number or string automatically
# "header" tells Spark the first row contains column names
df = spark.read.option("header", "true").option("inferSchema", "true").csv(args['input_path'])

# 3. Dynamic Column Cleaning
# This loop fixes column names automatically (e.g., "Total Cost" -> "total_cost")
# It works for ANY columns, whether you have 3 or 300.
cleaned_df = df
for col_name in df.columns:
    # Replace spaces/special chars with underscores and make lowercase
    new_name = re.sub(r'[^a-zA-Z0-9]', '_', col_name).lower()
    cleaned_df = cleaned_df.withColumnRenamed(col_name, new_name)

# 4. Write Output (Parquet)
# We append to the folder so we don't overwrite previous data
cleaned_df.write.mode("append").parquet(args['output_path'])

job.commit()

# --- 5. AUTOMATION: START THE CRAWLER ---
# This block runs AFTER the file is saved.
# It tells the Crawler: "New data is here! Update the table definition!"
print("Triggering Crawler...")
client = boto3.client('glue', region_name='us-east-1')

try:
    client.start_crawler(Name='pipeline-schema-crawler')
    print("Crawler triggered successfully.")
except client.exceptions.CrawlerRunningException:
    print("Crawler is already running. Skipping trigger.")
except Exception as e:
    print(f"Error triggering crawler: {e}")