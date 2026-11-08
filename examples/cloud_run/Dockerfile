# syntax=docker/dockerfile:1
# Cloud Run image for a Rails 7.1+ app. Based on the Dockerfile that `rails new` generates;
# the lines that matter for cold starts are marked with "cold start".
ARG RUBY_VERSION=3.4.7
FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS base
WORKDIR /rails

# cold start: single-process Puma. RAILS_MAX_THREADS must equal containerConcurrency in service.yaml.
ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    WEB_CONCURRENCY=0 \
    RAILS_MAX_THREADS=8 \
    PORT=8080

FROM base AS build
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Copy only the dependency files first so the `bundle install` layer is cached. `rails new` creates
# vendor/ (with .keep), so the COPY works for any generated app; CI puts a path gem in vendor/hayaoki.
COPY Gemfile Gemfile.lock ./
COPY vendor/ vendor/
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git
COPY . .

# cold start: precompile the bootsnap cache at build time, so the first boot does not pay for it.
RUN bundle exec bootsnap precompile --gemfile && \
    bundle exec bootsnap precompile app/ lib/

FROM base
COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p log tmp && \
    chown -R rails:rails log tmp
USER 1000:1000

EXPOSE 8080
CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
