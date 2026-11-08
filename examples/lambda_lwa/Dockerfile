# syntax=docker/dockerfile:1
# AWS Lambda image (Lambda Web Adapter + Puma) for a Rails 7.1+ app. Based on the Dockerfile that
# `rails new` generates; the lines that matter for cold starts are marked with "cold start".
ARG RUBY_VERSION=3.4.7
FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS base
WORKDIR /rails

# cold start: single-process Puma. A Lambda execution environment handles one request at a time,
# so a few threads are enough.
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    WEB_CONCURRENCY=0 \
    RAILS_MAX_THREADS=3 \
    PORT=3000 \
    AWS_LWA_PORT=3000 \
    AWS_LWA_READINESS_CHECK_PATH=/up

FROM base AS build
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# The app is copied before `bundle install` because a path gem (the CI copy of hayaoki in
# vendor/hayaoki) must exist at that point. With `gem "hayaoki"` from rubygems you can
# copy only Gemfile and Gemfile.lock first, as the generated Dockerfile does.
COPY . .
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

# cold start: precompile the bootsnap cache at build time, so the first boot does not pay for it.
RUN bundle exec bootsnap precompile --gemfile && \
    bundle exec bootsnap precompile app/ lib/

FROM base
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails
RUN mkdir -p log tmp

# Lambda Web Adapter runs as a Lambda extension. Outside Lambda /opt/extensions is not used,
# so the image also runs as a plain container (this is how CI runs it).
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter

# Optional: for boot times that can exceed about 9.8 s, so the 10 s Init limit is not hit.
# ENV AWS_LWA_ASYNC_INIT=true

# Lambda's file system is read-only except /tmp, so writes under /rails/tmp fail on Lambda.
# Logs go to stdout (CloudWatch Logs).
EXPOSE 3000
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
