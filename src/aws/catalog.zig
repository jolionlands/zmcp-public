//! Bundled hint table for aws_suggest. A HINT only: any read operation of any
//! service works with aws_call whether or not it is listed here.

const std = @import("std");
const policy = @import("policy.zig");

pub const Entry = struct {
    svc: []const u8,
    op: []const u8,
    desc: []const u8,
    /// Example `params` JSON (empty when none needed).
    ex: []const u8 = "",
};

pub const entries = [_]Entry{
    // identity / org
    .{ .svc = "sts", .op = "get-caller-identity", .desc = "who am I (account, arn)" },
    .{ .svc = "iam", .op = "list-users", .desc = "list IAM users" },
    .{ .svc = "iam", .op = "list-roles", .desc = "list IAM roles" },
    .{ .svc = "iam", .op = "list-groups", .desc = "list IAM groups" },
    .{ .svc = "iam", .op = "list-policies", .desc = "list IAM policies", .ex = "{\"scope\":\"Local\"}" },
    .{ .svc = "iam", .op = "get-role", .desc = "role details and trust policy", .ex = "{\"role-name\":\"NAME\"}" },
    .{ .svc = "iam", .op = "get-user", .desc = "IAM user details", .ex = "{\"user-name\":\"NAME\"}" },
    .{ .svc = "iam", .op = "list-attached-role-policies", .desc = "managed policies on a role", .ex = "{\"role-name\":\"NAME\"}" },
    .{ .svc = "iam", .op = "list-role-policies", .desc = "inline policy names on a role", .ex = "{\"role-name\":\"NAME\"}" },
    .{ .svc = "iam", .op = "get-policy", .desc = "managed policy metadata", .ex = "{\"policy-arn\":\"ARN\"}" },
    .{ .svc = "iam", .op = "get-policy-version", .desc = "policy document", .ex = "{\"policy-arn\":\"ARN\",\"version-id\":\"v1\"}" },
    .{ .svc = "iam", .op = "list-access-keys", .desc = "access key ids of a user (no secrets)", .ex = "{\"user-name\":\"NAME\"}" },
    .{ .svc = "iam", .op = "get-account-summary", .desc = "IAM quotas and usage counts" },
    .{ .svc = "iam", .op = "list-account-aliases", .desc = "account alias" },
    .{ .svc = "iam", .op = "simulate-principal-policy", .desc = "test whether a principal may do actions", .ex = "{\"policy-source-arn\":\"ARN\",\"action-names\":[\"s3:GetObject\"]}" },
    .{ .svc = "organizations", .op = "list-accounts", .desc = "accounts in the organization" },
    .{ .svc = "organizations", .op = "describe-organization", .desc = "organization details" },
    .{ .svc = "account", .op = "list-regions", .desc = "regions and opt-in status" },
    // ec2
    .{ .svc = "ec2", .op = "describe-instances", .desc = "list EC2 instances", .ex = "{\"filters\":\"Name=instance-state-name,Values=running\"}" },
    .{ .svc = "ec2", .op = "describe-instance-status", .desc = "instance health checks", .ex = "{\"include-all-instances\":true}" },
    .{ .svc = "ec2", .op = "describe-images", .desc = "AMIs", .ex = "{\"owners\":[\"self\"]}" },
    .{ .svc = "ec2", .op = "describe-volumes", .desc = "EBS volumes" },
    .{ .svc = "ec2", .op = "describe-snapshots", .desc = "EBS snapshots", .ex = "{\"owner-ids\":[\"self\"]}" },
    .{ .svc = "ec2", .op = "describe-security-groups", .desc = "security groups and rules" },
    .{ .svc = "ec2", .op = "describe-security-group-rules", .desc = "individual SG rules" },
    .{ .svc = "ec2", .op = "describe-vpcs", .desc = "VPCs" },
    .{ .svc = "ec2", .op = "describe-subnets", .desc = "subnets" },
    .{ .svc = "ec2", .op = "describe-route-tables", .desc = "route tables" },
    .{ .svc = "ec2", .op = "describe-internet-gateways", .desc = "internet gateways" },
    .{ .svc = "ec2", .op = "describe-nat-gateways", .desc = "NAT gateways" },
    .{ .svc = "ec2", .op = "describe-network-interfaces", .desc = "ENIs" },
    .{ .svc = "ec2", .op = "describe-addresses", .desc = "elastic IPs" },
    .{ .svc = "ec2", .op = "describe-key-pairs", .desc = "key pair names (no key material)" },
    .{ .svc = "ec2", .op = "describe-regions", .desc = "regions enabled for the account" },
    .{ .svc = "ec2", .op = "describe-availability-zones", .desc = "AZs in the region" },
    .{ .svc = "ec2", .op = "describe-tags", .desc = "tags", .ex = "{\"filters\":\"Name=resource-id,Values=i-123\"}" },
    .{ .svc = "ec2", .op = "describe-launch-templates", .desc = "launch templates" },
    .{ .svc = "ec2", .op = "describe-transit-gateways", .desc = "transit gateways" },
    .{ .svc = "ec2", .op = "describe-vpc-endpoints", .desc = "VPC endpoints" },
    .{ .svc = "ec2", .op = "describe-instance-types", .desc = "instance type specs", .ex = "{\"instance-types\":[\"m5.large\"]}" },
    .{ .svc = "ec2", .op = "describe-spot-price-history", .desc = "spot prices", .ex = "{\"instance-types\":[\"m5.large\"],\"product-descriptions\":[\"Linux/UNIX\"]}" },
    .{ .svc = "ec2", .op = "start-instances", .desc = "WRITE: start instances", .ex = "{\"instance-ids\":[\"i-123\"]}" },
    .{ .svc = "ec2", .op = "stop-instances", .desc = "DESTRUCTIVE: stop instances", .ex = "{\"instance-ids\":[\"i-123\"]}" },
    .{ .svc = "ec2", .op = "terminate-instances", .desc = "DESTRUCTIVE: terminate instances", .ex = "{\"instance-ids\":[\"i-123\"]}" },
    // s3
    .{ .svc = "s3", .op = "ls", .desc = "list buckets or objects (text output)", .ex = "args=[\"s3://bucket/prefix/\"]" },
    .{ .svc = "s3api", .op = "list-buckets", .desc = "list buckets" },
    .{ .svc = "s3api", .op = "list-objects-v2", .desc = "list objects", .ex = "{\"bucket\":\"B\",\"prefix\":\"p/\"}" },
    .{ .svc = "s3api", .op = "head-object", .desc = "object metadata, no body", .ex = "{\"bucket\":\"B\",\"key\":\"K\"}" },
    .{ .svc = "s3api", .op = "head-bucket", .desc = "does the bucket exist / is it accessible", .ex = "{\"bucket\":\"B\"}" },
    .{ .svc = "s3api", .op = "get-bucket-location", .desc = "bucket region", .ex = "{\"bucket\":\"B\"}" },
    .{ .svc = "s3api", .op = "get-bucket-policy", .desc = "bucket policy", .ex = "{\"bucket\":\"B\"}" },
    .{ .svc = "s3api", .op = "get-bucket-versioning", .desc = "versioning state", .ex = "{\"bucket\":\"B\"}" },
    .{ .svc = "s3api", .op = "get-bucket-encryption", .desc = "default encryption", .ex = "{\"bucket\":\"B\"}" },
    .{ .svc = "s3api", .op = "get-public-access-block", .desc = "public access block", .ex = "{\"bucket\":\"B\"}" },
    .{ .svc = "s3api", .op = "get-bucket-lifecycle-configuration", .desc = "lifecycle rules", .ex = "{\"bucket\":\"B\"}" },
    .{ .svc = "s3api", .op = "list-object-versions", .desc = "object versions", .ex = "{\"bucket\":\"B\",\"prefix\":\"K\"}" },
    .{ .svc = "s3api", .op = "get-object", .desc = "download (needs ZMCP_AWS_DOWNLOAD_DIR; args=[filename])", .ex = "{\"bucket\":\"B\",\"key\":\"K\"} args=[\"out.bin\"]" },
    .{ .svc = "s3", .op = "cp", .desc = "WRITE: copy to/from S3", .ex = "args=[\"s3://b/k\",\"local.txt\"]" },
    .{ .svc = "s3", .op = "rm", .desc = "DESTRUCTIVE: delete objects", .ex = "args=[\"s3://b/k\"]" },
    // lambda
    .{ .svc = "lambda", .op = "list-functions", .desc = "Lambda functions" },
    .{ .svc = "lambda", .op = "get-function", .desc = "function config + code location (presigned URL is scrubbed)", .ex = "{\"function-name\":\"F\"}" },
    .{ .svc = "lambda", .op = "get-function-configuration", .desc = "function config (env values redacted)", .ex = "{\"function-name\":\"F\"}" },
    .{ .svc = "lambda", .op = "list-event-source-mappings", .desc = "event source mappings" },
    .{ .svc = "lambda", .op = "list-layers", .desc = "layers" },
    .{ .svc = "lambda", .op = "list-aliases", .desc = "aliases of a function", .ex = "{\"function-name\":\"F\"}" },
    .{ .svc = "lambda", .op = "list-versions-by-function", .desc = "versions of a function", .ex = "{\"function-name\":\"F\"}" },
    .{ .svc = "lambda", .op = "invoke", .desc = "DESTRUCTIVE: run a function (needs outfile positional)", .ex = "{\"function-name\":\"F\"} args=[\"/dev/null\"]" },
    // logs / monitoring
    .{ .svc = "logs", .op = "describe-log-groups", .desc = "log groups", .ex = "{\"log-group-name-prefix\":\"/aws/lambda\"}" },
    .{ .svc = "logs", .op = "describe-log-streams", .desc = "streams in a group", .ex = "{\"log-group-name\":\"G\",\"order-by\":\"LastEventTime\",\"descending\":true}" },
    .{ .svc = "logs", .op = "filter-log-events", .desc = "search log events", .ex = "{\"log-group-name\":\"G\",\"filter-pattern\":\"ERROR\",\"limit\":50}" },
    .{ .svc = "logs", .op = "get-log-events", .desc = "events of one stream", .ex = "{\"log-group-name\":\"G\",\"log-stream-name\":\"S\",\"limit\":50}" },
    .{ .svc = "logs", .op = "tail", .desc = "recent events of a group (no --follow)", .ex = "args=[\"G\"] {\"since\":\"10m\"}" },
    .{ .svc = "logs", .op = "get-query-results", .desc = "results of a Logs Insights query", .ex = "{\"query-id\":\"ID\"}" },
    .{ .svc = "cloudwatch", .op = "describe-alarms", .desc = "alarms", .ex = "{\"state-value\":\"ALARM\"}" },
    .{ .svc = "cloudwatch", .op = "list-metrics", .desc = "metrics", .ex = "{\"namespace\":\"AWS/EC2\"}" },
    .{ .svc = "cloudwatch", .op = "get-metric-statistics", .desc = "metric datapoints", .ex = "{\"namespace\":\"AWS/EC2\",\"metric-name\":\"CPUUtilization\",\"start-time\":\"2026-01-01T00:00:00Z\",\"end-time\":\"2026-01-02T00:00:00Z\",\"period\":3600,\"statistics\":[\"Average\"]}" },
    .{ .svc = "cloudwatch", .op = "list-dashboards", .desc = "dashboards" },
    .{ .svc = "cloudtrail", .op = "lookup-events", .desc = "recent management events", .ex = "{\"lookup-attributes\":\"AttributeKey=EventName,AttributeValue=RunInstances\"}" },
    .{ .svc = "cloudtrail", .op = "describe-trails", .desc = "trails" },
    .{ .svc = "events", .op = "list-rules", .desc = "EventBridge rules" },
    .{ .svc = "config", .op = "describe-config-rules", .desc = "AWS Config rules" },
    .{ .svc = "xray", .op = "get-service-graph", .desc = "X-Ray service graph", .ex = "{\"start-time\":\"2026-01-01T00:00:00Z\",\"end-time\":\"2026-01-01T01:00:00Z\"}" },
    // containers
    .{ .svc = "ecs", .op = "list-clusters", .desc = "ECS clusters" },
    .{ .svc = "ecs", .op = "list-services", .desc = "services in a cluster", .ex = "{\"cluster\":\"C\"}" },
    .{ .svc = "ecs", .op = "describe-services", .desc = "service details", .ex = "{\"cluster\":\"C\",\"services\":[\"S\"]}" },
    .{ .svc = "ecs", .op = "list-tasks", .desc = "tasks in a cluster", .ex = "{\"cluster\":\"C\"}" },
    .{ .svc = "ecs", .op = "describe-tasks", .desc = "task details", .ex = "{\"cluster\":\"C\",\"tasks\":[\"ARN\"]}" },
    .{ .svc = "ecs", .op = "describe-task-definition", .desc = "task definition (env secrets redacted)", .ex = "{\"task-definition\":\"T\"}" },
    .{ .svc = "ecs", .op = "describe-clusters", .desc = "cluster details", .ex = "{\"clusters\":[\"C\"]}" },
    .{ .svc = "eks", .op = "list-clusters", .desc = "EKS clusters" },
    .{ .svc = "eks", .op = "describe-cluster", .desc = "cluster details", .ex = "{\"name\":\"C\"}" },
    .{ .svc = "eks", .op = "list-nodegroups", .desc = "node groups", .ex = "{\"cluster-name\":\"C\"}" },
    .{ .svc = "ecr", .op = "describe-repositories", .desc = "ECR repositories" },
    .{ .svc = "ecr", .op = "describe-images", .desc = "images in a repo", .ex = "{\"repository-name\":\"R\"}" },
    .{ .svc = "ecr", .op = "list-images", .desc = "image ids in a repo", .ex = "{\"repository-name\":\"R\"}" },
    // databases
    .{ .svc = "rds", .op = "describe-db-instances", .desc = "RDS instances" },
    .{ .svc = "rds", .op = "describe-db-clusters", .desc = "Aurora/RDS clusters" },
    .{ .svc = "rds", .op = "describe-db-snapshots", .desc = "RDS snapshots" },
    .{ .svc = "rds", .op = "describe-db-parameter-groups", .desc = "parameter groups" },
    .{ .svc = "rds", .op = "describe-events", .desc = "RDS events", .ex = "{\"duration\":60}" },
    .{ .svc = "dynamodb", .op = "list-tables", .desc = "DynamoDB tables" },
    .{ .svc = "dynamodb", .op = "describe-table", .desc = "table schema and size", .ex = "{\"table-name\":\"T\"}" },
    .{ .svc = "dynamodb", .op = "get-item", .desc = "read one item", .ex = "{\"table-name\":\"T\",\"key\":{\"id\":{\"S\":\"1\"}}}" },
    .{ .svc = "dynamodb", .op = "query", .desc = "query by key", .ex = "{\"table-name\":\"T\",\"key-condition-expression\":\"id = :i\",\"expression-attribute-values\":{\":i\":{\"S\":\"1\"}}}" },
    .{ .svc = "dynamodb", .op = "scan", .desc = "scan a table (use max_items)", .ex = "{\"table-name\":\"T\",\"limit\":25}" },
    .{ .svc = "elasticache", .op = "describe-cache-clusters", .desc = "ElastiCache clusters" },
    .{ .svc = "redshift", .op = "describe-clusters", .desc = "Redshift clusters" },
    .{ .svc = "opensearch", .op = "list-domain-names", .desc = "OpenSearch domains" },
    .{ .svc = "docdb", .op = "describe-db-clusters", .desc = "DocumentDB clusters" },
    // networking / edge
    .{ .svc = "elbv2", .op = "describe-load-balancers", .desc = "ALB/NLB" },
    .{ .svc = "elbv2", .op = "describe-target-groups", .desc = "target groups" },
    .{ .svc = "elbv2", .op = "describe-target-health", .desc = "target health", .ex = "{\"target-group-arn\":\"ARN\"}" },
    .{ .svc = "elbv2", .op = "describe-listeners", .desc = "listeners", .ex = "{\"load-balancer-arn\":\"ARN\"}" },
    .{ .svc = "route53", .op = "list-hosted-zones", .desc = "hosted zones" },
    .{ .svc = "route53", .op = "list-resource-record-sets", .desc = "DNS records", .ex = "{\"hosted-zone-id\":\"Z123\"}" },
    .{ .svc = "cloudfront", .op = "list-distributions", .desc = "CloudFront distributions" },
    .{ .svc = "acm", .op = "list-certificates", .desc = "ACM certificates" },
    .{ .svc = "acm", .op = "describe-certificate", .desc = "certificate details", .ex = "{\"certificate-arn\":\"ARN\"}" },
    .{ .svc = "apigateway", .op = "get-rest-apis", .desc = "REST APIs" },
    .{ .svc = "apigatewayv2", .op = "get-apis", .desc = "HTTP/WebSocket APIs" },
    .{ .svc = "wafv2", .op = "list-web-acls", .desc = "WAF web ACLs", .ex = "{\"scope\":\"REGIONAL\"}" },
    .{ .svc = "autoscaling", .op = "describe-auto-scaling-groups", .desc = "ASGs" },
    // integration / messaging
    .{ .svc = "sqs", .op = "list-queues", .desc = "SQS queues" },
    .{ .svc = "sqs", .op = "get-queue-attributes", .desc = "queue depth etc.", .ex = "{\"queue-url\":\"URL\",\"attribute-names\":[\"All\"]}" },
    .{ .svc = "sns", .op = "list-topics", .desc = "SNS topics" },
    .{ .svc = "sns", .op = "list-subscriptions-by-topic", .desc = "subscriptions", .ex = "{\"topic-arn\":\"ARN\"}" },
    .{ .svc = "stepfunctions", .op = "list-state-machines", .desc = "state machines" },
    .{ .svc = "stepfunctions", .op = "list-executions", .desc = "executions", .ex = "{\"state-machine-arn\":\"ARN\",\"status-filter\":\"FAILED\"}" },
    .{ .svc = "stepfunctions", .op = "describe-execution", .desc = "one execution", .ex = "{\"execution-arn\":\"ARN\"}" },
    .{ .svc = "kinesis", .op = "list-streams", .desc = "Kinesis streams" },
    .{ .svc = "events", .op = "list-event-buses", .desc = "event buses" },
    // config / secrets metadata
    .{ .svc = "ssm", .op = "describe-parameters", .desc = "parameter names/metadata (no values)" },
    .{ .svc = "ssm", .op = "get-parameter", .desc = "read a parameter (with-decryption is blocked)", .ex = "{\"name\":\"/app/x\"}" },
    .{ .svc = "ssm", .op = "get-parameters-by-path", .desc = "parameters under a path", .ex = "{\"path\":\"/app/\",\"recursive\":true}" },
    .{ .svc = "ssm", .op = "describe-instance-information", .desc = "SSM managed instances" },
    .{ .svc = "ssm", .op = "list-commands", .desc = "Run Command history" },
    .{ .svc = "secretsmanager", .op = "list-secrets", .desc = "secret names (values are never returned)" },
    .{ .svc = "secretsmanager", .op = "describe-secret", .desc = "secret metadata", .ex = "{\"secret-id\":\"NAME\"}" },
    .{ .svc = "kms", .op = "list-keys", .desc = "KMS keys" },
    .{ .svc = "kms", .op = "list-aliases", .desc = "KMS aliases" },
    .{ .svc = "kms", .op = "describe-key", .desc = "key metadata", .ex = "{\"key-id\":\"alias/x\"}" },
    .{ .svc = "kms", .op = "get-key-policy", .desc = "key policy", .ex = "{\"key-id\":\"ID\",\"policy-name\":\"default\"}" },
    .{ .svc = "appconfig", .op = "list-applications", .desc = "AppConfig apps" },
    // deployment / infra
    .{ .svc = "cloudformation", .op = "list-stacks", .desc = "stacks", .ex = "{\"stack-status-filter\":[\"CREATE_COMPLETE\",\"UPDATE_COMPLETE\"]}" },
    .{ .svc = "cloudformation", .op = "describe-stacks", .desc = "stack details/outputs", .ex = "{\"stack-name\":\"S\"}" },
    .{ .svc = "cloudformation", .op = "describe-stack-events", .desc = "stack events (debug failures)", .ex = "{\"stack-name\":\"S\"}" },
    .{ .svc = "cloudformation", .op = "list-stack-resources", .desc = "resources of a stack", .ex = "{\"stack-name\":\"S\"}" },
    .{ .svc = "cloudformation", .op = "get-template", .desc = "stack template", .ex = "{\"stack-name\":\"S\"}" },
    .{ .svc = "codebuild", .op = "list-projects", .desc = "CodeBuild projects" },
    .{ .svc = "codebuild", .op = "batch-get-builds", .desc = "build details", .ex = "{\"ids\":[\"proj:id\"]}" },
    .{ .svc = "codepipeline", .op = "list-pipelines", .desc = "pipelines" },
    .{ .svc = "codepipeline", .op = "get-pipeline-state", .desc = "pipeline stage state", .ex = "{\"name\":\"P\"}" },
    .{ .svc = "codecommit", .op = "list-repositories", .desc = "CodeCommit repos" },
    .{ .svc = "elasticbeanstalk", .op = "describe-environments", .desc = "Beanstalk environments" },
    .{ .svc = "glue", .op = "get-databases", .desc = "Glue catalog databases" },
    .{ .svc = "glue", .op = "get-tables", .desc = "tables in a database", .ex = "{\"database-name\":\"D\"}" },
    .{ .svc = "athena", .op = "list-work-groups", .desc = "Athena workgroups" },
    .{ .svc = "athena", .op = "get-query-execution", .desc = "query state", .ex = "{\"query-execution-id\":\"ID\"}" },
    .{ .svc = "athena", .op = "get-query-results", .desc = "query result rows", .ex = "{\"query-execution-id\":\"ID\"}" },
    .{ .svc = "emr", .op = "list-clusters", .desc = "EMR clusters", .ex = "{\"active\":true}" },
    .{ .svc = "sagemaker", .op = "list-endpoints", .desc = "SageMaker endpoints" },
    .{ .svc = "bedrock", .op = "list-foundation-models", .desc = "Bedrock models" },
    // cost / governance
    .{ .svc = "ce", .op = "get-cost-and-usage", .desc = "cost by period/service", .ex = "{\"time-period\":\"Start=2026-01-01,End=2026-02-01\",\"granularity\":\"MONTHLY\",\"metrics\":[\"UnblendedCost\"],\"group-by\":\"Type=DIMENSION,Key=SERVICE\"}" },
    .{ .svc = "budgets", .op = "describe-budgets", .desc = "budgets", .ex = "{\"account-id\":\"123456789012\"}" },
    .{ .svc = "pricing", .op = "get-products", .desc = "price list", .ex = "{\"service-code\":\"AmazonEC2\",\"max-results\":5}" },
    .{ .svc = "service-quotas", .op = "list-service-quotas", .desc = "quotas", .ex = "{\"service-code\":\"ec2\"}" },
    .{ .svc = "resourcegroupstaggingapi", .op = "get-resources", .desc = "find resources by tag", .ex = "{\"tag-filters\":\"Key=Env,Values=prod\"}" },
    .{ .svc = "guardduty", .op = "list-detectors", .desc = "GuardDuty detectors" },
    .{ .svc = "securityhub", .op = "get-findings", .desc = "Security Hub findings (use max_items)" },
    .{ .svc = "inspector2", .op = "list-findings", .desc = "Inspector findings (use max_items)" },
    .{ .svc = "health", .op = "describe-events", .desc = "AWS Health events" },
    .{ .svc = "support", .op = "describe-trusted-advisor-checks", .desc = "Trusted Advisor checks", .ex = "{\"language\":\"en\"}" },
    .{ .svc = "backup", .op = "list-backup-plans", .desc = "Backup plans" },
    .{ .svc = "cognito-idp", .op = "list-user-pools", .desc = "Cognito user pools", .ex = "{\"max-results\":20}" },
    .{ .svc = "cognito-idp", .op = "list-users", .desc = "users of a pool", .ex = "{\"user-pool-id\":\"ID\"}" },
    .{ .svc = "servicediscovery", .op = "list-namespaces", .desc = "Cloud Map namespaces" },
    .{ .svc = "ram", .op = "get-resource-shares", .desc = "RAM shares", .ex = "{\"resource-owner\":\"SELF\"}" },
};

