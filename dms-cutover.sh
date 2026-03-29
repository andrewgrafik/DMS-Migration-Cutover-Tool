#!/usr/bin/env bash

# DMS Migration Cutover Script
# Handles: CDC stop, data verification, Secrets Manager endpoint update

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   DMS Migration Cutover                       ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo

# Step 1: Credentials
echo -e "${BLUE}Step 1: Account Credentials${NC}"
read -p "Source AWS Access Key: " SRC_KEY
read -s -p "Source AWS Secret Key: " SRC_SECRET
echo
read -p "Source Region [us-east-2]: " REGION
REGION=${REGION:-us-east-2}

aws configure set aws_access_key_id "$SRC_KEY" --profile source-account
aws configure set aws_secret_access_key "$SRC_SECRET" --profile source-account
aws configure set region "$REGION" --profile source-account

read -p "Target AWS Access Key: " TGT_KEY
read -s -p "Target AWS Secret Key: " TGT_SECRET
echo

aws configure set aws_access_key_id "$TGT_KEY" --profile target-account
aws configure set aws_secret_access_key "$TGT_SECRET" --profile target-account
aws configure set region "$REGION" --profile target-account

SRC_ACCOUNT=$(aws sts get-caller-identity --profile source-account --query Account --output text)
TGT_ACCOUNT=$(aws sts get-caller-identity --profile target-account --query Account --output text)
echo -e "${GREEN}✓ Source: $SRC_ACCOUNT | Target: $TGT_ACCOUNT${NC}"
echo

# Step 2: Select CDC task
echo -e "${BLUE}Step 2: Select CDC Task${NC}"
TASKS=$(aws dms describe-replication-tasks --profile target-account --region $REGION \
    --query 'ReplicationTasks[*].[ReplicationTaskIdentifier,Status,ReplicationTaskArn]' --output text)

if [ -z "$TASKS" ]; then
    echo -e "${RED}No DMS tasks found on target account${NC}"
    exit 1
fi

i=1
declare -A TASK_MAP
declare -A TASK_ARN_MAP
while IFS=$'\t' read -r id status arn; do
    echo "$i) $id ($status)"
    TASK_MAP[$i]=$id
    TASK_ARN_MAP[$i]=$arn
    ((i++))
done <<< "$TASKS"

echo
read -p "Select CDC task: " TASK_NUM
CDC_TASK_ID=${TASK_MAP[$TASK_NUM]}
CDC_TASK_ARN=${TASK_ARN_MAP[$TASK_NUM]}
echo -e "${GREEN}✓ Selected: $CDC_TASK_ID${NC}"
echo

# Step 3: Check CDC latency
echo -e "${BLUE}Step 3: CDC Latency Check${NC}"
CDC_INFO=$(aws dms describe-replication-tasks --filters "Name=replication-task-id,Values=$CDC_TASK_ID" \
    --profile target-account --region $REGION \
    --query 'ReplicationTasks[0].{Status:Status,CDCLatency:ReplicationTaskStats.CDCLatencySource}' --output json)

CDC_STATUS=$(echo "$CDC_INFO" | jq -r '.Status')
CDC_LATENCY=$(echo "$CDC_INFO" | jq -r '.CDCLatency // "N/A"')
echo "  Task Status: $CDC_STATUS"
echo "  CDC Latency: ${CDC_LATENCY}s"

if [ "$CDC_LATENCY" != "0" ] && [ "$CDC_LATENCY" != "N/A" ] && [ "$CDC_LATENCY" != "null" ]; then
    echo -e "${YELLOW}⚠ CDC latency is ${CDC_LATENCY}s — ideally should be 0 before cutover${NC}"
    read -p "Continue anyway? (yes/no): " CONT
    [ "$CONT" != "yes" ] && echo "Cancelled" && exit 0
fi
echo

# Step 4: Source & Target RDS info
echo -e "${BLUE}Step 4: Identify Source & Target RDS${NC}"

