# Lab 2 - Murano Voley Connect

## Integrantes
- Camilo Velasquez
- Samuel Delgado

## Emprendimiento
**Murano Voley Connect** - Evolucion de la plataforma Murano Voley hacia una arquitectura de microservicios escalable y resiliente en AWS para la comunidad de volleyball del sur de Chile.

## Infraestructura AWS (ECS Fargate)
| Recurso | Detalle |
|---------|---------|
| VPC | vpc-0d422bb15ed40e678 |
| Cluster ECS | murano-cluster |
| Launch Type | Fargate (Serverless) |
| Balanceador | Application Load Balancer (ALB) |
| Registro | Amazon ECR |
| Despliegue | Multi-AZ (Alta Disponibilidad) |
| Escalado | 4 Tareas Running |

## URL del sitio (ALB DNS)
http://murano-alb-850757385.us-east-1.elb.amazonaws.com

## Instrucciones para ejecutar deploy.sh
1. Entrar a la carpeta de infraestructura.
2. Asegurarse de tener configurado AWS CLI.
3. Ejecutar: `chmod +x deploy.sh && ./deploy.sh`

## Estructura del repositorio
lab2-murano-voley/
├── infraestructura/
│   ├── deploy.sh
│   ├── cleanup.sh
│   └── taskdef.json
├── sitio-web/
│   ├── index.html
│   └── Dockerfile
├── documentacion/
│   ├── Informe_Laboratorio_2_Velasquez_Delgado.docx
│   ├── arquitectura.png
│   └── capturas/
└── README.md
