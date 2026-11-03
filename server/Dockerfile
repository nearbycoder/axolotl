FROM node:24-alpine
WORKDIR /app
COPY package.json server.mjs ./
ENV PORT=8787 DATA_DIR=/data NODE_ENV=production
VOLUME /data
EXPOSE 8787
USER node
CMD ["node", "server.mjs"]
