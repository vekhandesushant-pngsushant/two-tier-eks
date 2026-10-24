FROM mysql:8.0
# Scripts in this folder run ONLY on first start (when data dir is empty)
COPY init.sql /docker-entrypoint-initdb.d/01-init.sql
EXPOSE 3306
