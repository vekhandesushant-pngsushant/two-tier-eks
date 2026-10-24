# ---------- Stage 1: install dependencies ----------
FROM node:20-alpine AS deps
WORKDIR /usr/src/app
COPY package*.json ./
RUN npm install --omit=dev && npm cache clean --force

# ---------- Stage 2: small runtime image ----------
FROM node:20-alpine
ENV NODE_ENV=production
WORKDIR /usr/src/app
COPY --from=deps /usr/src/app/node_modules ./node_modules
COPY package*.json ./
COPY src ./src
COPY public ./public
# Run as non-root user (security best practice)
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://localhost:3000/health || exit 1
CMD ["node", "src/server.js"]
