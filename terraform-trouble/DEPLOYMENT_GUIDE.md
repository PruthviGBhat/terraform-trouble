# CloudKitchen AWS Deployment Guide

This guide provides foolproof, step-by-step instructions to deploy the entire CloudKitchen 3-Tier Web Application to **any AWS account** and from **any laptop**. 

By following this guide, you will deploy a highly available, secure, and production-ready infrastructure using Terraform.

---

## 🛠️ Phase 0: Prerequisites

Before touching any code, you need to ensure your laptop and AWS account are ready.

### 1. Install Required Software on your Laptop
- **Terraform** (Version 1.0.0 or higher) - [Download here](https://developer.hashicorp.com/terraform/downloads)
- **AWS CLI** (Version 2) - [Download here](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- **Git** - [Download here](https://git-scm.com/downloads)

### 2. Configure AWS Credentials
You need to authenticate your laptop with your AWS account.
1. Log into your AWS Console.
2. Go to **IAM** -> **Users** -> Create a new user (or use an existing admin user).
3. Generate an **Access Key** and **Secret Access Key**.
4. Open your laptop's terminal and run:
   ```bash
   aws configure
   ```
5. Paste your Access Key, Secret Key, default region (e.g., `ap-south-1`), and output format (`json`).

### 3. Create an SSH Key Pair in AWS
The EC2 instances need an SSH key to allow secure connections.
1. In the AWS Console, go to **EC2** -> **Key Pairs**.
2. Click **Create key pair**.
3. Name it (e.g., `ustproject-mb` or `my-cloudkitchen-key`).
4. Select **RSA** and **.pem** format.
5. Click **Create**. The `.pem` file will download to your laptop. Keep this file safe!

---

## 🏗️ Phase 1: Create the Remote Backend (The "Bootstrap")

Terraform uses a "State File" to remember what it has deployed. For teamwork and safety, we store this state securely in an AWS S3 Bucket and lock it using DynamoDB. We must build this bucket *first*.

1. Open your terminal and navigate to the `bootstrap` folder inside this project:
   ```bash
   cd bootstrap
   ```

2. Initialize Terraform and deploy the bootstrap resources:
   ```bash
   terraform init
   terraform apply -auto-approve
   ```

3. **IMPORTANT**: When the apply finishes, look at the output in your terminal. You will see a value called `state_bucket_name` (it will look something like `cloudkitchen-tfstate-123456789012`). **Copy this bucket name!**

4. Go back to the main project folder:
   ```bash
   cd ..
   ```

---

## 🔗 Phase 2: Connect the Remote Backend

Now that the S3 bucket exists, we tell Terraform to use it.

1. Open the file `backend.tf` in your code editor.
2. You will see a block of code at the bottom that is commented out (has `#` symbols in front). Remove the `#` symbols to uncomment it.
3. Replace the `bucket` value with the bucket name you copied in Phase 1. 
   
   It should look like this:
   ```hcl
   terraform {
     backend "s3" {
       bucket         = "cloudkitchen-tfstate-123456789012" # <-- YOUR BUCKET NAME HERE
       key            = "cloudkitchen/terraform.tfstate"
       region         = "ap-south-1"
       dynamodb_table = "cloudkitchen-tfstate-lock"
       encrypt        = true
     }
   }
   ```

4. Initialize the main project and migrate the state to AWS:
   ```bash
   terraform init -migrate-state
   ```
   *(If prompted, type `yes` and press Enter).*

---

## ⚙️ Phase 3: Configure Project Variables

Before deploying the main infrastructure, you need to configure your specific settings.

1. Open the `terraform.tfvars` file.
2. Update the following values to match your AWS account:
   - `aws_region`: Ensure this matches where you created your SSH key (default is `ap-south-1`).
   - `key_name`: The exact name of the EC2 Key Pair you created in Phase 0 (e.g., `"ustproject-mb"`).
   - `admin_email`: Your email address for receiving SNS alerts (e.g., `"my-email@gmail.com"`).

---

## 🚀 Phase 4: Deploy the Infrastructure

You are now ready to deploy the entire CloudKitchen architecture (VPCs, Load Balancers, Auto Scaling Groups, RDS PostgreSQL, CloudFront, API Gateway, and Lambdas).

1. Validate your code to ensure there are no syntax errors:
   ```bash
   terraform validate
   ```

2. See exactly what Terraform is going to build:
   ```bash
   terraform plan
   ```

3. Deploy the infrastructure!
   ```bash
   terraform apply -auto-approve
   ```

> [!WARNING]
> **Be Patient!** The `terraform apply` command will take about **5 to 10 minutes** to provision everything (especially the RDS database and CloudFront distribution). 
> 
> Furthermore, once Terraform says it's done, the backend App servers will take an additional **10 to 15 minutes** to download Maven dependencies, compile the Spring Boot Java app, and run the database migrations. The application will not work immediately. Please wait ~15 minutes before testing.

---

## 💻 Phase 5: Deploy the React Frontend

Terraform has successfully built your Load Balancers, API endpoints, S3 buckets, and CloudFront distribution. However, your CloudFront URL will currently show a blank page (or 403 error) because the React frontend code hasn't been compiled or uploaded to the new S3 bucket yet!

1. **Find your Frontend S3 Bucket Name:**
   The frontend bucket was created automatically by Terraform. Its name follows this pattern: `cloudkitchen-frontend-<YOUR_AWS_ACCOUNT_ID>` (for example, `cloudkitchen-frontend-123456789012`). You can verify the exact name by checking the S3 section in your AWS Console.

2. **Navigate to the Frontend Directory:**
   ```bash
   cd ../frontend
   ```
   *(Assuming your React app is located in a folder named `frontend` alongside the terraform folder. Adjust the path if necessary).*

3. **Configure the Environment Variables:**
   Before building, you must tell the React app where your new API Gateway is located.
   - Open the `.env` file in the frontend directory (create it if it doesn't exist).
   - Add your API Gateway URL (copied from the Terraform outputs) like this:
     ```env
     REACT_APP_API_GATEWAY_URL=https://<YOUR_API_GATEWAY_ID>.execute-api.ap-south-1.amazonaws.com
     ```
     *(Make sure you use the exact environment variable name your React app expects).*

4. **Install Dependencies and Build the React App:**
   ```bash
   npm install
   npm run build
   ```
   *(This creates an optimized production bundle inside the `build/` folder).*

5. **Upload the Build to S3:**
   Sync the compiled files to your S3 bucket. Replace `<YOUR_FRONTEND_BUCKET_NAME>` with the exact name you copied in step 1:
   ```bash
   aws s3 sync build/ s3://<YOUR_FRONTEND_BUCKET_NAME>
   ```

*(Your CloudFront CDN will now automatically serve these files globally!)*

---

## 🌐 Phase 6: Testing the Application

Once everything is deployed, Terraform will output several useful links and commands in your terminal. Look for the `quick_reference` output.

1. **Test the CloudFront CDN URL**:
   Copy the `cloudfront_url` from the Terraform outputs and paste it into your browser. This is your globally cached React frontend!

2. **Test the Application ALB URL**:
   Copy the `external_alb_dns` URL and append `/api/categories` to test the Spring Boot backend directly (e.g., `http://cloudkitchen-ext-alb-XXXX.ap-south-1.elb.amazonaws.com/api/categories`).

3. **Test Video Testimonial Presign**:
   Copy the `api_gateway_url` and use an API testing tool (like Postman or `curl`) to send a POST request to `<api_gateway_url>/api/testimonials/presign`.

4. **Check the SNS Email Subscription**:
   Check your email inbox! You should have received an email from AWS SNS asking you to confirm your subscription. Click the "Confirm subscription" link to start receiving alerts.

---

## 🛑 Phase 7: Teardown (Avoid Unexpected Bills!)

If you are just testing this out and don't want to incur ongoing AWS charges, you must destroy the infrastructure when you are done.

1. In the root directory, destroy the main infrastructure:
   ```bash
   terraform destroy -auto-approve
   ```
   *(This takes about 10 minutes. The RDS database, Load Balancers, and S3 buckets will be safely deleted).*

2. Navigate to the bootstrap folder to destroy the state bucket and lock table:
   ```bash
   cd bootstrap
   terraform destroy -auto-approve
   ```

You have now completely cleaned up your AWS account!
