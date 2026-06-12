#!/bin/bash
set -e

# --- Paso 0: Configurar variables ---
export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REPO_NAME=murano-voley-connect
export IMG_TAG=1.0
export VPC_ID=vpc-0d422bb15ed40e678
export SUBNET_1=subnet-04839cffc918efe07
export SUBNET_2=subnet-066fc39cf0bcd55fc
export SG_ID=sg-04686f36c8730bb02
export CLUSTER_NAME=murano-cluster
export SERVICE_NAME=murano-svc

echo "--- Paso 1: Publicar en Amazon ECR ---"
# (Nota: En este lab se uso CodeBuild por falta de Docker local, pero el comando estandar seria:)
# aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
# docker build -t $REPO_NAME:$IMG_TAG .
# docker tag $REPO_NAME:$IMG_TAG $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO_NAME:$IMG_TAG
# docker push $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO_NAME:$IMG_TAG

echo "--- Paso 2: Crear Infraestructura de Red y Balanceador ---"
TG_ARN=$(aws elbv2 create-target-group --name murano-tg --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type ip --query "TargetGroups[0].TargetGroupArn" --output text)
ALB_ARN=$(aws elbv2 create-load-balancer --name murano-alb --subnets $SUBNET_1 $SUBNET_2 --security-groups $SG_ID --query "LoadBalancers[0].LoadBalancerArn" --output text)
aws elbv2 create-listener --load-balancer-arn $ALB_ARN --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$TG_ARN

echo "--- Paso 3: Despliegue en ECS / Fargate ---"
aws ecs create-cluster --cluster-name $CLUSTER_NAME --capacity-providers FARGATE
aws ecs register-task-definition --cli-input-json file://taskdef.json

aws ecs create-service \
  --cluster $CLUSTER_NAME --service-name $SERVICE_NAME \
  --task-definition murano-task --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$SG_ID],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=murano-web,containerPort=80"

echo "Esperando a que el servicio sea estable..."
aws ecs wait services-stable --cluster $CLUSTER_NAME --services $SERVICE_NAME

echo "--- Paso 4: Verificacion y Escalado ---"
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $ALB_ARN --query "LoadBalancers[0].DNSName" --output text)
echo "El sitio esta disponible en: http://$ALB_DNS"

echo "Escalando a 4 tareas..."
aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 4

echo "--- Despliegue Completado ---"
