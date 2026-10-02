"""Regenerate the architecture diagrams: pip install diagrams (needs Graphviz), then python generate.py"""
from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECR, EKS, ECS, EC2, EC2AutoScaling, Fargate, Lambda
from diagrams.aws.database import Dynamodb, RDS
from diagrams.aws.devtools import Codebuild, Codedeploy, Codepipeline
from diagrams.aws.integration import SNS
from diagrams.aws.management import Cloudformation, Cloudtrail, Cloudwatch, CloudwatchAlarm, CloudwatchLogs, SystemsManager
from diagrams.aws.network import ALB, APIGateway, CloudFront
from diagrams.aws.security import KMS, SecretsManager
from diagrams.aws.storage import S3
from diagrams.onprem.ci import Jenkins
from diagrams.onprem.client import Users
from diagrams.onprem.iac import Terraform
from diagrams.onprem.vcs import Github

GRAPH = {"fontsize": "20", "pad": "0.4", "splines": "spline"}


def architecture():
    with Diagram("Feedback Board - Architecture", filename="architecture", show=False, direction="LR", graph_attr=GRAPH):
        users = Users("Users")
        with Cluster("Serverless (CloudFormation)"):
            cdn = CloudFront("CloudFront")
            site = S3("Static site")
            api = APIGateway("HTTP API")
            fn = Lambda("Feedback API")
            table = Dynamodb("DynamoDB\n(PITR, KMS)")
            cdn >> site
            cdn >> Edge(label="/api/*") >> api >> fn >> table
        with Cluster("Dashboard - one image, three runtimes"):
            alb = ALB("ALB\n:80 prod / :8080 test / :8000 EC2")
            with Cluster("ECS Fargate (blue/green)"):
                ecs = [Fargate("blue"), Fargate("green")]
            with Cluster("EC2 Auto Scaling (in-place)"):
                asg = EC2AutoScaling("ASG")
                db = RDS("RDS PostgreSQL")
            eks = EKS("EKS")
            alb >> ecs
            alb >> asg >> db
        users >> cdn
        users >> alb
        users >> eks
        ecs[0] >> Edge(style="dashed") >> table
        with Cluster("Foundation (Terraform)"):
            Terraform("Terraform") - [KMS("KMS CMK"), Cloudtrail("CloudTrail"), ECR("ECR"), SNS("SNS alerts")]


def pipeline():
    with Diagram("Task 1 - CI/CD Pipeline", filename="pipeline", show=False, direction="LR", graph_attr=GRAPH):
        gh = Github("GitHub\n(main)")
        with Cluster("AWS CodePipeline (V2)"):
            src = Codepipeline("Source\nCodeConnections")
            build = Codebuild("Build\npytest · pip-audit\ndocker · cfn package")
            approve = SNS("Manual approval\n(SNS email)")
            with Cluster("Deploy"):
                cfn = Cloudformation("Serverless stack")
                cd = Codedeploy("ECS blue/green")
                web = S3("Publish site")
        gh >> src >> build >> approve >> [cfn, cd]
        cfn >> web
        build >> ECR("ECR\nscan on push")
        cd >> ECS("Fargate service")
        with Cluster("EC2 track"):
            jenkins = Jenkins("Jenkins")
            jenkins >> Codedeploy("CodeDeploy\nin-place") >> EC2AutoScaling("ASG")
        gh >> Edge(label="poll") >> jenkins


def bluegreen():
    with Diagram("Task 3 - Blue/Green Deployment", filename="bluegreen", show=False, direction="LR", graph_attr=GRAPH):
        users = Users("Users")
        cd = Codedeploy("CodeDeploy\nECSCanary10Percent5Minutes")
        with Cluster("Application Load Balancer"):
            prod = ALB("Prod listener :80")
            test = ALB("Test listener :8080")
        with Cluster("Blue target group (v1)"):
            blue = Fargate("tasks v1")
        with Cluster("Green target group (v2)"):
            green = Fargate("tasks v2")
        users >> prod
        prod >> Edge(label="90%") >> blue
        prod >> Edge(label="10% canary", color="darkgreen") >> green
        test >> Edge(style="dashed") >> green
        alarms = CloudwatchAlarm("5xx / UnHealthyHost\nalarms")
        green >> Edge(label="health checks /health") >> alarms
        alarms >> Edge(label="auto-rollback", color="red") >> cd
        cd >> Edge(label="shift traffic") >> prod


def logging():
    with Diagram("Task 5 - Centralized Logging", filename="logging", show=False, direction="LR", graph_attr=GRAPH):
        with Cluster("Sources (JSON log lines)"):
            sources = [Lambda("Lambda"), APIGateway("API access logs"), Fargate("ECS dashboard"),
                       EC2("EC2 (CW agent)"), Codebuild("CodeBuild")]
        logs = CloudwatchLogs("CloudWatch Logs\n/feedback-board/*\nKMS, 7-day retention")
        filters = Cloudwatch("Metric filters\nerrors · 5xx · latency\nTraceback pattern")
        alarm = CloudwatchAlarm("Alarms")
        sources >> logs >> filters >> alarm >> SNS("SNS -> email")
        filters >> Cloudwatch("Dashboard")
        logs >> Edge(label="saved queries") >> Cloudwatch("Logs Insights")
        Cloudtrail("CloudTrail") >> S3("Trail bucket")


if __name__ == "__main__":
    for draw in (architecture, pipeline, bluegreen, logging):
        draw()
