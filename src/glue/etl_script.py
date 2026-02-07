import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

# 1. Initialize Glue
args = getResolvedOptions(sys.argv, ['JOB_NAME', 'input_path', 'output_path'])
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# 2. Read Input Data (CSV)
# We read the file passed from the input_path argument
datasource0 = spark.read.option("header", "true").csv(args['input_path'])

# 3. Transformation (Example: Rename column 'Amount' to 'Total_Cost')
# You can add more complex logic here
transformed_df = datasource0.withColumnRenamed("Amount", "Total_Cost")

# 4. Write Output Data (Parquet)
# We write to the processed folder
transformed_df.write.mode("append").parquet(args['output_path'])

job.commit()