TASK_DETAIL=$(aws dms describe-replication-tasks --filters "Name=replication-task-id,Values=$CDC_TASK_ID" \
    --profile target-account --region $REGION --output json)
SOURCE_EP_ARN=$(echo "$TASK_DETAIL" | jq -r '.ReplicationTasks[0].SourceEndpointArn')
TARGET_EP_ARN=$(echo "$TASK_DETAIL" | jq -r '.ReplicationTasks[0].TargetEndpointArn')

TGT_SERVER=$(aws dms describe-endpoints --filters "Name=endpoint-arn,Values=$TARGET_EP_ARN" \
    --profile target-account --region $REGION --query 'Endpoints[0].ServerName' --output text)
TGT_PORT=$(aws dms describe-endpoints --filters "Name=endpoint-arn,Values=$TARGET_EP_ARN" \
    --profile target-account --region $REGION --query 'Endpoints[0].Port' --output text)
TGT_DBNAME=$(aws dms describe-endpoints --filters "Name=endpoint-arn,Values=$TARGET_EP_ARN" \
    --profile target-account --region $REGION --query 'Endpoints[0].DatabaseName' --output text)

SRC_SERVER=$(aws dms describe-endpoints --filters "Name=endpoint-arn,Values=$SOURCE_EP_ARN" \
    --profile target-account --region $REGION --query 'Endpoints[0].ServerName' --output text)

# Get source RDS endpoint (might be private IP, resolve actual hostname)
SRC_RDS_ENDPOINT=$(aws rds describe-db-instances --profile source-account --region $REGION \
    --query 'DBInstances[?Engine==`postgres`].Endpoint.Address' --output text | head -1)

echo "  Source: $SRC_RDS_ENDPOINT"
echo "  Target: $TGT_SERVER:$TGT_PORT/$TGT_DBNAME"
echo

# Step 5: Data verification
echo -e "${BLUE}Step 5: Data Verification${NC}"
echo "  Fetching table stats from DMS..."

# Get full load task (most recent stopped one) or CDC task stats
ALL_TASKS=$(aws dms describe-replication-tasks --profile target-account --region $REGION \
    --query 'ReplicationTasks[*].ReplicationTaskArn' --output text)

for task_arn in $ALL_TASKS; do
    echo "  Task: $(aws dms describe-replication-tasks --filters "Name=replication-task-arn,Values=$task_arn" \
        --profile target-account --region $REGION --query 'ReplicationTasks[0].ReplicationTaskIdentifier' --output text)"
    aws dms describe-table-statistics --replication-task-arn "$task_arn" \
        --profile target-account --region $REGION \
        --query 'TableStatistics[*].{Table:TableName,FullLoadRows:FullLoadRows,Inserts:Inserts,Updates:Updates,Deletes:Deletes}' \
        --output table 2>/dev/null || echo "  No stats available"
    echo
done

read -p "Data looks correct? Proceed with cutover? (yes/no): " VERIFY
[ "$VERIFY" != "yes" ] && echo "Cancelled" && exit 0
echo

# Step 6: Stop CDC task
echo -e "${BLUE}Step 6: Stop CDC Task${NC}"
echo -e "${YELLOW}⚠ IMPORTANT: Ensure application writes to source DB are STOPPED before proceeding${NC}"
read -p "Have you stopped application writes? (yes/no): " WRITES_STOPPED
[ "$WRITES_STOPPED" != "yes" ] && echo "Stop application writes first, then re-run" && exit 0

echo "  Waiting for final CDC catch-up..."
sleep 10

# Check latency one more time
FINAL_LATENCY=$(aws dms describe-replication-tasks --filters "Name=replication-task-id,Values=$CDC_TASK_ID" \
    --profile target-account --region $REGION \
    --query 'ReplicationTasks[0].ReplicationTaskStats.CDCLatencySource' --output text 2>/dev/null || echo "0")
