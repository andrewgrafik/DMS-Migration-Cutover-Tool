# DMS Migration Cutover Tool

Automated cutover tool for AWS DMS PostgreSQL migrations. Handles CDC task stop, data verification, Secrets Manager endpoint update, and provides rollback instructions.

## Features

- ✅ **CDC Latency Check**: Verifies replication lag before cutover
- ✅ **Data Verification**: Shows DMS table statistics for all migration tasks
- ✅ **Safe Cutover**: Confirms application writes are stopped before proceeding
- ✅ **Secrets Manager Integration**: Create or update secrets with new endpoint
- ✅ **Interactive Workflow**: Step-by-step guided process with confirmations
- ✅ **Rollback Instructions**: Provides rollback steps if issues arise
- ✅ **Credential Management**: Persistent AWS profile configuration
- ✅ **Multi-Task Support**: Lists all DMS tasks for selection

## Prerequisites

- Bash 4.0 or higher
- AWS CLI installed and configured
- `jq` command-line JSON processor
- Access credentials for both source and target AWS accounts
- A running DMS CDC task (created by `dms-pg-migrate.sh`)

## Required IAM Permissions

### Source Account

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBInstances",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

### Target Account

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dms:DescribeReplicationTasks",
        "dms:DescribeEndpoints",
        "dms:DescribeTableStatistics",
        "dms:StopReplicationTask",
        "secretsmanager:ListSecrets",
        "secretsmanager:GetSecretValue",
        "secretsmanager:CreateSecret",
        "secretsmanager:UpdateSecret",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

Note: Secrets Manager permissions are optional — only needed if updating endpoints via Secrets Manager.

## Usage

```bash
chmod +x dms-cutover.sh
./dms-cutover.sh
```

## Cutover Workflow

### Step 1: Account Credentials
- Enter AWS access credentials for source and target accounts
- Automatic validation of both accounts
- Displays account IDs upon successful authentication

### Step 2: Select CDC Task
- Lists all DMS replication tasks on target account
- Shows task identifier and current status
- Select the CDC task to stop during cutover

### Step 3: CDC Latency Check
- Displays current CDC task status and replication lag
- Warns if latency is not zero
- Option to proceed or wait for lag to reach zero

### Step 4: Identify Source & Target RDS
- Resolves source and target endpoints from DMS task configuration
- Displays old (source) and new (target) database endpoints
- Shows port and database name

### Step 5: Data Verification
- Fetches DMS table statistics for all migration tasks
- Shows per-table row counts: full load rows, inserts, updates, deletes
- Confirmation prompt before proceeding

### Step 6: Stop CDC Task
- **Safety check**: Confirms application writes to source DB are stopped
- Waits 10 seconds for final CDC catch-up
- Checks final CDC latency
- Stops the CDC replication task
- Waits for task to reach `stopped` status

### Step 7: Update Secrets Manager
- **Option 1**: Update secret in source account
- **Option 2**: Update secret in target account
- **Option 3**: Skip — update manually

For Options 1 & 2:
- Lists existing secrets or creates a new one
- For existing secrets: reads current value, replaces host/port/dbname, preserves other fields
- For new secrets: creates with host, port, dbname, username, password, engine
- Confirmation prompt before applying changes

### Step 8: Summary
- Displays old and new endpoints
- Shows CDC task status
- Provides next steps and rollback instructions

## Secrets Manager Integration

### Secret Format

The tool creates/updates secrets in standard RDS format:

```json
{
  "host": "target-amaxrating.abc123.us-east-2.rds.amazonaws.com",
  "port": 5432,
  "dbname": "postgres",
  "username": "postgres",
  "password": "********",
  "engine": "postgres"
}
```

### Update Behavior

When updating an existing secret:
- ✅ Updates `host`, `port`, `dbname` to target values
- ✅ Preserves `username`, `password`, and any custom fields
- ✅ Shows before/after values for confirmation

### Application Integration

Applications using Secrets Manager can pick up the new endpoint automatically:

```python
# Python example — no code change needed after secret update
import boto3
import json

client = boto3.client('secretsmanager')
secret = json.loads(client.get_secret_value(SecretId='rds/myapp/endpoint')['SecretString'])
connection = psycopg2.connect(
    host=secret['host'],
    port=secret['port'],
    dbname=secret['dbname'],
    user=secret['username'],
    password=secret['password']
)
```

