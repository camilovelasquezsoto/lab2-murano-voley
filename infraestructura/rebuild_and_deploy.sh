#!/bin/bash
# rebuild_and_deploy.sh
# Reconstruye la imagen Docker via CodeBuild y fuerza el redeploy en ECS
set -e

export AWS_REGION=us-east-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REPO_NAME=murano-voley-connect
export IMG_TAG=1.1
export CLUSTER_NAME=murano-cluster
export SERVICE_NAME=murano-svc
export CODEBUILD_PROJECT=murano-build
export CODEBUILD_ROLE=murano-codebuild-role
export SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "╔══════════════════════════════════════════╗"
echo "║   Murano Voley — Rebuild & Redeploy      ║"
echo "╠══════════════════════════════════════════╣"
echo "  Account : $ACCOUNT_ID"
echo "  Region  : $AWS_REGION"
echo "  Repo    : $REPO_NAME:$IMG_TAG"
echo "  Cluster : $CLUSTER_NAME"
echo "╚══════════════════════════════════════════╝"

# ── Paso 1: Crear rol IAM para CodeBuild (si no existe) ──────────────────────
echo ""
echo "▶ Paso 1: Verificando rol IAM de CodeBuild..."

if ! aws iam get-role --role-name $CODEBUILD_ROLE &>/dev/null; then
  echo "  → Creando rol $CODEBUILD_ROLE..."
  aws iam create-role \
    --role-name $CODEBUILD_ROLE \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' > /dev/null

  aws iam attach-role-policy \
    --role-name $CODEBUILD_ROLE \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

  aws iam attach-role-policy \
    --role-name $CODEBUILD_ROLE \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess

  # Inline policy for ECR token
  aws iam put-role-policy \
    --role-name $CODEBUILD_ROLE \
    --policy-name codebuild-ecr-inline \
    --policy-document '{
      "Version":"2012-10-17",
      "Statement":[
        {"Effect":"Allow","Action":["ecr:GetAuthorizationToken","ecr:BatchCheckLayerAvailability",
         "ecr:GetDownloadUrlForLayer","ecr:BatchGetImage","ecr:PutImage",
         "ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload"],
         "Resource":"*"}
      ]
    }'

  echo "  → Esperando propagación del rol (10s)..."
  sleep 10
else
  echo "  → Rol ya existe, continuando."
fi

ROLE_ARN=$(aws iam get-role --role-name $CODEBUILD_ROLE --query Role.Arn --output text)
echo "  ✓ Rol: $ROLE_ARN"

# ── Paso 2: Empaquetar el código fuente en S3 ────────────────────────────────
echo ""
echo "▶ Paso 2: Empaquetando fuente y subiendo a S3..."

BUCKET="murano-build-src-${ACCOUNT_ID}"

# Crear bucket si no existe
if ! aws s3api head-bucket --bucket $BUCKET 2>/dev/null; then
  aws s3api create-bucket --bucket $BUCKET --region $AWS_REGION > /dev/null
  echo "  → Bucket creado: s3://$BUCKET"
fi

# Empaquetar sitio-web (Dockerfile + index.html) + buildspec
TMPDIR=$(mktemp -d)
cp "$SRC_DIR/sitio-web/Dockerfile" "$TMPDIR/"
cp "$SRC_DIR/sitio-web/index.html" "$TMPDIR/"
cp "$SRC_DIR/infraestructura/buildspec.yml" "$TMPDIR/buildspec.yml"

zip -j "$TMPDIR/source.zip" "$TMPDIR/Dockerfile" "$TMPDIR/index.html" "$TMPDIR/buildspec.yml" > /dev/null
aws s3 cp "$TMPDIR/source.zip" "s3://$BUCKET/source.zip" > /dev/null
rm -rf "$TMPDIR"
echo "  ✓ Fuente subida a s3://$BUCKET/source.zip"

# ── Paso 3: Crear/actualizar proyecto CodeBuild ──────────────────────────────
echo ""
echo "▶ Paso 3: Configurando proyecto CodeBuild..."

