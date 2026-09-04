FROM nginx:1.30.4-alpine-slim

RUN rm -f /usr/share/nginx/html/50x.html /usr/share/nginx/html/index.html

COPY nginx.conf /etc/nginx/nginx.conf
COPY --chown=nginx:nginx index.html styles.css script.js site.webmanifest /usr/share/nginx/html/
COPY --chown=nginx:nginx assets/ /usr/share/nginx/html/assets/

USER nginx

EXPOSE 8080

ENTRYPOINT []

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://127.0.0.1:8080/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