/// Split into lowercase alnum tokens (>=2 chars); plural 's' is stripped.
fn tokenize(alloc: std.mem.Allocator, q: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, q, " \t\r\n,;:/_.-=\"'()[]{}");
    while (it.next()) |raw| {
        const low = try std.ascii.allocLowerString(alloc, raw);
        var t: []const u8 = low;
        if (t.len > 3 and t[t.len - 1] == 's' and t[t.len - 2] != 's') t = t[0 .. t.len - 1];
        if (t.len >= 2) try out.append(alloc, t);
    }
    return out.toOwnedSlice(alloc);
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

fn score(e: Entry, toks: []const []const u8) u32 {
    var s: u32 = 0;
    var matched: u32 = 0;
    for (toks) |t| {
        var m: u32 = 0;
        if (std.mem.eql(u8, e.svc, t)) m += 6 else if (has(e.svc, t)) m += 3;
        if (std.mem.eql(u8, e.op, t)) m += 6 else if (has(e.op, t)) m += 4;
        if (has(e.desc, t)) m += 2;
        if (m > 0) matched += 1;
        s += m;
    }
    // every token matching something beats a lucky single hit
    return if (matched == 0) 0 else s + matched * 2;
}

fn classLetter(e: Entry) u8 {
    return switch (policy.classify(e.svc, e.op)) {
        .deny => 'X',
        .allow => |c| switch (c) {
            .read => 'R',
            .write => 'W',
            .destructive => 'D',
        },
    };
}