echo "  Final CDC latency: ${FINAL_LATENCY}s"

echo "  Stopping CDC task..."
aws dms stop-replication-task --replication-task-arn "$CDC_TASK_ARN" \
    --profile target-account --region $REGION > /dev/null

while true; do
    STATUS=$(aws dms describe-replication-tasks --filters "Name=replication-task-id,Values=$CDC_TASK_ID" \
        --profile target-account --region $REGION \
        --query 'ReplicationTasks[0].Status' --output text)
    [ "$STATUS" = "stopped" ] && break
    echo "  Status: $STATUS..."
    sleep 10
done
echo -e "${GREEN}✓ CDC task stopped${NC}"
echo

# Step 7: Secrets Manager update
echo -e "${BLUE}Step 7: Update Secrets Manager${NC}"
echo
echo "Which account has the secret to update?"
echo "1) Source account ($SRC_ACCOUNT)"
echo "2) Target account ($TGT_ACCOUNT)"
echo "3) Skip — I'll update manually"
read -p "Select: " SECRET_ACCOUNT

if [ "$SECRET_ACCOUNT" = "3" ]; then
    echo "  Skipped. Update your application config manually:"
    echo "  Old endpoint: $SRC_RDS_ENDPOINT"
    echo "  New endpoint: $TGT_SERVER"
