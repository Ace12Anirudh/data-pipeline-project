import sys
import re
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'input_path', 'output_path'])
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# 1. Read ANY CSV file (Generic)
# "inferSchema" tells Spark to guess if it's a number or string automatically
df = spark.read.option("header", "true").option("inferSchema", "true").csv(args['input_path'])

# 2. Dynamic Column Cleaning
# This loop fixes column names automatically (e.g., "Total Cost" -> "total_cost")
# It works for ANY columns, whether you have 3 or 300.
cleaned_df = df
for col_name in df.columns:
    # Replace spaces/special chars with underscores and make lowercase
    new_name = re.sub(r'[^a-zA-Z0-9]', '_', col_name).lower()
    cleaned_df = cleaned_df.withColumnRenamed(col_name, new_name)

# 3. Write Output (Parquet)
cleaned_df.write.mode("append").parquet(args['output_path'])

job.commit()