# 1. Base image: small Linux + Node.js 20
FROM node:20-alpine

# 2. Work inside /app in the image
WORKDIR /app

# 3. Copy ONLY dependency manifests first so Docker caches the npm layer
COPY package*.json ./

# 4. Install production dependencies only
RUN npm install --omit=dev

# 5. Copy the rest of the source code
COPY . .

# 6. Don't run as root (security best practice)
USER node

# 7. Document the port the app listens on
EXPOSE 3000

# 8. Command that starts the container
CMD ["node", "server.js"]
