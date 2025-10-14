# AWS Account Manager

Multi-account user environment management with IAM Identity Center, automatic cost tracking, and budget controls.

## Architecture

One Command = Complete Isolated Environment

Each user gets:

- ✅ Dedicated AWS account (e.g., `alice-dev`)
- ✅ Identity Center authentication
- ✅ Automatic cost tracking via LinkedAccount (no tagging needed)
- ✅ Budget alerts at 80%, 90%, 100%

```text
Management Account
├── IAM Identity Center
│   ├── User: alice
│   └── User: bob
├── Permission Sets
│   └── TerraformDeployer
└── Budgets
    ├── alice-dev-budget → tracks account 123456789012
    └── bob-dev-budget → tracks account 234567890123

Member Accounts (isolated)
├── alice-dev (123456789012) ← alice has access
└── bob-dev (234567890123) ← bob has access
```

## Prerequisites

> **⚠️ One-Time Manual Setup Required**  
> The following steps **must be completed manually** before using the automation scripts.  
> These are AWS limitations - they cannot be automated via CLI/API.

### 1. Enable AWS Organizations (Manual - One Time)

**Required:** AWS Organizations must be enabled in your AWS account.

```bash
# Go to: https://console.aws.amazon.com/organizations/
# Click: "Create Organization" → "Enable All Features"
```

**Why manual?** AWS requires console confirmation for organization creation.

### 2. Enable IAM Identity Center (Manual - One Time)

**Required:** IAM Identity Center must be enabled before running scripts.

```bash
# Go to: https://console.aws.amazon.com/singlesignon/
# Click: "Enable"
```

**Why manual?** Initial IAM Identity Center setup requires console interaction.

### 3. Configure AWS CLI (Local Setup)

**Required:** Configure AWS CLI with management account credentials.

```bash
aws configure --profile root
export AWS_PROFILE=root
```

Verify access:

```bash
aws sts get-caller-identity  # Should show your management account ID
```

### 4. Install Required Tools (Local Setup)

**Required:** Install AWS CLI v2 and jq.

```bash
aws --version  # AWS CLI v2 required (v1 doesn't support SSO)
jq --version   # JSON processor (brew install jq)
```

---

**✅ After completing the above prerequisites, everything else is automated!**

The scripts will automatically handle:

- ✅ Creating AWS member accounts
- ✅ Creating Identity Center users
- ✅ Creating and assigning Permission Sets
- ✅ Setting up budgets with automatic cost tracking

## Usage

### Budget Notification Configuration

**Default behavior:**

- Budget alerts are sent to **user email + management account email** (auto-detected)
- Management account email is automatically detected from AWS Organizations
- Admin email is always included for monitoring purposes

**Add extra notification recipients:**

```bash
./account-manager.sh create \
  --username alice \
  --email alice@company.com \
  --notification-emails "finance@company.com,cto@company.com"
```

This will send budget alerts to: `alice@company.com`, `admin@org.com`, `finance@company.com`, `cto@company.com`

**Important:** Each recipient will receive **3 confirmation emails** (for 80%, 90%, 100% thresholds).
All recipients must click "Confirm subscription" in each email to receive alerts.

### Create User Environment

```bash
./account-manager.sh create \
  --username alice \
  --email alice@company.com \
  --budget 100
```

**Creates:**

- AWS Account: `alice-dev (123456789012)`
  - Account email auto-generated: `alice+alice-aws@company.com`
- User Identity: `alice` (IAM Identity Center)
- Permission: TerraformDeployer (assigned to account)
- Budget: $100/month (automatic LinkedAccount tracking)
  - Alerts sent to: `alice@company.com` + management account email

**Note:** Account email is automatically generated using + notation.
All emails will be received at the user's email address.

### List All Users

```bash
./account-manager.sh list
```

### Show User Details

```bash
./account-manager.sh show --username alice
```

### Delete User Environment

```bash
./account-manager.sh delete --username alice
```

## Module Scripts

For advanced usage or automation:

### Organization Accounts

```bash
# Create member account
./org-account.sh create --name alice-dev --email alice-aws@company.com

# Get account ID
./org-account.sh get-id --name alice-dev

# List all accounts
./org-account.sh list
```

### Identity Center Users

```bash
# Create user
./identity-user.sh create --username alice --email alice@company.com

# Get user ID
./identity-user.sh get-id --username alice

# List all users
./identity-user.sh list
```

### Permission Sets

```bash
# Create Permission Set
./permission-set.sh create --config permission-sets/terraform-deployer.json

# List Permission Sets
./permission-set.sh list

# Assign to user + account
./permission-set.sh assign \
  --user-id xxxx-xxxx \
  --account-id 123456789012 \
  --permission-set TerraformDeployerPermissionSet

# List assignments
./permission-set.sh list-assignments --account-id 123456789012

# Revoke assignment
./permission-set.sh revoke \
  --user-id xxxx-xxxx \
  --account-id 123456789012 \
  --permission-set TerraformDeployerPermissionSet
```

