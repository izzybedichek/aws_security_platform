FROM node:20-alpine

WORKDIR /app

# Install deps first so this layer is cached unless package files change.
COPY package*.json ./
RUN npm install --omit=dev

# App source (test-vulnerable.js is excluded via .dockerignore).
COPY . .

EXPOSE 3000

# Drop root for least privilege; node:alpine ships a non-root "node" user.
USER node

CMD ["node", "server.js"]