PROJECT_JSON=$(cat <<JSON
{
  "name": "$CODEBUILD_PROJECT",
  "source": {
    "type": "S3",
    "location": "$BUCKET/source.zip"
  },
  "artifacts": { "type": "NO_ARTIFACTS" },
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/standard:7.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": true,
    "environmentVariables": [
      {"name":"AWS_REGION",   "value":"$AWS_REGION"},
      {"name":"AWS_ACCOUNT_ID","value":"$ACCOUNT_ID"},
      {"name":"REPO_NAME",    "value":"$REPO_NAME"},
      {"name":"IMG_TAG",      "value":"$IMG_TAG"}
    ]
  },
  "serviceRole": "$ROLE_ARN"
}
JSON
)

if aws codebuild batch-get-projects --names $CODEBUILD_PROJECT --query "projects[0].name" --output text 2>/dev/null | grep -q $CODEBUILD_PROJECT; then
  aws codebuild update-project --cli-input-json "$PROJECT_JSON" > /dev/null
  echo "  → Proyecto actualizado."
else
  aws codebuild create-project --cli-input-json "$PROJECT_JSON" > /dev/null
  echo "  → Proyecto creado."
fi

# ── Paso 4: Iniciar build y esperar ──────────────────────────────────────────
echo ""
echo "▶ Paso 4: Iniciando build en CodeBuild..."

BUILD_ID=$(aws codebuild start-build \
  --project-name $CODEBUILD_PROJECT \
  --query "build.id" --output text)

echo "  Build ID: $BUILD_ID"
echo "  Esperando que termine (puede tardar ~2-3 min)..."

while true; do
  STATUS=$(aws codebuild batch-get-builds --ids $BUILD_ID \
    --query "builds[0].buildStatus" --output text)
  echo "  → Status: $STATUS"
  if [[ "$STATUS" == "SUCCEEDED" ]]; then
    echo "  ✓ Build exitoso."
    break
  elif [[ "$STATUS" == "FAILED" || "$STATUS" == "FAULT" || "$STATUS" == "TIMED_OUT" || "$STATUS" == "STOPPED" ]]; then
    echo "  ✗ Build falló con status: $STATUS"
    echo "  Ver logs en CloudWatch Logs: /aws/codebuild/$CODEBUILD_PROJECT"
    exit 1
  fi
  sleep 15
done

# ── Paso 5: Actualizar task definition con nueva imagen ──────────────────────
echo ""
echo "▶ Paso 5: Actualizando Task Definition con imagen $IMG_TAG..."

NEW_IMAGE="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO_NAME:$IMG_TAG"

# Obtener la task def actual y crear una nueva revisión con la imagen actualizada
CURRENT_TASKDEF=$(aws ecs describe-services \
  --cluster $CLUSTER_NAME --services $SERVICE_NAME \
  --query "services[0].taskDefinition" --output text)

aws ecs describe-task-definition --task-definition $CURRENT_TASKDEF \
  --query "taskDefinition" > /tmp/taskdef_current.json

python3 -c "
import json
with open('/tmp/taskdef_current.json') as f:
    td = json.load(f)
td['containerDefinitions'][0]['image'] = '$NEW_IMAGE'
# Remove fields that can't be re-registered
for k in ['taskDefinitionArn','revision','status','requiresAttributes','compatibilities','registeredAt','registeredBy']:
    td.pop(k, None)
with open('/tmp/taskdef_new.json','w') as f:
    json.dump(td, f)
print('Task def prepared.')
"

NEW_TD_ARN=$(aws ecs register-task-definition \
  --cli-input-json file:///tmp/taskdef_new.json \
  --query "taskDefinition.taskDefinitionArn" --output text)
echo "  ✓ Nueva task definition: $NEW_TD_ARN"

# ── Paso 6: Force redeploy del servicio ──────────────────────────────────────
echo ""
echo "▶ Paso 6: Forzando redeploy del servicio ECS..."

aws ecs update-service \
  --cluster $CLUSTER_NAME \
  --service $SERVICE_NAME \
  --task-definition "$NEW_TD_ARN" \
  --force-new-deployment > /dev/null

echo "  Esperando estabilización del servicio..."
aws ecs wait services-stable --cluster $CLUSTER_NAME --services $SERVICE_NAME
echo "  ✓ Servicio estable con nueva imagen."

# ── Verificación final ───────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo "  ✓ Redeploy completado exitosamente"
echo "══════════════════════════════════════════"
aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME \
  --query "services[0].{Running:runningCount,Desired:desiredCount,Pending:pendingCount}" \
  --output table

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?LoadBalancerName=='murano-alb'].DNSName" --output text)
echo ""
echo "  🌐 URL: http://$ALB_DNS"
echo ""
