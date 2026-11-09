# syntax=docker/dockerfile:1
# Redmine 7.0 with SQLite baked in at build time (as in .github/workflows/real-apps.yml) plus hayaoki.
# Build with --target cloud_run or --target lambda. Context: this Dockerfile + puma.rb.
FROM redmine:7.0 AS base
USER root
WORKDIR /usr/src/redmine
ENV RAILS_ENV=production WEB_CONCURRENCY=0 RAILS_MAX_THREADS=8 DB_PATH=db/production.sqlite3
RUN printf 'production:\n  adapter: sqlite3\n  database: <%%= ENV.fetch("DB_PATH", "db/production.sqlite3") %%>\n' > config/database.yml && \
    { printf 'gem "hayaoki", "0.3.1", require: false\n'; grep -q '"puma"' Gemfile || printf 'gem "puma"\n'; } > Gemfile.local && \
    bundle install && \
    SECRET_KEY_BASE=build-only bundle exec rake db:migrate && \
    sed -i "/bundler\/setup/a require 'hayaoki/insitu'" config/boot.rb && grep -q hayaoki/insitu config/boot.rb
COPY puma.rb config/puma.rb
RUN chown -R redmine:redmine /usr/src/redmine

FROM base AS cloud_run
ENV PORT=8080
USER redmine
EXPOSE 8080
ENTRYPOINT []
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]

FROM base AS lambda
ENV PORT=3000 AWS_LWA_PORT=3000 AWS_LWA_READINESS_CHECK_PATH=/up RAILS_MAX_THREADS=3 DB_PATH=/tmp/rm/redmine.sqlite3
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter
# Lambda's file system is read-only except /tmp: point the writable Redmine dirs at /tmp and copy the DB there at start.
# files/ is a VOLUME in the base image and cannot be removed during build; attachments_storage_path moves it instead.
RUN mv db/production.sqlite3 /opt/production.sqlite3 && rm -rf tmp log public/plugin_assets && \
    ln -s /tmp/rm/tmp tmp && ln -s /tmp/rm/log log && ln -s /tmp/rm/plugin_assets public/plugin_assets && \
    printf 'production:\n  attachments_storage_path: /tmp/rm/files\n' > config/configuration.yml
USER redmine
EXPOSE 3000
ENTRYPOINT []
CMD ["sh", "-c", "mkdir -p /tmp/rm/tmp/cache /tmp/rm/tmp/sessions /tmp/rm/tmp/sockets /tmp/rm/tmp/pdf /tmp/rm/tmp/thumbnails /tmp/rm/log /tmp/rm/files /tmp/rm/plugin_assets && cp /opt/production.sqlite3 /tmp/rm/redmine.sqlite3 && exec bundle exec puma -C config/puma.rb"]
