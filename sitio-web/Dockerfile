# Usamos el mirror de ECR Public para evitar limites de Docker Hub
FROM public.ecr.aws/nginx/nginx:1.27-alpine

# Copiamos el contenido estatico al directorio de Nginx
COPY index.html /usr/share/nginx/html/index.html

# Exponemos el puerto 80
EXPOSE 80