pub fn search(alloc: std.mem.Allocator, query: []const u8, max: usize) ![]const u8 {
    const toks = try tokenize(alloc, query);
    const Hit = struct { idx: usize, score: u32 };
    var hits: std.ArrayList(Hit) = .empty;
    for (entries, 0..) |e, i| {
        const s = score(e, toks);
        if (s > 0) try hits.append(alloc, .{ .idx = i, .score = s });
    }
    std.mem.sort(Hit, hits.items, {}, struct {
        fn lt(_: void, a: Hit, b: Hit) bool {
            if (a.score != b.score) return a.score > b.score;
            return a.idx < b.idx;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    if (hits.items.len == 0) {
        try out.appendSlice(alloc, "no match in the bundled hint table. It is only a hint: any read operation works with aws_call (service=<cli service>, operation=describe-*/list-*/get-*). Try broader words or a service name.");
        return out.toOwnedSlice(alloc);
    }
    const n = @min(hits.items.len, max);
    for (hits.items[0..n]) |h| {
        const e = entries[h.idx];
        try out.print(alloc, "{s} {s} [{c}] {s}", .{ e.svc, e.op, classLetter(e), e.desc });
        if (e.ex.len > 0) try out.print(alloc, " e.g. {s}", .{e.ex});
        try out.append(alloc, '\n');
    }
    try out.appendSlice(alloc, "(hint table, not exhaustive; R=read W=write D=destructive; params keys are the CLI flag names without --)");
    return out.toOwnedSlice(alloc);
}

test "every catalog entry is valid, unique and not denied" {
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    var nb: [160]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (entries) |e| {
        try std.testing.expect(policy.checkName("service", e.svc, &nb) == null);
        try std.testing.expect(policy.checkName("operation", e.op, &nb) == null);
        try std.testing.expect(classLetter(e) != 'X');
        const key = try std.fmt.allocPrint(arena.allocator(), "{s}/{s}", .{ e.svc, e.op });
        try std.testing.expect(!seen.contains(key));
        try seen.put(key, {});
        // "WRITE:"/"DESTRUCTIVE:" descriptions must match the classifier
        if (std.mem.startsWith(u8, e.desc, "WRITE:")) try std.testing.expect(classLetter(e) == 'W');
        if (std.mem.startsWith(u8, e.desc, "DESTRUCTIVE:")) try std.testing.expect(classLetter(e) == 'D');
        if (e.ex.len > 0 and e.ex[0] == '{') {
            // examples that are pure JSON must parse
            if (std.mem.indexOf(u8, e.ex, "} args=") == null) {
                var p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, e.ex, .{});
                p.deinit();
            }
        }
    }
    try std.testing.expect(entries.len >= 140);
}

test "search ranks relevant entries first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try search(a, "list ec2 instances", 5);
    try std.testing.expect(std.mem.startsWith(u8, r, "ec2 describe-instances"));
    const r2 = try search(a, "lambda function environment", 3);
    try std.testing.expect(std.mem.indexOf(u8, r2, "lambda get-function-configuration") != null);
    const r3 = try search(a, "zzzzqq", 3);
    try std.testing.expect(std.mem.indexOf(u8, r3, "no match") != null);
    const r4 = try search(a, "terminate instance", 3);
    try std.testing.expect(std.mem.indexOf(u8, r4, "[D]") != null);
}
