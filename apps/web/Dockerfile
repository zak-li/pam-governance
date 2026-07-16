# --- build the Angular app ---
FROM node:20-alpine AS build
WORKDIR /src
COPY package.json ./
RUN npm install --no-audit --no-fund
COPY . .
RUN npm run build

# Bake the Auth0 domain into the Content Security Policy at build time so the
# served config is self-consistent. deploy-app.sh passes it as a build arg.
ARG AUTH0_DOMAIN=dev-k5xncag6gzsmst88.eu.auth0.com
RUN sed "s|__AUTH0_DOMAIN__|$AUTH0_DOMAIN|g" default.conf.template > default.conf

# --- serve on a non-root nginx ---
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY --from=build /src/default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/dist/app/browser /usr/share/nginx/html
EXPOSE 8080
