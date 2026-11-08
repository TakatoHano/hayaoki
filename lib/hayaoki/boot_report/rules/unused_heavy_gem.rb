# frozen_string_literal: true
require "set"

require_relative "base"
require_relative "dev_gems_in_production"

module Hayaoki
  module BootReport
    module Rules
      # 重い gem の定数が app/ config/ lib/ から参照されていない (require: false の候補)。
      class UnusedHeavyGem < Base
        SEARCH_DIRS = %w[app config lib].freeze
        SEARCH_EXTS = %w[.rb .erb .rake .haml .slim .jbuilder .ru].freeze
        SEARCH_ROOT_FILES = %w[config.ru Rakefile].freeze
        MAX_FILE_BYTES = 2_000_000

        EXCLUDED = (%w[
          rails railties activesupport activerecord activemodel actionpack actionview actionmailer actioncable
          activejob activestorage actiontext actionmailbox bootsnap zeitwerk bundler rubygems rack i18n
          concurrent-ruby tzinfo mutex_m bigdecimal drb base64 logger
        ]).freeze
        # Railtie やアダプタ経由で使われ、定数を直接書かないことが多い gem (誤検出を避けるため対象外)
        IMPLICIT_USE = %w[
          puma pg mysql2 sqlite3 sprockets sprockets-rails sass-rails sassc sassc-rails propshaft importmap-rails
          turbo-rails stimulus-rails jbuilder tailwindcss-rails jsbundling-rails cssbundling-rails
          solid_cache solid_queue solid_cable tzinfo-data kamal thruster net-imap net-smtp net-pop
        ].freeze
        # APM / 監視系: Railtie や Rack middleware 経由で動くため定数参照が無くても使われている
        APM_GEMS = %w[newrelic_rpm ddtrace datadog scout_apm skylight honeybadger bugsnag rollbar appsignal].freeze
        APM_PREFIXES = %w[sentry- opentelemetry-].freeze
        # gem が提供する DSL 名 (定数でなくクラス本体のマクロとして使われるもの)。小さく明示的に保つ
        DSL_NAMES = {
          "paper_trail" => %w[has_paper_trail], "carrierwave" => %w[mount_uploader mount_uploaders],
          "friendly_id" => %w[friendly_id], "acts-as-taggable-on" => %w[acts_as_taggable_on acts_as_taggable],
          "acts_as_list" => %w[acts_as_list], "ancestry" => %w[has_ancestry], "rolify" => %w[rolify],
          "searchkick" => %w[searchkick], "counter_culture" => %w[counter_culture],
          "devise" => %w[devise_for devise], "audited" => %w[audited], "aasm" => %w[aasm],
          "enumerize" => %w[enumerize],
        }.freeze
        # 既知の定数名 (gem 名から機械的に導けないもの)
        KNOWN_CONSTANTS = {
          "httparty" => %w[HTTParty], "aws-sdk-s3" => %w[Aws::S3 Aws], "aws-sdk" => %w[Aws],
          "nokogiri" => %w[Nokogiri], "rest-client" => %w[RestClient], "activeadmin" => %w[ActiveAdmin],
          "google-cloud-storage" => %w[Google::Cloud::Storage], "mini_magick" => %w[MiniMagick],
          "ruby-vips" => %w[Vips], "image_processing" => %w[ImageProcessing], "rqrcode" => %w[RQRCode],
          "redcarpet" => %w[Redcarpet], "kaminari" => %w[Kaminari], "elasticsearch" => %w[Elasticsearch],
          "stripe" => %w[Stripe], "sentry-ruby" => %w[Sentry], "sentry-rails" => %w[Sentry],
        }.freeze

        def call
          return [] unless gemfile_entries # Gemfile が無ければ直接依存か判定できないので提案しない
          cands = candidates
          return [] if cands.empty?
          used = referenced(cands)
          cands.reject { |c| used.include?(c[:name]) }.sort_by { |c| -c[:ms] }.map do |c|
            suggestion(:low,
                       title: "No references found to #{c[:name]} in app code (#{round(c[:ms])} ms at boot)",
                       evidence: [{ "gem" => c[:name], "self_ms" => round(c[:ms]), "searched_tokens" => c[:tokens] }],
                       savings: c[:ms],
                       action: "If it is not needed at boot, consider loading it lazily in the Gemfile:\n" \
                               "  gem \"#{c[:name]}\", require: false\n" \
                               "and `require \"#{c[:name]}\"` where it is first needed. This is a static text search: " \
                               "it can miss use via metaprogramming, other gems, rake tasks outside the searched " \
                               "directories, or Railtie hooks, so please verify before changing.")
          end
        end

        private

        def candidates
          entries = gemfile_entries
          ctx.gems.filter_map do |g|
            name = get(g, :name).to_s
            ms = med(get(g, :self_ms))
            next unless get(g, :category).to_s == "gem" && ms && ms > ctx.gem_threshold_ms
            next if EXCLUDED.include?(name) || IMPLICIT_USE.include?(name) || DevGemsInProduction.dev_gem?(name)
            next if apm?(name) || railtie?(g, name)
            if entries
              entry = entries[name]
              next unless entry # 間接依存は Gemfile で require: false にできない
              next if entry.require == false # 既に lazy
              next if entry.require.is_a?(Array) && !entry.require.empty? # 別名で require されている
            end
            given = Array(get(g, :constants)).map(&:to_s).reject(&:empty?)
            tokens = (given.empty? ? guess_constants(name) : given) + DSL_NAMES.fetch(name, [])
            { name: name, ms: ms, tokens: tokens.uniq }
          end
        end

        def apm?(name) = APM_GEMS.include?(name) || APM_PREFIXES.any? { name.start_with?(_1) }

        # Railtie / Engine を持つ gem は初期化時に自動で組み込まれるので、定数参照が無くても使われている。
        # 計測結果 (gem が initializer を定義している / on_load の時間が gem に計上されている) か、gem 内の railtie.rb / engine.rb で判定する。
        def railtie?(g, name)
          return true if (med(get(g, :initializer_count)) || 0) > 0 || (med(get(g, :on_load_ms)) || 0) > 0
          railtie_files?(name)
        end

        def railtie_files?(name)
          path = gem_paths[name] || Gem.loaded_specs[name]&.full_gem_path or return false # 子プロセスの記録を優先
          Dir.glob(File.join(path, "lib", "**", "{railtie,engine}.rb")).any?
        rescue StandardError
          false
        end

        # gem 名 → 定数名の候補 (ゆるい方に倒す: 一つでも見つかれば「使われている」とみなす)
        def guess_constants(name)
          return KNOWN_CONSTANTS[name] if KNOWN_CONSTANTS.key?(name)
          parts = name.split(/[-]/)
          camel = ->(s) { s.split("_").map { |w| w[0].to_s.upcase + w[1..].to_s }.join }
          toks = [parts.map(&camel).join("::"), parts.map(&camel).join]
          # rack-attack → Rack のように先頭だけでは広すぎるので、単一セグメントの gem 名だけ
          toks << camel.call(parts.first) if parts.size == 1
          toks << name # require "foo-bar" の文字列
          toks.uniq
        end

        # 各ファイルを 1 回だけ読み、全トークンをまとめた正規表現で比べる。使われていた gem 名の Set を返す。
        def referenced(cands)
          owner = Hash.new { |h, k| h[k] = [] }
          cands.each { |c| c[:tokens].each { |t| owner[t.downcase] << c[:name] } }
          re = Regexp.new("(?<![A-Za-z0-9_])(#{owner.keys.sort_by { |k| -k.size }.map { |k| Regexp.escape(k) }.join("|")})(?![A-Za-z0-9_])", Regexp::IGNORECASE)
          used = Set.new
          each_source_file do |path|
            text = File.binread(path).force_encoding(Encoding::UTF_8).scrub
            text.scan(re) { |(tok)| owner[tok.downcase].each { |n| used << n } }
            return used if used.size >= cands.size
          end
          used
        end

        def each_source_file
          root = ctx.app_dir.to_s
          files = SEARCH_DIRS.flat_map do |d|
            Dir.glob(File.join(root, d, "**", "*{#{SEARCH_EXTS.join(",")}}"), File::FNM_DOTMATCH)
          end
          files += SEARCH_ROOT_FILES.map { |f| File.join(root, f) }
          files.uniq.each do |path|
            next unless File.file?(path)
            next if File.size(path) > MAX_FILE_BYTES
            yield path
          rescue SystemCallError
            next
          end
        end
      end
    end
  end
end
