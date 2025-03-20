# Serverless scRNA Pipeline

## Description
This pipeline processes single-cell RNA sequencing (scRNA-seq) data using AWS services for scalable computation. It leverages Piscem for efficient read mapping to a reference genome and Alevin-Fry for generating quantification matrices.

## Usage

Create a m6id.16xlarge Ubuntu 22.04 EC2 Instance with a root volume of 500GB.

SSH into the EC2 instance

Clone this repository

```
# Navigate to main folder
cd refactored-serverless-pipeline

# install necessary dependencies
cd install_scripts
./install.sh
./install_scripts.sh
./install_alevin_fry.sh
./install_radtk.sh

# configure AWS CLI
aws configure

# copy credentials file to scrna-pipeline folder
cp ~/.aws/credentials ~/refactored-serverless-pipeline/scrna-pipeline/

#copy reference indexed transcriptome to scrna-pipleine folder
cd ~/refactored-serverless-pipeline/scrna-pipeline
aws s3 cp s3://nnasam-reference-index . --recursive


aws s3 cp s3://nnasam-pipeline/reference ./recursive --recursive
```
### Configuration Parameters

Below parameters need to be changed in the run_scripts.sh file before triggering the pipeline
- AWS_REGION: your aws account region
- AWS_ACCOUNT_ID: your aws account ID
- S3_INPUT_BUCKET_NAME: S3 bucket containing input fastq.gz files
- S3_INPUT_TXT_BUCKET_NAME: Temp S3 bucket to hold input.txt files. This bucket will be created during pipeline execution.
- S3_OUTPUT_BUCKET_NAME: Temp S3 bucket to hold individual output folders. This bucket will be created during pipeline execution.
- SCRNA_OUTPUT_S3_BUCKET: Final output bucket that should contain count matrix
- OUTPUT_BASE_DIR: Output folder path in EC2 instance to download individual output files from S3 bucket. Select this to be some path inside /mnt/nvme as we are mounting the instance store to /mnt/nvme


```
# start the pipeline
cd ~/refactored-serverless-pipeline
./run_scripts.sh
```



The final quant matrix will be present in the S3 bucket mentioned in SCRNA_OUTPUT_S3_BUCKET parameter of the run_scripts.sh file

```
# delete AWS Resources created
cd ~/refactored-serverless-pipeline
./clean_up_resources.sh
```