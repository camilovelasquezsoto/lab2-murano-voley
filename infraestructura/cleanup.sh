#!/bin/bash
# Script de limpieza para el Laboratorio 2
export CLUSTER_NAME=murano-cluster
export SERVICE_NAME=murano-svc
export ALB_ARN=arn:aws:elasticloadbalancing:us-east-1:656751413705:loadbalancer/app/murano-alb/fac7df414fd5c848
export TG_ARN=arn:aws:elasticloadbalancing:us-east-1:656751413705:targetgroup/murano-tg/21bbf7c437deb279
export REPO_NAME=murano-voley-connect

echo "--- Iniciando limpieza de recursos ---"
aws ecs update-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --desired-count 0
aws ecs delete-service --cluster $CLUSTER_NAME --service $SERVICE_NAME --force
aws ecs delete-cluster --cluster $CLUSTER_NAME

# Listener se borra con el ALB
aws elbv2 delete-load-balancer --load-balancer-arn $ALB_ARN
aws elbv2 delete-target-group --target-group-arn $TG_ARN
aws ecr delete-repository --repository-name $REPO_NAME --force

echo "--- Limpieza completada ---"
