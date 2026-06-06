FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund || true

COPY relay.js ./

ENV NODE_ENV=production
ENV PORT=8085
EXPOSE 8085

USER node

CMD ["node", "relay.js"]