## Cutover Timing

| Step | Duration |
|---|---|
| CDC latency check | ~5 seconds |
| Stop application writes | Customer-dependent |
| Final CDC catch-up | ~10-30 seconds |
| Stop CDC task | ~10-30 seconds |
| Update Secrets Manager | ~5 seconds |
| Restart application | Customer-dependent |
| **Total downtime** | **~1-2 minutes** |

## Pre-Cutover Checklist

Before running the cutover script:

- [ ] CDC task is running with latency near zero
- [ ] Target RDS has been verified (spot-check queries)
- [ ] Application team is ready to stop writes
- [ ] Maintenance window communicated to stakeholders
- [ ] Rollback plan reviewed
- [ ] DNS TTL lowered (if using Route 53)

## Post-Cutover Verification

### Verify Application Connectivity
```bash
# Check target RDS is accepting connections
psql -h <target-endpoint> -U postgres -d postgres -c "SELECT 1;"

# Verify row counts match
psql -h <target-endpoint> -U postgres -d postgres -c "SELECT count(*) FROM <table>;"
```

### Verify Secrets Manager Update
```bash
aws secretsmanager get-secret-value --secret-id <secret-name> --query 'SecretString' --output text | jq .
```

### Monitor Application Logs
```bash
# Check for connection errors after cutover
aws logs filter-log-events --log-group-name <app-log-group> --start-time $(date -d '5 minutes ago' +%s000)
```

## Rollback

If issues arise after cutover:

### Quick Rollback (< 5 minutes)
1. Point application back to source endpoint
2. Restart application
3. Source DB still has all data (was not modified)

### Rollback with Data Sync
If writes were made to target after cutover:
1. Stop application writes to target
2. Create reverse DMS task (target → source)
3. Sync delta changes back to source
4. Point application to source
5. Resume application

### Rollback Secrets Manager
```bash
# Revert to source endpoint
aws secretsmanager update-secret \
    --secret-id <secret-name> \
    --secret-string '{"host":"<source-endpoint>","port":5432,"dbname":"postgres","username":"postgres","password":"<password>","engine":"postgres"}'
```

## Troubleshooting

### CDC Latency Not Reaching Zero
- Check source DB write activity — high write volume increases lag
- Verify DMS replication instance has sufficient resources (CPU, memory)
- Check DMS CloudWatch logs for errors

### Secrets Manager Permission Denied
- Ensure IAM user has `secretsmanager:UpdateSecret` permission
- Check if secret has a resource policy restricting access
- Verify KMS key permissions if secret is encrypted with CMK

### CDC Task Won't Stop
- Check DMS console for task errors
- Force stop via console if CLI fails
- Check CloudWatch logs: `/aws/dms/tasks/<task-id>`

### Application Can't Connect After Cutover
- Verify target RDS security group allows application CIDR
- Check target RDS is publicly accessible (if needed)
- Verify Secrets Manager secret has correct values
- Check application connection pool — may need restart to pick up new endpoint

## Migration Toolkit

This tool is part of the DMS PostgreSQL Migration Toolkit:

| Script | Purpose | When to Run |
|---|---|---|
| 🔍 `db-assessment.sh` | Database discovery & complexity scoring | Before planning |
| 🚀 `dms-pg-migrate.sh` | Full migration (VPC peering → RDS → DMS → full load → CDC) | Migration execution |
| ✂️ **`dms-cutover.sh`** | **Stop CDC, verify data, update Secrets Manager** | **Cutover day** |
| 🧹 `dms-cleanup.sh` | Remove all DMS resources, peering, routes | After migration confirmed stable |

## Notes

- AWS profiles `source-account` and `target-account` are cleared after cutover
- Source RDS is not modified — remains available for rollback
- CDC task is stopped, not deleted — can be restarted if rollback needed
- Secrets Manager update is immediate — applications using cached secrets may need restart

## Related Tools

- [EC2 Cross-Account Migration](https://github.com/andrewgrafik/Crossaccount-EC2-Migration.git)
- [RDS PostgreSQL Cross-Account Migration (Snapshot)](https://github.com/andrewgrafik/RDS-PostgreSQL-Cross-Account-Migration-Tool.git)