else
    if [ "$SECRET_ACCOUNT" = "1" ]; then
        SECRET_PROFILE="source-account"
    else
        SECRET_PROFILE="target-account"
    fi

    # List secrets
    SECRETS=$(aws secretsmanager list-secrets --profile "$SECRET_PROFILE" --region $REGION \
        --query 'SecretList[*].[Name,ARN]' --output text 2>/dev/null || echo "")

    if [ -z "$SECRETS" ]; then
        echo "  No secrets found. Creating new secret..."
        read -p "  Secret name [rds/migration/endpoint]: " SECRET_NAME
        SECRET_NAME=${SECRET_NAME:-rds/migration/endpoint}

        read -p "  DB Username [postgres]: " DB_USER
        DB_USER=${DB_USER:-postgres}
        read -s -p "  DB Password: " DB_PASS
        echo

        SECRET_VALUE=$(jq -n \
            --arg host "$TGT_SERVER" \
            --arg port "$TGT_PORT" \
            --arg dbname "$TGT_DBNAME" \
            --arg user "$DB_USER" \
            --arg pass "$DB_PASS" \
            --arg engine "postgres" \
            '{host:$host,port:($port|tonumber),dbname:$dbname,username:$user,password:$pass,engine:$engine}')

        aws secretsmanager create-secret \
            --name "$SECRET_NAME" \
            --description "RDS PostgreSQL endpoint (migrated)" \
            --secret-string "$SECRET_VALUE" \
            --profile "$SECRET_PROFILE" --region $REGION > /dev/null

        echo -e "${GREEN}✓ Created secret: $SECRET_NAME${NC}"
    else
        echo "  Existing secrets:"
        i=1
        declare -A SECRET_MAP
        declare -A SECRET_ARN_MAP
        echo "  0) Create new secret"
        while IFS=$'\t' read -r sname sarn; do
            echo "  $i) $sname"
            SECRET_MAP[$i]=$sname
            SECRET_ARN_MAP[$i]=$sarn
            ((i++))
        done <<< "$SECRETS"

        echo
        read -p "  Select secret to update (or 0 for new): " SECRET_NUM

        if [ "$SECRET_NUM" = "0" ]; then
            read -p "  Secret name [rds/migration/endpoint]: " SECRET_NAME
            SECRET_NAME=${SECRET_NAME:-rds/migration/endpoint}

            read -p "  DB Username [postgres]: " DB_USER
            DB_USER=${DB_USER:-postgres}
            read -s -p "  DB Password: " DB_PASS
            echo

            SECRET_VALUE=$(jq -n \
                --arg host "$TGT_SERVER" \
                --arg port "$TGT_PORT" \
                --arg dbname "$TGT_DBNAME" \
                --arg user "$DB_USER" \
                --arg pass "$DB_PASS" \
                --arg engine "postgres" \
                '{host:$host,port:($port|tonumber),dbname:$dbname,username:$user,password:$pass,engine:$engine}')

            aws secretsmanager create-secret \
                --name "$SECRET_NAME" \
                --description "RDS PostgreSQL endpoint (migrated)" \
                --secret-string "$SECRET_VALUE" \
                --profile "$SECRET_PROFILE" --region $REGION > /dev/null

            echo -e "${GREEN}✓ Created secret: $SECRET_NAME${NC}"
        else
            SELECTED_SECRET=${SECRET_MAP[$SECRET_NUM]}
            echo "  Updating secret: $SELECTED_SECRET"

            # Get current secret value
            CURRENT=$(aws secretsmanager get-secret-value --secret-id "$SELECTED_SECRET" \
                --profile "$SECRET_PROFILE" --region $REGION \
                --query 'SecretString' --output text 2>/dev/null || echo "{}")

            echo "  Current value:"
            echo "$CURRENT" | jq -r 'to_entries[] | "    \(.key): \(.value)"' 2>/dev/null || echo "    $CURRENT"
            echo

            # Update host/port/dbname
            UPDATED=$(echo "$CURRENT" | jq \
                --arg host "$TGT_SERVER" \
                --arg port "$TGT_PORT" \
                --arg dbname "$TGT_DBNAME" \
                '.host=$host | .port=($port|tonumber) | .dbname=$dbname' 2>/dev/null)

            if [ -z "$UPDATED" ] || [ "$UPDATED" = "null" ]; then
                read -p "  DB Username [postgres]: " DB_USER
                DB_USER=${DB_USER:-postgres}
                read -s -p "  DB Password: " DB_PASS
                echo
                UPDATED=$(jq -n \
                    --arg host "$TGT_SERVER" \
                    --arg port "$TGT_PORT" \
                    --arg dbname "$TGT_DBNAME" \
                    --arg user "$DB_USER" \
                    --arg pass "$DB_PASS" \
                    --arg engine "postgres" \
                    '{host:$host,port:($port|tonumber),dbname:$dbname,username:$user,password:$pass,engine:$engine}')
            fi

            echo "  New value:"
            echo "$UPDATED" | jq -r 'to_entries[] | "    \(.key): \(.value)"'
            echo

            read -p "  Confirm update? (yes/no): " CONFIRM_UPDATE
            if [ "$CONFIRM_UPDATE" = "yes" ]; then
                aws secretsmanager update-secret \
                    --secret-id "$SELECTED_SECRET" \
                    --secret-string "$UPDATED" \
                    --profile "$SECRET_PROFILE" --region $REGION > /dev/null
                echo -e "${GREEN}✓ Secret updated: $SELECTED_SECRET${NC}"
            else
                echo "  Skipped"
            fi
        fi
    fi
fi
echo

# Step 8: Summary
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       Cutover Complete!                       ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo
echo "  Old endpoint: $SRC_RDS_ENDPOINT"
echo "  New endpoint: $TGT_SERVER:$TGT_PORT/$TGT_DBNAME"
echo "  CDC task: $CDC_TASK_ID (stopped)"
echo
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Update application to use new endpoint (if not using Secrets Manager)"
echo "  2. Restart application"
echo "  3. Verify application is working"
echo "  4. Clean up DMS resources when confirmed stable"
echo
echo -e "${YELLOW}Rollback (if needed):${NC}"
echo "  1. Point application back to: $SRC_RDS_ENDPOINT"
echo "  2. Restart CDC task to re-sync any changes made to target"
echo

aws configure --profile source-account set aws_access_key_id "" 2>/dev/null || true
aws configure --profile target-account set aws_access_key_id "" 2>/dev/null || true
