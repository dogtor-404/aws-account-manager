# IAM Identity Center - Terraform Deployment Identity Configuration Guide

> Create secure Terraform deployment identity using AWS IAM Identity Center (SSO) with temporary credentials and enterprise-grade permission management

## 📋 Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Step 1: Enable IAM Identity Center](#step-1-enable-iam-identity-center)
- [Step 2: Create Users](#step-2-create-users)
- [Step 3: Configure Permission Set](#step-3-configure-permission-set)
- [Step 4: Assign Permissions](#step-4-assign-permissions)
- [Step 5: Configure AWS CLI](#step-5-configure-aws-cli)
- [Step 6: Set Up Budget Alerts](#step-6-set-up-budget-alerts)
- [Step 7: Verify Permissions](#step-7-verify-permissions)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)

---

## Overview

This guide walks you through creating identity authentication configuration for Terraform infrastructure management using **IAM Identity Center (formerly AWS SSO)**.

### Core Features

- ✅ **Complete Infrastructure Permissions**: Access to almost all AWS services
- ✅ **IAM Role Management**: Create and manage service roles (Lambda, EC2, etc.)
- ❌ **Restricted Sensitive Operations**: Cannot manage IAM users, modify account settings, or delete audit logs
- 💰 **Budget Control**: $100/month budget limit with multi-level alerts
- 🔒 **Temporary Credentials**: Auto-expire (1-12 hours), no long-term key management needed
- 🏢 **Enterprise-Grade**: Unified identity management, multi-account support, and third-party identity provider integration

### Permission Model

PowerUser + IAM Role Management + Security Deny Policies

### Why Choose IAM Identity Center?

- ⭐⭐⭐⭐⭐ Highest security level
- Automatic credential refresh without manual management
- Unified login portal for improved user experience
- Support for third-party identity providers like Okta, Azure AD
- Native MFA (multi-factor authentication) support
- Ideal for enterprise teams and multi-account management

---

## Prerequisites

- AWS account administrator permissions
- Access to AWS Management Console
- AWS Organizations (IAM Identity Center will create it automatically if not enabled)
- Email address (for receiving user activation emails and budget alerts)

---

## Step 1: Enable IAM Identity Center

### 1.1 Navigate to IAM Identity Center

1. Log in to [AWS Management Console](https://console.aws.amazon.com/) with administrator account
2. Search for **IAM Identity Center** (or search for **SSO**)
3. Click to enter **IAM Identity Center** service

### 1.2 Enable the Service

1. If first time using, click **Enable** button
2. AWS will automatically configure necessary resources (may take a few minutes)
3. Record your **SSO start URL**, format similar to:
   ```
   https://d-1234567890.awsapps.com/start
   ```

### 1.3 Choose Identity Source

1. From the left menu, select **Settings**
2. In **Identity source** section, choose one of the following:

   - **Identity Center directory** (Recommended)
     - AWS-managed identity store
     - Suitable for most scenarios
     - MFA support
   
   - **Active Directory**
     - If using AWS Managed Microsoft AD
     - Or connecting to on-premises Active Directory
   
   - **External identity provider**
     - Connect to Okta, Azure AD, Google Workspace, etc.
     - Requires SAML 2.0 configuration

3. This guide uses **Identity Center directory** (default option)

---

## Step 2: Create Users

### 2.1 Add User

1. From the left menu, select **Users**
2. Click **Add user** button
3. Fill in user information:

```
Username: terraform.deployer
Email: deployer@example.com
First name: Terraform
Last name: Deployer
Display name: Terraform Deployer
```

**Note**:
- Username must be unique, lowercase with dots recommended
- Email will receive activation emails and notifications
- Modify First/Last name based on team member information

4. Click **Next**
5. Review information and click **Add user**

### 2.2 User Activation

1. User will receive activation email from AWS (sender: `no-reply@signin.aws`)
2. Email contains temporary login link and instructions
3. Click activation link and set permanent password

### 2.3 Configure MFA (Multi-Factor Authentication)

**Important**: MFA is required for all users to enhance security.

**Steps for users to enable MFA:**

1. After setting password, user logs in to AWS Access Portal
   - URL: Your SSO start URL (e.g., `https://d-1234567890.awsapps.com/start`)
   - Enter username and password

2. Click on username in top right corner → **Profile**

3. In **Multi-factor authentication (MFA)** section, click **Register device**

4. Choose MFA device type:
   - **Authenticator app** (Recommended): Google Authenticator, Microsoft Authenticator, Authy
   - **Security key**: Hardware token (YubiKey, etc.)

5. For Authenticator app:
   - Open authenticator app on phone
   - Scan the QR code displayed on screen
   - Enter the 6-digit verification code shown in app
   - Click **Verify** to complete registration

6. Save backup codes (if provided) in a secure location

**After MFA is enabled:**
- Every login will require: Password + 6-digit code from authenticator app
- Significantly increases account security
- Required for accessing AWS resources

---

## Step 3: Configure Permission Set

Permission Set defines what operations users can perform in AWS accounts.

### 3.1 Create Permission Set

1. From the left menu, select **Permission sets**
2. Click **Create permission set** button
3. Choose type: **Custom permission set**
4. Click **Next**

### 3.2 Attach AWS Managed Policy

1. In **Policies** section, select **AWS managed policies**
2. Search for `PowerUserAccess`
3. Check **PowerUserAccess**
4. Click **Next**

### 3.3 Configure Permission Set Details

```
Permission set name: TerraformDeployerPermissionSet
Description: Full infrastructure management for Terraform with security restrictions
Session duration: 4 hours
```

**Note**:
- Session duration can be set from 1-12 hours
- 4 hours suitable for most development work
- Re-login required after expiration to refresh credentials

Click **Next**

### 3.4 Create Inline Policy

Now add two custom policies: IAM role management permissions and security deny policies.

Click **Create a custom permissions policy**

In the editor, paste the following **merged policy**:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowIAMRoleManagement",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:GetRole",
        "iam:ListRoles",
        "iam:UpdateRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:PassRole"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowIAMPolicyManagement",
      "Effect": "Allow",
      "Action": [
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListPolicies",
        "iam:ListPolicyVersions",
        "iam:CreatePolicyVersion",
        "iam:DeletePolicyVersion",
        "iam:SetDefaultPolicyVersion",
        "iam:TagPolicy",
        "iam:UntagPolicy"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowIAMReadOperations",
      "Effect": "Allow",
      "Action": [
        "iam:GetUser",
        "iam:GetGroup",
        "iam:ListUsers",
        "iam:ListGroups",
        "iam:ListAccountAliases"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyIAMUserManagement",
      "Effect": "Deny",
      "Action": [
        "iam:CreateUser",
        "iam:DeleteUser",
        "iam:UpdateUser",
        "iam:CreateGroup",
        "iam:DeleteGroup",
        "iam:AddUserToGroup",
        "iam:RemoveUserFromGroup",
        "iam:AttachUserPolicy",
        "iam:DetachUserPolicy",
        "iam:PutUserPolicy",
        "iam:DeleteUserPolicy",
        "iam:CreateAccessKey",
        "iam:DeleteAccessKey",
        "iam:UpdateAccessKey",
        "iam:CreateLoginProfile",
        "iam:DeleteLoginProfile",
        "iam:UpdateLoginProfile"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyAccountLevelChanges",
      "Effect": "Deny",
      "Action": [
        "iam:CreateAccountAlias",
        "iam:DeleteAccountAlias",
        "iam:UpdateAccountPasswordPolicy",
        "iam:DeleteAccountPasswordPolicy"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyBillingAndCostManagement",
      "Effect": "Deny",
      "Action": [
        "account:*",
        "billing:*",
        "budgets:ModifyBudget",
        "budgets:DeleteBudget",
        "ce:UpdateCostAllocationTagsStatus",
        "cur:DeleteReportDefinition"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyOrganizationChanges",
      "Effect": "Deny",
      "Action": [
        "organizations:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyAuditLogDeletion",
      "Effect": "Deny",
      "Action": [
        "cloudtrail:DeleteTrail",
        "cloudtrail:StopLogging",
        "cloudtrail:UpdateTrail"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DenyGuardDutyDisable",
      "Effect": "Deny",
      "Action": [
        "guardduty:DeleteDetector",
        "guardduty:DisassociateFromAdministratorAccount",
        "guardduty:DisassociateMembers",
        "guardduty:StopMonitoringMembers"
      ],
      "Resource": "*"
    }
  ]
}
```

Click **Next**

### 3.5 Review and Create

1. Review all configurations
2. Click **Create**

### 3.6 Verify Permission Set

Confirm the permission set contains:
- ✅ PowerUserAccess (AWS managed policy)
- ✅ Inline policy (includes IAM role management and security restrictions)

---

## Step 4: Assign Permissions

Assign the permission set to users to enable AWS account access.

### 4.1 Select Account

1. From the left menu, select **AWS accounts**
2. You'll see all accounts in AWS Organizations
3. Check the target account (usually your current dev/production account)
4. Click **Assign users or groups** button

### 4.2 Select User

1. Under **Users** tab
2. Check `terraform.deployer` user
3. Click **Next**

### 4.3 Select Permission Set

1. Check `TerraformDeployerPermissionSet`
2. Click **Next**

### 4.4 Review and Submit

1. Review assignment information:
   - Account: `<Your Account ID>`
   - User: `terraform.deployer`
   - Permission set: `TerraformDeployerPermissionSet`
2. Click **Submit**

### 4.5 Wait for Configuration to Complete

AWS will create necessary IAM roles in the target account (usually takes 1-2 minutes).

---

## Step 5: Configure AWS CLI

### 5.1 Install AWS CLI v2

IAM Identity Center requires AWS CLI v2 (v1 doesn't support SSO).

**macOS:**
```bash
brew install awscli
```

**Linux:**
```bash
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**Windows:**
Download and install [AWS CLI v2 for Windows](https://awscli.amazonaws.com/AWSCLIV2.msi)

**Verify version:**
```bash
aws --version
# Should output: aws-cli/2.x.x ...
```

### 5.2 Configure SSO Profile

Run configuration wizard:

```bash
aws configure sso
```

Enter the following information when prompted:

```
SSO session name (Recommended): affyned-terraform
SSO start URL [None]: https://d-1234567890.awsapps.com/start
SSO region [None]: us-east-1
SSO registration scopes [sso:account:access]: sso:account:access
```

**Note**:
- **SSO start URL**: The URL recorded in Step 1.2
- **SSO region**: The region where IAM Identity Center is located (usually us-east-1)
- Browser will open automatically after pressing Enter

### 5.3 Browser Authorization

1. Browser will open AWS SSO login page
2. Enter username and password (user created in Step 2)
3. If MFA is enabled, enter verification code
4. Click **Allow** to authorize AWS CLI access

### 5.4 Select Account and Role

Return to terminal, you'll see available account list:

```
There are 2 AWS accounts available to you.
> account-1 (123456789012)
  account-2 (987654321098)
```

Select account (enter number), then select role:

```
There are 2 roles available to you.
> TerraformDeployerPermissionSet
  AdministratorAccess
```

Select `TerraformDeployerPermissionSet`

### 5.5 Complete Configuration

```
CLI default client Region [us-east-1]: us-east-1
CLI default output format [json]: json
CLI profile name [TerraformDeployerPermissionSet-123456789012]: terraform-deployer
```

**Suggestion**: Change profile name to the shorter `terraform-deployer`

### 5.6 Verify Configuration

View configuration file:

```bash
cat ~/.aws/config
```

Should see content similar to:

```ini
[profile terraform-deployer]
sso_session = affyned-terraform
sso_account_id = 123456789012
sso_role_name = TerraformDeployerPermissionSet
region = us-east-1
output = json

[sso-session affyned-terraform]
sso_start_url = https://d-1234567890.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

### 5.7 Login to SSO

```bash
aws sso login --profile terraform-deployer
```

Browser will open again, complete login and return to terminal.

### 5.8 Set Default Profile

Add to `~/.zshrc` or `~/.bashrc`:

```bash
export AWS_PROFILE=terraform-deployer
```

Apply configuration:

```bash
source ~/.zshrc  # or source ~/.bashrc
```

---

## Step 6: Set Up Budget Alerts

### 6.1 Navigate to Billing

1. Click account name dropdown menu in top right corner
2. Select **Billing and Cost Management**
3. Select **Budgets** from left menu

### 6.2 Create Budget

1. Click **Create budget**
2. Select budget type: **Cost budget**
3. Click **Next**

### 6.3 Configure Budget Details

**Budget setup:**
```
Budget name: terraform-sso-monthly-budget
Period: Monthly
Budget effective dates: Recurring budget
Start month: <Current month>
Budget renewal type: Recurring
```

**Budget amount:**
```
Budgeting method: Fixed
Enter your budgeted amount: $100
```

Click **Next**

### 6.4 Configure Alert Thresholds

**Alert 1 - 80% threshold (early warning)**
```
Alert threshold: 80% of budgeted amount ($80)
Email recipients: your-email@example.com
```
Click **Add another alert**

**Alert 2 - 90% threshold (serious warning)**
```
Alert threshold: 90% of budgeted amount ($90)
Email recipients: your-email@example.com
```
Click **Add another alert**

**Alert 3 - 100% threshold (overage warning)**
```
Alert threshold: 100% of budgeted amount ($100)
Email recipients: your-email@example.com
```

Click **Next**

### 6.5 Complete Creation

1. Review configuration
2. Click **Create budget**

### 6.6 Confirm Email Subscriptions

1. Check your email inbox
2. You'll receive one confirmation email per alert threshold (from AWS Notifications)
3. Click **Confirm subscription** link in each email

---

## Step 7: Verify Permissions

### 7.1 Test AWS CLI Connection

```bash
# View current identity
aws sts get-caller-identity
```

Expected output:
```json
{
    "UserId": "AROAEXAMPLE:terraform.deployer",
    "Account": "123456789012",
    "Arn": "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_TerraformDeployerPermissionSet_xxxxx/terraform.deployer"
}
```

### 7.2 Test Infrastructure Permissions (should succeed)

```bash
# Test S3
aws s3 ls

# Test EC2
aws ec2 describe-instances

# Test Lambda
aws lambda list-functions

# Test IAM role management
aws iam list-roles

# Test RDS
aws rds describe-db-instances
```

### 7.3 Test Deny Policies (should fail)

**Test IAM user creation (should be denied):**
```bash
aws iam create-user --user-name test-user
```

Expected output:
```
An error occurred (AccessDenied) when calling the CreateUser operation: 
User is not authorized to perform: iam:CreateUser
```

**Test budget modification (should be denied):**
```bash
aws budgets describe-budgets --account-id 123456789012
```

Expected output:
```
An error occurred (AccessDenied) when calling the DescribeBudgets operation
```

### 7.4 Test Terraform

In your Terraform project directory:

```bash
cd /Users/neozhang/dev/affyned/Affyned-cash-adv-infra

# Initialize Terraform
terraform init

# Validate configuration
terraform validate

# View plan
terraform plan
```

If everything is working correctly, Terraform should be able to read state and generate execution plan.

---

## Security Best Practices

### 1. Automatic Temporary Credential Expiration

IAM Identity Center uses temporary credentials with the following advantages:
- ✅ Auto-expire (4 hours, configurable 1-12 hours)
- ✅ Minimized exposure risk
- ✅ No manual rotation needed
- ✅ Follows AWS best practices

**Important Notes**:
- Session duration in Console: Enter as "4 hours"
- Session duration in Terraform/API: Use ISO 8601 format `PT4H`
- Credentials cached in `~/.aws/sso/cache/` - automatically refreshed on re-login

### 2. Regular Credential Refresh

When credentials expire, re-run:

```bash
aws sso login --profile terraform-deployer
```

**Automation tip**: Add alias to shell configuration:

```bash
# ~/.zshrc or ~/.bashrc
alias tf-login='aws sso login --profile terraform-deployer'
```

### 3. MFA Already Configured

MFA (Multi-Factor Authentication) is already set up during user creation (Step 2.3).

**MFA Verification:**
- Users must enter 6-digit code from authenticator app at each login
- Provides additional security layer beyond password
- Cannot be bypassed once enabled

### 4. Credential Protection

**Never commit credentials to code repository:**

Ensure `.gitignore` includes:
```gitignore
# AWS Credentials
*.pem
*.key
.aws/credentials
*.csv

# AWS SSO cache
.aws/sso/
.aws/cli/

# Terraform
*.tfstate
*.tfstate.backup
.terraform/
terraform.tfvars
```

**Don't hardcode credentials in code:**
```hcl
# ❌ Wrong approach
provider "aws" {
  access_key = "AKIA..."
  secret_key = "wJalr..."
}

# ✅ Correct approach
provider "aws" {
  region = "us-east-1"
  # Use AWS_PROFILE environment variable, Terraform auto-detects SSO
}
```

### 5. Audit and Monitoring

**Regularly check user activity:**

```bash
# View CloudTrail logs
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=Username,AttributeValue=terraform.deployer \
  --max-results 50

# View recent API calls
aws cloudtrail lookup-events \
  --start-time $(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%S) \
  --max-results 100
```

**Monitor costs:**
- Check Billing Dashboard weekly
- Watch for budget alert emails
- Use Cost Explorer to analyze spending trends

### 6. Permission Review

**Quarterly permission review:**
1. Check CloudTrail logs to see actual API calls used
2. Use IAM Access Analyzer to identify unused permissions
3. Adjust Permission Set based on actual needs

**IAM Access Analyzer usage:**
1. Navigate to **IAM** → **Access Analyzer**
2. Create Analyzer (if none exists)
3. Review recommendations in **Findings**

### 7. Team Management

**Create independent users for team members:**
- Don't share SSO accounts
- Each developer should have independent IAM Identity Center user
- Use Groups for unified permission management

**Create user groups:**
1. IAM Identity Center → **Groups** → **Create group**
2. Group name: `terraform-deployers`
3. Add multiple users to group
4. Select group instead of individual users when assigning permissions

### 8. Session Security

**Configure session timeout:**
- Adjust Session duration (1-12 hours) based on security needs
- Development environment: 4-8 hours
- Production environment: 1-2 hours (more frequent re-authentication)

### 9. Service Control Policies (SCPs)

**Important**: If your organization uses AWS Organizations with Service Control Policies (SCPs):
- SCPs can further restrict permissions regardless of IAM policies
- Even with full permissions in IAM, SCPs can block certain actions
- Check with your AWS Organization administrator if you encounter unexpected permission denials
- SCPs apply at the account or organizational unit (OU) level

To verify if SCPs are affecting your permissions:
```bash
aws organizations list-policies-for-target --target-id <account-id> --filter SERVICE_CONTROL_POLICY
```

### 10. Permission Set Updates

**Key considerations when updating Permission Sets**:
- Changes to Permission Sets require **reassignment** to take effect
- Updates propagate to all assigned accounts (may take 1-2 minutes)
- Users may need to re-login after permission changes
- Test permission changes in a development account first

**Update workflow**:
1. Edit Permission Set in IAM Identity Center
2. Save changes
3. Go to **AWS accounts** → Select account → **Reassign** users/groups
4. Verify changes: `aws sts get-caller-identity` (check role ARN includes latest timestamp)

---

## Troubleshooting

### Issue 1: Cannot Enable IAM Identity Center

**Error message:**
```
You don't have permissions to enable AWS IAM Identity Center
```

**Solution:**
- Requires AWS account administrator permissions
- Confirm you're using the management account (not member account)
- Check if IAM Identity Center is already enabled in another region (can only enable in one region)

### Issue 2: SSO Login Failure

**Error message:**
```
Error loading SSO Token: Token for ... does not exist
```

**Solution:**
```bash
# Clear SSO cache
rm -rf ~/.aws/sso/cache/

# Re-login
aws sso login --profile terraform-deployer
```

### Issue 3: Credentials Expired

**Error message:**
```
An error occurred (ExpiredToken) when calling the ... operation: The security token included in the request is expired
```

**Solution:**
```bash
# Re-login to refresh credentials
aws sso login --profile terraform-deployer
```

**Automation script (check and auto-refresh):**

Create file `~/.aws/sso-refresh.sh`:

```bash
#!/bin/bash
# Check if SSO credentials are valid, auto-refresh if invalid

PROFILE=${1:-terraform-deployer}

if ! aws sts get-caller-identity --profile $PROFILE &>/dev/null; then
    echo "⚠️  SSO credentials expired, refreshing..."
    aws sso login --profile $PROFILE
    echo "✅ Credentials refreshed!"
else
    echo "✅ SSO credentials are valid"
fi
```

Usage:
```bash
chmod +x ~/.aws/sso-refresh.sh
source ~/.aws/sso-refresh.sh terraform-deployer
```

### Issue 4: Cannot Create IAM Role

**Error message:**
```
Error: creating IAM Role: AccessDenied
```

**Solution:**
1. Confirm Permission Set includes custom inline policy
2. View Permission Set details in IAM Identity Center
3. Verify policy JSON format is correct
4. Test permissions:
   ```bash
   aws iam list-roles
   aws iam create-role --role-name test-role --assume-role-policy-document '{...}'
   ```

### Issue 5: PassRole Permission Error

**Error message:**
```
Error: User is not authorized to perform: iam:PassRole on resource
```

**Solution:**
- Confirm inline policy includes `iam:PassRole` permission
- Ensure `Resource` field is `"*"` not specific ARN
- Redeploy Permission Set (requires reassignment after modification)

### Issue 6: Terraform Insufficient Permissions

**Error message:**
```
Error: Error creating <resource>: UnauthorizedOperation
```

**Solution:**
1. PowerUserAccess should cover most services
2. Check specific missing permission (shown in error message)
3. Temporary test: Use AdministratorAccess Permission Set to confirm it's a permission issue
4. If additional permission confirmed needed, modify inline policy to add

### Issue 7: Budget Alert Emails Not Received

**Solution:**
1. Check spam folder
2. Confirm you clicked **Confirm subscription** link in AWS Notifications email
3. Check alert configuration in Budgets Console
4. Verify email address is correct
5. Wait for actual spending to exceed threshold (or manually verify current spending using AWS Cost Explorer)

### Issue 8: Browser Not Opening Automatically

**Solution:**
1. Manually copy URL displayed in terminal
2. Open the URL in browser
3. Complete authorization and return to terminal
4. Or set environment variable to disable auto-open:
   ```bash
   export AWS_BROWSER=none
   ```

### Issue 9: Wrong AWS Account Selected

**Solution:**

If you have access to multiple accounts, ensure correct account is selected:

```bash
# View all available profiles
aws configure list-profiles

# View currently used account
aws sts get-caller-identity --profile terraform-deployer

# Reconfigure SSO (select correct account)
aws configure sso --profile terraform-deployer
```

### Issue 10: Permission Set Changes Not Applied

**Error**: After updating Permission Set, permissions remain unchanged

**Solution:**
1. Permission Set changes require reassignment
2. Go to IAM Identity Center → **AWS accounts** → Select account
3. Find the user/group assignment
4. Click the assignment and verify it's using the latest Permission Set version
5. If needed, remove and re-add the assignment
6. Wait 1-2 minutes for propagation
7. Users should run `aws sso logout && aws sso login` to get fresh credentials

### Issue 11: Cannot Use Terraform with SSO

**Error**: Terraform commands fail with authentication errors

**Solution:**
1. Verify AWS CLI v2 is installed (v1 doesn't support SSO)
2. Ensure `AWS_PROFILE` environment variable is set:
   ```bash
   export AWS_PROFILE=terraform-deployer
   ```
3. Login to SSO before running Terraform:
   ```bash
   aws sso login --profile terraform-deployer
   ```
4. Verify credentials:
   ```bash
   aws sts get-caller-identity
   ```
5. For Terraform backend authentication, SSO profile is automatically used

### Issue 12: Browser Caching Issues

**Error**: SSO login shows cached old sessions or wrong user

**Solution:**
```bash
# Clear browser cache for AWS SSO portal
# Or use incognito/private browsing mode

# Clear AWS CLI SSO cache
rm -rf ~/.aws/sso/cache/
rm -rf ~/.aws/cli/cache/

# Re-login
aws sso login --profile terraform-deployer
```

---

## Appendix

### Permission Policy Summary

| Policy Name | Type | Purpose |
|------------|------|---------|
| PowerUserAccess | AWS Managed | Provides complete access to almost all AWS services |
| Inline Policy - Allow IAM | Custom | Allow creating and managing IAM roles and policies (for Terraform) |
| Inline Policy - Deny | Custom | Explicitly deny high-risk operations (user management, account settings, audit log deletion) |

### AWS CLI Profile Configuration Example

**Complete configuration example (~/.aws/config):**

```ini
[profile terraform-deployer]
sso_session = affyned-terraform
sso_account_id = 123456789012
sso_role_name = TerraformDeployerPermissionSet
region = us-east-1
output = json

[sso-session affyned-terraform]
sso_start_url = https://d-1234567890.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access
```

### Common Commands

```bash
# SSO login
aws sso login --profile terraform-deployer

# SSO logout
aws sso logout

# View current identity
aws sts get-caller-identity

# List all profiles
aws configure list-profiles

# View SSO cache information
ls -la ~/.aws/sso/cache/

# Clear SSO cache
rm -rf ~/.aws/sso/cache/
```

### Terraform Provider Configuration

```hcl
# terraform.tf
terraform {
  required_version = ">= 1.0"
  
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  
  backend "s3" {
    # SSO profile automatically used for backend authentication
    bucket = "your-terraform-state-bucket"
    key    = "terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
  # AWS_PROFILE environment variable automatically detected
  # No need to hardcode any credentials in code
}
```

### Cost Control Mechanism

1. **Budget Limit**: $100/month hard budget
2. **Three-tier Alerts**:
   - 80% ($80) - Early warning
   - 90% ($90) - Serious warning
   - 100% ($100) - Overage warning
3. **Monitoring Recommendations**:
   - Check Cost Explorer weekly
   - Review Billing Dashboard monthly
   - Use AWS Cost Anomaly Detection

### IAM Policy Updates (2024-2025)

**Deprecated Actions** (still work but use modern equivalents):
- ❌ `aws-portal:*` → ✅ Use `account:*` and `billing:*`
- ❌ `guardduty:DisassociateFromMasterAccount` → ✅ Use `guardduty:DisassociateFromAdministratorAccount`

**This document uses current AWS terminology** as of 2025.

### Terraform Automation Notes

**What CAN be automated with Terraform:**
- ✅ Creating users and groups (`aws_identitystore_user`, `aws_identitystore_group`)
- ✅ Creating Permission Sets (`aws_ssoadmin_permission_set`)
- ✅ Assigning permissions (`aws_ssoadmin_account_assignment`)
- ✅ Creating budgets (`aws_budgets_budget`)

**What CANNOT be automated:**
- ❌ Initial IAM Identity Center enablement (must be done manually via Console)
- ❌ Choosing identity source (must be done manually)

**Terraform module example:**
```hcl
module "sso_permission_set" {
  source = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  
  # See AWS documentation for full Terraform configuration examples
}
```

### Related Documentation

- [AWS IAM Identity Center Official Documentation](https://docs.aws.amazon.com/singlesignon/latest/userguide/what-is.html)
- [AWS CLI SSO Configuration Guide](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html)
- [Terraform AWS Provider Authentication](https://registry.terraform.io/providers/hashicorp/aws/latest/docs#authentication-and-configuration)
- [AWS Budgets Documentation](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-managing-costs.html)
- [IAM Best Practices](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)

---

**Document Version**: 2.3  
**Last Updated**: 2025-10-12  
**Maintained by**: Affyned Infrastructure Team

**Changelog**:
- v2.3 (2025-10-12): Made MFA mandatory with detailed setup steps, removed optional user groups and IP restrictions
- v2.2 (2025-10-12): Removed optional PassRole condition section for simplicity
- v2.1 (2025-10-12): Updated policy actions to modern AWS equivalents, added enhanced security options, expanded troubleshooting
- v2.0 (2025-10-12): Simplified to include only IAM Identity Center approach, improved readability
- v1.0 (2025-10-12): Initial version with multiple authentication approaches

**Verification Status**: ✅ Verified against AWS official documentation (October 2025)

For questions or permission configuration updates, please contact AWS account administrator.