### Budgets

```bash
# Create budget for member account
./budget.sh create-linked \
  --account-id 123456789012 \
  --name alice-dev-budget \
  --amount 100 \
  --email alice@company.com

# Create global budget
./budget.sh create-global \
  --name org-monthly-budget \
  --amount 1000 \
  --email admin@company.com

# List budgets
./budget.sh list

# Show budget details
./budget.sh show --name alice-dev-budget
```

## User Login Flow

1. User receives IAM Identity Center activation email
2. User clicks link, sets password, and enables MFA
3. User confirms 3 budget alert email subscriptions (80%, 90%, 100%)
   - Admin also receives 3 confirmation emails (if configured with extra recipients, they also receive 3 each)
   - All recipients must confirm subscriptions to receive alerts
4. User gets SSO portal URL:

   ```bash
   aws sso-admin list-instances --query 'Instances[0].[AccessUrl]' --output text
   ```

5. User logs in at portal and selects their account (e.g., `alice-dev`)
6. User works in isolated environment

**✨ No resource tagging required!** All costs automatically tracked via LinkedAccount.

## Project Structure

```text
├── account-manager.sh          # Main orchestrator (create/list/show/delete)
├── org-account.sh           # AWS Organizations account management
├── identity-user.sh         # Identity Center user management
├── permission-set.sh        # Permission Set definition + assignment
├── budget.sh                # Budget management (LinkedAccount)
├── permission-sets/         # Permission Set configs
│   └── terraform-deployer.json
└── policies/                # IAM policies
    └── terraform-deployer-permission-policy.json
```

## Verification

### Check Environment Created

```bash
# Verify user
./account-manager.sh show --username alice

# Or check individually
./identity-user.sh list
./org-account.sh list
./budget.sh list
./permission-set.sh list
```

### User Email Verification (4 emails total)

- 1x IAM Identity Center activation → set password + enable MFA
- 3x Budget alert confirmations → click to confirm

### User Test Access

```bash
# User configures AWS CLI
aws configure sso

# Test access
export AWS_PROFILE=<sso-profile-name>
aws sts get-caller-identity
aws s3 ls  # Test permissions
```

## Key Benefits

### Automatic Cost Tracking

- ✅ **No tagging required** - LinkedAccount filter tracks all resources
- ✅ **100% accurate** - Can't forget to tag resources
- ✅ **Immediate** - No 24-hour delay for tag activation
- ✅ **Zero maintenance** - Set once, works forever

### Perfect Isolation

- ✅ Each user has dedicated AWS account
- ✅ No resource conflicts
- ✅ Clear cost attribution
- ✅ Account-level security boundaries

### Simplified Management

- ✅ One command creates complete environment
- ✅ Modular scripts for automation
- ✅ Built-in budget alerts
- ✅ Easy cleanup

## Troubleshooting

| Issue | Solution |
|-------|----------|
| No Organizations instance | Enable AWS Organizations in console first |
| No Identity Center instance | Enable IAM Identity Center in console first |
| Must run from management account | Use root credentials or admin user from management account |
| Budget alerts not received | Check spam, confirm 3 email subscriptions |
| Account email already in use | Use unique email per account (aliases or + notation) |
| Permission denied for user | Verify MFA enabled, check Permission Set assignment |

## Security Best Practices

1. ✅ **MFA Required** - All users must enable MFA
2. ✅ **Root Access** - Use root only for setup, then IAM Identity Center
3. ✅ **Session Duration** - Default 12 hours (configurable in Permission Set)
4. ✅ **Budget Alerts** - Always confirm email subscriptions
5. ✅ **Account Isolation** - Each user in separate account

## Advanced: Custom Permission Sets

Create custom Permission Set config:

```json
{
  "name": "CustomDeveloper",
  "description": "Custom developer permissions",
  "session_duration": "PT8H",
  "managed_policies": [
    "ReadOnlyAccess"
  ],
  "inline_policy_file": "policies/custom-policy.json"
}
```

Then use it:

```bash
./account-manager.sh create \
  --username alice \
  --email alice@company.com \
  --permission-set-config permission-sets/custom-developer.json
```

## Email Auto-Generation

The script automatically generates a unique account email for each AWS account using + notation:

**Pattern:** `user+username-aws@domain.com`

**Examples:**

- User email: `alice@company.com` → Account email: `alice+alice-aws@company.com`
- User email: `bob@company.com` → Account email: `bob+bob-aws@company.com`

**All emails are received at the user's email address.** Gmail and most email providers ignore the + suffix, so all notifications go to one inbox.
